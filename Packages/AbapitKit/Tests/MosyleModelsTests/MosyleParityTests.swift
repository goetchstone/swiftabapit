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

    /// A case's input: `input`, or `input_json` parsed here as abapit's httpx parsed it, so a number arrives as
    /// Mosyle wrote it (`1e20`) rather than as Python writes it back (`1e+20`): Phase 7a review L4.
    static func input(_ item: JSONObject) throws -> JSONValue? {
        guard let text = item["input_json"]?.string else { return item["input"] }
        return try #require(JSONValue.parse(text), "input_json must parse: \(text)")
    }

    static func describe(_ item: JSONObject) -> String {
        item["input_json"]?.string ?? item["input"].map(JSONValue.dumps) ?? "nil"
    }

    /// Includes the range's ends, the calendar before 1582 (proleptic, as Python's), and `int()` of any script's
    /// digits (Phase 7a review L4).
    @Test func timestampsMatchTheGolden() throws {
        let cases = try Self.cases("to_iso")
        #expect(cases.count == 81)
        for item in cases {
            let input = try Self.input(item)?["value"]
            #expect(Self.same(MosyleTime.iso(input).map(JSONValue.string) ?? .null, item["expected"] ?? .null), "\(Self.describe(item))")
        }
    }

    /// The hour is 1 to 12 and the date is a proleptic Gregorian one (`02/29/1500` is not): Phase 7a review L4.
    @Test func complianceStampsMatchTheGolden() throws {
        let cases = try Self.cases("compliance_time")
        #expect(cases.count == 39)
        for item in cases {
            let input = try Self.input(item)?["value"]
            #expect(Self.same(MosyleTime.compliance(input).map(JSONValue.string) ?? .null, item["expected"] ?? .null), "\(Self.describe(item))")
        }
    }

    /// Python's `str()` and `bool()` of what `json.loads` made of Mosyle's text: the ids, the family's words and a
    /// log's stamp lean on them (Phase 7a review L4: `1e20` was `1e20`, Python's is `1e+20`; `1e3` is `1000.0`).
    @Test func pythonStrAndTruthMatchTheGolden() throws {
        let strings = try Self.cases("py_str"), truths = try Self.cases("py_truthy")
        #expect(strings.count == 947 && truths.count == 24)
        for item in strings {
            let value = try Self.input(item)?["value"]
            #expect(Array(Python.str(value).utf8) == Array((item["expected"]?.string ?? "<missing>").utf8), "\(Self.describe(item))")
        }
        for item in truths {
            #expect(Python.truthy(try Self.input(item)?["value"]) == item["expected"]?.bool, "\(Self.describe(item))")
        }
    }

    /// The adapter keeps abapit's names and values for everything it maps, in abapit's order, and nothing else.
    @Test func devicesMatchTheGoldenWithinTheAllowlist() throws {
        let cases = try Self.cases("adapt_device")
        #expect(cases.count == 66)
        for item in cases {
            let raw = try #require(item["input"]?.object)
            let device = MosyleAdapter.device(raw)
            let expected = try #require(item["expected"])
            #expect(Array(device.id.utf8) == Array((expected["id"]?.string ?? "<missing>").utf8), "\(Self.describe(item))")
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
        let users = try Self.cases("adapt_user"), groups = try Self.cases("adapt_group")
        #expect(users.count == 27 && groups.count == 27)
        for item in users {
            let user = MosyleAdapter.user(try #require(item["input"]?.object))
            #expect(Self.same(user.asJSON, try #require(item["expected"])), "\(Self.describe(item))")
        }
        for item in groups {
            let input = try #require(item["input"])
            let group = MosyleAdapter.group(try #require(input["raw"]?.object), kind: input["kind"]?.string ?? "")
            #expect(Self.same(group.asJSON, try #require(item["expected"])), "\(Self.describe(item))")
        }
    }

    /// The user and group allowlists are the generator's (the golden's expectations are cut to them there).
    @Test func theUserAndGroupAllowlistsAreTheGoldens() throws {
        let lists = try #require(try Self.cases("allowlists").first?["expected"])
        #expect(MosyleAdapter.userAttributes == (lists["user"]?.array ?? []).compactMap(\.string))
        #expect(MosyleAdapter.groupAttributes == (lists["group"]?.array ?? []).compactMap(\.string))
    }

    /// Invariant 11, Phase 7a review L1: a user or a group passes an allowlist too. abapit kept every raw field, so
    /// a password, a token or a bypass code sent on one reached its page and its CSV.
    @Test func noSecretGetsPastTheUserAndGroupAdapters() throws {
        let raw: JSONObject = ["iduser": .string("U1"), "idusergroup": .string("G1"), "name": .string("Avery"),
                               "activation_bypass": .string("TESTBYPASS-1"), "activation_bypass_mdm": .string("TESTBYPASS-2"),
                               "password": .string("TESTSECRET-3"), "token": .string("TESTSECRET-4"), "apikey": .string("TESTSECRET-5"),
                               "accessToken": .string("TESTSECRET-6"), "no_such_field": .string("TESTSECRET-7")]
        let made = [MosyleAdapter.user(raw), MosyleAdapter.group(raw, kind: "userGroups"), MosyleAdapter.group(raw, kind: "deviceGroups")]
        for (resource, allowed) in zip(made, [MosyleAdapter.userAttributes, MosyleAdapter.groupAttributes, MosyleAdapter.groupAttributes]) {
            #expect(resource.attributes.keys.allSatisfy(allowed.contains), "\(resource.attributes.keys)")
            let text = JSONValue.dumps(.object(resource.attributes))
            #expect(!text.contains("TESTBYPASS") && !text.contains("TESTSECRET"), "\(text)")
        }
        #expect(made[0].attributes["name"] == .string("Avery") && made[0].id == "U1" && made[1].id == "G1")
        // And across the golden, whose inputs carry bypass codes, passwords and tokens.
        let inputs = try Self.cases("adapt_user").compactMap { $0["input"]?.object }
            + Self.cases("adapt_group").compactMap { $0["input"]?["raw"]?.object }
        #expect(inputs.contains { $0["password"] != nil } && inputs.contains { $0["activation_bypass"] != nil })
        for raw in inputs {
            for resource in [MosyleAdapter.user(raw), MosyleAdapter.group(raw, kind: "userGroups")] {
                #expect(!resource.attributes.keys.contains { key in
                    ["bypass", "password", "token", "secret", "apikey"].contains { key.lowercased().contains($0) }
                })
            }
        }
    }

    /// abapit's own `devices()` dedupe, through `deviceKey`: by value for a number (`123`, `123.0` and `1.23e2` are
    /// one key, `"123"` another, `true` is 1), by code points for a string (Swift's `==` merges "é" and
    /// "e" + U+0301), and a list or an object is no key (abapit raised `TypeError`): Phase 7a review L4.
    @Test func devicesDeduplicateAsAbapitsSetDid() throws {
        let cases = try Self.cases("dedupe_devices")
        #expect(cases.count == 10)
        for item in cases {
            let rows = (try Self.input(item)?.array ?? []).compactMap(\.object)
            var seen: Set<MosyleAdapter.DeviceKey> = [], kept: [JSONValue] = []
            for row in rows where MosyleAdapter.deviceKey(row).map({ seen.insert($0).inserted }) ?? true {
                kept.append(row["custom_index"] ?? .null)
            }
            #expect(Self.same(.array(kept), item["expected"] ?? .null), "\(Self.describe(item))")
        }
    }

    @Test func logsMatchTheGolden() throws {
        let cases = try Self.cases("normalize_logs")
        #expect(cases.count == 39)
        for item in cases {
            let events = MosyleLogs.normalize(try Self.input(item))
            #expect(Self.same(.array(events.map(JSONValue.object)), try #require(item["expected"])), "\(Self.describe(item))")
        }
    }

    /// The deviations: bypass codes dropped, a non-string serial's id written as Python's `str()`, users and
    /// groups cut to their allowlists, a list or an object serial kept where abapit raised, compliance stamps
    /// parsed, and a log entry that isn't an object skipped where abapit raised. Nothing else differs from abapit.
    @Test func theDeviationsAreTheListedOnes() throws {
        for item in try Self.cases("adapt_device") where item["abapit"] != nil {
            let input = try #require(item["input"])
            #expect(input["activation_bypass"] != nil || input["activation_bypass_mdm"] != nil || item["abapit"]?["id"]?.string == nil)
        }
        for (function, allowed) in [("adapt_user", MosyleAdapter.userAttributes), ("adapt_group", MosyleAdapter.groupAttributes)] {
            for item in try Self.cases(function) where item["abapit"] != nil {
                // Only dropped keys: what is left is abapit's, in abapit's order.
                let abapit = try #require(item["abapit"]?["attributes"]?.object)
                var cut = JSONObject()
                for (key, value) in abapit where allowed.contains(key) { cut[key] = value }
                #expect(Self.same(.object(cut), item["expected"]?["attributes"] ?? .null) && cut.count < abapit.count)
            }
        }
        for item in try Self.cases("dedupe_devices") where item["abapit"] != nil {
            #expect(item["abapit"] == .string("TypeError"))
        }
        for item in try Self.cases("normalize_logs") where item["abapit"] != nil {
            let abapit = JSONValue.dumps(item["abapit"]!)
            #expect(abapit.contains(" PM - ") || abapit.contains(" AM - ") || item["abapit"] == .string("AttributeError"))
        }
        for function in ["to_iso", "py_str", "py_truthy"] {
            #expect(try Self.cases(function).allSatisfy { $0["abapit"] == nil }, "\(function) matches abapit exactly")
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
