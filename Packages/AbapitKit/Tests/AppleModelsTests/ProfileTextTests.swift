@testable import AppleModels
import Foundation
import Testing

/// A configuration's `configurationProfile` as the detail view shows it (plan Phase 2): pretty-printed XML with every
/// secret masked (invariant 11), a signed profile never shown, anything else a note; the input bounded and a DTD or
/// entity declaration refused before any parser sees it.
@Suite("Configuration profile text")
struct ProfileTextTests {
    /// Every secret the profile below holds, as text and as the base64 its data blobs are written in.
    static let secrets = ["wifi-pass-123", "eap-user-pass", "vpn-auth-pass", "xauth-pass", "p12-pass", "a long passphrase", "4321",
                          "shared-psk", "scep-challenge", "aXBzZWMtc2hhcmVk", "ZmFrZS1wMTItaWRlbnRpdHk=", "dG9rZW4tYmxvYg=="]

    /// A Wi-Fi + VPN + certificate profile: the secrets sit at several depths, in arrays, under keys spelled several ways.
    static let profile = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>PayloadContent</key>
        <array>
            <dict>
                <key>PayloadType</key><string>com.apple.wifi.managed</string>
                <key>SSID_STR</key><string>Office</string>
                <key>EncryptionType</key><string>WPA2</string>
                <key>Password</key><string>wifi-pass-123</string>
                <key>EAPClientConfiguration</key>
                <dict>
                    <key>UserName</key><string>front-desk</string>
                    <key>UserPassword</key><string>eap-user-pass</string>
                    <key>AcceptEAPTypes</key><array><integer>25</integer></array>
                </dict>
            </dict>
            <dict>
                <key>PayloadType</key><string>com.apple.vpn.managed</string>
                <key>VPNType</key><string>IPSec</string>
                <key>IPSec</key>
                <dict>
                    <key>RemoteAddress</key><string>vpn.example.com</string>
                    <key>SharedSecret</key><data>aXBzZWMtc2hhcmVk</data>
                    <key>XAuthPassword</key><string>xauth-pass</string>
                    <key>PromptForVPNPIN</key><true/>
                    <key>Shipping</key><string>kept</string>
                </dict>
                <key>VPN</key>
                <dict>
                    <key>AuthPassword</key><string>vpn-auth-pass</string>
                    <key>shared_psk_secret</key><string>shared-psk</string>
                </dict>
                <key>Accounts</key>
                <array>
                    <dict><key>UserPIN</key><string>4321</string><key>Label</key><string>token one</string></dict>
                    <dict><key>Passphrase</key><string>a long passphrase</string></dict>
                </array>
            </dict>
            <dict>
                <key>PayloadType</key><string>com.apple.security.pkcs12</string>
                <key>PayloadCertificateFileName</key><string>identity.p12</string>
                <key>Password</key><string>p12-pass</string>
                <key>PayloadContent</key><data>ZmFrZS1wMTItaWRlbnRpdHk=</data>
            </dict>
            <dict>
                <key>PayloadType</key><string>com.apple.security.scep</string>
                <key>PayloadContent</key>
                <dict>
                    <key>URL</key><string>https://scep.example.com</string>
                    <key>Challenge</key><string>scep-challenge</string>
                </dict>
            </dict>
            <dict>
                <key>PayloadType</key><string>com.apple.mobiledevice.passwordpolicy</string>
                <key>maxPINAgeInDays</key><integer>90</integer>
                <key>Icon</key><data>dG9rZW4tYmxvYg==</data>
            </dict>
        </array>
        <key>PayloadDisplayName</key><string>Office network</string>
        <key>PayloadType</key><string>Configuration</string>
    </dict>
    </plist>
    """

    /// Ten secrets by their keys and two data blobs that aren't under one (the identity and the icon; the IPSec shared
    /// secret is a data blob under a secret key, counted once).
    static let masked = 12

    static func shown(_ text: String) throws -> (text: String, masked: Int) {
        guard case .plist(let shown, let masked, let merged) = ProfileText(text) else {
            Issue.record("not shown as a plist: \(ProfileText(text))")
            throw CancellationError()
        }
        #expect(merged == 0, "\(text)")
        return (shown, masked)
    }

    @Test func aProfileIsShownWithEverySecretMasked() throws {
        let (text, masked) = try Self.shown(Self.profile)
        #expect(masked == Self.masked)
        #expect(ProfileText(Self.profile).note == "12 values masked")
        for secret in Self.secrets { #expect(!text.contains(secret), "\(secret) was shown") }
        for kept in ["Office", "front-desk", "vpn.example.com", "identity.p12", "https://scep.example.com", "token one", "kept",
                     "<integer>90</integer>", "<integer>25</integer>", "Office network", "com.apple.security.pkcs12"] {
            #expect(text.contains(kept), "\(kept) was lost")
        }
        // The text is a property list again, pretty-printed, with the mask where each secret was.
        let reread = try #require(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        let payloads = try #require(reread["PayloadContent"] as? [[String: Any]])
        let wifi = try #require(payloads.first { $0["PayloadType"] as? String == "com.apple.wifi.managed" })
        #expect(wifi["Password"] as? String == ProfileText.mask)
        #expect((wifi["EAPClientConfiguration"] as? [String: Any])?["UserPassword"] as? String == ProfileText.mask)
        let vpn = try #require(payloads.first { $0["PayloadType"] as? String == "com.apple.vpn.managed" })
        #expect((vpn["IPSec"] as? [String: Any])?["SharedSecret"] as? String == ProfileText.mask)
        #expect((vpn["IPSec"] as? [String: Any])?["PromptForVPNPIN"] as? Bool == true)
        let accounts = try #require(vpn["Accounts"] as? [[String: Any]])
        #expect(accounts.first?["UserPIN"] as? String == ProfileText.mask && accounts.last?["Passphrase"] as? String == ProfileText.mask)
        #expect(text.contains("\n\t<key>PayloadContent</key>\n\t<array>\n\t\t<dict>"))
    }

    /// Apple types the profile `byte` (base64), while its example sends XML text: both are read, and a binary plist
    /// in base64 too (it can't travel as JSON text).
    @Test func aBase64OrBinaryProfileIsShownTheSame() throws {
        let xml = try Self.shown(Self.profile)
        let base64 = Data(Self.profile.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        #expect(try Self.shown(base64) == xml)
        #expect(try Self.shown(String(base64.filter { $0 != "=" })) == xml)
        let tree = try PropertyListSerialization.propertyList(from: Data(Self.profile.utf8), format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0)
        #expect(binary.starts(with: Array("bplist00".utf8)))
        #expect(try Self.shown(binary.base64EncodedString()) == xml)
        // With a UTF-8 byte-order mark first.
        #expect(try Self.shown("\u{FEFF}" + Self.profile) == xml)
    }

    /// A key is read folded, as the CSV denylist reads one: case, a full-width spelling, an invisible split and
    /// punctuation don't hide `password`; a PIN is one by its own word; a policy number or a flag under such a key isn't
    /// masked; and a value of a secret key is masked whole, whatever it holds.
    @Test(arguments: [
        ("PASSWORD", true), ("pass\u{200B}word", true), ("\u{FF30}\u{FF21}\u{FF33}\u{FF33}\u{FF37}\u{FF2F}\u{FF32}\u{FF24}", true),
        ("Pass_Word", true), ("PayloadCertificatePassword", true), ("LDAPAccountPassword", true), ("Passwd", true),
        ("passphrase", true), ("SharedSecret", true), ("client-secret", true), ("Challenge", true), ("AuthToken", true),
        ("PrivateKey", true), ("PIN", true), ("pin", true), ("UserPIN", true), ("PINCode", true), ("P\u{200B}INCode", true), ("pinCode", true), ("user_pin", true),
        ("VPNPIN", true), ("Shipping", false), ("AllowPinning", false), ("Opinion", false), ("SSID_STR", false), ("UserName", false),
        ("RemoteAddress", false), ("PayloadDisplayName", false),
        // Phase 2a review L2: each of these was shown.
        ("PreSharedKey", true), ("PSK", true), ("WPA_PSK", true), ("SharedKey", true), ("EncryptionKey", true), ("ClientKey", true),
        ("AccessKey", true), ("LicenseKey", true), ("AdminPW", true), ("PW", true), ("pw_value", true),
        ("EncryptionType", false), ("Power", false), ("PWR", false), ("KeySize", false), ("ClientID", false),
    ])
    func aSecretKeyIsFoundHoweverItIsSpelled(key: String, secret: Bool) throws {
        let plist = "<plist version=\"1.0\"><dict><key>\(key)</key><string>s3cr3t-value</string></dict></plist>"
        let (text, masked) = try Self.shown(plist)
        #expect(text.contains("s3cr3t-value") != secret, "\(key)")
        #expect(masked == (secret ? 1 : 0), "\(key)")
    }

    @Test func aSecretKeysValueIsMaskedWholeAndAFlagIsNot() throws {
        let plist = """
        <plist version="1.0"><dict>
        <key>Passwords</key><array><string>one-secret</string><dict><key>x</key><string>two-secret</string></dict></array>
        <key>SecretSettings</key><dict><key>Name</key><string>three-secret</string></dict>
        <key>PasswordRequired</key><true/><key>pinHistory</key><integer>5</integer><key>TokenExpiry</key><date>2026-01-01T00:00:00Z</date>
        </dict></plist>
        """
        let (text, masked) = try Self.shown(plist)
        #expect(masked == 2)
        for secret in ["one-secret", "two-secret", "three-secret"] { #expect(!text.contains(secret)) }
        #expect(text.contains("<true/>") && text.contains("<integer>5</integer>") && text.contains("<date>2026-01-01T00:00:00Z</date>"))
    }

    /// A number is masked when its key's last word is a secret word (a numeric passcode, PIN or unlock code), unless a
    /// policy word is in the key too: `MaxPINAgeInDays` and `PasscodeMinLength` are rules about a secret, not one (Phase
    /// 2a review L2: `UnlockCode` and `Passcode` integers were shown). A flag under any of these keys is never masked.
    @Test(arguments: [
        ("Passcode", true), ("devicePasscode", true), ("DevicePassword", true), ("UserPIN", true), ("PIN", true), ("PINCode", true),
        ("PINNumber", true), ("UnlockCode", true), ("unlock_code", true), ("Unlockcode", true), ("AdminPW", true), ("UserPwd", true),
        ("\u{FF30}\u{FF29}\u{FF2E}", true),
        ("MaxPINAgeInDays", false), ("PasscodeMinLength", false), ("pinHistory", false), ("MaxPIN", false), ("MinimumPasscode", false),
        ("maxFailedAttempts", false), ("PasswordAttempts", false), ("PasscodeComplexity", false), ("RequiredPIN", false), ("ComplexPasscode", false),
        ("PasscodeAgeDays", false), ("PasswordHistoryLength", false), ("Port", false), ("AuthCode", false), ("PINTimeout", false),
        // Each policy word on its own before a secret last word.
        ("MaximumPIN", false), ("MinPIN", false), ("AgeOfPasscode", false), ("LengthOfPIN", false), ("HistoryOfPasscode", false),
        ("AttemptBeforePIN", false), ("AttemptsBeforePIN", false), ("ComplexityOfPIN", false),
        // A last word ending in `pin` is a secret one, as for strings: over-masked, never shown.
        ("Spin", true),
    ])
    func aNumberUnderASecretWordIsMaskedAndAPolicyIsNot(key: String, secret: Bool) throws {
        for (value, written) in [("<integer>4321</integer>", "4321"), ("<real>43.5</real>", "43.5"), ("<integer>0</integer>", "<integer>0</integer>")] {
            let (text, masked) = try Self.shown("<plist version=\"1.0\"><dict><key>\(key)</key>\(value)</dict></plist>")
            #expect(text.contains(written) != secret && masked == (secret ? 1 : 0), "\(key) \(value)")
        }
        for flag in ["<true/>", "<false/>"] {
            let (text, masked) = try Self.shown("<plist version=\"1.0\"><dict><key>\(key)</key>\(flag)</dict></plist>")
            #expect(text.contains(flag) && masked == 0, "\(key) \(flag)")
            let tree = try PropertyListSerialization.propertyList(from: Data("<plist version=\"1.0\"><dict><key>\(key)</key>\(flag)</dict></plist>".utf8), format: nil)
            let binary = try PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0)
            #expect(try Self.shown(binary.base64EncodedString()).masked == 0, "\(key) \(flag), binary")
        }
    }

    /// A PEM private key is masked whatever its key, as text or as base64 of the text, in a dictionary or a list, in any
    /// of its labels and either case; a certificate is public and shown (Phase 2a review L2: one under `Identity` was
    /// shown).
    @Test func aPrivateKeyIsMaskedWhateverItsKey() throws {
        let body = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7"
        for label in ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "ENCRYPTED PRIVATE KEY", "OPENSSH PRIVATE KEY", "PGP PRIVATE KEY BLOCK"] {
            for pem in ["-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n", "-----begin \(label.lowercased())-----\r\n\(body)"] {
                for value in [pem, Data(pem.utf8).base64EncodedString(), Data(pem.utf8).base64EncodedString(options: .lineLength64Characters)] {
                    let plist = "<plist version=\"1.0\"><dict><key>Identity</key><string>\(value)</string><key>Chain</key><array><string>\(value)</string></array></dict></plist>"
                    let (text, masked) = try Self.shown(plist)
                    #expect(!text.contains(body) && !text.contains(value) && masked == 2, "\(label): \(value)")
                }
            }
        }
        let certificate = "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----"
        // The label is the BEGIN line's alone: a certificate followed by words about its private key is still public.
        for value in [certificate, Data(certificate.utf8).base64EncodedString(), "a note on the private key policy", "BEGIN PRIVATE KEY",
                      certificate + "\nThe private key stays on the device.", "-----BEGIN CERTIFICATE\nprivate key"] {
            let (text, masked) = try Self.shown("<plist version=\"1.0\"><dict><key>Certificate</key><string>\(value)</string></dict></plist>")
            #expect(text.contains(value) && masked == 0, "\(value)")
        }
    }

    /// Two keys that differ only in Unicode normalization merge when Foundation's dictionary becomes Swift's, and one
    /// value is lost: the count says how many, and the note says it, never silent (Phase 2a review L2).
    @Test func keysMergedByNormalizationAreSaid() throws {
        let plist = "<plist version=\"1.0\"><dict><key>caf\u{E9}</key><string>one</string><key>cafe\u{301}</key><string>two</string>"
            + "<key>Inner</key><dict><key>\u{C5}</key><integer>1</integer><key>A\u{30A}</key><integer>2</integer><key>\u{212B}</key><integer>3</integer></dict>"
            + "<key>Password</key><string>hunter2</string></dict></plist>"
        guard case .plist(let text, let masked, let merged) = ProfileText(plist) else {
            Issue.record("not shown: \(ProfileText(plist))")
            return
        }
        #expect(merged == 3 && masked == 1 && !text.contains("hunter2"))
        #expect(text.contains("<string>one</string>") != text.contains("<string>two</string>"), "one of the two is shown")
        #expect(ProfileText(plist).note == "1 value masked · 3 keys not shown: each reads as another key once normalized")
        #expect(try Self.shown(Self.plist(bytes: 100)).masked == 0 && ProfileText(Self.plist(bytes: 100)).note == nil)
        #expect(ProfileText("nope").note == nil)
    }

    /// Secrets inside arrays inside arrays, any depth.
    @Test func aSecretIsMaskedAtAnyDepth() throws {
        var plist = "<dict><key>Password</key><string>deep-secret</string></dict>"
        for level in 0..<30 { plist = level.isMultiple(of: 2) ? "<array>\(plist)</array>" : "<dict><key>k\(level)</key>\(plist)</dict>" }
        let (text, masked) = try Self.shown("<plist version=\"1.0\">\(plist)</plist>")
        #expect(masked == 1 && !text.contains("deep-secret"))
    }

    /// A signed profile (CMS SignedData, DER) is never shown, its bytes neither: the signed content holds the profile's
    /// secrets in the clear.
    @Test func aSignedProfileIsNeverShown() {
        var der: [UInt8] = [0x30, 0x82, 0x01, 0x00, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02, 0xA0, 0x82]
        der += Array(Self.profile.utf8)
        let shown = ProfileText(Data(der).base64EncodedString())
        #expect(shown == .signed(bytes: der.count))
        #expect(shown.text == "signed profile, \(der.count) bytes, not shown")
        for secret in Self.secrets { #expect(!shown.text.contains(secret)) }
        // DER that isn't SignedData is not called signed.
        #expect(ProfileText(Data([0x30, 0x03, 0x02, 0x01, 0x05] + Array(repeating: 0, count: 40)).base64EncodedString()) == .notShown(ProfileText.unreadable))
    }

    /// Anything else is a short note, never the value: text, an OpenStep plist (which Foundation would read), a cut XML.
    @Test(arguments: ["hello", "{ Password = hunter2; }", "<0fbd77>", "( hunter2 )", "<?xml version=\"1.0\"?><plist><dict><key>Password",
                      "", "   ", "!!!!", "<?xml version=\"1.0\" encoding=\"UTF-8\"<plist version=\"1.0\"><string>hunter2</string></plist>"])
    func anythingElseIsANote(text: String) {
        let shown = ProfileText(text)
        #expect(shown == .notShown(ProfileText.unreadable), "\(text)")
        #expect(!shown.text.contains("hunter2") && !shown.text.contains("hello"))
    }

    @Test func aPlistThatIsntADictionaryIsShown() throws {
        let (text, masked) = try Self.shown("<plist version=\"1.0\"><array><string>a</string><integer>1</integer></array></plist>")
        #expect(masked == 0 && text.contains("<string>a</string>"))
    }

    // MARK: The bounds

    /// A plist of exactly `count` UTF-8 bytes.
    static func plist(bytes count: Int) -> String {
        let head = "<plist version=\"1.0\"><string>", tail = "</string></plist>"
        return head + String(repeating: "a", count: count - head.utf8.count - tail.utf8.count) + tail
    }

    @Test func theInputIsBoundedBeforeAnythingReadsIt() throws {
        let limit = ProfileText.maximumBytes
        #expect(limit == 1 << 20)
        let atLimit = Self.plist(bytes: limit)
        #expect(atLimit.utf8.count == limit)
        #expect(try Self.shown(atLimit).masked == 0)
        let over = Self.plist(bytes: limit + 1)
        #expect(ProfileText(over) == .notShown(ProfileText.tooLarge(bytes: limit + 1)))
        // Counted in bytes, not characters: 2-byte letters past the limit by byte count.
        let wide = "<plist version=\"1.0\"><string>" + String(repeating: "\u{E9}", count: limit / 2) + "</string></plist>"
        #expect(ProfileText(wide) == .notShown(ProfileText.tooLarge(bytes: wide.utf8.count)))
        // Base64 that would decode past the limit is refused as text first.
        #expect(ProfileText(String(repeating: "A", count: limit + 4)) == .notShown(ProfileText.tooLarge(bytes: limit + 4)))
        #expect(ProfileText.tooLarge(bytes: 5).contains("5 bytes"))
    }

    /// A DTD's internal subset is where XML entities live (an entity bomb, an external entity): the only declaration
    /// passed to the parser is Apple's own plist DOCTYPE, in either of its public identifiers.
    @Test(arguments: [
        "<!DOCTYPE plist [<!ENTITY a \"aaaaaaaaaa\">]><plist version=\"1.0\"><string>&a;</string></plist>",
        "<!DOCTYPE plist SYSTEM \"file:///etc/passwd\"><plist version=\"1.0\"><string>x</string></plist>",
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\" [<!ENTITY a \"b\">]><plist version=\"1.0\"><string>x</string></plist>",
        "<plist version=\"1.0\"><!ENTITY a \"b\"><string>x</string></plist>",
        "<!doctype plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><string>x</string></plist>",
        "<!ELEMENT plist ANY><plist version=\"1.0\"><string>x</string></plist>",
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><string>x</string></plist>",
        "<![IGNORE[ x ]]><plist version=\"1.0\"><string>x</string></plist>",
    ])
    func aDeclarationIsRefused(text: String) {
        #expect(ProfileText(text) == .notShown(ProfileText.declaration), "\(text)")
        #expect(ProfileText(Data(text.utf8).base64EncodedString()) == .notShown(ProfileText.declaration))
    }

    @Test func applesDoctypeIsRead() throws {
        for identifier in ["-//Apple//DTD PLIST 1.0//EN", "-//Apple Computer//DTD PLIST 1.0//EN"] {
            let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"\(identifier)\"\n  \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><string>x</string></plist>"
            #expect(try Self.shown(text).masked == 0)
        }
        // A comment or CDATA mentioning a declaration is text, not one.
        let commented = "<plist version=\"1.0\"><!-- <!ENTITY a \"b\"> --><string><![CDATA[<!DOCTYPE x>]]></string></plist>"
        #expect(try Self.shown(commented).text.contains("&lt;!DOCTYPE x&gt;"))
    }

    /// The scan reads bytes, so a profile in another encoding would hide a declaration from it: refused.
    @Test(arguments: [
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?><plist version=\"1.0\"><string>x</string></plist>",
        "<?xml version=\"1.0\" encoding='UTF-7'?><plist version=\"1.0\"><string>x</string></plist>",
        "<plist version=\"1.0\"><string>x\u{0}</string></plist>",
    ])
    func anotherEncodingIsRefused(text: String) {
        #expect(ProfileText(text) == .notShown(ProfileText.notUTF8), "\(text)")
    }

    @Test func aUTF16ProfileIsRefused() {
        let utf16 = Data([0xFF, 0xFE]) + Self.profile.data(using: .utf16LittleEndian)!
        #expect(ProfileText(utf16.base64EncodedString()) == .notShown(ProfileText.notUTF8))
    }

    static func nested(_ depth: Int) -> String {
        "<plist version=\"1.0\">" + String(repeating: "<array>", count: depth) + "<string>x</string>"
            + String(repeating: "</array>", count: depth) + "</plist>"
    }

    /// Foundation's plist readers recurse once per level, so nesting is bounded before they run.
    @Test func nestingIsBoundedBeforeTheParser() throws {
        #expect(ProfileText.maximumDepth == 64)
        #expect(try Self.shown(Self.nested(ProfileText.maximumDepth)).masked == 0)
        #expect(ProfileText(Self.nested(ProfileText.maximumDepth + 1)) == .notShown(ProfileText.tooDeep))
        #expect(ProfileText(Self.nested(50_000)) == .notShown(ProfileText.tooDeep))
        // Empty containers don't nest, and closing tags count back down.
        let siblings = "<plist version=\"1.0\"><array>" + String(repeating: "<dict/><array></array>", count: 200) + "</array></plist>"
        #expect(try Self.shown(siblings).masked == 0)
        let dicts = "<plist version=\"1.0\">" + String(repeating: "<dict><key>k</key>", count: 65) + "<true/>" + String(repeating: "</dict>", count: 65) + "</plist>"
        #expect(ProfileText(dicts) == .notShown(ProfileText.tooDeep))
    }

    /// The scan itself, before any parser: its depth bound is the parser's guard, whatever the walk after it checks.
    @Test func theScanRefusesNestingAndDeclarationsItself() {
        func refusal(_ text: String) -> String? { ProfileText.xmlRefusal(Array(text.utf8), from: 0) }
        #expect(refusal(Self.nested(ProfileText.maximumDepth)) == nil)
        #expect(refusal(Self.nested(ProfileText.maximumDepth + 1)) == ProfileText.tooDeep)
        #expect(refusal("<plist version=\"1.0\"><dict/>" + Self.nested(ProfileText.maximumDepth).dropFirst(21)) == nil)
        #expect(refusal("<plist version=\"1.0\"></array><array>") == ProfileText.unreadable)
        #expect(refusal("<plist version=\"1.0\"><string>a</string></plist>") == nil)
        #expect(refusal("<plist version=\"1.0\"><!-- x") == ProfileText.unreadable)
        // Arrays, ordered sets, sets and dictionaries all nest.
        let containers = Self.bplist([[0x51, 0x78], Self.array([0]), [0xB0], [0xC0], [0xD0], Self.array([1, 0])])
        #expect(ProfileText.binaryContainers(Array(containers)) == 5)
        #expect(ProfileText.binaryContainers(Array("bplist00".utf8) + Array(repeating: 0, count: 40)) == nil)
    }

    // MARK: Binary plists, written by hand: Foundation's writer can't make the shapes an attacker can.

    /// A binary plist of `objects` (each its marker and body; references are 2 bytes), the last the top.
    static func bplist(_ objects: [[UInt8]]) -> Data {
        var bytes = Array("bplist00".utf8), offsets: [Int] = []
        for object in objects { offsets.append(bytes.count); bytes += object }
        let table = bytes.count
        for offset in offsets { bytes += [UInt8(offset >> 24 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)] }
        func be64(_ value: Int) -> [UInt8] { (0..<8).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) } }
        bytes += [0, 0, 0, 0, 0, 0, 4, 2] + be64(objects.count) + be64(objects.count - 1) + be64(table)
        return Data(bytes)
    }

    static func array(_ references: [Int]) -> [UInt8] {
        let count = references.count
        let head: [UInt8] = count < 15 ? [0xA0 | UInt8(count)]
            : count <= 0xFFFF ? [0xAF, 0x11, UInt8(count >> 8), UInt8(count & 0xFF)]
            : [0xAF, 0x12, UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        return head + references.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }

    @Test func aHandWrittenBinaryPlistReads() throws {
        let plist = Self.bplist([[0x51, 0x78], Self.array([0, 0])])
        #expect(try Self.shown(plist.base64EncodedString()).text.contains("<string>x</string>"))
    }

    /// Foundation shares an object referenced twice, so 25 levels of `[a, a]` are 2^25 strings to anything that walks
    /// them: the walk stops at `maximumValues`, counting the list and each string it visits.
    @Test func aSharedObjectCantMultiplyTheWalk() throws {
        var objects: [[UInt8]] = [[0x51, 0x78]]
        for level in 0..<25 { objects.append(Self.array([level, level])) }
        #expect(ProfileText(Self.bplist(objects).base64EncodedString()) == .notShown(ProfileText.tooMany))
        let limit = ProfileText.maximumValues
        #expect(limit == 200_000)
        let atLimit = Self.bplist([[0x51, 0x78], Self.array(Array(repeating: 0, count: limit - 1))])
        #expect(try Self.shown(atLimit.base64EncodedString()).masked == 0)
        let over = Self.bplist([[0x51, 0x78], Self.array(Array(repeating: 0, count: limit))])
        #expect(ProfileText(over.base64EncodedString()) == .notShown(ProfileText.tooMany))
    }

    @Test func aBinaryPlistsContainersAreBoundedBeforeTheParser() throws {
        // Many containers side by side: refused past the count, whatever their depth.
        let count = ProfileText.maximumContainers
        let atLimit = Self.bplist(Array(repeating: Self.array([]), count: count - 1) + [Self.array(Array(0..<(count - 1)))])
        #expect(try Self.shown(atLimit.base64EncodedString()).masked == 0)
        let over = Self.bplist(Array(repeating: Self.array([]), count: count) + [Self.array(Array(0..<count))])
        #expect(ProfileText(over.base64EncodedString()) == .notShown(ProfileText.tooMany))
        // A chain 65 deep is under the count, and the walk refuses it.
        var chain: [[UInt8]] = [[0x51, 0x78]]
        for level in 0..<(ProfileText.maximumDepth + 1) { chain.append(Self.array([level])) }
        #expect(ProfileText(Self.bplist(chain).base64EncodedString()) == .notShown(ProfileText.tooDeep))
        chain.removeLast()
        #expect(try Self.shown(Self.bplist(chain).base64EncodedString()).masked == 0)
    }

    /// Dictionaries one inside the next, about a hundred: under the container count, so Foundation reads them, and the
    /// walk refuses them past `maximumDepth` (Phase 2a review L4: with the walk's dictionary bound deleted, every test
    /// stayed green, since no binary plist nested 65 to 256 dictionaries).
    @Test func aDeepBinaryChainOfDictionariesIsTooDeep() throws {
        func chain(_ count: Int) -> Data {
            var objects: [[UInt8]] = [[0x51, 0x6B], [0x09]]
            for _ in 0..<count {
                let value = objects.count - 1
                objects.append([0xD1, 0x00, 0x00, UInt8(value >> 8), UInt8(value & 0xFF)])
            }
            return Self.bplist(objects)
        }
        #expect(ProfileText.binaryContainers(Array(chain(100))) == 100)
        #expect(ProfileText(chain(100).base64EncodedString()) == .notShown(ProfileText.tooDeep))
        #expect(ProfileText(chain(ProfileText.maximumDepth + 1).base64EncodedString()) == .notShown(ProfileText.tooDeep))
        let atBound = try Self.shown(chain(ProfileText.maximumDepth).base64EncodedString())
        #expect(atBound.masked == 0 && atBound.text.contains("<key>k</key>") && atBound.text.contains("<true/>"))
    }

    /// A trailer or offset table that points outside the bytes is refused, never handed on.
    @Test func aBrokenBinaryPlistIsRefused() {
        let good = Array(Self.bplist([[0x51, 0x78], Self.array([0])]))
        var badTable = good
        badTable[badTable.count - 1] = 0xFF
        var badOffset = good
        badOffset[badOffset.count - 32 - 1] = 0xF0
        var badSizes = good
        badSizes[badSizes.count - 26] = 0
        for bytes in [badTable, badOffset, badSizes, Array(good.prefix(20)), Array("bplist00".utf8)] {
            #expect(ProfileText(Data(bytes).base64EncodedString()) == .notShown(ProfileText.unreadable))
        }
    }
}
