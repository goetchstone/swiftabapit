import Foundation
import JSONAPI
import Testing
import TestSupport
@testable import Reports

/// abapit's `reports.py`, held to `Tests/Fixtures/parity/{csv,reports}.json` (invariant 6).
@Suite("Reports parity")
struct ReportsParityTests {
    /// The generator's FIXED_NOW, read from the golden itself rather than typed here (a typed epoch was once three
    /// days off).
    static var now: Date { ISODate.parse((try? Fixtures.parityValue("reports"))?["now"]?.string)?.date ?? .distantPast }

    static func cases(_ golden: String, _ function: String? = nil) throws -> [JSONObject] {
        let cases = try #require(try Fixtures.parityValue(golden)["cases"]?.array).compactMap(\.object)
        return function.map { name in cases.filter { $0["function"]?.string == name } } ?? cases
    }

    static func resources(_ value: JSONValue?) -> [Resource] { (value?.array ?? []).compactMap(Resource.init) }

    @Test func theGeneratorsNowIsRead() {
        #expect(Self.now == Date(timeIntervalSince1970: 1_792_152_000))
    }

    @Test func csvMatchesTheGoldenByteForByte() throws {
        let cases = try Self.cases("csv")
        #expect(cases.count == 70)
        for item in cases {
            let items = (item["input"]?.array ?? []).compactMap { value -> CSV.Item? in
                guard let id = value["id"]?.string else { return nil }
                return CSV.Item(id: id, attributes: value["attributes"]?.object ?? [:])
            }
            let expected = try #require(item["expected"]?.string)
            #expect(Array(CSV.text(items).utf8) == Array(expected.utf8), "\(expected.debugDescription)")
        }
    }

    /// The deviation: abapit wrote containers as Python's repr. Each deviating case holds a dict or a nested list.
    @Test func everyCSVDeviationIsAContainerCell() throws {
        let deviating = try Self.cases("csv").filter { $0["abapit"] != nil }
        #expect(!deviating.isEmpty)
        for item in deviating {
            let hasContainer = (item["input"]?.array ?? []).contains { value in
                (value["attributes"]?.object?.members ?? []).contains { member in
                    if case .object = member.value { return true }
                    if case .array(let items) = member.value { return items.contains { if case .object = $0 { true } else if case .array = $0 { true } else { false } } }
                    return false
                }
            }
            #expect(hasContainer)
        }
    }

    @Test func theExportPolicyDropsWhatMustNotLeave() {
        let items = [CSV.Item(id: "C02X", attributes: ["serialNumber": .string("C02X"), "lastConnectedIp": .string("192.0.2.1"),
                                                       "activation_bypass": .string("TESTBYPASS"), "accessToken": .string("x")])]
        let text = CSV.text(items, allowing: ExportPolicy.allowing())
        #expect(text == "id,serialNumber\r\nC02X,C02X\r\n")
        #expect(CSV.text(items, allowing: ExportPolicy.allowing(["serialNumber", "lastConnectedIp"], includeNotByDefault: true))
                == "id,serialNumber,lastConnectedIp\r\nC02X,C02X,192.0.2.1\r\n")
    }

    @Test func deviceStatsMatchTheGolden() throws {
        let cases = try Self.cases("reports", "device_stats")
        #expect(cases.count == 25)
        let now = Self.now
        for item in cases {
            let stats = DeviceStats(Self.resources(item["input"]?["devices"]), now: now)
            let expected = try #require(item["expected"]?["ok"])
            func tallies(_ key: String) -> [Tally] {
                (expected[key]?.array ?? []).compactMap { pair in
                    guard let name = pair.array?.first?.string, let count = pair.array?.last?.int else { return nil }
                    return Tally(name: name, count: count)
                }
            }
            #expect(stats.total == expected["total"]?.int)
            #expect(stats.byFamily == tallies("by_family"))
            #expect(stats.byStatus == tallies("by_status"))
            #expect(stats.topModels == tallies("top_models"))
            #expect(stats.added30 == expected["added_30"]?.int)
            #expect(stats.added90 == expected["added_90"]?.int)
            #expect(stats.addedByMonth == tallies("added_by_month"))
            #expect(stats.monthMax == expected["month_max"]?.int)
            #expect(stats.familyMax == expected["family_max"]?.int)
        }
    }

    @Test func assignmentSummaryMatchesTheGolden() throws {
        let cases = try Self.cases("reports", "assignment_summary")
        #expect(cases.count == 20)
        for item in cases {
            let input = try #require(item["input"])
            var ids: [String: [String]] = [:]
            for (key, value) in input["server_device_ids"]?.object ?? [:] { ids[key] = value.array?.compactMap(\.string) ?? [] }
            let summary = AssignmentSummary(devices: Self.resources(input["devices"]), services: Self.resources(input["servers"]), deviceIDs: ids)
            let expected = try #require(item["expected"]?["ok"])
            #expect(summary.unassigned == (expected["unassigned"]?.array ?? []).compactMap(\.string))
            #expect(summary.assignedCount == expected["assigned_count"]?.int)
            #expect(summary.perService.map(\.count) == (expected["per_server"]?.array ?? []).compactMap { $0["count"]?.int })
            #expect(summary.perService.map(\.service.id) == (expected["per_server"]?.array ?? []).compactMap { $0["server"]?["id"]?.string })
        }
    }
}
