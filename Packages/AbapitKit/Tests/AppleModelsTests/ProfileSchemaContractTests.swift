import AppleModels
import CryptoKit
import Foundation
import Testing
import TestSupport

/// `ProfileText`'s masking held to Apple's own profile schemas: apple/device-management at Release-v27.0, vendored into
/// Contracts/device-management/profiles-27.0.json by scripts/device_management_schemas.py.
///
/// Each payload is written as a profile carries it, every key in its real nesting with a value of its own type, and each
/// value's needle is looked for in what the detail shows. What is masked is exactly `secrets`, `overMasked` and every data
/// blob, so masking more fails here as masking less does (review M-1: each key alone at the top level hid a list masked
/// whole). Which keys are secrets follows Apple's descriptions: the script marks a key `describedAsSecret` from its wording,
/// and every marked key is on `secrets` or on `notSecret` with the reason (review M-2), so a secret a later release adds
/// fails here, not in an operator's detail pane.
@Suite("Configuration profile masking, over Apple's schemas")
struct ProfileSchemaContractTests {
    struct Key {
        let payload: String, path: [String], type: String, described: Bool
        var name: String { "\(payload) \(path.joined(separator: "."))" }
    }

    static func contract() throws -> [String: Any] {
        let url = Fixtures.contracts.appending(path: "device-management/profiles-27.0.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func payloads() throws -> [[String: Any]] { try #require(try contract()["payloads"] as? [[String: Any]]) }

    /// A payload's keys in the contract's order: depth first, a parent before its subkeys.
    static func keys(of payload: [String: Any]) -> [Key] {
        let type = payload["payloadtype"] as? String ?? "?"
        return (payload["keys"] as? [[String: Any]] ?? []).compactMap { key in
            guard let path = key["path"] as? [String] else { return nil }
            return Key(payload: type, path: path, type: key["type"] as? String ?? "", described: key["describedAsSecret"] as? Bool == true)
        }
    }

    static func keys() throws -> [Key] { try payloads().flatMap(keys(of:)) }

    /// The secrets, as `<payload type> <key path>`, the schema's item names included: every key whose description Apple
    /// wrote as a secret's (`describedAsSecret`) and isn't on `notSecret`, and two its description doesn't name, each
    /// marked. A data secret is masked as data and also by its key, written as a string (`aDataSecretAsAStringIsMasked`).
    static let secrets: Set<String> = [
        "com.apple.AIM.account AIMPassword",
        "com.apple.DirectoryService.managed Password",
        "com.apple.MCX.FileVault2 Password",
        "com.apple.airplay Passwords.PasswordsItem.Password",
        "com.apple.airplay.security Password",
        "com.apple.apn.managed DefaultsData.apns.apnsItem.password",
        "com.apple.caldav.account CalDAVPassword",
        "com.apple.carddav.account CardDAVPassword",
        "com.apple.cellular APNs.APNsItem.Password",
        "com.apple.cellular AttachAPN.Password",
        "com.apple.configurationprofile.identification PayloadIdentification.Password",
        "com.apple.eas.account CertificatePassword",
        "com.apple.eas.account Password",
        "com.apple.ews.account Password",
        "com.apple.extensiblesso RegistrationToken",
        "com.apple.jabber.account JabberPassword",
        "com.apple.ldap.account LDAPAccountPassword",
        "com.apple.loginwindow AutologinPassword",
        "com.apple.mail.managed IncomingPassword",
        "com.apple.mail.managed OutgoingPassword",
        "com.apple.osxserver.account Password",
        "com.apple.profileRemovalPassword RemovalPassword",
        "com.apple.proxy.http.global ProxyPassword",
        // Not described as one: a header's value, which can be a bearer token (review M-3).
        "com.apple.relay.managed Relays.Relay.AdditionalHTTPHeaderFields.ANY",
        "com.apple.security.acme ClientIdentifier",
        "com.apple.security.pkcs12 Password",
        "com.apple.security.scep PayloadContent.Challenge",
        "com.apple.subscribedcalendar.account SubCalAccountPassword",
        "com.apple.vpn.managed IKEv2.AuthPassword",
        "com.apple.vpn.managed IKEv2.PPK",
        "com.apple.vpn.managed IKEv2.Password",
        // Not described as one: "the device uses this value for IKE authentication".
        "com.apple.vpn.managed IKEv2.SharedSecret",
        "com.apple.vpn.managed IPSec.SharedSecret",
        "com.apple.vpn.managed IPSec.XAuthPassword",
        "com.apple.vpn.managed PPP.AuthPassword",
        "com.apple.vpn.managed Proxies.HTTPProxyPassword",
        "com.apple.vpn.managed TransparentProxy.Password",
        "com.apple.vpn.managed VPN.AuthPassword",
        "com.apple.webcontent-filter Password",
        "com.apple.webcontent-filter URLFilterParameters.PIRAuthenticationToken",
        "com.apple.wifi.managed EAPClientConfiguration.UserPassword",
        "com.apple.wifi.managed Password",
        "com.apple.wifi.managed ProxyPassword",
        "com.apple.xsan sharedSecret",
    ]

    /// Keys Apple's wording marks (`describedAsSecret`) whose value isn't a secret, each read and the reason given.
    static let notSecret: [String: String] = [
        "com.apple.airplay.security SecurityType": "an enum (NONE, PASSWORD, …); its description names the passphrase `Password` holds",
        "com.apple.extensiblesso PlatformSSO.NewUserAuthenticationMethods.NewUserAuthenticationMethod":
            "an enum (`Password`, `SmartCard`): the method, not the password",
        "com.apple.vpn.managed IKEv2.PPKIdentifier": "names the pre-shared key `PPK` holds (RFC 8784's PPK_ID), not the key",
    ]

    /// Masked though not a secret: the safe direction, each named so that a new one is a decision. A name, a URL or a
    /// policy under a secret word (`password`, `token`, `credential`, `passcode`, `accesskey`), and a name beside a secret in
    /// a list masked whole (AirPlay's `Passwords`, Platform SSO's `TokenToUserMapping`, `customRegex`'s descriptions under
    /// `passwordContentDescription`), which only the nesting shows.
    static let overMasked: Set<String> = [
        "com.apple.airplay Passwords.PasswordsItem.DeviceID",
        "com.apple.airplay Passwords.PasswordsItem.DeviceName",
        "com.apple.domains SafariPasswordAutoFillDomains.SafariPasswordAutoFillDomainsItem",
        "com.apple.eas.account OAuthTokenRequestURL",
        "com.apple.education Users.UsersItem.PasscodeType",
        "com.apple.extensiblesso ExtensionData.credentialBundleIdACL.credentialBundleIdACLItem",
        "com.apple.extensiblesso ExtensionData.credentialUseMode",
        "com.apple.extensiblesso ExtensionData.pwChangeURL",
        "com.apple.extensiblesso ExtensionData.pwReqText",
        "com.apple.extensiblesso PlatformSSO.AccessKeyReaderIssuerCertificateUUID",
        "com.apple.extensiblesso PlatformSSO.AccessKeyTerminalIdentityUUID",
        "com.apple.extensiblesso PlatformSSO.TokenToUserMapping.AccountName",
        "com.apple.extensiblesso PlatformSSO.TokenToUserMapping.FullName",
        "com.apple.mobiledevice.passwordpolicy customRegex.passwordContentDescription.ANY",
        "com.apple.mobiledevice.passwordpolicy customRegex.passwordContentRegex",
        "com.apple.vpn.managed IPSec.XAuthPasswordEncryption",
        "com.apple.wifi.managed EAPClientConfiguration.SystemModeCredentialsSource",
    ]

    /// One payload as a profile carries it, and each value's needle with the key's name: a `<dictionary>` holds its subkeys,
    /// an `<array>` one item built from its single subkey (the schema's item name is no key), `ANY` is written as that name,
    /// and the payload sits in `PayloadContent`, in a dictionary with its `PayloadType` (`TopLevel` is the profile itself).
    /// Every string, untyped value, integer, real and data blob is unique; a container with no subkeys (one that repeats an
    /// ancestor) holds one string. A flag is `<true/>` and a date one date, with no needle: no key rule masks either, and no
    /// schema puts one in a header dictionary. `asString`: the path of a key written as a string, whatever its type.
    static func profile(of payload: [String: Any], asString: [String]? = nil) -> (xml: String, needles: [(name: String, needle: String)]) {
        let keys = keys(of: payload)
        let subkeys = Dictionary(grouping: keys) { Array($0.path.dropLast()) }
        var needles: [(name: String, needle: String)] = []
        func entry(_ key: Key) -> String { "<key>\(ProfileTextTests.escaped(key.path.last ?? ""))</key>" + value(key) }
        func value(_ key: Key) -> String {
            let n = 10_000 + needles.count, inner = subkeys[key.path] ?? []
            func leaf(_ written: String, _ needle: String) -> String {
                needles.append((key.name, needle))
                return written
            }
            switch key.path == asString ? "<string>" : key.type {
            case "<dictionary>" where inner.isEmpty: return leaf("<dict><key>Sample</key><string>CANARY-\(n)</string></dict>", "CANARY-\(n)")
            case "<dictionary>": return "<dict>" + inner.map(entry).joined() + "</dict>"
            case "<array>" where inner.isEmpty: return leaf("<array><string>CANARY-\(n)</string></array>", "CANARY-\(n)")
            case "<array>": return "<array>" + inner.map(value).joined() + "</array>"
            case "<string>", "<any>": return leaf("<string>CANARY-\(n)</string>", "CANARY-\(n)")
            case "<integer>": return leaf("<integer>\(7_000_000_000 + n)</integer>", "\(7_000_000_000 + n)")
            case "<real>": return leaf("<real>\(n).5</real>", "\(n).5")
            case "<data>":
                let base64 = Data("DATA-\(n)".utf8).base64EncodedString()
                return leaf("<data>\(base64)</data>", base64)
            case "<boolean>": return "<true/>"
            case "<date>": return "<date>2026-01-01T00:00:00Z</date>"
            default:
                Issue.record("\(key.name): no value for \(key.type)")
                return ""
            }
        }
        let top = keys.filter { $0.path.count == 1 }
        var body = top.map(entry).joined()
        let type = payload["payloadtype"] as? String ?? "?"
        if type != "TopLevel" {
            let named = top.contains { $0.path == ["PayloadType"] } ? "" : "<key>PayloadType</key><string>\(ProfileTextTests.escaped(type))</string>"
            body = "<key>PayloadContent</key><array><dict>\(named)\(body)</dict></array>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """
        return (xml, needles)
    }

    /// The names whose needle the detail's text lacks (masked) and holds (shown), and how many needles were looked for. Each
    /// needle is in the profile once, so one value's needle can't be found in another's.
    static func shown(_ payload: [String: Any], asString: [String]? = nil) -> (masked: Set<String>, shown: Set<String>, needles: Int) {
        let (xml, needles) = profile(of: payload, asString: asString)
        let repeated = needles.filter { xml.components(separatedBy: $0.needle).count != 2 }.map(\.name)
        #expect(repeated == [], "\(payload["file"] ?? "?"): a needle not unique")
        guard case .plist(let text, _, let merged) = ProfileText(xml) else {
            Issue.record("\(payload["file"] ?? "?"): not read as a profile: \(ProfileText(xml))")
            return ([], [], 0)
        }
        #expect(merged == 0, "\(payload["file"] ?? "?"): a key written twice")
        var masked: Set<String> = [], shown: Set<String> = []
        for (name, needle) in needles {
            if text.contains(needle) { shown.insert(name) } else { masked.insert(name) }
        }
        return (masked, shown, needles.count)
    }

    /// The pin the plan names (Appendix E), whole, with Apple's licence beside it. Its counts and its SHA-256 are recomputed
    /// from its payloads, so a contract cut short with its header kept fails (review L-3).
    @Test func theContractIsThePinnedRelease() throws {
        let contract = try Self.contract()
        let payloads = try Self.payloads()
        #expect(contract["commit"] as? String == "09f249a06e7e3289930bf6d05f38fb562f748ebf")
        #expect(contract["release"] as? String == "Release-v27.0")
        let counts = try #require(contract["counts"] as? [String: Int])
        let keys = payloads.map(Self.keys(of:))
        #expect(counts == ["files": payloads.count, "keys": keys.map(\.count).reduce(0, +),
                           "describedAsSecret": keys.joined().filter(\.described).count])
        #expect(counts == ["files": 127, "keys": 2321, "describedAsSecret": 45])
        let files = payloads.compactMap { $0["sha256"] as? String }
        #expect(files.count == payloads.count && Set(files).count == files.count)
        let whole = SHA256.hash(data: Data(files.sorted().map { $0 + "\n" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(contract["sha256"] as? String == whole)
        #expect((contract["pyyaml"] as? String)?.isEmpty == false)
        #expect((contract["license"] as? String)?.contains("Permission is hereby granted, free of charge") == true)
    }

    /// Every name on the lists is a key in the contract, so a misspelt one can't pass by testing nothing, and no key is
    /// both a secret and not one.
    @Test func everyListedKeyIsInTheSchemas() throws {
        let names = Set(try Self.keys().map(\.name)), notSecret = Set(Self.notSecret.keys)
        #expect(Self.secrets.subtracting(names).sorted() == [])
        #expect(Self.overMasked.subtracting(names).sorted() == [])
        #expect(notSecret.subtracting(names).sorted() == [])
        #expect(Self.secrets.isDisjoint(with: Self.overMasked) && Self.secrets.isDisjoint(with: notSecret))
    }

    /// The builder's own check, read without `ProfileText`: every key of every payload is at its path in the profile written
    /// for it, as its type (an item name written as a key, or a key left out or retyped, fails here).
    @Test func eachBuiltProfileHoldsEveryKeyAtItsPath() throws {
        for payload in try Self.payloads() {
            let tree = try PropertyListSerialization.propertyList(from: Data(Self.profile(of: payload).xml.utf8), format: nil)
            let keys = Self.keys(of: payload), types = Dictionary(keys.map { ($0.path, $0.type) }) { first, _ in first }
            let root = payload["payloadtype"] as? String == "TopLevel" ? tree : ((tree as? [String: Any])?["PayloadContent"] as? [Any])?.first
            for key in keys {
                var value = root
                for index in key.path.indices {
                    value = index > 0 && types[Array(key.path[..<index])] == "<array>"
                        ? (value as? [Any])?.first : (value as? [String: Any])?[key.path[index]]
                }
                let kind = (value as? NSNumber).map { String(cString: $0.objCType) }
                let written = switch key.type {
                case "<dictionary>": value is [String: Any]
                case "<array>": value is [Any]
                case "<string>", "<any>": value is String
                case "<integer>": value is NSNumber && kind == "q"
                case "<real>": value is NSNumber && kind == "d"
                case "<boolean>": value as? Bool == true && kind == "c"
                case "<data>": value is Data
                case "<date>": value is Date
                default: false
                }
                #expect(written, "\(key.name): not written as \(key.type)")
            }
        }
    }

    /// Exactly the listed keys and the data blobs are masked, each in its real nesting: a secret shown fails, and so does a
    /// value masked that is on no list (a container masked whole, a stem that hides a policy).
    @Test func whatIsMaskedIsExactlyTheListedKeys() throws {
        var masked: Set<String> = [], shown: Set<String> = [], needles = 0
        for payload in try Self.payloads() {
            let run = Self.shown(payload)
            masked.formUnion(run.masked)
            shown.formUnion(run.shown)
            needles += run.needles
        }
        // Every string, untyped, integer, real and data key, and the 4 that repeat an ancestor.
        #expect(needles == 1199)
        #expect(masked.intersection(shown).sorted() == [], "masked in one payload file, shown in another")
        let data = Set(try Self.keys().filter { $0.type == "<data>" }.map(\.name))
        #expect(data.count == 26)
        #expect(masked.subtracting(Self.secrets).subtracting(Self.overMasked).subtracting(data).sorted() == [],
                "masked, on no list: a secret goes on `secrets`; anything else on `overMasked`, as a decision")
        #expect(Self.secrets.subtracting(masked).sorted() == [], "a secret shown")
        #expect(data.subtracting(masked).sorted() == [], "a data blob shown")
        #expect(Self.overMasked.subtracting(masked).sorted() == [],
                "on overMasked, now shown: check Apple's description before taking it off this list")
    }

    /// Every key Apple describes as a secret is on `secrets` or, read and reasoned, on `notSecret`; a secret Apple doesn't
    /// describe is one of the two marked on `secrets`. So moving a described secret to `overMasked` fails here.
    @Test func everySecretAppleDescribesIsListed() throws {
        let described = Set(try Self.keys().filter(\.described).map(\.name)), notSecret = Set(Self.notSecret.keys)
        #expect(described.subtracting(Self.secrets).subtracting(notSecret).sorted() == [],
                "Apple's description says a secret: put it on `secrets`, or on `notSecret` with the reason")
        #expect(notSecret.subtracting(described).sorted() == [], "on notSecret, but Apple's description no longer says a secret")
        #expect(Self.secrets.subtracting(described).sorted() == ["com.apple.relay.managed Relays.Relay.AdditionalHTTPHeaderFields.ANY",
                                                                  "com.apple.vpn.managed IKEv2.SharedSecret"])
    }

    /// A data secret written as a string is masked by its key, not only as a blob: `IKEv2.PPK` by the `ppk` ending, while
    /// `PPKIdentifier` (a string) and `PPKMandatory` (an integer) stay shown (review M-2).
    @Test func aDataSecretAsAStringIsMasked() throws {
        let keys = try Self.keys().filter { $0.type == "<data>" && Self.secrets.contains($0.name) }
        #expect(keys.map(\.name).sorted() == ["com.apple.apn.managed DefaultsData.apns.apnsItem.password",
                                              "com.apple.vpn.managed IKEv2.PPK", "com.apple.vpn.managed IPSec.SharedSecret"])
        let payloads = try Self.payloads()
        for key in keys {
            let payload = try #require(payloads.first { $0["payloadtype"] as? String == key.payload })
            let run = Self.shown(payload, asString: key.path)
            #expect(run.masked.contains(key.name), "\(key.name), as a string, shown")
            if key.payload == "com.apple.vpn.managed" {
                #expect(run.shown.isSuperset(of: ["com.apple.vpn.managed IKEv2.PPKIdentifier", "com.apple.vpn.managed IKEv2.PPKMandatory"]))
            }
        }
    }

    /// A relay's `AdditionalHTTPHeaderFields` is keyed by header names, so a credential can sit under any name, written any
    /// way: every value of a header dictionary is masked, whatever its type, and every item of a header list (review M-3:
    /// only a string under four names was). Only under such a key: the privacy payload's `Authorization` is a policy (Allow,
    /// Deny) and stays shown, and a string under a header-named key is any other string (EAS `HeaderMagic`).
    @Test func everyValueOfHTTPHeadersIsMasked() throws {
        func relay(_ headers: String) -> String {
            "<dict><key>HTTP3RelayURL</key><string>https://relay.example.com</string><key>AdditionalHTTPHeaderFields</key>\(headers)</dict>"
        }
        let relays = [
            relay("""
            <dict><key>Authorization</key><string>Bearer CANARY-A</string><key>X-Authorization</key><string>Bearer CANARY-B</string>
            <key>Ocp-Apim-Subscription-Key</key><string>CANARY-C</string>
            <key>Default</key><dict><key>Authorization</key><string>Bearer CANARY-D</string></dict></dict>
            """),
            relay("<dict><key>Authorization</key><array><string>Bearer CANARY-E</string></array></dict>"),
            relay("<dict><key>Authorization</key><dict><key>scheme</key><string>Bearer CANARY-F</string></dict></dict>"),
            relay("<dict><key>Authorization</key><integer>98765</integer></dict>"),
            relay("<array><dict><key>Name</key><string>Authorization</string><key>Value</key><string>Bearer CANARY-G</string></dict></array>"),
        ]
        let profile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>PayloadContent</key><array>
        <dict><key>PayloadType</key><string>com.apple.relay.managed</string><key>Relays</key><array>\(relays.joined())</array></dict>
        <dict><key>PayloadType</key><string>com.apple.TCC.configuration-profile-policy</string>
            <key>Services</key><dict><key>Camera</key><array><dict>
            <key>Identifier</key><string>com.example.app</string><key>Authorization</key><string>Allow</string>
            </dict></array></dict></dict>
        <dict><key>PayloadType</key><string>com.apple.eas.account</string><key>HeaderMagic</key><string>magic-shown</string></dict>
        </array></dict></plist>
        """
        guard case .plist(let text, let masked, _) = ProfileText(profile) else { Issue.record("not read"); return }
        #expect(masked == 8)
        #expect(!text.contains("CANARY") && !text.contains("98765"))
        for kept in ["<key>Ocp-Apim-Subscription-Key</key>", "<key>Default</key>", "relay.example.com", "<string>Allow</string>", "magic-shown"] {
            #expect(text.contains(kept), "\(kept) was lost")
        }
    }
}
