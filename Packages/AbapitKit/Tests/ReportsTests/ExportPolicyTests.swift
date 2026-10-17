import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// Invariant 11: CSV export is an allowlist (Phase 1b review M2). Each view names its columns; a key Apple sends
/// that isn't listed never leaves, and the denylist drops a listed one that must not leave anyway.
@Suite("Export policy")
struct ExportPolicyTests {
    /// The names the review exported through the old denylist-only mode, spelled the ways it tried: full-width,
    /// and split by a zero-width space. Then verifier round 1's: a `passwd` (the one stem no other name held), a
    /// modifier-letter and a mathematical-bold `TOKEN` (no lowercase of their own, so the fold's order matters),
    /// and marks a composed fold kept (`k` + U+0301 composes to U+1E31; U+0345 is Other_Alphabetic).
    static let secretShaped = [
        "escrowKey", "recoveryKey", "fileVaultRecoveryKey", "privateKey", "apiKey", "assertion", "credential", "passcode",
        "pwd", "jwt", "bearer", "unlockPin", "\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}", "tok\u{200B}en",
        "activation_bypass", "activation_bypass_mdm", "activationLockBypassCode", "accessToken", "client_secret", "Password",
        "unixPasswd", "\u{1D40}\u{1D3C}\u{1D37}\u{1D31}\u{1D3A}", "\u{1D413}\u{1D40E}\u{1D40A}\u{1D404}\u{1D40D}",
        "tok\u{301}en", "tok\u{345}en", "pa\u{301}ssword", "\u{D4E}token",
        // Verifier round 3: modifier letters that stay modifier letters, a modifier apostrophe, prime and
        // triangular colon, and the tatweel.
        "to\u{2BC}ken", "pass\u{2B9}word", "se\u{2D0}cret", "tok\u{640}en",
    ]

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    /// A column list as only Reports (and so this test) can make one.
    static func columns(_ names: [String]) -> ExportPolicy.Columns { ExportPolicy.Columns(names) }
    /// The first row (CR LF is one `Character`).
    static func header(_ text: String) -> String { String(text.prefix { $0 != "\r\n" }) }

    @Test func anExportWritesOnlyItsColumnsInItsOrder() {
        let items = [CSV.Item(id: "C02X", attributes: ["deviceModel": .string("Mac mini (M4)"), "unlisted": .string("harmless"),
                                                       "serialNumber": .string("C02X"), "color": .string("SILVER")])]
        #expect(Self.bytes(CSV.text(items, columns: Self.columns(["serialNumber", "deviceModel"])))
                == Self.bytes("id,serialNumber,deviceModel\r\nC02X,C02X,Mac mini (M4)\r\n"))
        // A listed column no item has is still a column, empty; a repeated one is written once.
        #expect(Self.bytes(CSV.text(items, columns: Self.columns(["color", "orderNumber", "color"])))
                == Self.bytes("id,color,orderNumber\r\nC02X,SILVER,\r\n"))
        #expect(Self.bytes(CSV.text(items, columns: Self.columns([]))) == Self.bytes("id\r\nC02X\r\n"))
    }

    /// "Written once" compares code points, as `union` compares Apple's keys: NFC and NFD spellings are two
    /// attributes, so two columns (verifier round 1: a `String` dedupe merged them and no test saw it).
    @Test func aRepeatedColumnIsTheSameCodePoints() {
        let items = [CSV.Item(id: "C02X", attributes: ["\u{E9}": .string("nfc"), "e\u{301}": .string("nfd")])]
        #expect(Self.bytes(CSV.text(items, columns: Self.columns(["\u{E9}", "e\u{301}", "\u{E9}"])))
                == Self.bytes("id,\u{E9},e\u{301}\r\nC02X,nfc,nfd\r\n"))
    }

    @Test func aSecretShapedKeyNeverExportsListedOrNot() {
        for key in Self.secretShaped {
            #expect(ExportPolicy.isSensitive(key), "\(key.debugDescription)")
            let items = [CSV.Item(id: "C02X", attributes: ["serialNumber": .string("C02X"), key: .string("VALUE-THAT-MUST-NOT-LEAVE")])]
            // `includeNotByDefault` lets only `notByDefault` through, never a secret (verifier round 1: no test
            // passed it with a secret, and a mutant that skipped the denylist when it was set survived). And on a
            // list as long as the Devices one, before it and after it (verifier round 2: every list here had one or
            // two names, so a denylist skipped past ten columns survived).
            let devices = ExportPolicy.devices.names
            for names in [devices + [key], [key] + devices, ["serialNumber", key], [key]] {
                for includeNotByDefault in [false, true] {
                    let text = CSV.text(items, columns: Self.columns(names), includeNotByDefault: includeNotByDefault)
                    #expect(!text.contains("VALUE-THAT-MUST-NOT-LEAVE"), "\(key.debugDescription) via \(names), \(includeNotByDefault)")
                    #expect(!Self.header(text).contains(key), "\(key.debugDescription) in the header")
                    #expect(!ExportPolicy.permits(key, includeNotByDefault: includeNotByDefault), "\(key.debugDescription)")
                    if names.count > 2 {
                        #expect(Self.bytes(Self.header(text)) == Self.bytes((["id"] + devices).joined(separator: ",")), "\(key.debugDescription)")
                    }
                }
            }
        }
    }

    @Test func lastConnectedIpLeavesOnlyWhenAsked() {
        let items = [CSV.Item(id: "A0", attributes: ["serverName": .string("Mosyle"), "lastConnectedIp": .string("192.0.2.1")])]
        #expect(Self.bytes(CSV.text(items, columns: Self.columns(["serverName", "lastConnectedIp"]))) == Self.bytes("id,serverName\r\nA0,Mosyle\r\n"))
        #expect(Self.bytes(CSV.text(items, columns: Self.columns(["serverName", "lastConnectedIp"]), includeNotByDefault: true))
                == Self.bytes("id,serverName,lastConnectedIp\r\nA0,Mosyle,192.0.2.1\r\n"))
        // Read folded, as the denylist reads a key: another spelling is held back by default too (verifier round 2:
        // an exact match let `last_connected_ip` out unasked).
        let spellings = ["last_connected_ip", "LastConnectedIP", "LAST-CONNECTED-IP", "lastConnected\u{200B}Ip"]
        var attributes: JSONObject = [:]
        for spelling in spellings { attributes[spelling] = .string("192.0.2.1") }
        let spelled = [CSV.Item(id: "A0", attributes: attributes)]
        #expect(Self.bytes(CSV.text(spelled, columns: Self.columns(spellings))) == Self.bytes("id\r\nA0\r\n"))
        #expect(Self.bytes(CSV.text(spelled, columns: Self.columns(spellings), includeNotByDefault: true))
                == Self.bytes((["id"] + spellings).joined(separator: ",") + "\r\nA0,192.0.2.1,192.0.2.1,192.0.2.1,192.0.2.1\r\n"))
        #expect(!ExportPolicy.isNotByDefault("lastConnectedDateTime") && !ExportPolicy.isNotByDefault("connectedIp"))
        // The attribute named, not every name holding it (verifier round 3: a containment match survived).
        #expect(!ExportPolicy.isNotByDefault("lastConnectedIpCount") && !ExportPolicy.isNotByDefault("previousLastConnectedIp"))
    }

    /// The Devices export: the table's columns first, then every other documented attribute in Apple's order
    /// (verifier round 1: a subset check let a dropped or reordered column through), none the denylist would
    /// drop (so a listed column can't vanish silently), and never a key Apple adds later.
    @Test func theDevicesExportIsTheTablesColumnsAndDocumentedAttributes() {
        let columns = ExportPolicy.devices.names
        let table = ["serialNumber", "deviceModel", "productFamily", "status", "addedToOrgDateTime"]
        #expect(columns == table + OrgDevice.fields.filter { !table.contains($0) })
        #expect(Set(columns).count == columns.count)
        for column in columns {
            #expect(!ExportPolicy.isSensitive(column), "\(column)")
            #expect(!ExportPolicy.isNotByDefault(column), "\(column)")
        }
        var attributes: JSONObject = [:]
        for field in OrgDevice.fields { attributes[field] = .string("x") }
        attributes["someFutureAttribute"] = .string("not yet")
        let header = Self.header(CSV.text([CSV.Item(id: "C02X", attributes: attributes)], columns: ExportPolicy.devices))
        #expect(Self.bytes(header) == Self.bytes((["id"] + columns).joined(separator: ",")))
    }

    /// The denylist reads a key folded: compatibility forms, then case, and nothing but letters and numbers.
    @Test func theDenylistFoldsBeforeItMatches() {
        #expect(ExportPolicy.fold("\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}") == "token")
        #expect(ExportPolicy.fold("tok\u{200B}en") == "token")
        #expect(ExportPolicy.fold("API_Key-2") == "apikey2")
        // Decomposed before lowercasing: a modifier or mathematical capital has no lowercase until it is `T`.
        #expect(ExportPolicy.fold("\u{1D40}\u{1D3C}\u{1D37}\u{1D31}\u{1D3A}") == "token")
        #expect(ExportPolicy.fold("\u{1D413}\u{1D40E}\u{1D40A}\u{1D404}\u{1D40D}") == "token")
        // Decomposed, not composed, and marks dropped: `k` + U+0301 is not U+1E31, U+0345 is not a letter.
        #expect(ExportPolicy.fold("tok\u{301}en") == "token")
        #expect(ExportPolicy.fold("tok\u{345}en") == "token")
        #expect(ExportPolicy.fold("Pa\u{301}ss\u{2163}") == "passiv")
        // Every number category stays, Nd, Nl and No: U+0F2A TIBETAN DIGIT HALF ONE and U+10107 AEGEAN NUMBER ONE
        // have no decomposition, so they are kept as they are (verifier round 2: dropping No survived).
        #expect(Array(ExportPolicy.fold("Half\u{F2A}\u{10107}9").unicodeScalars) == Array("half\u{F2A}\u{10107}9".unicodeScalars))
        // Other letters stay; a modifier letter that decomposes stays as its letter, and one that doesn't is
        // dropped like the punctuation it looks like (verifier round 3).
        #expect(Array(ExportPolicy.fold("Serial\u{4E2D}\u{E01}").unicodeScalars) == Array("serial\u{4E2D}\u{E01}".unicodeScalars))
        #expect(ExportPolicy.fold("to\u{2BC}ken") == "token")
        #expect(ExportPolicy.fold("\u{2B0}\u{1D2C}") == "ha")
        for key in OrgDevice.fields + ["serverName", "deviceCount", "lastConnectedDateTime", "description", "agreementNumber"] {
            #expect(!ExportPolicy.isSensitive(key), "\(key)")
        }
    }
}
