#if DEBUG
import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Phase 0 spikes, debug builds only, headless: `ABAPIT_SPIKE=keychain` (S1) or `model` (S4). Results
/// print to stdout and the process exits before any window exists. They only ever touch one throwaway key
/// item, tagged `swiftabapit-spike.p256` — never the operator's.
enum Spikes {
    static let keyTag = Data("swiftabapit-spike.p256".utf8)

    /// Runs `name` and returns the exit status.
    static func run(_ name: String) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: a killed spike still shows how far it got
        print("signing: team=\(teamIdentifier() ?? "none (ad-hoc)"); sandboxed=\(isSandboxed)")
        switch name {
        case "keychain": return keychain()
        case "model": return ModelSpike.run()
        default:
            print("unknown spike \(name); use keychain or model")
            return 64
        }
    }

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    static func describe(_ status: OSStatus) -> String {
        "\(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "?"))"
    }

    /// S1 (plan §8 Phase 0, step 6): a P-256 key as a data-protection `kSecClassKey` item behind user
    /// presence, inside the App Sandbox. Add, sign, sign again in the reuse window, delete. On an ad-hoc
    /// build every call is expected to fail with errSecMissingEntitlement (-34018).
    static func keychain() -> Int32 {
        // A UI-capable process with no Dock icon and no window, so the Touch ID sheet can appear.
        NSApplication.shared.setActivationPolicy(.accessory)
        let base: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecUseDataProtectionKeychain: true,
        ]
        print("cleanup (a leftover from an earlier run): \(describe(SecItemDelete(base as CFDictionary)))")

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .userPresence, &error) else {
            print("access control: \(String(describing: error?.takeRetainedValue()))")
            return 1
        }
        // The plan's import path (§3.4.1): a CryptoKit key → SecKey from its x9.63 bytes → a Keychain item.
        let software = P256.Signing.PrivateKey()
        let keyAttributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                              kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let secKey = SecKeyCreateWithData(software.x963Representation as CFData, keyAttributes as CFDictionary, &error) else {
            print("SecKeyCreateWithData: \(String(describing: error?.takeRetainedValue()))")
            return 1
        }
        var add = base
        add[kSecValueRef] = secKey
        add[kSecAttrAccessControl] = access
        add[kSecAttrSynchronizable] = false
        // A key item is identified by its application tag: kSecAttrService belongs to passwords, and a key
        // carrying it would fail on its own (Phase 0's review), hidden on an ad-hoc build behind -34018.
        add[kSecAttrLabel] = "swiftabapit-spike (throwaway P-256 key)"
        let added = SecItemAdd(add as CFDictionary, nil)
        print("add kSecClassKey (data-protection, userPresence, this device only): \(describe(added))")
        if added == errSecMissingEntitlement {
            print("guidance: this build can't use the data-protection Keychain. Sign it with your team: "
                  + "Config/Local.xcconfig with DEVELOPMENT_TEAM and CODE_SIGN_ENTITLEMENTS = Config/abapit-Team.entitlements, "
                  + "then build once in Xcode so it provisions the keychain access group.")
            return 2
        }
        guard added == errSecSuccess else { return 1 }

        let context = LAContext()
        context.localizedReason = "run the swiftabapit Keychain spike (a throwaway key)"
        let message = Data("swiftabapit spike \(Date().timeIntervalSince1970)".utf8)
        var allVerified = true
        for attempt in 1...2 {
            var query = base
            query[kSecAttrKeyClass] = kSecAttrKeyClassPrivate
            query[kSecReturnRef] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext] = context
            var item: CFTypeRef?
            let clock = ContinuousClock()
            let started = clock.now
            let found = SecItemCopyMatching(query as CFDictionary, &item)
            guard found == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
                print("read \(attempt): \(describe(found))")
                return 1
            }
            let key = item as! SecKey   // swiftlint:disable:this force_cast — checked by CFGetTypeID above
            guard let der = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data? else {
                print("sign \(attempt): \(String(describing: error?.takeRetainedValue()))")
                return 1
            }
            let elapsed = clock.now - started
            // DER from the Keychain → raw r‖s for JWS (plan §3.4.2), verified with the public half.
            let raw = (try? P256.Signing.ECDSASignature(derRepresentation: der))?.rawRepresentation
            let verified = raw.flatMap { try? P256.Signing.ECDSASignature(rawRepresentation: $0) }
                .map { software.publicKey.isValidSignature($0, for: message) } ?? false
            allVerified = allVerified && verified
            print("sign \(attempt): DER \(der.count) bytes → raw \(raw?.count ?? 0) bytes, verifies=\(verified), took \(elapsed)"
                  + (attempt == 2 ? " (same LAContext: no second prompt expected)" : ""))
        }
        let deleted = SecItemDelete(base as CFDictionary)
        let again = SecItemDelete(base as CFDictionary)
        print("delete: \(describe(deleted)); delete again: \(describe(again)) (errSecItemNotFound expected)")
        // Every step must hold, the signature's verification included: a DER-in-JWS bug must not exit 0.
        return allVerified && deleted == errSecSuccess && again == errSecItemNotFound ? 0 : 1
    }

    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [CFString: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier] as? String
    }
}
#endif
