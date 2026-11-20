import Foundation
import JSONAPI
import MosyleModels

/// abapit's `reports.fleet_age_report` (held to `Tests/Fixtures/parity/reports.json`): device age buckets and the
/// refresh candidates (at least `years` old), oldest first.
///
/// Age is `timedelta.days / 365.25` from `orderDateTime`, else `addedToOrgDateTime` (a value that is empty or
/// doesn't read as a date falls through to the next); a device with neither is undated. `timedelta.days` floors, so a
/// device ordered 100.5 days ahead is -101 days. `ageYears` is `round(age, 1)` (`Python.round1`), and candidates sort
/// by that rounded age, descending, equal ages in input order. A device is covered when one of its own records is
/// exactly `ACTIVE`; without coverage data (`coverage` is nil) `covered` is nil.
///
/// One listed deviation, the generator's correction (`corrected_fleet_age`; not one of the operator's two
/// diff decisions): a device ordered more than 365 days ahead is "< 1 yr", never a candidate. abapit's
/// `bucket_labels[min(int(age), 4)]` read `int(-1.2) = -1` as the last bucket, "4+ yrs". The golden keeps abapit's
/// output beside the corrected one.
///
/// Read as the fleet reports do (invariant 8). `list` says how much of the device list this was given, and `coverage`, nil
/// when no coverage was swept, holds the sweep's read of each device by device id: `.read(records)` is its AppleCare
/// records, and `.notRead(why)` or no entry (the sweep never reached it) is not read. A candidate with no active record
/// that is not read has `covered` nil and `notRead` true (the export's cell reads `not read`, where no coverage data leaves
/// it empty) and is counted in `notReadCandidates`, never in `uncoveredCandidates`: an unread device is not an
/// unprotected one. An empty map is data too: no device has an entry, so every one is not read. `years` is held to 0...10
/// (abapit's route allowed 1...10; the golden calls 0).
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
        /// The device has no active record and its coverage sweep failed: `covered` is nil because it is unknown, not
        /// because there is no coverage data.
        public let notRead: Bool
    }

    /// How much of the device list this was given. A list that wasn't read judges nothing.
    public let list: ListRead
    public let buckets: [Bucket]
    public let bucketMax: Int
    public let candidates: [Candidate]
    public let uncoveredCandidates: Int?
    /// Candidates whose coverage sweep failed and that have no active record: not counted as uncovered.
    public let notReadCandidates: Int
    public let undated: Int
    public let years: Int
    public let hasCoverageData: Bool

    public init(devices listed: [Resource], coverage: [String: DeviceRead<[Resource]>]?, years requested: Int, now: Date, list: ListRead = .whole) {
        self.list = list
        let devices = list.isNotRead ? [] : listed
        let years = min(max(requested, 0), Self.maximumYears)
        /// A device's state: true or false when its records were read, nil when they weren't.
        func state(_ device: Resource) -> Bool? {
            guard case .read(let records)? = coverage?[device.id] else { return nil }
            return records.contains { $0.attributes["status"]?.string.map(Instant.bytes) == Instant.bytes("ACTIVE") }
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
                    covered: state(device), notRead: coverage != nil && state(device) == nil)))
            }
        }
        // Python's sort is stable and keys on the rounded age: equal rounded ages keep the input order.
        candidates = rows.sorted { $0.candidate.ageYears != $1.candidate.ageYears ? $0.candidate.ageYears > $1.candidate.ageYears : $0.offset < $1.offset }
            .map(\.candidate)
        buckets = zip(Self.labels, counts).map { Bucket(label: $0, count: $1) }
        bucketMax = counts.max() ?? 0
        uncoveredCandidates = coverage == nil ? nil : candidates.filter { $0.covered == false }.count
        notReadCandidates = coverage == nil ? 0 : candidates.filter(\.notRead).count
        self.undated = undated
        self.years = years
        hasCoverageData = coverage != nil
    }

    /// The list's read state first, then the counts. A list that wasn't read says only that.
    public var words: [String] {
        if list.isNotRead { return [list.words] }
        var lines = [list.words, "\(candidates.count) devices are \(years) or more years old; \(undated) have no readable date and are not aged."]
        if hasCoverageData {
            lines.append("\(uncoveredCandidates ?? 0) of the candidates have no active coverage; \(notReadCandidates) had their coverage unread: counted as neither covered nor uncovered.")
        } else {
            lines.append("No coverage data was read: nothing is said about coverage.")
        }
        return lines
    }

    /// `int(age)` (toward zero), at most 4, and at least 0: a device ordered more than a year ahead is "< 1 yr".
    static func bucket(_ age: Double) -> Int { min(max(Int(age), 0), labels.count - 1) }
}
