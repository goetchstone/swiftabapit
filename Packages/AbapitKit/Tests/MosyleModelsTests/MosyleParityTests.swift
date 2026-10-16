import Foundation
import JSONAPI
import Testing
import TestSupport
@testable import MosyleModels

/// abapit's `mosyle.py`, held to `Tests/Fixtures/parity/mosyle.json` (invariant 6), and invariant 11: no
/// Activation Lock bypass code gets past the adapter.
@Suite("Mosyle parity")
struct MosyleParityTests {
    static func cases(_ function: String) throws -> [JSONObject] {
        let root = try #require(JSONValue.parse(String(decoding: try Fixtures.parity("mosyle"), as: UTF8.self)))
        return (root["cases"]?.array ?? []).compactMap(\.object).filter { $0["function"]?.string == function }
    }

    /// Exact text and order: `==` on JSONObject ignores order, so this compares the serialized bytes.
    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool { Array(JSONValue.dumps(a).utf8) == Array(JSONValue.dumps(b).utf8) }

    @Test func timestampsMatchTheGolden() throws {
        let cases = try Self.cases("to_iso")
        #expect(cases.count == 19)
        for item in cases {
            let input = item["input"]?["value"]
            #expect(MosyleTime.iso(input).map(JSONValue.string) ?? .null == (item["expected"] ?? .null), "\(input.map(JSONValue.dumps) ?? "nil")")
        }
    }

    @Test func complianceStampsMatchTheGolden() throws {
        let cases = try Self.cases("compliance_time")
        #expect(cases.count == 9)
        for item in cases {
            #expect(MosyleTime.compliance(item["input"]?["value"]).map(JSONValue.string) ?? .null == (item["expected"] ?? .null))
        }
    }

    /// The adapter keeps abapit's names and values for everything it maps, in abapit's order, and nothing else.
    @Test func devicesMatchTheGoldenWithinTheAllowlist() throws {
        let cases = try Self.cases("adapt_device")
        #expect(cases.count == 60)
        for item in cases {
            let raw = try #require(item["input"]?.object)
            let device = MosyleAdapter.device(raw)
            let expected = try #require(item["expected"])
            #expect(device.id == expected["id"]?.string)
            var allowed = JSONObject()
            for (key, value) in expected["attributes"]?.object ?? [:] where MosyleAdapter.deviceAttributes.contains(key) { allowed[key] = value }
            #expect(Self.same(.object(device.attributes), .object(allowed)), "\(JSONValue.dumps(.object(device.attributes)))")
            #expect(device.attributes.keys.allSatisfy(MosyleAdapter.deviceAttributes.contains))
        }
    }

    /// Invariant 11: a bypass code never reaches a model, whatever Mosyle sends.
    @Test func noBypassCodeGetsPastTheAdapter() throws {
        let cases = try Self.cases("adapt_device")
        #expect(cases.contains { $0["input"]?["activation_bypass"] != nil }, "the golden must carry bypass codes to test")
        for item in cases {
            let device = MosyleAdapter.device(try #require(item["input"]?.object))
            let text = JSONValue.dumps(.object(device.attributes))
            #expect(!text.contains("TESTBYPASS"))
            #expect(!device.attributes.keys.contains { $0.lowercased().contains("bypass") })
        }
        #expect(!MosyleAdapter.deviceColumns.contains { $0.contains("bypass") })
    }

    @Test func usersAndGroupsMatchTheGolden() throws {
        for item in try Self.cases("adapt_user") {
            let user = MosyleAdapter.user(try #require(item["input"]?.object))
            #expect(Self.same(user.asJSON, try #require(item["expected"])))
        }
        for item in try Self.cases("adapt_group") {
            let input = try #require(item["input"])
            let group = MosyleAdapter.group(try #require(input["raw"]?.object), kind: input["kind"]?.string ?? "")
            #expect(Self.same(group.asJSON, try #require(item["expected"])))
        }
    }

    @Test func logsMatchTheGolden() throws {
        let cases = try Self.cases("normalize_logs")
        #expect(cases.count == 30)
        for item in cases {
            let events = MosyleLogs.normalize(item["input"])
            #expect(Self.same(.array(events.map(JSONValue.object)), try #require(item["expected"])), "\(JSONValue.dumps(item["input"]!))")
        }
    }

    /// The deviations: bypass codes dropped, and compliance stamps parsed. Nothing else differs from abapit.
    @Test func theDeviationsAreTheListedOnes() throws {
        for item in try Self.cases("adapt_device") where item["abapit"] != nil {
            #expect(item["input"]?["activation_bypass"] != nil || item["input"]?["activation_bypass_mdm"] != nil)
        }
        for item in try Self.cases("normalize_logs") where item["abapit"] != nil {
            #expect(JSONValue.dumps(item["abapit"]!).contains(" PM - ") || JSONValue.dumps(item["abapit"]!).contains(" AM - "))
        }
    }

    @Test func theEnvelopeReadsTheEntrysStatusNotTheTopLevel() throws {
        let missing = try #require(MosyleEnvelope(Data(#"{"status":"OK","response":[{"status":"MISSING_DATA","info":"os is required"}]}"#.utf8)))
        #expect(missing.failure == .known(.missingData))
        let end = try #require(MosyleEnvelope(Data(#"{"status":"OK","response":[{"status":"DEVICES_NOTFOUND"}]}"#.utf8)))
        #expect(end.failure == nil && end.list("devices").isEmpty)
        let page = try #require(MosyleEnvelope(Data(#"{"status":"OK","response":[{"devices":[{"serial_number":"X"}],"rows":"1200","page":1}]}"#.utf8)))
        #expect(page.list("devices").count == 1 && page.total == 1200 && page.failure == nil)
        let groups = try #require(MosyleEnvelope(Data(#"{"response":{"status":"OK","devicegroups":[{"id":"1"}],"rows_count":3}}"#.utf8)))
        #expect(groups.list("devicegroups", "groups").count == 1 && groups.total == 3)
        let unknown = try #require(MosyleEnvelope(Data(#"{"status":"OK","response":[{"status":"SOMETHING_NEW"}]}"#.utf8)))
        #expect(unknown.failure == .unknown("SOMETHING_NEW"), "an unknown status fails closed")
        for sent in ["COMMAND_SENT", "COMMAND_SENDED"] {
            #expect(MosyleEnvelope(Data(#"{"response":[{"status":"\#(sent)"}]}"#.utf8))?.failure == nil)
        }
    }
}
