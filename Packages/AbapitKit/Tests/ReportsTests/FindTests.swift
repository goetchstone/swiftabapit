import AppleModels
import JSONAPI
import Testing
import TestSupport
@testable import Reports

@Suite("Find")
struct FindTests {
    static func device(_ serial: String, id: String? = nil, imei: [String] = [], wifi: String? = nil, order: String? = nil,
                       more: JSONObject = [:]) -> OrgDevice {
        var attributes: JSONObject = ["serialNumber": .string(serial), "imei": .array(imei.map(JSONValue.string))]
        if let wifi { attributes["wifiMacAddress"] = .string(wifi) }
        if let order { attributes["orderNumber"] = .string(order) }
        for (key, value) in more { attributes[key] = value }
        return OrgDevice(resource: Resource(type: "orgDevices", id: id ?? serial, attributes: attributes))
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

    /// Every exact hit counts, as abapit's `exact` list does: an order number is every device's in that order, so
    /// it filters the table rather than opening one of them (verifier round 3: keeping the first exact hit only
    /// kept every test green, since no fleet had two devices with one identifier).
    @Test func everyExactHitFilters() {
        let fleet = [Self.device("C02XA1", order: "O-7"), Self.device("C02XA2", order: "O-7"), Self.device("C02XA3", order: "O-77")]
        #expect(Find.matches("o-7", in: fleet).map(\.id) == ["C02XA1", "C02XA2"])
        #expect(Find.matches("o-77", in: fleet).map(\.id) == ["C02XA3"])
    }

    /// abapit strips the query, never the identifiers (`value.lower() == needle`): an order number with a trailing
    /// space is not an exact hit, so the substring hits stand. And an empty query finds nothing, even a device
    /// whose identifier is empty, where abapit goes back to the list (verifier round 3: stripping the values, or
    /// dropping the empty-query guard, kept every test green).
    @Test func theIdentifiersAreNotStrippedAndNothingFindsAnEmptyOne() {
        let fleet = [Self.device("C02XA1", order: "O-1 "), Self.device("C02XA2", order: "O-12")]
        #expect(Find.matches("O-1", in: fleet).map(\.id) == ["C02XA1", "C02XA2"])
        #expect(Find.matches("o-1 ", in: fleet).map(\.id) == ["C02XA1", "C02XA2"])
        let blank = [Self.device("C02XA3", order: "")]
        #expect(blank[0].identifiers.contains(""))
        for query in ["", "   ", "\t\n", "\u{3000}"] {
            #expect(Find.matches(query, in: blank).isEmpty, "\(query.debugDescription)")
        }
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

    /// abapit compares code points (`value.lower() == needle`, `needle in value.lower()`), so canonically
    /// equivalent spellings are different identifiers (verifier round 1: `String`'s `==` and `contains` matched
    /// U+00C9 to `E` + U+0301, and missed `e` inside `e` + U+0301).
    @Test func identifiersAreMatchedByCodePoint() {
        let fleet = [Self.device("C02XA1", order: "E\u{301}X-1"), Self.device("C02XB2", order: "\u{C9}Y-2")]
        #expect(Find.matches("e", in: fleet).map(\.id) == ["C02XA1"])
        #expect(Find.matches("\u{E9}", in: fleet).map(\.id) == ["C02XB2"])
        #expect(Find.matches("\u{C9}X-1", in: fleet).isEmpty)
        #expect(Find.matches("e\u{301}x-1", in: fleet).map(\.id) == ["C02XA1"])
        #expect(Find.matches("\u{301}x", in: fleet).map(\.id) == ["C02XA1"])
    }

    /// abapit's identifiers are the id and eight fields (`serialNumber`, `imei`, `meid`, `eid`, `orderNumber` and
    /// the three MAC addresses). The id counts on its own: Apple's is the serial, but abapit yields both, so an id
    /// the serial doesn't repeat still finds the device. Nothing else is an identifier (verifier round 2: matching
    /// `deviceModel` too, or dropping the id, kept every test green).
    @Test func onlyTheIDAndTheIdentifiersAreMatched() {
        let device = Self.device("C02XQ1", id: "4F2E-ID", imei: ["351111"], order: "O-7", more: [
            "meid": .array([.string("35999901")]), "eid": .string("8904900"), "bluetoothMacAddress": .string("BB:01"),
            "ethernetMacAddress": .array([.string("EE:01")]), "deviceModel": .string("Mac mini (M4)"),
            "productFamily": .string("Mac"), "status": .string("ASSIGNED"), "color": .string("SILVER"),
            "partNumber": .string("MX123LL/A"), "productType": .string("Mac16,10"), "deviceCapacity": .string("512GB"),
            "purchaseSourceId": .string("PS-77"), "purchaseSourceType": .string("RESELLER"),
            "mdmMigrationStatus": .string("ELIGIBLE"), "addedToOrgDateTime": .string("2026-01-02T03:04:05Z"),
        ])
        let fleet = [device, Self.device("F9ZZ01")]
        for query in ["4f2e-id", "4F2E", "c02xq1", "351111", "o-7", "35999901", "8904900", "bb:01", "ee:01"] {
            #expect(Find.matches(query, in: fleet).map(\.id) == ["4F2E-ID"], "\(query)")
        }
        for query in ["mac", "mini", "Mac mini (M4)", "assigned", "silver", "mx123", "mac16", "512gb", "ps-77", "reseller",
                      "eligible", "2026-01", "orgDevices"] {
            #expect(Find.matches(query, in: fleet).isEmpty, "\(query)")
        }
    }

    /// Python's `lower()` makes a capital sigma that ends a word the final U+03C2, after skipping case-ignorable
    /// scalars both ways; Swift's `lowercased()` always gives U+03C3 (verifier round 2). Each expectation is
    /// what Python 3.12 gives.
    @Test func aFinalSigmaLowersAsPythonLowersIt() {
        func lower(_ text: String) -> [UInt8] { Find.lower(text) }
        #expect(lower("\u{39F}\u{394}\u{39F}\u{3A3}") == Array("\u{3BF}\u{3B4}\u{3BF}\u{3C2}".utf8))
        #expect(lower("\u{3A3}\u{391}\u{3A3} \u{3A3}\u{391}\u{3A3}") == Array("\u{3C3}\u{3B1}\u{3C2} \u{3C3}\u{3B1}\u{3C2}".utf8))
        #expect(lower("\u{3A3}") == Array("\u{3C3}".utf8))
        #expect(lower("A\u{3A3}'") == Array("a\u{3C2}'".utf8))
        #expect(lower("A\u{301}\u{3A3}") == Array("a\u{301}\u{3C2}".utf8))
        #expect(lower("\u{130}\u{3A3}") == Array("i\u{307}\u{3C2}".utf8))
        #expect(lower("'\u{3A3}") == Array("'\u{3C3}".utf8))
        #expect(lower("-\u{3A3}") == Array("-\u{3C3}".utf8))
        #expect(lower("A\u{3A3}\u{3A3}") == Array("a\u{3C3}\u{3C2}".utf8))
        #expect(lower("C02XA1") == Array("c02xa1".utf8))
        // Verifier round 3. A mark after the sigma makes one `Character` with it, so the sigma is looked for by
        // scalar. The nearest scalar counts, not the first. A scalar both cased and case-ignorable (U+02B0,
        // U+0345) is skipped. Cased is not alphabetic (U+4E2D isn't cased) and takes in titlecase (U+01C5).
        // Private use is never case-ignorable, whatever Apple's data says of U+F870.
        #expect(lower("A\u{3A3}\u{301}") == Array("a\u{3C2}\u{301}".utf8))
        #expect(lower("1A\u{3A3}") == Array("1a\u{3C2}".utf8))
        #expect(lower("\u{2B0}\u{3A3}") == Array("\u{2B0}\u{3C3}".utf8))
        #expect(lower("A\u{3A3}\u{2B0}") == Array("a\u{3C2}\u{2B0}".utf8))
        #expect(lower("A\u{3A3}\u{345}") == Array("a\u{3C2}\u{345}".utf8))
        #expect(lower("\u{4E2D}\u{3A3}") == Array("\u{4E2D}\u{3C3}".utf8))
        #expect(lower("A\u{3A3}\u{4E2D}") == Array("a\u{3C2}\u{4E2D}".utf8))
        #expect(lower("\u{1C5}\u{3A3}") == Array("\u{1C6}\u{3C2}".utf8))
        #expect(lower("A\u{3A3}\u{1C5}") == Array("a\u{3C3}\u{1C6}".utf8))
        #expect(lower("A\u{F870}\u{3A3}") == Array("a\u{F870}\u{3C3}".utf8))
        #expect(lower("A\u{3A3}\u{F870}B") == Array("a\u{3C2}\u{F870}b".utf8))

        // Order numbers lower to: a + final, sigma + b, c + period + final, d + sigma + apostrophe + s, e + sigma + e.
        let fleet = [Self.device("C02XS1", order: "A\u{3A3}"), Self.device("C02XS2", order: "\u{3A3}B"),
                     Self.device("C02XS3", order: "C.\u{3A3}"), Self.device("C02XS4", order: "D\u{3A3}'S"),
                     Self.device("C02XS5", order: "E\u{3A3}E")]
        #expect(Find.matches("\u{3A3}", in: fleet).map(\.id) == ["C02XS2", "C02XS4", "C02XS5"])
        #expect(Find.matches("\u{3C2}", in: fleet).map(\.id) == ["C02XS1", "C02XS3"])
        #expect(Find.matches("a\u{3A3}", in: fleet).map(\.id) == ["C02XS1"])
        #expect(Find.matches("c.\u{3C3}", in: fleet).isEmpty)
    }
}
