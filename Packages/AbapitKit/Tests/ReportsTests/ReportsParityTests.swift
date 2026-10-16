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
        // scalar, the wider formula guard, NFC and NFD keys; then verifier round 1's: invisible leads and look-alike
        // triggers, rows of empty fields, JSON keys past the BMP, and a list inside a list.
        #expect(cases.count == 86)
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

    /// The deviations: abapit wrote containers as Python's repr, and its guard missed look-alike triggers and a
    /// trigger after invisible leads. Each deviating case holds one of those, and the list doesn't grow unseen.
    @Test func everyCSVDeviationIsAContainerOrTheWiderGuard() throws {
        let deviating = try Self.cases("csv").filter { $0["abapit"] != nil }
        #expect(deviating.count == 41)
        var wider = 0
        for item in deviating {
            let items = Self.items(item)
            let container = items.contains { $0.attributes.members.contains { Self.isContainer($0.value) } }
            let cells = items.flatMap { [$0.id] + $0.attributes.keys + $0.attributes.members.map { CSV.cell($0.value) } }
            let widerGuard = cells.contains { CSV.safe($0) != $0 && !Self.abapitGuards($0) }
            if widerGuard { wider += 1 }
            #expect(container || widerGuard)
        }
        #expect(wider == 5)
    }

    /// The guard's sets are the golden's, scalar by scalar: what may lead unseen (check_text.py's invisible, which
    /// holds Python's whitespace) and what reads as a trigger (verifier round 1). Python and Swift each derive
    /// theirs from Unicode properties, so a property that moves between their Unicode versions shows here.
    @Test func theGuardsSetsAreTheGoldens() throws {
        let golden = try Fixtures.parityValue("csv")
        var blank: Set<UInt32> = []
        for run in try #require(golden["blank"]?.array) {
            let bounds = (run.array ?? []).compactMap(\.int)
            try #require(bounds.count == 2)
            blank.formUnion(UInt32(bounds[0])...UInt32(bounds[1]))
        }
        let triggers = Set(try #require(golden["triggers"]?.array).compactMap(\.int).map(UInt32.init))
        #expect(blank.count == 4291)
        #expect(triggers.count == 22)
        var wrongBlank: [UInt32] = [], wrongTrigger: [UInt32] = []
        for value in UInt32(0)..<0x110000 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if CSV.isBlank(scalar) != blank.contains(value) { wrongBlank.append(value) }
            if CSV.isTrigger(scalar) != triggers.contains(value) { wrongTrigger.append(value) }
        }
        #expect(wrongBlank.isEmpty, "\(wrongBlank.prefix(20).map { String($0, radix: 16) })")
        #expect(wrongTrigger.isEmpty, "\(wrongTrigger.prefix(20).map { String($0, radix: 16) })")
    }

    /// The wider guard, cell by cell: what abapit guarded is still guarded, and the deviation adds only cells
    /// whose first visible scalar is a trigger or reads as one.
    @Test func theFormulaGuardCatchesWhatAbapitDidAndTheListedRest() {
        for text in ["=1", "+1", "-1", "@x", "\tx", "\rx", "\r\n=1", "=\u{301}x", "\t plain"] {
            #expect(CSV.safe(text) == "'" + text, "\(text.debugDescription)")
            #expect(Self.abapitGuards(text), "\(text.debugDescription)")
        }
        for text in ["\u{FF1D}1", "\u{FF0B}1", "\u{FF0D}1", "\u{FF20}x", " =1", "\u{A0}=1", "\u{2003}+1", "\u{3000}-1",
                     "\u{FEFF}=1", "\u{200B}=1", "\u{200E}@x", "\u{2060}=1", "\n=1", "\n \u{200B}\u{FF1D}1",
                     // Verifier round 1: other controls and separators, default-ignorables and U+2800 as leads;
                     // small, super- and subscript forms, U+2A75 and U+2212 as triggers.
                     "\u{0B}=1", "\u{0C}+1", "\u{1C}-1", "\u{85}=1", "\u{2028}=1", "\u{2029}@x", "\u{0}=1", "\u{1}=1",
                     "\u{3164}=1", "\u{115F}=1", "\u{FFA0}=1", "\u{2800}=1", "\u{34F}=1", "\u{FE0F}=1",
                     "\u{FE66}1", "\u{FE62}1", "\u{FE63}1", "\u{FE6B}x", "\u{207A}1", "\u{208C}1", "\u{207B}1", "\u{2A75}1",
                     "\u{2212}1", "\u{A0}\u{2212}1"] {
            #expect(CSV.safe(text) == "'" + text, "\(text.debugDescription)")
            #expect(!Self.abapitGuards(text), "\(text.debugDescription)")
        }
        // A combining mark shows (and nothing trims it), a hyphen, a heavy minus and a plus-minus aren't signs.
        for text in ["", "plain", " lead", "\u{200B}plain", "\n plain", "x=1", "'=1", "\u{301}=1", "\u{20DD}+1",
                     "\u{2028}plain", "\u{2010}1", "\u{2796}1", "\u{B1}1", "x\u{2212}1"] {
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

    /// A breakdown as bytes and counts: `Tally`'s `==` compares names as `String`s, which canonical equivalence
    /// would let an NFC name pass for an NFD one (verifier round 1).
    static func bytes(_ tallies: [Tally]) -> [[UInt8]] { tallies.map { Array($0.name.utf8) + [0xFF] + Array(String($0.count).utf8) } }

    /// 25 drawn fleets, then five hand-written ones (Phase 1b review, LOW): thirteen models (the top-10 cap), the
    /// values `or "Unknown"` reads (null, `0`, `0.0`, `false`, `true`, `5`, `""`, `"0"`), months in the
    /// timestamp's own offset across a month boundary, and the exact 30- and 90-day boundaries. Then verifier
    /// round 1's two: whitespace-only names and NFC and NFD spellings of one name, each its own row as in Python;
    /// and the one listed deviation, rows by the name shown (Python's Counter merges `True`, `1` and `1.0`, and
    /// keeps `"5"` and `5` as two rows named `5`).
    @Test func deviceStatsMatchTheGolden() throws {
        let cases = try Self.cases("reports", "device_stats")
        #expect(cases.count == 32)
        #expect(cases.indices.filter { cases[$0]["abapit"] != nil } == [31])
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
            #expect(Self.bytes(stats.byFamily) == Self.bytes(try tallies("by_family")), "case \(index)")
            #expect(Self.bytes(stats.byStatus) == Self.bytes(try tallies("by_status")), "case \(index)")
            #expect(Self.bytes(stats.topModels) == Self.bytes(try tallies("top_models")), "case \(index)")
            #expect(stats.added30 == expected["added_30"]?.int, "case \(index)")
            #expect(stats.added90 == expected["added_90"]?.int, "case \(index)")
            #expect(Self.bytes(stats.addedByMonth) == Self.bytes(try tallies("added_by_month")), "case \(index)")
            #expect(stats.monthMax == expected["month_max"]?.int, "case \(index)")
            #expect(stats.familyMax == expected["family_max"]?.int, "case \(index)")
        }
        // The hand-written fleets reach what the drawn ones don't.
        let edges = cases.suffix(7).compactMap { $0["expected"]?["ok"] }
        #expect(edges.contains { ($0["top_models"]?.array?.count ?? 0) == 10 })
        #expect(edges.contains { ($0["by_status"]?.array ?? []).contains { $0.array?.first?.bool == true } })
        let names = edges.flatMap { ($0["top_models"]?.array ?? []) + ($0["by_status"]?.array ?? []) }.compactMap { $0.array?.first?.string }
        #expect(names.contains(" ") && names.contains("\u{3000}"))
        #expect(names.contains { Array($0.utf8) == Array("Caf\u{E9}".utf8) } && names.contains { Array($0.utf8) == Array("Cafe\u{301}".utf8) })
    }

    @Test func assignmentSummaryMatchesTheGolden() throws {
        let cases = try Self.cases("reports", "assignment_summary")
        // 20 drawn, then verifier round 1's NFC and NFD spellings of one serial: two devices, as in Python.
        #expect(cases.count == 21)
        for item in cases {
            let input = try #require(item["input"])
            var ids: [String: [String]] = [:]
            for (key, value) in input["server_device_ids"]?.object ?? [:] { ids[key] = value.array?.compactMap(\.string) ?? [] }
            let summary = AssignmentSummary(devices: Self.resources(input["devices"]), services: Self.resources(input["servers"]), deviceIDs: ids)
            let expected = try #require(item["expected"]?["ok"])
            #expect(summary.unassigned.map { Array($0.utf8) } == (expected["unassigned"]?.array ?? []).compactMap(\.string).map { Array($0.utf8) })
            #expect(summary.assignedCount == expected["assigned_count"]?.int)
            #expect(summary.perService.map(\.count) == (expected["per_server"]?.array ?? []).compactMap { $0["count"]?.int })
            #expect(summary.perService.map(\.service.id) == (expected["per_server"]?.array ?? []).compactMap { $0["server"]?["id"]?.string })
        }
    }
}
