import Foundation
import JSONAPI

/// Whole microseconds, so a window's edge (`now <= end <= cutoff`) and a timedelta's `.days` are exact where a
/// `Date`'s `Double` seconds are not.
enum Instant {
    static let day = 86_400_000_000

    static func micros(_ date: ISODate) -> Int {
        Int((date.date.timeIntervalSince1970 - Double(date.microsecond) / 1_000_000).rounded()) * 1_000_000 + date.microsecond
    }

    static func micros(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1_000_000).rounded()) }

    /// `timedelta.days`: the whole days, rounded toward negative infinity.
    static func days(_ micros: Int) -> Int {
        let quotient = micros / day
        return micros % day < 0 ? quotient - 1 : quotient
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
}

/// abapit's `reports.coverage_report` (held to `Tests/Fixtures/parity/reports.json`, no deviation): the active
/// coverages ending between `now` and `now + days` (both ends count), soonest first; the devices with no active
/// coverage; and how many of the devices have one.
///
/// Only a record whose `status` is exactly `ACTIVE` covers its `serialNumber`; a missing or unreadable `endDateTime`
/// is covered and never expiring. A serial is a string compared by bytes; a record with no string serial covers no
/// device. `days_left` is `timedelta.days`, so a coverage ending in 29 days and a second is 29.
///
/// One addition: `notRead`, the serials whose coverage a sweep could not read. A device with no active coverage
/// that is in it is listed there and not as uncovered (an unread device isn't an unprotected one), and counted
/// apart; a device with an active record is covered whatever the sweep said. With none given the report is abapit's.
public struct CoverageReport: Sendable {
    public struct Expiring: Sendable, Equatable {
        /// The record's attributes with `days_left` set over them, abapit's `{**attrs, "days_left": n}`.
        public let attributes: JSONObject
        public let daysLeft: Int
    }

    public let expiring: [Expiring]
    public let uncovered: [Resource]
    /// Devices with no active coverage whose sweep failed; never in `uncovered`.
    public let notRead: [Resource]
    /// Devices with an active coverage, each counted once by its id.
    public let coveredCount: Int
    public let days: Int

    public init(applecare: [Resource], devices: [Resource], days: Int, now: Date, notRead unread: [String] = []) {
        let start = Instant.micros(now)
        let cutoff = start + days * Instant.day
        var rows: [(offset: Int, row: Expiring)] = []
        var covered: Set<[UInt8]> = []
        for item in applecare where item.attributes["status"]?.string.map(Instant.bytes) == Instant.bytes("ACTIVE") {
            if let serial = item.attributes["serialNumber"]?.string { covered.insert(Instant.bytes(serial)) }
            guard let end = ISODate.parse(item.attributes["endDateTime"]?.string).map(Instant.micros),
                  start <= end, end <= cutoff else { continue }
            let left = Instant.days(end - start)
            rows.append((rows.count, Expiring(attributes: item.attributes.merging(["days_left": .number(String(left))]), daysLeft: left)))
        }
        // Python's sort is stable: equal days_left keep the input order.
        expiring = rows.sorted { $0.row.daysLeft != $1.row.daysLeft ? $0.row.daysLeft < $1.row.daysLeft : $0.offset < $1.offset }.map(\.row)
        let unreadBytes = Set(unread.map(Instant.bytes))
        let missing = devices.filter { !covered.contains(Instant.bytes($0.id)) }
        uncovered = missing.filter { !unreadBytes.contains(Instant.bytes($0.id)) }
        notRead = missing.filter { unreadBytes.contains(Instant.bytes($0.id)) }
        coveredCount = Set(devices.map { Instant.bytes($0.id) }).intersection(covered).count
        self.days = days
    }
}
