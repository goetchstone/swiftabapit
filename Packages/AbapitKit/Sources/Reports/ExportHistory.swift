import Foundation
import JSONAPI

extension ExportPolicy {
    /// The refresh-candidates export (invariant 11: an allowlist), abapit's `/export/refresh-candidates.csv` columns
    /// in its order: `serialNumber`, `deviceModel`, `productFamily`, `ordered`, `ageYears`, `activeCoverage`
    /// (`True`, `False`, or empty: no coverage data, or the device's sweep failed).
    public static let refreshCandidates = Columns([
        "serialNumber", "deviceModel", "productFamily", "ordered", "ageYears", "activeCoverage",
    ])

    /// The expiring-coverage export, abapit's `/export/coverage-expiring-<days>d.csv` columns in its order. A record's
    /// other attributes (Apple adds some) are not exported until listed here.
    public static let coverageExpiring = Columns([
        "serialNumber", "description", "paymentType", "startDateTime", "endDateTime", "days_left", "isRenewable",
    ])
}

/// The two CSVs abapit wrote from the history reports, through `CSV.text`: the same writer, formula guard, column
/// allowlist and denylist as every other export. A cell is abapit's `_cell` (`True`, `4.3`, nothing for null).
public enum ExportHistory {
    public static func refreshCandidates(_ report: FleetAgeReport) -> String {
        CSV.text(report.candidates.map { candidate in
            CSV.Item(id: candidate.serial, attributes: [
                "serialNumber": .string(candidate.serial), "deviceModel": candidate.model, "productFamily": candidate.family,
                "ordered": candidate.ordered, "ageYears": .number(String(candidate.ageYears)),
                "activeCoverage": candidate.covered.map(JSONValue.bool) ?? .null,
            ])
        }, columns: ExportPolicy.refreshCandidates)
    }

    public static func coverageExpiring(_ report: CoverageReport) -> String {
        CSV.text(report.expiring.map { CSV.Item(id: $0.attributes["serialNumber"]?.string ?? "", attributes: $0.attributes) },
                 columns: ExportPolicy.coverageExpiring)
    }
}
