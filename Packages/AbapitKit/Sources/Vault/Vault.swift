import CryptoKit
import Dispatch
import Foundation

/// The app's secrets: one `SecretStore` (the Keychain in the app, memory for the demo and tests). It holds
/// no copy of any secret itself: every use goes to the store, and the store's shared authentication
/// session keeps that to one prompt per burst. Adapted from SwiftGamGui
/// Packages/GamKit/Sources/Vault/Vault.swift @ bfdb494.
public actor Vault {
    /// How long one authentication covers uses (plan D6). Measured on `ContinuousClock`, which keeps
    /// counting while the Mac sleeps (GamGUI failure-log 2026-09-24: an expiry that paused during sleep).
    public static let defaultSessionLifetime: Duration = .seconds(600)

    private let store: any SecretStore
    private let sessionLifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var sessionStarted: ContinuousClock.Instant?

    /// The Keychain, for the app.
    public init(store: KeychainStore, sessionLifetime: Duration = Vault.defaultSessionLifetime) {
        self.init(secretStore: store, sessionLifetime: sessionLifetime)
    }

    #if DEBUG
    /// Memory, for the demo org and tests: debug builds only, with `MemoryStore`.
    public init(store: MemoryStore, sessionLifetime: Duration = Vault.defaultSessionLifetime,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.init(secretStore: store, sessionLifetime: sessionLifetime, now: now)
    }
    #endif

    package init(secretStore store: any SecretStore, sessionLifetime: Duration = Vault.defaultSessionLifetime,
                 now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.store = store
        self.sessionLifetime = sessionLifetime
        self.now = now
    }

    /// A session past its lifetime is ended before the next use, so that use prompts again.
    private func beginUse() {
        if let started = sessionStarted, now() - started >= sessionLifetime { lock() }
    }

    private func used() { sessionStarted = sessionStarted ?? now() }

    // MARK: using secrets (package: the clients, never the app)

    /// A stored secret (Mosyle's token, email, password); `missing` when it isn't stored.
    package func secret(_ item: VaultItem) async throws -> Secret {
        beginUse()
        let data = try await offMainThread { [store] in try store.read(item) }
        used()
        guard let data else { throw VaultError.missing(item) }
        return Secret(data)
    }

    /// The optional secret (the Logs Stream token): nil when it isn't stored, any other failure thrown.
    package func optionalSecret(_ item: VaultItem) async throws -> Secret? {
        do {
            return try await secret(item)
        } catch VaultError.missing {
            return nil
        }
    }

    /// An ES256 signature, raw `r‖s`, by the org's stored key: the key never leaves the Keychain.
    package func sign(_ message: Data, with item: VaultItem) async throws -> Data {
        beginUse()
        let signature = try await offMainThread { [store] in try store.sign(message, with: item) }
        used()
        guard let signature else { throw VaultError.missing(item) }
        return signature
    }

    // MARK: storing and removing (public: Settings does this)

    /// Stores a parsed Apple key (`KeyImport`), replacing the org's old one.
    public func storeKey(_ key: ImportedKey, as item: VaultItem) async throws {
        guard item.kind.isKey else { throw VaultError.wrongKind(item.kind) }
        beginUse()
        try await offMainThread { [store] in try store.storeKey(key.key, as: item) }
    }

    /// Creates or replaces one secret (never a key: those go through `storeKey`).
    public func store(_ secret: Secret, as item: VaultItem) async throws {
        guard !item.kind.isKey else { throw VaultError.wrongKind(item.kind) }
        beginUse()
        try await offMainThread { [store] in try store.write(secret.bytes, as: item) }
    }

    /// Makes `set` the org's whole set of those kinds (Mosyle's four): a kind given as nil is removed. A set
    /// is whole or absent: when a write fails part-way (a refused prompt, a locked Mac), every kind in `set`
    /// is removed rather than left a mix of old and new. If that removal is refused too, its error is thrown,
    /// since something is still stored.
    public func replaceSet(_ set: [VaultItem.Kind: Secret?], for org: String) async throws {
        let items = try set.keys.sorted().map { kind in
            guard let item = VaultItem(org: org, kind: kind) else { throw VaultError.keyNotUsable }
            guard !kind.isKey else { throw VaultError.wrongKind(kind) }
            return (item, set[kind] ?? nil)
        }
        do {
            for (item, secret) in items {
                if let secret {
                    try await store(secret, as: item)
                } else {
                    try await offMainThread { [store] in try store.delete(item) }
                }
            }
        } catch {
            // Every kind of the set is removed, each tried even when another is refused, so what stays is at most
            // the refused items, never old and new mixed (Phase 1a's review). The first refusal is thrown, since
            // something is still stored; else the write's own error.
            var refused: (any Error)?
            for kind in VaultItem.Kind.removalOrder where set.keys.contains(kind) {
                guard let item = VaultItem(org: org, kind: kind) else { continue }
                do {
                    try await offMainThread { [store] in try store.delete(item) }
                } catch {
                    refused = refused ?? error
                }
            }
            throw refused ?? error
        }
    }

    /// Replaces a secret only while it still holds `original`: a removed one stays removed, and one replaced
    /// meanwhile keeps its new value. Returns whether it replaced anything.
    @discardableResult
    package func refresh(_ secret: Secret, as item: VaultItem, replacing original: Secret) async throws -> Bool {
        beginUse()
        return try await offMainThread { [store] in try store.replace(secret.bytes, as: item, ifCurrent: original.bytes) }
    }

    /// What each org has stored, by kind: names only, never a prompt.
    public func inventory() async throws -> [String: Set<VaultItem.Kind>] {
        try await offMainThread { [store] in try store.inventory() }
    }

    /// Removes everything the org has stored, the most dangerous first. Stops at the first refusal, so an
    /// org is never reported gone while something of it is still stored.
    public func remove(org: String) async throws {
        for kind in VaultItem.Kind.removalOrder {
            guard let item = VaultItem(org: org, kind: kind) else { continue }
            try await offMainThread { [store] in try store.delete(item) }
        }
        try await offMainThread { [store] in try store.forget(org: org) }
    }

    /// Ends the authenticated session: the next use prompts again.
    public func lock() {
        store.endSession()
        sessionStarted = nil
    }

    /// Keychain calls can block on a Touch ID prompt: run them on a GCD thread, never on the cooperative
    /// pool or the main thread.
    private func offMainThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

#if DEBUG
extension Vault {
    /// Debug builds only, for the app's vault spike: a signature by the stored key, as a token mint makes one.
    /// `sign(_:with:)` itself is `package`, so the app can't sign with an org's key.
    public func signForSpike(_ message: Data, with item: VaultItem) async throws -> Data {
        precondition(item.org == "swiftabapit-spike", "the spike signs only with its throwaway org's key")
        return try await sign(message, with: item)
    }
}
#endif
