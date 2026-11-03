import AppleModels
import Foundation
import Testing
import TestSupport

/// `ProfileText`'s masking held to Apple's own profile schemas: apple/device-management at Release-v27.0, vendored into
/// Contracts/device-management/profiles-27.0.json by scripts/device_management_schemas.py. The schemas carry no secret
/// flag, so which keys hold one is read from each key's description in Apple's YAML and written here, one line each. Every
/// key Apple names a secret is masked; every other key is shown, or is on `overMasked` by name. So a new stem that hides
/// a policy (an `authorization` stem would hide the privacy payload's Allow or Deny for 24 services), or a secret the
/// stems stop catching, fails here, not in an operator's detail pane.
@Suite("Configuration profile masking, over Apple's schemas")
struct ProfileSchemaContractTests {
    struct Key {
        let payload: String, path: [String], type: String
        var name: String { "\(payload) \(path.joined(separator: "."))" }
    }

    static func contract() throws -> [String: Any] {
        let url = Fixtures.contracts.appending(path: "device-management/profiles-27.0.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func keys() throws -> [Key] {
        let payloads = try #require(try contract()["payloads"] as? [[String: Any]])
        return payloads.flatMap { payload in
            let type = payload["payloadtype"] as? String ?? "?"
            return (payload["keys"] as? [[String: Any]] ?? []).compactMap { (key: [String: Any]) -> Key? in
                guard key["recursive"] == nil, let path = key["path"] as? [String] else { return nil }
                return Key(payload: type, path: path, type: key["type"] as? String ?? "")
            }
        }
    }

    /// The keys whose own description in Apple's schema says the value is a secret (a password, a shared secret, a token,
    /// a SCEP challenge), as `<payload type> <key path>`. Data keys are masked whatever they are (`everyDataKeyIsMasked`).
    static let secrets: Set<String> = [
        "com.apple.AIM.account AIMPassword",
        "com.apple.DirectoryService.managed Password",
        "com.apple.MCX.FileVault2 Password",
        "com.apple.airplay Passwords.PasswordsItem.Password",
        "com.apple.airplay.security Password",
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
        "com.apple.security.pkcs12 Password",
        "com.apple.security.scep PayloadContent.Challenge",
        "com.apple.subscribedcalendar.account SubCalAccountPassword",
        "com.apple.vpn.managed IKEv2.AuthPassword",
        "com.apple.vpn.managed IKEv2.Password",
        "com.apple.vpn.managed IKEv2.SharedSecret",
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

    /// Masked though Apple doesn't describe a secret: the safe direction, each named so that a new one is a decision. They
    /// are a name or a URL that holds a stem (`password`, `token`, `credential`, `passcode`, `accesskey`), not a value
    /// that could unlock anything.
    static let overMasked: Set<String> = [
        "com.apple.domains SafariPasswordAutoFillDomains.SafariPasswordAutoFillDomainsItem",
        "com.apple.eas.account OAuthTokenRequestURL",
        "com.apple.education Users.UsersItem.PasscodeType",
        "com.apple.extensiblesso ExtensionData.credentialBundleIdACL.credentialBundleIdACLItem",
        "com.apple.extensiblesso ExtensionData.credentialUseMode",
        "com.apple.extensiblesso ExtensionData.pwChangeURL",
        "com.apple.extensiblesso ExtensionData.pwReqText",
        "com.apple.extensiblesso PlatformSSO.AccessKeyReaderIssuerCertificateUUID",
        "com.apple.extensiblesso PlatformSSO.AccessKeyTerminalIdentityUUID",
        "com.apple.mobiledevice.passwordpolicy customRegex.passwordContentRegex",
        "com.apple.vpn.managed IPSec.XAuthPasswordEncryption",
        "com.apple.wifi.managed EAPClientConfiguration.SystemModeCredentialsSource",
    ]

    /// A profile of one key at the top level, with a value of the schema's type.
    static func profile(_ key: String, _ value: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>\(ProfileTextTests.escaped(key))</key>\(value)</dict></plist>
        """
    }

    static let samples = ["<string>": "<string>CANARY-1234</string>", "<any>": "<string>CANARY-1234</string>",
                          "<integer>": "<integer>4242</integer>", "<real>": "<real>42.5</real>"]

    static func masked(_ key: String, _ value: String) throws -> Bool {
        guard case .plist(let text, let masked, _) = ProfileText(profile(key, value)) else {
            Issue.record("\(key): not read as a profile")
            return false
        }
        #expect((masked > 0) == !text.contains("CANARY") || !value.contains("CANARY"), "\(key): the count and the text disagree")
        return masked > 0
    }

    /// The pin the plan names (Appendix E), whole, with Apple's licence beside it.
    @Test func theContractIsThePinnedRelease() throws {
        let contract = try Self.contract()
        #expect(contract["commit"] as? String == "09f249a06e7e3289930bf6d05f38fb562f748ebf")
        #expect(contract["release"] as? String == "Release-v27.0")
        let counts = try #require(contract["counts"] as? [String: Int])
        #expect(counts == ["files": 127, "keys": 2321])
        #expect((contract["sha256"] as? String)?.utf8.count == 64)
        #expect((contract["license"] as? String)?.contains("Permission is hereby granted, free of charge") == true)
    }

    /// Every name on both lists is a key in the contract, so a misspelt one can't pass by testing nothing.
    @Test func everyListedKeyIsInTheSchemas() throws {
        let names = Set(try Self.keys().map(\.name))
        #expect(Self.secrets.subtracting(names).isEmpty, "\(Self.secrets.subtracting(names).sorted())")
        #expect(Self.overMasked.subtracting(names).isEmpty, "\(Self.overMasked.subtracting(names).sorted())")
        #expect(Self.secrets.isDisjoint(with: Self.overMasked))
    }

    @Test func everySecretAppleNamesIsMasked() throws {
        let keys = try Self.keys().filter { Self.secrets.contains($0.name) }
        #expect(Set(keys.map(\.name)) == Self.secrets)
        for key in keys {
            let value = try #require(Self.samples[key.type], "\(key.name) is \(key.type)")
            #expect(try Self.masked(try #require(key.path.last), value), "\(key.name) shown")
        }
    }

    /// Every string, number and untyped key is shown unless it is a secret or a named over-mask: exactly those, so
    /// masking more is as visible here as masking less.
    @Test func everyOtherKeyIsShown() throws {
        var masked: Set<String> = []
        for key in try Self.keys() {
            guard let value = Self.samples[key.type], let name = key.path.last else { continue }
            if try Self.masked(name, value) { masked.insert(key.name) }
        }
        #expect(masked.subtracting(Self.secrets).subtracting(Self.overMasked).sorted() == [], "masked, not a secret")
        #expect(Self.overMasked.subtracting(masked).sorted() == [], "on overMasked, now shown: take it off the list")
    }

    @Test func everyDataKeyIsMasked() throws {
        let keys = try Self.keys().filter { $0.type == "<data>" }
        #expect(keys.count == 26)
        for key in keys {
            #expect(try Self.masked(try #require(key.path.last), "<data>Q0FOQVJZ</data>"), "\(key.name) shown")
        }
    }

    /// A relay's `AdditionalHTTPHeaderFields` is keyed by header names, so a bearer token sits under `Authorization`.
    /// Masked as a header only: the privacy payload's `Authorization` is a policy (Allow, Deny) and stays shown.
    @Test func aCredentialHeaderIsMaskedOnlyAsAHeader() throws {
        let relay = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Relays</key><array><dict>
            <key>HTTP3RelayURL</key><string>https://relay.example.com</string>
            <key>AdditionalHTTPHeaderFields</key><dict>
                <key>Authorization</key><string>Bearer CANARY-A</string>
                <key>proxy-authorization</key><string>Basic CANARY-B</string>
                <key>Cookie</key><string>session=CANARY-C</string>
                <key>SET-COOKIE</key><string>id=CANARY-D</string>
                <key>X-Request-Source</key><string>managed-mac</string>
            </dict>
            <key>Headers</key><array><dict><key>Cookie</key><string>session=CANARY-E</string></dict></array>
        </dict></array>
        <key>Services</key><dict><key>Camera</key><array><dict>
            <key>Identifier</key><string>com.example.app</string>
            <key>Authorization</key><string>Allow</string>
        </dict></array></dict>
        </dict></plist>
        """
        guard case .plist(let text, let masked, _) = ProfileText(relay) else { Issue.record("not read"); return }
        #expect(masked == 5)
        #expect(!text.contains("CANARY"))
        #expect(text.contains("managed-mac") && text.contains("<string>Allow</string>") && text.contains("relay.example.com"))
    }
}
