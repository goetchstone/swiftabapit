import AppleBusiness
import AppleModels
import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Synchronization
import TestSupport
import Vault

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
         registerKey: P256.Signing.PrivateKey? = nil) async throws {
        let key = P256.Signing.PrivateKey()
        stub = AppleStub()
        stub.register(AppleStub.Account(clientID: Self.clientID, keyID: Self.keyID, teamID: teamID, scope: scope.rawValue,
                                        publicKey: (registerKey ?? key).publicKey))
        store = MemoryStore()
        vault = Vault(store: store)
        try await vault.storeKey(KeyImport.importForTests(key), as: VaultItem(org: "acme", kind: .appleKey)!)
        let sleeps = Recorder()
        self.sleeps = sleeps
        limiter = RateLimiter(readsPerMinute: 600, sleep: { _ in })
        client = AppleClient(account: TokenBroker.Account(org: "acme", scope: scope, clientID: Self.clientID, keyID: Self.keyID, teamID: teamID),
                             vault: vault, transport: stub, limiter: limiter, pageCap: pageCap,
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
