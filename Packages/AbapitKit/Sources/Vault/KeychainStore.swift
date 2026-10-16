import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Secrets in the data-protection Keychain: this device only, never synced, each item behind a
/// user-presence check (Touch ID or the login password). Needs a team-signed, provisioned build
/// (`Config/abapit-Team.entitlements`); an ad-hoc build gets `errSecMissingEntitlement` (-34018) on every
/// call, sandboxed or not (spike S1, docs/domains/auth-keychain.md). Adapted from SwiftGamGui
/// Packages/GamKit/Sources/Vault/KeychainStore.swift @ bfdb494, with key items added.
///
/// - Mosyle's secrets are generic passwords: service `swiftabapit`, account `<org>/<kind>`.
/// - An Apple key is a `kSecClassKey` item tagged `<org>/apple-key`: the Keychain signs with it, and its
///   private bytes are never read back out (Apple's "Storing CryptoKit keys in the Keychain").
/// - A name-only index (service `swiftabapit.orgs`, account `<org>`, the kinds stored as its data, no
///   user presence) answers "what is stored" without a prompt: listing the items themselves asked for
///   Touch ID in SwiftGamGui.
///
/// One `LAContext` is shared until `endSession()`, so one authentication covers a burst of uses instead of
/// a prompt per item. Every call that touches an item runs under its lock, which also serializes prompts.
/// Calls block while a prompt is up: never call this on the main thread.
public final class KeychainStore: SecretStore {
    public static let defaultService = "swiftabapit"

    public let service: String
    private let context: Mutex<LAContext>

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
        context = Mutex(Self.newContext())
    }

    private static func newContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = "use your organization's API credentials"
        return context
    }

    private var indexService: String { "\(service).orgs" }

    // Queries are made fresh from Sendable parts wherever the shared context goes into one, inside its lock:
    // a dictionary from outside the lock would carry the context out of it (Swift 6 region isolation).
    private static func passwordQuery(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecUseDataProtectionKeychain: true]
    }

    private static func keyQuery(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassKey, kSecAttrApplicationTag: Data("\(service)/\(account)".utf8),
         kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecUseDataProtectionKeychain: true]
    }

    private func passwordQuery(_ item: VaultItem) -> [CFString: Any] { Self.passwordQuery(service: service, account: item.account) }
    private func keyQuery(_ item: VaultItem) -> [CFString: Any] { Self.keyQuery(service: service, account: item.account) }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    private static func userPresence() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw VaultError.accessControlUnavailable
        }
        return access
    }

    // MARK: generic passwords

    package func read(_ item: VaultItem) throws -> Data? {
        precondition(!item.kind.isKey, "a key is used to sign, never read")
        let service = service, account = item.account
        let (status, data) = context.withLock { context -> (OSStatus, Data?) in
            var query = Self.passwordQuery(service: service, account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
        switch status {
        case errSecSuccess: return data
        case errSecItemNotFound: return nil
        default: throw VaultError.keychain(status)
        }
    }

    package func write(_ data: Data, as item: VaultItem) throws {
        precondition(!item.kind.isKey, "a key is stored with storeKey")
        try index(item)
        if try update(data, as: item) { return }
        var add = passwordQuery(item)
        add[kSecValueData] = data
        add[kSecAttrAccessControl] = try Self.userPresence()
        add[kSecAttrLabel] = "abapit: \(item.org) \(item.kind.rawValue)"
        let status = context.withLock { _ in SecItemAdd(add as CFDictionary, nil) }
        if status == errSecDuplicateItem, try update(data, as: item) { return }
        try Self.check(status)
    }

    package func replace(_ data: Data, as item: VaultItem, ifCurrent expected: Data) throws -> Bool {
        let service = service, account = item.account
        let status = context.withLock { context -> OSStatus in
            var query = Self.passwordQuery(service: service, account: account)
            query[kSecUseAuthenticationContext] = context
            var read = query
            read[kSecReturnData] = true
            read[kSecMatchLimit] = kSecMatchLimitOne
            var current: CFTypeRef?
            let found = SecItemCopyMatching(read as CFDictionary, &current)
            guard found == errSecSuccess else { return found }
            guard current as? Data == expected else { return errSecItemNotFound }
            return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw VaultError.keychain(status)
        }
    }

    /// Replaces the value of an item that exists; false when it doesn't.
    private func update(_ data: Data, as item: VaultItem) throws -> Bool {
        let service = service, account = item.account
        let status = context.withLock { context -> OSStatus in
            var query = Self.passwordQuery(service: service, account: account)
            query[kSecUseAuthenticationContext] = context
            return SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw VaultError.keychain(status)
        }
    }

    // MARK: key items

    /// Replacing a key deletes the old one first: a key item's bytes can't be updated in place. If the add
    /// then fails, the org has no key and the import says so; the source file is never moved to the Trash
    /// until an import succeeded (plan §3.4.1), so nothing is lost.
    package func storeKey(_ key: P256.Signing.PrivateKey, as item: VaultItem) throws {
        precondition(item.kind.isKey, "only a key kind holds a key")
        try index(item)
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, &error) else {
            throw VaultError.keyNotUsable
        }
        var add = keyQuery(item)
        add[kSecValueRef] = secKey
        add[kSecAttrAccessControl] = try Self.userPresence()
        add[kSecAttrIsPermanent] = true
        add[kSecAttrLabel] = "abapit: \(item.org) Apple API key"
        let query = keyQuery(item)
        let status = context.withLock { _ -> OSStatus in
            let removed = SecItemDelete(query as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { return removed }
            return SecItemAdd(add as CFDictionary, nil)
        }
        try Self.check(status)
    }

    package func sign(_ message: Data, with item: VaultItem) throws -> Data? {
        precondition(item.kind.isKey, "only a key signs")
        let service = service, account = item.account
        let result = context.withLock { context -> Result<Data?, VaultError> in
            var query = Self.keyQuery(service: service, account: account)
            query[kSecReturnRef] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext] = context
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecItemNotFound { return .success(nil) }
            guard status == errSecSuccess, let found, CFGetTypeID(found) == SecKeyGetTypeID() else {
                return .failure(.keychain(status == errSecSuccess ? errSecInvalidItemRef : status))
            }
            let key = found as! SecKey   // checked by CFGetTypeID above
            var error: Unmanaged<CFError>?
            // The prompt, if the session has none yet, happens here.
            guard let der = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data? else {
                let code = error.map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
                return .failure(.keychain(code))
            }
            // The Keychain signs in DER; JWS wants raw r‖s (the classic ES256 bug: plan §3.4.2).
            guard let raw = try? P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation else {
                return .failure(.keyNotUsable)
            }
            return .success(raw)
        }
        return try result.get()
    }

    // MARK: both

    package func delete(_ item: VaultItem) throws {
        let query = item.kind.isKey ? keyQuery(item) : passwordQuery(item)
        let status = context.withLock { _ in SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
        try unindex(item)
    }

    package func inventory() throws -> [String: Set<VaultItem.Kind>] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: indexService,
                                      kSecUseDataProtectionKeychain: true, kSecMatchLimit: kSecMatchLimitAll,
                                      kSecReturnAttributes: true, kSecReturnData: true]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            var found: [String: Set<VaultItem.Kind>] = [:]
            for entry in items as? [[CFString: Any]] ?? [] {
                guard let org = entry[kSecAttrAccount] as? String, VaultItem.isValidOrg(org) else { continue }
                found[org] = Self.kinds(entry[kSecValueData] as? Data)
            }
            return found
        case errSecItemNotFound: return [:]
        default: throw VaultError.keychain(status)
        }
    }

    package func forget(org: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: indexService,
                                      kSecAttrAccount: org, kSecUseDataProtectionKeychain: true]
        let status = context.withLock { _ in SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }

    package func endSession() {
        context.withLock { context in
            context.invalidate()
            context = Self.newContext()
        }
    }

    // MARK: the index

    private static func kinds(_ data: Data?) -> Set<VaultItem.Kind> {
        Set(String(decoding: data ?? Data(), as: UTF8.self).split(separator: ",").compactMap { VaultItem.Kind(rawValue: String($0)) })
    }

    private static func encode(_ kinds: Set<VaultItem.Kind>) -> Data {
        Data(kinds.sorted().map(\.rawValue).joined(separator: ",").utf8)
    }

    /// Adds the item's kind to its org's index entry, before the item itself is written, so anything stored
    /// is always listed (and can be removed).
    private func index(_ item: VaultItem) throws {
        try editIndex(item.org) { $0.insert(item.kind) }
    }

    /// Drops the kind after its item is deleted.
    private func unindex(_ item: VaultItem) throws {
        try editIndex(item.org) { $0.remove(item.kind) }
    }

    private func editIndex(_ org: String, _ change: (inout Set<VaultItem.Kind>) -> Void) throws {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: indexService,
                                     kSecAttrAccount: org, kSecUseDataProtectionKeychain: true]
        let indexService = indexService
        try context.withLock { _ in
            var read = base
            read[kSecReturnData] = true
            read[kSecMatchLimit] = kSecMatchLimitOne
            var current: CFTypeRef?
            let found = SecItemCopyMatching(read as CFDictionary, &current)
            guard found == errSecSuccess || found == errSecItemNotFound else { throw VaultError.keychain(found) }
            var kinds = Self.kinds(current as? Data)
            change(&kinds)
            if found == errSecSuccess {
                try Self.check(SecItemUpdate(base as CFDictionary, [kSecValueData: Self.encode(kinds)] as CFDictionary))
            } else {
                var add = base
                add[kSecValueData] = Self.encode(kinds)
                add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                add[kSecAttrLabel] = "abapit: \(org) (what is stored, names only; \(indexService))"
                try Self.check(SecItemAdd(add as CFDictionary, nil))
            }
        }
    }
}
