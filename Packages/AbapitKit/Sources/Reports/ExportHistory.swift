import AppleModels
import Foundation
import JSONAPI

extension ExportPolicy {
    /// The refresh-candidates export (invariant 11: an allowlist), abapit's `/export/refresh-candidates.csv` columns
    /// in its order after a leading `listRead` (how much of the device list the report was given, as every fleet export says it): `serialNumber`, `deviceModel`, `productFamily`, `ordered`, `ageYears`, `activeCoverage`
    /// (`True`, `False`, `not read` when the device's coverage sweep failed, or empty when there is no coverage data).
    public static let refreshCandidates = Columns([
        "listRead", "serialNumber", "deviceModel", "productFamily", "ordered", "ageYears", "activeCoverage",
    ])

    /// The expiring-coverage export, abapit's `/export/coverage-expiring-<days>d.csv` columns in its order. A record's
    /// other attributes (Apple adds some) are not exported until listed here.
    public static let coverageExpiring = Columns([
        "listRead", "serialNumber", "description", "paymentType", "startDateTime", "endDateTime", "days_left", "isRenewable",
    ])
}

extension ExportPolicy {
    /// The snapshot comparison's export: the two snapshots' times, what changed (`added`, `removed`, `changed`, or a resource not
    /// compared, or `no differences`), the resource, the item's label, the field with its old and new value, and a note. The
    /// item's id is the `id` column. Not abapit's: it had no diff CSV, its Changes page was HTML only.
    public static let snapshotDiff = Columns(["older", "newer", "change", "resource", "label", "field", "old", "new", "note"])
}

/// The two CSVs abapit wrote from the history reports, through `CSV.text`: the same writer, formula guard, column
/// allowlist and denylist as every other export. A cell is abapit's `_cell` (`True`, `4.3`, nothing for null).
public enum ExportHistory {
    /// A resource the comparison left out, and why, in words ("not read in the newer snapshot, so no change is shown").
    public struct NotCompared: Sendable, Equatable {
        public let resource: String
        public let why: String

        public init(resource: String, why: String) {
            self.resource = resource
            self.why = why
        }
    }

    /// What differs between two snapshots, one row per added or removed item and one per changed field, then a row for each
    /// resource not compared and why. Values go through `masking` (a secret-named key's value withheld at any depth), as
    /// `shownJSON` does. `older` and `newer` are the snapshots' times, written on every row. A comparison with nothing to say
    /// is one row, `no differences`, never a bare header, and only when every resource was read in full on both sides and none was
    /// left out: a `partial` row is written for every resource read in part (`partial`), and a `not compared` row for each left out. `deltas` are what the comparison shows: a removal a part read couldn't
    /// vouch for is never in them (the caller withholds it), and says so in `notCompared`.
    public static func snapshotDiff(older: String, newer: String, deltas: [SnapshotDiff.Delta], notCompared: [NotCompared], partial: [NotCompared] = []) -> String {
        func row(_ id: String, _ change: String, _ resource: String, label: String = "", field: String = "", old: JSONValue = .null,
                 new: JSONValue = .null, note: String = "") -> CSV.Item {
            CSV.Item(id: id, attributes: ["older": .string(older), "newer": .string(newer), "change": .string(change), "resource": .string(resource),
                                          "label": .string(label), "field": .string(field), "old": old, "new": new, "note": .string(note)])
        }
        func shown(_ value: JSONValue, _ field: String) -> JSONValue {
            ExportPolicy.isSensitive(field) ? .string(AuditEvent.withheld) : masking(value, depth: 0)
        }
        var rows: [CSV.Item] = []
        for delta in deltas {
            for item in delta.added { rows.append(row(item.id, "added", delta.resource, label: SnapshotDiff.label(item.attributes))) }
            for item in delta.removed { rows.append(row(item.id, "removed", delta.resource, label: SnapshotDiff.label(item.attributes))) }
            for change in delta.changed {
                for field in change.fields {
                    rows.append(row(change.id, "changed", delta.resource, label: SnapshotDiff.label(change.attributes), field: field.field,
                                    old: shown(field.old, field.field), new: shown(field.new, field.field)))
                }
            }
        }
        // A resource read in part says so, whatever else it shows: "no differences" is never written over a part read.
        for part in partial { rows.append(row("", "partial", part.resource, note: part.why)) }
        for skipped in notCompared { rows.append(row("", "not compared", skipped.resource, note: skipped.why)) }
        if rows.isEmpty { rows = [row("", "no differences", "")] }
        return CSV.text(rows, columns: ExportPolicy.snapshotDiff)
    }

    public static func refreshCandidates(_ report: FleetAgeReport) -> String {
        CSV.text(withSentinel(report.list, rows: report.candidates.map { candidate in
            CSV.Item(id: candidate.serial, attributes: [
                "listRead": .string(report.list.csvWords), "serialNumber": .string(candidate.serial), "deviceModel": masking(candidate.model, depth: 0), "productFamily": masking(candidate.family, depth: 0),
                "ordered": masking(candidate.ordered, depth: 0), "ageYears": .number(String(candidate.ageYears)),
                "activeCoverage": candidate.notRead ? .string("not read") : (candidate.covered.map(JSONValue.bool) ?? .null),
            ])
        }), columns: ExportPolicy.refreshCandidates)
    }

    public static func coverageExpiring(_ report: CoverageReport) -> String {
        CSV.text(withSentinel(report.list, rows: report.expiring.map { CSV.Item(id: $0.attributes["serialNumber"]?.string ?? "", attributes: maskedObject($0.attributes).merging(["listRead": .string(report.list.csvWords)])) }),
                 columns: ExportPolicy.coverageExpiring)
    }
}

/// A record's attributes with every secret-keyed value inside an object or list value withheld, as `shownJSON` does (invariant 11).
private func maskedObject(_ object: JSONObject) -> JSONObject {
    var out = JSONObject()
    for (key, value) in object { out[key] = masking(value, depth: 0) }
    return out
}
