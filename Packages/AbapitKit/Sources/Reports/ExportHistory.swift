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

/// The two CSVs abapit wrote from the history reports, through `CSV.text`: the same writer, formula guard, column
/// allowlist and denylist as every other export. A cell is abapit's `_cell` (`True`, `4.3`, nothing for null).
public enum ExportHistory {
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
