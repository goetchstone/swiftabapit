import Foundation
import JSONAPI
import MosyleModels
import Testing
import TestSupport
@testable import Reports

/// abapit's Mosyle reports and its reconciliation, held to `Tests/Fixtures/parity/reports.json` (invariant 6): every value
/// compared as bytes (`JSONValue.dumps`, never `String ==`, whose canonical equivalence would pass an NFC serial for an NFD one).
@Suite("Mosyle reports parity")
struct MosyleReportsParityTests {
    static func cases(_ function: String) throws -> [JSONObject] { try ReportsParityTests.cases("reports", function) }
    static func resources(_ value: JSONValue?) -> [Resource] { ReportsParityTests.resources(value) }
    static func bytes(_ value: JSONValue?) -> [UInt8] { Array(JSONValue.dumps(value ?? .null).utf8) }

    static func row(_ row: Reconciliation.Row) -> JSONValue { .object(row.attributes) }

    /// 20 drawn org pairs, then six hand-written (`mosyle_edges`): serials joined after Python's `strip()` and `upper()`, a
    /// later duplicate replacing an earlier one, NFC and NFD as two serials, falsy Apple values giving way to Mosyle's, null
    /// and numeric statuses, code-point order, and the rates that need Python's `round`.
    @Test func reconciliationMatchesTheGolden() throws {
        let cases = try Self.cases("reconcile_enrollments")
        #expect(cases.count == 26)
        #expect(cases.allSatisfy { $0["abapit"] == nil })
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let report = Reconciliation(apple: Self.resources(input["abm_devices"]), mosyle: Self.resources(input["mosyle_devices"]))
            let expected = try #require(item["expected"]?["ok"])
            for (bucket, rows) in [("abm_only", report.appleOnly), ("both", report.both), ("mosyle_only", report.mosyleOnly)] {
                #expect(Self.bytes(.array(rows.map(Self.row))) == Self.bytes(expected[bucket]), "case \(index) \(bucket)")
            }
            let summary = try #require(expected["summary"])
            #expect(report.totalApple == summary["total_abm"]?.int, "case \(index)")
            #expect(report.totalMosyle == summary["total_mosyle"]?.int, "case \(index)")
            #expect(report.totalUnique == summary["total_unique"]?.int, "case \(index)")
            #expect(report.both.count == summary["both_count"]?.int, "case \(index)")
            #expect(report.appleOnly.count == summary["abm_only_count"]?.int, "case \(index)")
            #expect(report.mosyleOnly.count == summary["mosyle_only_count"]?.int, "case \(index)")
            #expect(report.enrollmentRate == summary["enrollment_rate"]?.double, "case \(index)")
        }
        // The hand-written pairs reach what the drawn ones don't: 3 of 16 is 18.75, which Python rounds to 18.8.
        let rates = cases.suffix(6).compactMap { $0["expected"]?["ok"]?["summary"]?["enrollment_rate"]?.double }
        #expect(rates.contains(18.8) && rates.contains(12.5) && rates.contains(0))
    }

    /// 15 drawn fleets, then four hand-written: a version spelled Unknown merged with the missing ones, ties by code point,
    /// NFC and NFD versions as two rows, an empty fleet, and a share of 3 in 16.
    @Test func osBreakdownMatchesTheGolden() throws {
        let cases = try Self.cases("mosyle_os_breakdown")
        #expect(cases.count == 19)
        for (index, item) in cases.enumerated() {
            let report = OSBreakdown(Self.resources(item["input"]?["devices"]))
            let expected = try #require(item["expected"]?["ok"])
            let rows: [JSONValue] = report.rows.map { .array([.string($0.version), .number(String($0.count)), .number(String($0.percent))]) }
            let golden = (expected["rows"]?.array ?? []).map { row in
                JSONValue.array((row.array ?? []).enumerated().map { $0.offset == 2 ? .number(String($0.element.double ?? -1)) : $0.element })
            }
            #expect(Self.bytes(.array(rows)) == Self.bytes(.array(golden)), "case \(index)")
            #expect(report.total == expected["total"]?.int, "case \(index)")
            #expect(report.maxCount == expected["max_count"]?.int, "case \(index)")
        }
    }

    /// 15 drawn fleets, then the same eleven devices at 0, 1, 30 and 31 days: exactly the threshold, a microsecond short, an
    /// offset, a naive date, a check-in ahead of now, unreadable dates, and equal ages kept in their order.
    @Test func staleDevicesMatchTheGolden() throws {
        let cases = try Self.cases("mosyle_stale_devices")
        #expect(cases.count == 19)
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let days = try #require(input["days"]?.int)
            let report = StaleDevices(Self.resources(input["devices"]), days: days, now: ReportsParityTests.now)
            let expected = try #require(item["expected"]?["ok"])
            let rows: [JSONValue] = report.rows.map { row in
                .object(["serial": .string(row.serial), "deviceModel": row.deviceModel, "productFamily": row.productFamily,
                         "osVersion": row.osVersion, "lastCheckIn": row.lastCheckIn, "currentUser": row.currentUser,
                         "days_stale": row.daysStale.map { .number(String($0)) } ?? .null])
            }
            #expect(Self.bytes(.array(rows)) == Self.bytes(expected["rows"]), "case \(index)")
            #expect(report.total == expected["total"]?.int, "case \(index)")
            #expect(report.staleCount == expected["stale_count"]?.int, "case \(index)")
            #expect(report.neverCount == expected["never_count"]?.int, "case \(index)")
            #expect(report.days == expected["days"]?.int, "case \(index)")
        }
        // The 30-day run (0, 1, 30, 31): exactly 30 days is stale, a microsecond less isn't.
        let edge = try #require(cases[cases.count - 2]["expected"]?["ok"]?["rows"]?.array?.compactMap { $0["serial"]?.string })
        #expect(edge.contains("EDGE") && !edge.contains("SHORT") && edge.contains("OFFSET") && edge.contains("NAIVE"))
    }

    /// 20 drawn devices, then three hand-written: equal dates in the order added, a missing type, falsy outcomes, and
    /// Python's `title()` over digits, `ß`, accents and a combining mark after an underscore.
    @Test func timelineMatchesTheGolden() throws {
        let cases = try Self.cases("device_timeline")
        #expect(cases.count == 23)
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let items = MergedTimeline.items(apple: input["abm_attrs"]?.object, mosyle: input["mosyle_attrs"]?.object,
                                             audit: input["audit_events"]?.array.map { $0.compactMap(Resource.init) })
            let shown: [JSONValue] = items.map {
                .object(["when": .string($0.when), "kind": .string($0.kind), "label": .string($0.label), "source": .string($0.source)])
            }
            #expect(Self.bytes(.array(shown)) == Self.bytes(item["expected"]?["ok"]), "case \(index)")
        }
        let labels = (cases[20]["expected"]?["ok"]?.array ?? []).compactMap { $0["label"]?.string }
        #expect(labels.contains("Iphone1X Added") && labels.contains("Event"))
    }

    /// Python's `round(x, 1)` rounds the double's exact value, a tie to even; `(x * 10).rounded() / 10` doesn't.
    @Test func roundingIsPythons() {
        #expect(Python.round1(18.75) == 18.8)
        #expect(Python.round1(0.25) == 0.2)
        #expect(Python.round1(0.35) == 0.3)
        #expect(Python.round1(2.675) == 2.7)
        #expect(Python.round1(100.0 / 3) == 33.3)
        #expect(Python.round1(200.0 / 3) == 66.7)
    }
}
