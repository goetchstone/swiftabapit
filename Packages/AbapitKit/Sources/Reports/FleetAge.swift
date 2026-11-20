import Foundation
import JSONAPI
import MosyleModels

/// abapit's `reports.fleet_age_report` (held to `Tests/Fixtures/parity/reports.json`): device age buckets and the
/// refresh candidates (at least `years` old), oldest first.
///
/// Age is `timedelta.days / 365.25` from `orderDateTime`, else `addedToOrgDateTime` (a value that is empty or
/// doesn't read as a date falls through to the next); a device with neither is undated. `timedelta.days` floors, so a
/// device ordered 100.5 days ahead is -101 days. `ageYears` is `round(age, 1)` (`Python.round1`), and candidates sort
/// by that rounded age, descending, equal ages in input order. Coverage is the set of `serialNumber`s whose record is
/// exactly `ACTIVE`; without coverage data (`applecare` is nil) `covered` is nil, and an empty list is data, with
/// every candidate uncovered.
///
/// One listed deviation, the generator's correction (`corrected_fleet_age`; not one of the operator's two
/// diff decisions): a device ordered more than 365 days ahead is "< 1 yr", never a candidate. abapit's
/// `bucket_labels[min(int(age), 4)]` read `int(-1.2) = -1` as the last bucket, "4+ yrs". The golden keeps abapit's
/// output beside the corrected one.
///
/// `notRead` names the devices whose AppleCare sweep failed. A candidate with no active record that is among them has
/// `covered` nil (not read, said apart; the export's cell is empty) and is counted in `notReadCandidates`, never in
/// `uncoveredCandidates`: an unread device is not an unprotected one. Callers must say who wasn't read, so a missing
/// entry can't pass for a read one. `years` is held to 0...10 (abapit's route allowed 1...10; the golden calls 0).
public struct FleetAgeReport: Sendable {
    /// The most years a refresh plan looks back (abapit's route: `min(years, 10)`).
    public static let maximumYears = 10
    public static let labels = ["< 1 yr", "1\u{2013}2 yrs", "2\u{2013}3 yrs", "3\u{2013}4 yrs", "4+ yrs"]

    public struct Bucket: Sendable, Equatable {
        public let label: String
        public let count: Int
    }

    public struct Candidate: Sendable, Equatable {
        public let serial: String
        /// `deviceModel` as Apple sent it, `""` when absent.
        public let model: JSONValue
        public let family: JSONValue
        /// `orderDateTime` if it is truthy, else `addedToOrgDateTime`: the text may be one that didn't parse.
        public let ordered: JSONValue
        public let ageYears: Double
        /// Nil when there is no coverage data.
        public let covered: Bool?
    }

    public let buckets: [Bucket]
    public let bucketMax: Int
    public let candidates: [Candidate]
    public let uncoveredCandidates: Int?
    /// Candidates whose coverage sweep failed and that have no active record: not counted as uncovered.
    public let notReadCandidates: Int
    public let undated: Int
    public let years: Int
    public let hasCoverageData: Bool

    public init(devices: [Resource], applecare: [Resource]?, years requested: Int, now: Date, notRead unread: [String]) {
        let years = min(max(requested, 0), Self.maximumYears)
        let unreadBytes = Set(unread.map(Instant.bytes))
        var covered: Set<[UInt8]>?
        if let applecare {
            covered = Set(applecare.filter { $0.attributes["status"]?.string.map(Instant.bytes) == Instant.bytes("ACTIVE") }
                .compactMap { $0.attributes["serialNumber"]?.string.map(Instant.bytes) })
        }
        let start = Instant.micros(now)
        var counts = [Int](repeating: 0, count: Self.labels.count)
        var rows: [(offset: Int, candidate: Candidate)] = []
        var undated = 0
        for device in devices {
            let attrs = device.attributes
            guard let basis = ISODate.parse(attrs["orderDateTime"]?.string) ?? ISODate.parse(attrs["addedToOrgDateTime"]?.string) else {
                undated += 1
                continue
            }
            let age = Double(Instant.days(start - Instant.micros(basis))) / 365.25
            counts[Self.bucket(age)] += 1
            if age >= Double(years) {
                let order = attrs["orderDateTime"] ?? .null
                rows.append((rows.count, Candidate(
                    serial: device.id, model: attrs["deviceModel"] ?? .string(""), family: attrs["productFamily"] ?? .string(""),
                    ordered: order.isTruthy ? order : (attrs["addedToOrgDateTime"] ?? .null),
                    ageYears: Python.round1(age),
                    covered: covered.flatMap { set -> Bool? in
                        let id = Instant.bytes(device.id)
                        return set.contains(id) ? true : (unreadBytes.contains(id) ? nil : false)
                    })))
            }
        }
        // Python's sort is stable and keys on the rounded age: equal rounded ages keep the input order.
        candidates = rows.sorted { $0.candidate.ageYears != $1.candidate.ageYears ? $0.candidate.ageYears > $1.candidate.ageYears : $0.offset < $1.offset }
            .map(\.candidate)
        buckets = zip(Self.labels, counts).map { Bucket(label: $0, count: $1) }
        bucketMax = counts.max() ?? 0
        uncoveredCandidates = covered == nil ? nil : candidates.filter { $0.covered == false }.count
        notReadCandidates = covered == nil ? 0 : candidates.filter { c in unreadBytes.contains(Instant.bytes(c.serial)) && c.covered == nil }.count
        self.undated = undated
        self.years = years
        hasCoverageData = covered != nil
    }

    /// `int(age)` (toward zero), at most 4, and at least 0: a device ordered more than a year ahead is "< 1 yr".
    static func bucket(_ age: Double) -> Int { min(max(Int(age), 0), labels.count - 1) }
}
