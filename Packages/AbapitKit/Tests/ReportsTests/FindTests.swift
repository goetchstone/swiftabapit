import AppleModels
import JSONAPI
import Testing
import TestSupport
@testable import Reports

@Suite("Find")
struct FindTests {
    static func device(_ serial: String, imei: [String] = [], wifi: String? = nil, order: String? = nil) -> OrgDevice {
        var attributes: JSONObject = ["serialNumber": .string(serial), "imei": .array(imei.map(JSONValue.string))]
        if let wifi { attributes["wifiMacAddress"] = .string(wifi) }
        if let order { attributes["orderNumber"] = .string(order) }
        return OrgDevice(resource: Resource(type: "orgDevices", id: serial, attributes: attributes))
    }

    static let fleet = [device("C02XA1", imei: ["351234"], wifi: "AA:BB:CC:00:11:22", order: "O-100"),
                        device("C02XA2", imei: ["359999"], order: "O-1000"), device("F9ZZ01")]

    @Test func anExactIdentifierFindsOneDeviceCaseInsensitively() {
        #expect(Find.matches("c02xa1", in: Self.fleet).map(\.id) == ["C02XA1"])
        #expect(Find.matches(" 351234 ", in: Self.fleet).map(\.id) == ["C02XA1"])
        #expect(Find.matches("aa:bb:cc:00:11:22", in: Self.fleet).map(\.id) == ["C02XA1"])
        // Exact beats substring: O-100 is exactly one device's order, and a substring of another's.
        #expect(Find.matches("O-100", in: Self.fleet).map(\.id) == ["C02XA1"])
    }

    @Test func otherwiseSubstringsFilter() {
        #expect(Find.matches("C02X", in: Self.fleet).map(\.id) == ["C02XA1", "C02XA2"])
        #expect(Find.matches("nothing", in: Self.fleet).isEmpty)
        #expect(Find.matches("   ", in: Self.fleet).isEmpty)
    }

    /// abapit's `q.strip()` trims Python's whitespace, which the serials golden lists. A pasted serial brings a
    /// tab, a line break or a no-break space; each still finds the one device (Phase 1b review: a spaces-only
    /// trim survived every test).
    @Test func pastedWhitespaceIsTrimmedAsPythonTrimsIt() throws {
        let whitespace = try #require(try Fixtures.parityValue("serials")["python_whitespace"]?.array).compactMap(\.int)
        #expect(whitespace.count == 29)
        #expect(Find.pythonWhitespace == Set(whitespace.map(UInt32.init)))
        for point in whitespace {
            let blank = String(Character(try #require(Unicode.Scalar(UInt32(point)))))
            let label = "U+\(String(point, radix: 16))"
            #expect(Find.matches(blank + "c02xa1" + blank + blank, in: Self.fleet).map(\.id) == ["C02XA1"], "\(label)")
            #expect(Find.matches(blank, in: Self.fleet).isEmpty, "\(label)")
        }
        #expect(Find.matches("\r\nC02XA1\r\n", in: Self.fleet).map(\.id) == ["C02XA1"])
        #expect(Find.matches("\t351234\n", in: Self.fleet).map(\.id) == ["C02XA1"])
        // Not whitespace to Python, so not trimmed: after a zero-width space or a BOM nothing matches exactly, and
        // the needle is no device's substring either.
        #expect(Find.matches("\u{200B}C02XA1", in: Self.fleet).isEmpty)
        #expect(Find.matches("C02XA1\u{FEFF}", in: Self.fleet).isEmpty)
        // Inner whitespace stays: "O-100", a no-break space, "0" is nobody's order.
        #expect(Find.matches("O-100\u{A0}0", in: Self.fleet).isEmpty)
    }
}
