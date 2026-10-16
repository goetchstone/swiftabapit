import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// Invariant 11: CSV export is an allowlist (Phase 1b review M2). Each view names its columns; a key Apple sends
/// that isn't listed never leaves, and the denylist drops a listed one that must not leave anyway.
@Suite("Export policy")
struct ExportPolicyTests {
    /// The names the review exported through the old denylist-only mode, spelled the ways it tried: full-width,
    /// and split by a zero-width space.
    static let secretShaped = [
        "escrowKey", "recoveryKey", "fileVaultRecoveryKey", "privateKey", "apiKey", "assertion", "credential", "passcode",
        "pwd", "jwt", "bearer", "unlockPin", "\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}", "tok\u{200B}en",
        "activation_bypass", "activation_bypass_mdm", "activationLockBypassCode", "accessToken", "client_secret", "Password",
    ]

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    /// The first row (CR LF is one `Character`).
    static func header(_ text: String) -> String { String(text.prefix { $0 != "\r\n" }) }

    @Test func anExportWritesOnlyItsColumnsInItsOrder() {
        let items = [CSV.Item(id: "C02X", attributes: ["deviceModel": .string("Mac mini (M4)"), "unlisted": .string("harmless"),
                                                       "serialNumber": .string("C02X"), "color": .string("SILVER")])]
        #expect(Self.bytes(CSV.text(items, columns: ["serialNumber", "deviceModel"]))
                == Self.bytes("id,serialNumber,deviceModel\r\nC02X,C02X,Mac mini (M4)\r\n"))
        // A listed column no item has is still a column, empty; a repeated one is written once.
        #expect(Self.bytes(CSV.text(items, columns: ["color", "orderNumber", "color"]))
                == Self.bytes("id,color,orderNumber\r\nC02X,SILVER,\r\n"))
        #expect(Self.bytes(CSV.text(items, columns: [])) == Self.bytes("id\r\nC02X\r\n"))
    }

    @Test func aSecretShapedKeyNeverExportsListedOrNot() {
        for key in Self.secretShaped {
            #expect(ExportPolicy.isSensitive(key), "\(key.debugDescription)")
            let items = [CSV.Item(id: "C02X", attributes: ["serialNumber": .string("C02X"), key: .string("VALUE-THAT-MUST-NOT-LEAVE")])]
            for columns in [ExportPolicy.devices, ["serialNumber", key], [key]] {
                let text = CSV.text(items, columns: columns)
                #expect(!text.contains("VALUE-THAT-MUST-NOT-LEAVE"), "\(key.debugDescription) via \(columns)")
                #expect(!Self.header(text).contains(key), "\(key.debugDescription) in the header")
            }
        }
    }

    @Test func lastConnectedIpLeavesOnlyWhenAsked() {
        let items = [CSV.Item(id: "A0", attributes: ["serverName": .string("Mosyle"), "lastConnectedIp": .string("192.0.2.1")])]
        #expect(Self.bytes(CSV.text(items, columns: ["serverName", "lastConnectedIp"])) == Self.bytes("id,serverName\r\nA0,Mosyle\r\n"))
        #expect(Self.bytes(CSV.text(items, columns: ["serverName", "lastConnectedIp"], includeNotByDefault: true))
                == Self.bytes("id,serverName,lastConnectedIp\r\nA0,Mosyle,192.0.2.1\r\n"))
    }

    /// The Devices export: the table's columns first, then Apple's documented attributes, each once, none the
    /// denylist would drop (so a listed column can't vanish silently), and never a key Apple adds later.
    @Test func theDevicesExportIsTheTablesColumnsAndDocumentedAttributes() {
        let columns = ExportPolicy.devices
        #expect(Array(columns.prefix(5)) == ["serialNumber", "deviceModel", "productFamily", "status", "addedToOrgDateTime"])
        #expect(Set(columns).count == columns.count)
        #expect(Set(columns).isSubset(of: OrgDevice.fields))
        for column in columns {
            #expect(!ExportPolicy.isSensitive(column), "\(column)")
            #expect(!ExportPolicy.notByDefault.contains(column), "\(column)")
        }
        var attributes: JSONObject = [:]
        for field in OrgDevice.fields { attributes[field] = .string("x") }
        attributes["someFutureAttribute"] = .string("not yet")
        let header = Self.header(CSV.text([CSV.Item(id: "C02X", attributes: attributes)], columns: columns))
        #expect(Self.bytes(header) == Self.bytes((["id"] + columns).joined(separator: ",")))
    }

    /// The denylist reads a key folded: compatibility forms, case, and anything but letters and digits.
    @Test func theDenylistFoldsBeforeItMatches() {
        #expect(ExportPolicy.fold("\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}") == "token")
        #expect(ExportPolicy.fold("tok\u{200B}en") == "token")
        #expect(ExportPolicy.fold("API_Key-2") == "apikey2")
        for key in OrgDevice.fields + ["serverName", "deviceCount", "lastConnectedDateTime", "description", "agreementNumber"] {
            #expect(!ExportPolicy.isSensitive(key), "\(key)")
        }
    }
}
