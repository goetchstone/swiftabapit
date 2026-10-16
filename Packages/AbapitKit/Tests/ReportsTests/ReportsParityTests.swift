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

    static func items(_ item: JSONObject) -> [CSV.Item] {
        (item["input"]?.array ?? []).compactMap { value -> CSV.Item? in
            guard let id = value["id"]?.string else { return nil }
            return CSV.Item(id: id, attributes: value["attributes"]?.object ?? [:])
        }
    }

    /// The writer with abapit's columns (every key, first seen first): the golden's shape. No export takes this
    /// path; `CSV.text` takes a column list.
    @Test func csvMatchesTheGoldenByteForByte() throws {
        let cases = try Self.cases("csv")
        // 70 drawn, then the hand-written ones: the Phase 1b review's H1 payloads, CR LF and combining marks by
        // scalar, the wider formula guard, NFC and NFD keys.
        #expect(cases.count == 79)
        for (index, item) in cases.enumerated() {
            let items = Self.items(item)
            let expected = try #require(item["expected"]?.string)
            #expect(Array(CSV.write(items, columns: CSV.union(items)).utf8) == Array(expected.utf8), "case \(index): \(expected.debugDescription)")
        }
    }

    /// abapit's own guard: a tab, a CR or one of its four triggers as the first code point.
    static func abapitGuards(_ text: String) -> Bool { text.unicodeScalars.first.map { "=+-@\t\r".unicodeScalars.contains($0) } ?? false }

    static func isContainer(_ value: JSONValue) -> Bool {
        if case .object = value { return true }
        if case .array(let items) = value { return items.contains { if case .object = $0 { true } else if case .array = $0 { true } else { false } } }
        return false
    }

    /// The deviations: abapit wrote containers as Python's repr, and its guard missed full-width triggers and a
    /// trigger after leading blanks. Each deviating case holds one of those, and the list doesn't grow unseen.
    @Test func everyCSVDeviationIsAContainerOrTheWiderGuard() throws {
        let deviating = try Self.cases("csv").filter { $0["abapit"] != nil }
        #expect(deviating.count == 37)
        var wider = 0
        for item in deviating {
            let items = Self.items(item)
            let container = items.contains { $0.attributes.members.contains { Self.isContainer($0.value) } }
            let cells = items.flatMap { [$0.id] + $0.attributes.keys + $0.attributes.members.map { CSV.cell($0.value) } }
            let widerGuard = cells.contains { CSV.safe($0) != $0 && !Self.abapitGuards($0) }
            if widerGuard { wider += 1 }
            #expect(container || widerGuard)
        }
        #expect(wider == 3)
    }

    /// The wider guard, cell by cell: what abapit guarded is still guarded, and the deviation adds only
    /// full-width triggers and triggers after Unicode spaces, format characters, tab, CR or LF.
    @Test func theFormulaGuardCatchesWhatAbapitDidAndTheListedRest() {
        for text in ["=1", "+1", "-1", "@x", "\tx", "\rx", "\r\n=1", "=\u{301}x", "\t plain"] {
            #expect(CSV.safe(text) == "'" + text, "\(text.debugDescription)")
            #expect(Self.abapitGuards(text), "\(text.debugDescription)")
        }
        for text in ["\u{FF1D}1", "\u{FF0B}1", "\u{FF0D}1", "\u{FF20}x", " =1", "\u{A0}=1", "\u{2003}+1", "\u{3000}-1",
                     "\u{FEFF}=1", "\u{200B}=1", "\u{200E}@x", "\u{2060}=1", "\n=1", "\n \u{200B}\u{FF1D}1"] {
            #expect(CSV.safe(text) == "'" + text, "\(text.debugDescription)")
            #expect(!Self.abapitGuards(text), "\(text.debugDescription)")
        }
        for text in ["", "plain", " lead", "\u{200B}plain", "\n plain", "x=1", "'=1", "\u{301}=1", "\u{2028}=1"] {
            #expect(CSV.safe(text) == text, "\(text.debugDescription)")
        }
    }

    /// Quoting by scalar (Phase 1b review H1): a quote followed by a combining mark is still a quote, and a
    /// CR LF (one `Character`) still forces quotes.
    @Test func quotesAreDecidedAndDoubledByScalar() {
        #expect(Array(CSV.quoted("Mosyle\"\u{301},=2+5").unicodeScalars) == Array("\"Mosyle\"\"\u{301},=2+5\"".unicodeScalars))
        #expect(Array(CSV.quoted("a\r\nb").unicodeScalars) == Array("\"a\r\nb\"".unicodeScalars))
        #expect(Array(CSV.quoted("\"\u{20DD}").unicodeScalars) == Array("\"\"\"\u{20DD}\"".unicodeScalars))
        #expect(Array(CSV.quoted("plain\u{301}").unicodeScalars) == Array("plain\u{301}".unicodeScalars))
    }

    /// A Counter key as abapit shows it, Python's `str(key)`: the golden holds a number or a boolean key as JSON
    /// (`[5, 2]`, `[true, 2]`), and the input's number text is what Python's `json` wrote, so it reads the same.
    static func pythonName(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: text
        case .number(let text)?: text
        case .bool(let flag)?: flag ? "True" : "False"
        default: nil
        }
    }

    /// 25 drawn fleets, then five hand-written ones (Phase 1b review, LOW): thirteen models (the top-10 cap), the
    /// values `or "Unknown"` reads (null, `0`, `0.0`, `false`, `true`, `5`, `""`, `"0"`), months in the
    /// timestamp's own offset across a month boundary, and the exact 30- and 90-day boundaries.
    @Test func deviceStatsMatchTheGolden() throws {
        let cases = try Self.cases("reports", "device_stats")
        #expect(cases.count == 30)
        let now = Self.now
        for (index, item) in cases.enumerated() {
            let stats = DeviceStats(Self.resources(item["input"]?["devices"]), now: now)
            let expected = try #require(item["expected"]?["ok"])
            func tallies(_ key: String) throws -> [Tally] {
                try (expected[key]?.array ?? []).map { pair in
                    Tally(name: try #require(Self.pythonName(pair.array?.first), "case \(index) \(key)"),
                          count: try #require(pair.array?.last?.int))
                }
            }
            #expect(stats.total == expected["total"]?.int, "case \(index)")
            #expect(stats.byFamily == (try tallies("by_family")), "case \(index)")
            #expect(stats.byStatus == (try tallies("by_status")), "case \(index)")
            #expect(stats.topModels == (try tallies("top_models")), "case \(index)")
            #expect(stats.added30 == expected["added_30"]?.int, "case \(index)")
            #expect(stats.added90 == expected["added_90"]?.int, "case \(index)")
            #expect(stats.addedByMonth == (try tallies("added_by_month")), "case \(index)")
            #expect(stats.monthMax == expected["month_max"]?.int, "case \(index)")
            #expect(stats.familyMax == expected["family_max"]?.int, "case \(index)")
        }
        // The hand-written fleets reach what the drawn ones don't.
        let edges = cases.suffix(5).compactMap { $0["expected"]?["ok"] }
        #expect(edges.contains { ($0["top_models"]?.array?.count ?? 0) == 10 })
        #expect(edges.contains { ($0["by_status"]?.array ?? []).contains { $0.array?.first?.bool == true } })
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
