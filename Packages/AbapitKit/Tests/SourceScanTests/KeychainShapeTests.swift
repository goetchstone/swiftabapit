import Foundation
import Testing
import TestSupport

/// The Keychain's protections, held as the text that asks for them (invariant 3: the data-protection Keychain, this
/// device only, user presence). `VaultTests` run on `MemoryStore`, and an ad-hoc build can't reach the data-protection
/// Keychain (-34018), so no offline test runs `KeychainStore`: with `.userPresence` dropped, the accessibility class
/// widened and all five queries sent to the file-based Keychain, every test passed (failure-log 2026-11-18, "the
/// Keychain's protections were held by no test"). This holds the text, not the behaviour: only the spike on a
/// team-signed build (`ABAPIT_SPIKE=vault`, the operator's) reads back what the Keychain stored. A deliberate change to
/// an item's protection (plan D5's unattended read-only key) is a reviewed change to these counts.
@Suite("Keychain shape")
struct KeychainShapeTests {
    static let path = "Packages/AbapitKit/Sources/Vault/KeychainStore.swift"

    /// The file's code: comments and string contents blanked, whitespace and backticks removed.
    static func code() throws -> String {
        let file = try #require(SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/Vault").first { $0.path == path }, "\(path) isn't where the scan looks")
        return String(SourceScan.code(file.text, strings: false).filter { !$0.isWhitespace && $0 != "`" })
    }

    /// What `code` asks of the Keychain that it shouldn't, or no longer asks: each needle with the count it must have.
    static func problems(_ code: String) -> [String] {
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        let held: [(String, Int)] = [
            // One access control: when unlocked, this device only, behind user presence.
            ("SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.userPresence,&error)", 1),
            ("SecAccessControlCreateWithFlags", 1),
            // Each secret written carries it: Mosyle's passwords and the Apple key.
            ("add[kSecAttrAccessControl]=trySelf.userPresence()", 2),
            ("kSecAttrAccessControl", 2),
            // The name-only index: this device only, no user presence. Three: the access control's class and this pair.
            ("add[kSecAttrAccessible]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly", 1),
            ("kSecAttrAccessible", 3),
            // Three items are written: a password, the key, an index entry.
            ("SecItemAdd(", 3),
            // Every query names the data-protection Keychain, never the file-based one; nothing syncs to iCloud.
            ("kSecClass:", 5),
            ("kSecUseDataProtectionKeychain:true", 5),
            ("kSecUseDataProtectionKeychain", 5),
            ("kSecAttrSynchronizable", 0),
        ]
        return held.filter { count($0.0) != $0.1 }.map { "\($0.0): \(count($0.0)), not \($0.1)" }
    }

    @Test func theKeychainStoreKeepsItsProtections() throws {
        let problems = try Self.problems(Self.code())
        #expect(problems.isEmpty, "\(Self.path): \(problems)")
    }

    /// The check is seen to fail: each weakening of the file's own text is found (three weakenings a review tried, and their kin).
    @Test func eachWeakeningIsFound() throws {
        let code = try Self.code()
        let weakenings: [(String, String, String)] = [
            ("no user presence", ".userPresence,&error)", "[],&error)"),
            ("readable while locked", "kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.userPresence", "kSecAttrAccessibleAfterFirstUnlock,.userPresence"),
            ("a secret written without the access control", "add[kSecAttrAccessControl]=trySelf.userPresence()", ""),
            ("an index that leaves the device", "add[kSecAttrAccessible]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly", "add[kSecAttrAccessible]=kSecAttrAccessibleAfterFirstUnlock"),
            ("the file-based Keychain", "kSecUseDataProtectionKeychain:true", "kSecUseDataProtectionKeychain:false"),
            ("a query that names no Keychain", ",kSecUseDataProtectionKeychain:true]", "]"),
        ]
        for (why, old, new) in weakenings {
            #expect(code.contains(old), "\(why): the text to weaken isn't there")
            #expect(!Self.problems(code.replacingOccurrences(of: old, with: new)).isEmpty, "\(why)")
        }
        // One of five is enough.
        let flag = try #require(code.range(of: "kSecUseDataProtectionKeychain:true"))
        #expect(!Self.problems(code.replacingCharacters(in: flag, with: "kSecUseDataProtectionKeychain:false")).isEmpty)
        for added in ["add[kSecAttrSynchronizable]=true", "SecItemAdd(otherasCFDictionary,nil)", "[kSecClass:kSecClassGenericPassword,kSecAttrService:service]"] {
            #expect(!Self.problems(code + added).isEmpty, "\(added)")
        }
    }
}
