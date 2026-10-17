import AppleBusiness
import AppModels
import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Synchronization
import Testing
import TestSupport
import Vault

/// Two Apple Business orgs, `a` and `b`, each with its own strict `AppleStub` behind a `Gate`, a memory Vault
/// holding their keys, and the three screen models over them, as the app builds them (Phase 1b review M6: the
/// screen models had no tests). Adapted from the review's race tests (scratchpad review1b/racepkg).
@MainActor
struct World {
    let orgs: OrgsModel
    let devices: DevicesModel
    let detail: DeviceDetailModel
    let stubs: [String: AppleStub]
    let gates: [String: Gate]
    let store: MemoryStore
    /// The memory store as the Vault sees it, with a hold on the next key write.
    let keychain: MemoryStore
    let vault: Vault
    let keys: [String: P256.Signing.PrivateKey]
    let stall: Stall

    static func clientID(_ org: String) -> String { "BUSINESSAPI.00000000-0000-4000-8000-0000000000\(org == "a" ? "a1" : org == "b" ? "b1" : "c1")" }
    static func keyID(_ org: String) -> String { "00000000-0000-4000-8000-0000000000\(org == "a" ? "a2" : org == "b" ? "b2" : "c2")" }
    static func prefix(_ org: String) -> String { org.uppercased() + "DEV" }

    /// `devices` per org, serials `ADEV0000000…`; `rates` are the profiles' learned rates; `profiles` replaces the
    /// two Apple orgs' profiles (an unusable org, none at all).
    static func make(devices: [String: Int] = ["a": 3, "b": 2], rates: [String: Double] = [:], pageCap: Int = AppleClient.defaultPageCap,
                     profiles: [OrgProfile]? = nil) async throws -> World {
        let keychain = MemoryStore()
        let vault = Vault(store: keychain)
        var stubs: [String: AppleStub] = [:], gates: [String: Gate] = [:], keys: [String: P256.Signing.PrivateKey] = [:]
        var orgStore = OrgStore()
        for org in ["a", "b"] {
            let key = P256.Signing.PrivateKey()
            keys[org] = key
            try await vault.storeKey(KeyImport.parse(Secret(key.pemRepresentation)), as: VaultItem(org: org, kind: .appleKey)!)
            let stub = AppleStub()
            stub.register(AppleStub.Account(clientID: clientID(org), keyID: keyID(org), publicKey: key.publicKey))
            stub.add(devices: (0..<(devices[org] ?? 0)).map { device(prefix(org), $0) })
            stubs[org] = stub
            gates[org] = Gate(stub)
            if profiles == nil { try orgStore.add(profile(org, rate: rates[org] ?? 0)) }
        }
        for profile in profiles ?? [] { try orgStore.add(profile) }
        orgStore.activeID = orgStore.orgs.first?.id
        let routes = gates, stall = Stall()
        // The limiter's sleeps move its own clock, and the client's retry sleeps return at once: nothing here
        // waits on real time but the gates and the stall.
        let orgs = OrgsModel(storage: .memory, vault: vault, store: orgStore) { account, rate in
            let clock = ManualClock(), clientID = account.clientID
            // An org a test adds is served by org a's stub, where the test registers its account.
            return AppleClient(account: account, vault: vault, transport: routes[account.org] ?? routes["a"]!,
                               limiter: RateLimiter(readsPerMinute: rate ?? 600, now: { stall.pass(clientID); return clock.now },
                                                    sleep: { clock.advance($0) }),
                               pageCap: pageCap, sleep: { _ in })
        }
        return World(orgs: orgs, devices: DevicesModel(orgs: orgs), detail: DeviceDetailModel(orgs: orgs), stubs: stubs, gates: gates,
                     store: keychain, keychain: keychain, vault: vault, keys: keys, stall: stall)
    }

    /// Org `org`'s profile as the world makes it: Apple Business, its own client and key IDs.
    static func profile(_ org: String, rate: Double = 0) -> OrgProfile {
        var profile = OrgProfile(id: org, name: "Org \(org)", provider: .apple)
        profile.scope = .known(.business)
        profile.clientID = clientID(org)
        profile.keyID = keyID(org)
        profile.learnedReadsPerMinute = rate
        return profile
    }

    /// An org this version can't read: a scope it doesn't know.
    static let unusable = OrgProfile(raw: ["id": .string("district"), "name": .string("District"), "provider": .string("apple"),
                                           "scope": .string("district"), "client_id": .string("SCHOOLAPI.x"), "key_id": .string("k")])

    static func device(_ prefix: String, _ index: Int) -> Resource {
        let serial = String(format: "\(prefix)%07d", index)
        return Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string("MacBook Air"), "productFamily": .string("Mac"),
            "status": .string("ASSIGNED"), "addedToOrgDateTime": .string("2025-04-30T22:05:14.192Z"),
        ])
    }

    static func service(_ id: String, name: String) -> Resource {
        Resource(type: "mdmServers", id: id, attributes: ["serverName": .string(name), "serverType": .string("MDM"), "status": .string("ACTIVE"),
                                                          "lastConnectedDateTime": .string("2026-10-01T00:00:00Z")])
    }

    /// A key as the editor's file import hands it over.
    static func imported(_ key: P256.Signing.PrivateKey) throws -> ImportedKey { try KeyImport.parse(Secret(key.pemRepresentation)) }

    /// Waits for both halves of every load started so far, the superseded ones too, to have returned.
    func settled(_ reads: Int) async {
        await eventually("\(reads) reads finished, \(devices.readsFinished) so far") { devices.readsFinished >= reads }
    }

    /// Releases `name` on `org`'s gate while holding the main actor until the stub has answered `count` more requests,
    /// and a little longer: what was answered waits, unread, in the old load's stream, for a loop a switch or a
    /// Refresh is about to cancel (a cancelled loop can still be handed it).
    func buffer(_ org: String, release name: String, count: Int = 1) {
        let gate = gates[org]!, answered = gate.answered
        gate.release(name)
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while gate.answered < answered + count, clock.now < end { usleep(500) }
        usleep(200_000)
    }

    /// Whether `org`'s stored key is the one its stub trusts: a token mints and a read answers.
    func keyWorks(_ org: String) async -> Bool {
        guard let profile = orgs.store[org], let client = orgs.client(for: profile) else { return false }
        do {
            try await client.ping()
            return true
        } catch {
            return false
        }
    }
}

/// Polls `condition` on the main actor; the bound is only how long to wait, never what is measured.
@MainActor
func eventually(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
    let clock = ContinuousClock(), end = clock.now + timeout
    while !condition() {
        if clock.now > end {
            Issue.record("timed out waiting: \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// The strict stub behind a gate: a request a hold matches waits, cancellably, until the hold is released, as a
/// slow tenant's page does. A released request is answered by the stub alone; the gate invents nothing.
final class Gate: Transport, Sendable {
    let stub: AppleStub
    private let holds = Mutex<[String: @Sendable (URL) -> Bool]>([:])
    private let waiting = Mutex(0)
    private let forwarded = Mutex(0)

    init(_ stub: AppleStub) { self.stub = stub }

    func hold(_ name: String, _ matches: @escaping @Sendable (URL) -> Bool) { holds.withLock { $0[name] = matches } }
    func release(_ name: String) { holds.withLock { $0[name] = nil } }
    /// Requests waiting at the gate now, and requests the stub has answered.
    var held: Int { waiting.withLock { $0 } }
    var answered: Int { forwarded.withLock { $0 } }

    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        if let url = request.url, isHeld(url) {
            waiting.withLock { $0 += 1 }
            defer { waiting.withLock { $0 -= 1 } }
            while isHeld(url) { try await Task.sleep(for: .milliseconds(2)) }
        }
        defer { forwarded.withLock { $0 += 1 } }
        return try await stub.send(request, limit: limit)
    }

    private func isHeld(_ url: URL) -> Bool { holds.withLock { $0.values.contains { $0(url) } } }

    /// Device pages after the first: the walk is under way and has more to read.
    static let laterDevicePages: @Sendable (URL) -> Bool = { $0.path() == "/v1/orgDevices" && ($0.query() ?? "").contains("cursor=") }
    static let devicePages: @Sendable (URL) -> Bool = { $0.path() == "/v1/orgDevices" }
}

/// Stalls the rate limiter of the client made for one client ID: its clock blocks until released, holding that
/// limiter's actor, so a read of the learned rate waits there, as it would behind a slow limiter. Nothing else waits.
final class Stall: Sendable {
    private let target = Mutex<String?>(nil)
    private let inside = Mutex(false)

    func hold(_ clientID: String) { target.withLock { $0 = clientID } }
    func release() { target.withLock { $0 = nil } }
    /// Whether a limiter is stalled now.
    var entered: Bool { inside.withLock { $0 } }

    func pass(_ clientID: String) {
        guard target.withLock({ $0 == clientID }) else { return }
        inside.withLock { $0 = true }
        while target.withLock({ $0 == clientID }) { usleep(500) }
        inside.withLock { $0 = false }
    }
}

/// A clock only the limiter's sleeps move.
final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ by: Duration) { instant.withLock { $0 = $0.advanced(by: by) } }
}
