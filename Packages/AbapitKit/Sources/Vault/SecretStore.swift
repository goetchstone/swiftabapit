import CryptoKit
import Foundation
import Security
import Synchronization

/// Where secrets live. Adapted from SwiftGamGui Packages/GamKit/Sources/Vault/SecretStore.swift @ bfdb494,
/// generalized from GAM's three files to `VaultItem`s, with key items an Apple key signs through.
///
/// `read` and `sign` return nil only for "no such item"; every other failure throws. `package`: only the
/// Vault (and AbapitKit's tests) touch secret bytes; the app picks a store and hands it to `Vault`.
package protocol SecretStore: Sendable {
    /// A generic password's value.
    func read(_ item: VaultItem) throws -> Data?
    /// Creates the item or replaces its value in place. Never deletes first: a failed write must leave
    /// the old value stored.
    func write(_ data: Data, as item: VaultItem) throws
    /// Replaces a value only while it still holds `expected`, read and replaced as one step; creates
    /// nothing. Returns whether it did.
    func replace(_ data: Data, as item: VaultItem, ifCurrent expected: Data) throws -> Bool
    /// Stores a P-256 key as a Keychain key item behind user presence. Replaces an existing one.
    func storeKey(_ key: P256.Signing.PrivateKey, as item: VaultItem) throws
    /// An ES256 signature of `message` by the stored key, raw `r‖s` (64 bytes), or nil when there is no key.
    func sign(_ message: Data, with item: VaultItem) throws -> Data?
    /// Removing an item that isn't there is not an error; any other failure throws.
    func delete(_ item: VaultItem) throws
    /// Each org with something stored, and what: from a name-only index, never secret data, never a prompt.
    func inventory() throws -> [String: Set<VaultItem.Kind>]
    /// Drops the org from the index once its items are all removed.
    func forget(org: String) throws
    /// Ends the authenticated session, so the next use asks for Touch ID or the password again.
    func endSession()
}

#if DEBUG
/// An in-memory store for tests and the demo org. A failure can be queued per operation with the exact
/// `OSStatus` the Keychain returns, so callers are tested against real failures, not just absence:
/// -25300 not found, -128 cancelled, -25293 auth failed, -25308 interaction not allowed (also a locked
/// Mac), -34018 missing entitlement (plan §6.3).
///
/// Debug builds only (invariant 3: a Release app keeps keys in the Keychain). Public and in every build, it was
/// picked unnamed: `Vault(store: .init(), now: …)` resolves to the one initializer that takes `now:`, this
/// store's, and a Release app built from it kept the org's key in memory past every scan and the gate (Phase 1b
/// gates verifier round 1). Compiled out, that is a compile error in Release.
public final class MemoryStore: SecretStore {
    public enum Operation: Sendable, Hashable { case read, write, storeKey, sign, delete, inventory }

    private struct State {
        var values: [VaultItem: Data] = [:]
        var keys: [VaultItem: P256.Signing.PrivateKey] = [:]
        var failures: [Operation: (status: OSStatus, skipping: Int)] = [:]
        var uses = 0
        var sessionsEnded = 0
        var keyHold = KeyHold()
    }

    private struct KeyHold { var armed = false, released = false, waiting = 0 }

    private let state = Mutex(State())

    public init() {}

    /// The next call of `operation`, after `skipping` that succeed, throws `VaultError.keychain(status)`.
    public func failNext(_ operation: Operation, with status: OSStatus, skipping: Int = 0) {
        state.withLock { $0.failures[operation] = (status, skipping) }
    }

    /// The next `storeKey` waits, off the caller's thread as a Keychain call runs, until `releaseKeyHold()`: a test then
    /// acts inside a save's Keychain window rather than racing it. It lives here, not in a wrapper store, because the
    /// screen models' tests sit in another package and see only this public API (Phase 1b review).
    /// A write still waiting keeps waiting; a hold left unreleased gives up after `keyHoldLimit`, so a test that throws
    /// before releasing doesn't leave a thread spinning for the rest of the run.
    public func holdNextKey() {
        state.withLock {
            $0.keyHold.armed = true
            $0.keyHold.released = false
        }
    }
    public static let keyHoldLimit: Duration = .seconds(10)
    public func releaseKeyHold() { state.withLock { $0.keyHold.released = true } }
    /// Key writes waiting at the hold now.
    public var keysWaiting: Int { state.withLock { $0.keyHold.waiting } }

    /// Reads and signatures so far: what a session would have prompted for.
    public var useCount: Int { state.withLock { $0.uses } }
    public var sessionsEnded: Int { state.withLock { $0.sessionsEnded } }

    private func check(_ operation: Operation, in state: inout State) throws {
        guard let failure = state.failures[operation] else { return }
        if failure.skipping > 0 {
            state.failures[operation] = (failure.status, failure.skipping - 1)
            return
        }
        state.failures[operation] = nil
        throw VaultError.keychain(failure.status)
    }

    package func read(_ item: VaultItem) throws -> Data? {
        try state.withLock { state in
            state.uses += 1
            try check(.read, in: &state)
            return state.values[item]
        }
    }

    package func write(_ data: Data, as item: VaultItem) throws {
        try state.withLock { state in
            try check(.write, in: &state)
            state.values[item] = data
        }
    }

    package func replace(_ data: Data, as item: VaultItem, ifCurrent expected: Data) throws -> Bool {
        try state.withLock { state in
            try check(.write, in: &state)
            guard state.values[item] == expected else { return false }
            state.values[item] = data
            return true
        }
    }

    package func storeKey(_ key: P256.Signing.PrivateKey, as item: VaultItem) throws {
        let held = state.withLock { state in
            defer { state.keyHold.armed = false }
            if state.keyHold.armed { state.keyHold.waiting += 1 }
            return state.keyHold.armed
        }
        if held {
            let deadline = ContinuousClock.now.advanced(by: Self.keyHoldLimit)
            while !state.withLock({ $0.keyHold.released }), ContinuousClock.now < deadline { usleep(500) }
            state.withLock { $0.keyHold.waiting -= 1 }
        }
        try state.withLock { state in
            try check(.storeKey, in: &state)
            state.keys[item] = key
        }
    }

    package func sign(_ message: Data, with item: VaultItem) throws -> Data? {
        try state.withLock { state in
            state.uses += 1
            try check(.sign, in: &state)
            return try state.keys[item].map { try $0.signature(for: message).rawRepresentation }
        }
    }

    package func delete(_ item: VaultItem) throws {
        try state.withLock { state in
            try check(.delete, in: &state)
            state.values[item] = nil
            state.keys[item] = nil
        }
    }

    package func inventory() throws -> [String: Set<VaultItem.Kind>] {
        try state.withLock { state in
            try check(.inventory, in: &state)
            var found: [String: Set<VaultItem.Kind>] = [:]
            for item in Array(state.values.keys) + Array(state.keys.keys) { found[item.org, default: []].insert(item.kind) }
            return found
        }
    }

    /// Nothing to drop: the inventory is read from the items themselves.
    package func forget(org: String) throws {}

    package func endSession() {
        state.withLock { $0.sessionsEnded += 1 }
    }
}
#endif
