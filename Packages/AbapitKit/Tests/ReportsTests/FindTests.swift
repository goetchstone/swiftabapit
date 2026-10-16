import AppleModels
import JSONAPI
import Testing
import Reports

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
}
