import CryptoKit
import Foundation
import Security
import Synchronization
import Testing
@testable import Vault

@Suite("Vault")
struct VaultTests {
    static let org = "example-business"
    static let key = VaultItem(org: org, kind: .appleKey)!
    static let token = VaultItem(org: org, kind: .mosyleAccessToken)!

    @Test func aSecretNeverPrintsItsBytes() {
        let secret = Secret("hunter2-hunter2")
        #expect(String(describing: secret) == "<secret: 15 bytes>")
        #expect(String(reflecting: secret) == "<secret: 15 bytes>")
        #expect(Mirror(reflecting: secret).children.isEmpty)
        var dumped = ""
        dump(secret, to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }

    @Test func anOrgNameCantSteerTheKeychainAccount() {
        #expect(VaultItem(org: "Example", kind: .appleKey) == nil)
        #expect(VaultItem(org: "a/b", kind: .appleKey) == nil)
        #expect(VaultItem(org: "", kind: .appleKey) == nil)
        #expect(VaultItem(org: String(repeating: "a", count: 65), kind: .appleKey) == nil)
        #expect(VaultItem(org: "acme-2", kind: .appleKey)?.description == "acme-2/apple-key")
    }

    @Test func theStoredKeySignsAndTheSignatureIsRawAndVerifies() async throws {
        let store = MemoryStore(), vault = Vault(store: store)
        let key = P256.Signing.PrivateKey()
        try await vault.storeKey(KeyImport.parseForTests(key), as: Self.key)
        let message = Data("header.payload".utf8)
        let signature = try await vault.sign(message, with: Self.key)
        #expect(signature.count == 64)
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
    }

    @Test func noKeyIsMissingButARefusedPromptIsAnError() async throws {
        let store = MemoryStore(), vault = Vault(store: store)
        await #expect(throws: VaultError.missing(Self.key)) { try await vault.sign(Data(), with: Self.key) }
        try await vault.storeKey(KeyImport.parseForTests(P256.Signing.PrivateKey()), as: Self.key)
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement] {
            store.failNext(.sign, with: status)
            await #expect(throws: VaultError.keychain(status)) { try await vault.sign(Data(), with: Self.key) }
        }
        store.failNext(.read, with: errSecUserCanceled)
        await #expect(throws: VaultError.keychain(errSecUserCanceled)) { try await vault.optionalSecret(Self.token) }
        #expect(try await vault.optionalSecret(Self.token) == nil)
    }

    @Test func theSessionEndsAfterItsLifetimeMeasuredOnAClockThatCountsSleep() async throws {
        let store = MemoryStore()
        let clock = Mutex(ContinuousClock.now)
        let vault = Vault(store: store, sessionLifetime: .seconds(600), now: { clock.withLock { $0 } })
        try await vault.store(Secret("t"), as: Self.token)
        _ = try await vault.secret(Self.token)
        clock.withLock { $0 = $0.advanced(by: .seconds(599)) }
        _ = try await vault.secret(Self.token)
        #expect(store.sessionsEnded == 0)
        clock.withLock { $0 = $0.advanced(by: .seconds(2)) }
        _ = try await vault.secret(Self.token)
        #expect(store.sessionsEnded == 1)
    }

    @Test func aSetIsWholeOrAbsent() async throws {
        let store = MemoryStore(), vault = Vault(store: store)
        let set: [VaultItem.Kind: Secret?] = [.mosyleAccessToken: Secret("a"), .mosyleEmail: Secret("b"),
                                              .mosylePassword: Secret("c"), .mosyleLogsToken: nil]
        try await vault.replaceSet(set, for: Self.org)
        #expect(try await vault.inventory()[Self.org] == [.mosyleAccessToken, .mosyleEmail, .mosylePassword])
        // A locked Mac refuses the second write: nothing of the set is left behind, old or new.
        store.failNext(.write, with: errSecInteractionNotAllowed, skipping: 1)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) {
            try await vault.replaceSet([.mosyleAccessToken: Secret("x"), .mosyleEmail: Secret("y"), .mosylePassword: Secret("z")],
                                       for: Self.org)
        }
        #expect(try await vault.inventory()[Self.org] == nil)
    }

    @Test func removingStopsAtTheFirstRefusalAndRemovesTheKeyFirst() async throws {
        let store = MemoryStore(), vault = Vault(store: store)
        try await vault.storeKey(KeyImport.parseForTests(P256.Signing.PrivateKey()), as: Self.key)
        try await vault.store(Secret("t"), as: Self.token)
        store.failNext(.delete, with: errSecInteractionNotAllowed, skipping: 1)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) { try await vault.remove(org: Self.org) }
        let left = try await vault.inventory()[Self.org]
        #expect(left == [.mosyleAccessToken], "the key went first; the refusal stopped the rest")
        try await vault.remove(org: Self.org)
        #expect(try await vault.inventory()[Self.org] == nil)
    }

    @Test func aWriteBackNeverResurrectsARemovedSecret() async throws {
        let store = MemoryStore(), vault = Vault(store: store)
        try await vault.store(Secret("old"), as: Self.token)
        #expect(try await vault.refresh(Secret("new"), as: Self.token, replacing: Secret("old")))
        try await vault.remove(org: Self.org)
        #expect(try await !vault.refresh(Secret("newer"), as: Self.token, replacing: Secret("new")))
        #expect(try await vault.optionalSecret(Self.token) == nil)
    }

    @Test func theGuidanceSaysWhatToDo() {
        #expect(VaultError.keychain(errSecMissingEntitlement).guidance.contains("Sign it with your team"))
        #expect(VaultError.keychain(errSecInteractionNotAllowed).guidance.contains("Unlock your Mac"))
        #expect(!VaultError.missing(Self.key).guidance.contains("example-business"))
    }
}
