import AppleBusiness
import AppleModels
import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Synchronization
import Testing
import TestSupport
import Vault
import Wire

/// A client wired to a strict `AppleStub`, a memory Vault holding a fresh key, and a sleep that records
/// instead of waiting.
struct Harness {
    let stub: AppleStub
    let client: AppleClient
    let store: MemoryStore
    let vault: Vault
    let limiter: RateLimiter
    let sleeps: Recorder

    static let clientID = "BUSINESSAPI.00000000-0000-4000-8000-000000000001"
    static let keyID = "00000000-0000-4000-8000-0000000000aa"

    init(scope: Scope = .business, teamID: String = "", devices: Int = 0, pageCap: Int = AppleClient.defaultPageCap,
         registerKey: P256.Signing.PrivateKey? = nil, bodyLimit: Int = HTTPClient.bodyLimit) async throws {
        let key = P256.Signing.PrivateKey()
        stub = AppleStub()
        stub.register(AppleStub.Account(clientID: Self.clientID, keyID: Self.keyID, teamID: teamID, scope: scope.rawValue,
                                        publicKey: (registerKey ?? key).publicKey))
        store = MemoryStore()
        vault = Vault(store: store)
        try await vault.storeKey(KeyImport.importForTests(key), as: VaultItem(org: "acme", kind: .appleKey)!)
        let sleeps = Recorder()
        self.sleeps = sleeps
        // The limiter's sleeps move its own clock: a no-op sleep on the real clock spins until real time refills it.
        let clock = ManualClock()
        limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        client = AppleClient(account: TokenBroker.Account(org: "acme", scope: scope, clientID: Self.clientID, keyID: Self.keyID, teamID: teamID),
                             vault: vault, transport: stub, limiter: limiter, pageCap: pageCap, bodyLimit: bodyLimit,
                             sleep: { duration in sleeps.value.withLock { $0.append(duration) } })
        stub.add(devices: (0..<devices).map(Self.device))
    }

    static func device(_ index: Int) -> Resource {
        let serial = String(format: "TESTD%07d", index)
        return Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string("MacBook Air"), "productFamily": .string(index % 3 == 0 ? "Mac" : "iPhone"),
            "status": .string("ASSIGNED"), "addedToOrgDateTime": .string("2025-04-30T22:05:14.192Z"),
        ])
    }

    static func service(_ id: String, name: String) -> Resource {
        Resource(type: "mdmServers", id: id, attributes: ["serverName": .string(name), "serverType": .string("MDM"), "status": .string("ACTIVE"),
                                                          "deviceCount": .number("2"), "lastConnectedDateTime": .string("2026-10-01T00:00:00Z")])
    }

    func allDevices() async throws -> [OrgDevice] {
        var found: [OrgDevice] = []
        for try await page in client.devices() { found += page.items }
        return found
    }
}

extension KeyImport {
    /// A key made in the test, as an import would hand it over.
    static func importForTests(_ key: P256.Signing.PrivateKey) throws -> ImportedKey {
        try parse(Secret(key.pemRepresentation))
    }
}

/// The sleeps a client asked for, instead of sleeping.
final class Recorder: Sendable {
    let value = Mutex<[Duration]>([])
    var all: [Duration] { value.withLock { $0 } }
}

extension Harness {
    /// The resources of Apple's own example answer (`Tests/Fixtures/docc/business/<name>.response.json`): a list's items, or
    /// the single item.
    static func example(_ name: String) throws -> [Resource] {
        try Document.parse(Data(contentsOf: Fixtures.docc.appending(path: "business/\(name).response.json"))).resources
    }

    /// What the stub answers a GET the client would never build (another parameter, a bad value), sent with this org's
    /// token straight to the stub: its own checks, not the client's, decide.
    func raw(_ path: String, _ query: [(String, String)] = [], host: APIHost = .appleBusiness) async throws -> (status: Int, body: JSONValue?) {
        let broker = TokenBroker(account: await client.account, vault: vault, http: HTTPClient(transport: stub, limiter: RateLimiter(sleep: { _ in })))
        var request = URLRequest(url: try #require(URL.make(host: host, path: path, query: query.map { QueryItem($0.0, $0.1) })))
        for (name, value) in try await broker.headers(for: host) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await stub.send(request, limit: 1 << 24)
        return (response.statusCode, JSONValue.parse(String(decoding: data, as: UTF8.self)))
    }

    /// Every page of `stream`'s items.
    static func all<Item>(_ stream: AsyncThrowingStream<Page<Item>, any Error>) async throws -> [Item] {
        var items: [Item] = []
        for try await page in stream { items += page.items }
        return items
    }

    /// The GETs the stub was sent (the token requests left out).
    var reads: [String] { stub.requests.filter { $0.hasPrefix("GET ") } }
}
