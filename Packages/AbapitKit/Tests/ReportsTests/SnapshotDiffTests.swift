import Foundation
import JSONAPI
import Testing
import TestSupport
@testable import Reports

/// abapit's `diff_snapshots` and `item_label`, held to `Tests/Fixtures/parity/diff.json` (72 cases) and the diff reads
/// of `history.json` (invariant 6). Six cases carry the operator's two decisions of 2026-11-20 beside abapit's output.
@Suite("Snapshot diff")
struct SnapshotDiffTests {
    static func json(_ deltas: [SnapshotDiff.Delta]) -> JSONValue {
        var out = JSONObject()
        for delta in deltas {
            func item(_ item: SnapshotDiff.Item) -> JSONValue { .object(["id": .string(item.id), "attributes": .object(item.attributes)]) }
            out[delta.resource] = .object([
                "added": .array(delta.added.map(item)),
                "removed": .array(delta.removed.map(item)),
                "changed": .array(delta.changed.map { change in
                    .object(["id": .string(change.id), "attributes": .object(change.attributes),
                             "fields": .array(change.fields.map { .object(["field": .string($0.field), "old": $0.old, "new": $0.new]) })])
                }),
            ])
        }
        return .object(out)
    }

    static func snapshot(_ value: JSONValue?) throws -> SnapshotDiff.Snapshot {
        try #require(value.flatMap(SnapshotDiff.Snapshot.init))
    }

    static func cases() throws -> [JSONObject] {
        try #require(try Fixtures.parityValue("diff")["cases"]?.array).compactMap(\.object)
    }

    /// Every case, drawn and hand-written: the output and the order of its resources, ids and fields.
    @Test func everyCaseMatchesTheGolden() throws {
        let cases = try Self.cases()
        #expect(cases.count == 72)
        for (index, item) in cases.enumerated() {
            let old = try Self.snapshot(item["input"]?["old"]), new = try Self.snapshot(item["input"]?["new"])
            let expected = try #require(item["expected"]?["ok"])
            let deltas = SnapshotDiff.diff(old: old, new: new)
            #expect(Self.json(deltas) == expected, "case \(index)")
            #expect(deltas.map(\.resource).map { Array($0.utf8) } == (expected.object?.keys ?? []).map { Array($0.utf8) }, "case \(index): resource order")
        }
    }

    /// abapit's six differences: each case holds abapit's output beside the corrected one, and the port is not abapit's.
    @Test func sixCasesDeviateFromAbapit() throws {
        let deviating = try Self.cases().filter { $0["abapit"] != nil }
        #expect(deviating.count == 6)
        for item in deviating {
            let deltas = SnapshotDiff.diff(old: try Self.snapshot(item["input"]?["old"]), new: try Self.snapshot(item["input"]?["new"]))
            #expect(Self.json(deltas) != item["abapit"]?["ok"])
        }
    }

    /// history.json's diff reads: the fake database's rows for two snapshot ids.
    @Test func theHistoryDiffReadsMatch() throws {
        let golden = try Fixtures.parityValue("history")
        let rows = try #require(golden["seed"]?["items"]?.array)
        let reads = try #require(golden["cases"]?.array).compactMap(\.object).filter { $0["call"]?.string == "diff_snapshots" }
        #expect(reads.count == 7)
        func snapshot(_ id: Int?) throws -> SnapshotDiff.Snapshot {
            SnapshotDiff.Snapshot(rows: rows.filter { $0["snapshot_id"]?.int == id }.compactMap { row in
                guard let resource = row["resource"]?.string, let item = row["item_id"]?.string, let attributes = row["attributes"]?.object else { return nil }
                return (resource, item, attributes)
            })
        }
        for (index, read) in reads.enumerated() {
            let deltas = SnapshotDiff.diff(old: try snapshot(read["args"]?["old_id"]?.int), new: try snapshot(read["args"]?["new_id"]?.int))
            #expect(Self.json(deltas) == read["expected"]?["ok"], "read \(index)")
        }
    }

    // MARK: what the goldens can't hold by themselves

    static func pair(_ old: JSONObject, _ new: JSONObject) -> [SnapshotDiff.Delta] {
        SnapshotDiff.diff(old: SnapshotDiff.Snapshot(rows: [("r", "a", old)]), new: SnapshotDiff.Snapshot(rows: [("r", "a", new)]))
    }

    @Test func numbersCompareByValueNeverThroughDouble() {
        // Python's ints are exact and 10**16 == 1e16: both of these fail a port that goes through Double (or text).
        #expect(!Self.pair(["n": .number("9007199254740993")], ["n": .number("9007199254740992")]).isEmpty)
        #expect(Self.pair(["n": .number("10000000000000000")], ["n": .number("1e16")]).isEmpty)
        #expect(!Self.pair(["n": .number("9007199254740993")], ["n": .number("9007199254740992.0")]).isEmpty)
        #expect(Self.pair(["n": .number("9007199254740992")], ["n": .number("9007199254740992.0")]).isEmpty)
        #expect(Self.pair(["n": .number("1")], ["n": .number("1.0")]).isEmpty)
        #expect(Self.pair(["n": .number("1.50")], ["n": .number("1.5")]).isEmpty)
        #expect(Self.pair(["n": .number("-0")], ["n": .number("0")]).isEmpty)
        #expect(Self.pair(["n": .number("100000000000000000000000")], ["n": .number("1e23")]).isEmpty == false)   // 1e23 is not 10**23
        #expect(Self.pair(["n": .number("9223372036854775808")], ["n": .number("9.223372036854775808e18")]).isEmpty)   // 2**63
        #expect(Self.pair(["n": .number("123456789012345678901234567890")], ["n": .number("123456789012345678901234567891")]).isEmpty == false)
    }

    @Test func aBooleanIsNotANumber() {
        #expect(!Self.pair(["f": .bool(true)], ["f": .number("1")]).isEmpty)
        #expect(!Self.pair(["f": .bool(false)], ["f": .number("0.0")]).isEmpty)
        #expect(Self.pair(["f": .bool(true)], ["f": .bool(true)]).isEmpty)
    }

    @Test func aMissingFieldIsNullAndNeverAChange() {
        #expect(Self.pair(["x": .null], [:]).isEmpty)
        #expect(Self.pair([:], ["x": .null]).isEmpty)
        let changed = Self.pair(["x": .null, "y": .number("1")], ["y": .number("2")])
        #expect(changed.first?.changed.first?.fields.map(\.field) == ["y"])
        // A missing field against a value is a change, read as null on its side.
        let added = Self.pair([:], ["x": .string("v")])
        #expect(added.first?.changed.first?.fields == [.init(field: "x", old: .null, new: .string("v"))])
    }

    @Test func orderIsByCodePoint() {
        let new = SnapshotDiff.Snapshot(rows: ["z", "\u{1F600}", "\u{FF21}", "\u{E9}", "A", "a"].map { ("r", $0, [:]) })
        let ids = SnapshotDiff.diff(old: .init(rows: []), new: new).first?.added.map(\.id)
        #expect(ids == ["A", "a", "z", "\u{E9}", "\u{FF21}", "\u{1F600}"])
        // NFC and NFD are two ids, in code-point order: E + U+0301 before U+00C9.
        let both = SnapshotDiff.Snapshot(rows: [("r", "E\u{301}", [:]), ("r", "\u{C9}", [:])])
        #expect(SnapshotDiff.diff(old: .init(rows: []), new: both).first?.added.map { Array($0.id.utf8) } == [Array("E\u{301}".utf8), Array("\u{C9}".utf8)])
        // Resources too.
        let resources = SnapshotDiff.Snapshot(rows: [("\u{1F600}", "a", [:]), ("b", "a", [:]), ("\u{FF21}", "a", [:])])
        #expect(SnapshotDiff.diff(old: .init(rows: []), new: resources).map(\.resource) == ["b", "\u{FF21}", "\u{1F600}"])
    }

    @Test func labelIsTheFirstTruthyName() {
        #expect(SnapshotDiff.label(["deviceModel": .string("Mac"), "name": .string("n")]) == "Mac")
        #expect(SnapshotDiff.label(["deviceModel": .string(""), "name": .string("n")]) == "n")
        #expect(SnapshotDiff.label(["deviceModel": .null, "serverName": .string("s"), "description": .string("d")]) == "s")
        #expect(SnapshotDiff.label(["managedAppleAccount": .string("m"), "description": .string("d")]) == "m")
        #expect(SnapshotDiff.label(["description": .string("d")]) == "d")
        #expect(SnapshotDiff.label(["name": .number("0"), "description": .string("d")]) == "d")
        #expect(SnapshotDiff.label(["name": .bool(false), "description": .string("d")]) == "d")
        #expect(SnapshotDiff.label(["name": .number("5")]) == "5")
        #expect(SnapshotDiff.label(["name": .bool(true)]) == "True")
        #expect(SnapshotDiff.label(["status": .string("x")]) == "")
        #expect(SnapshotDiff.label([:]) == "")
    }

    @Test func aSnapshotMustBeObjectsOfObjectsOfObjects() {
        #expect(SnapshotDiff.Snapshot(.object(["r": .object(["a": .object([:])])])) != nil)
        #expect(SnapshotDiff.Snapshot(.object(["r": .object(["a": .number("1")])])) == nil)
        #expect(SnapshotDiff.Snapshot(.object(["r": .array([])])) == nil)
        #expect(SnapshotDiff.Snapshot(.array([])) == nil)
    }
}
