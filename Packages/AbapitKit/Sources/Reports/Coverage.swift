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
/// Two additions to abapit's report. `notRead` names the serials whose coverage a sweep could not read (callers must say
/// who: a missing entry can't pass for a read one). A device with no active coverage that is among them is listed
/// there and not as uncovered (an unread device isn't an unprotected one); a device with an active record is covered
/// whatever the sweep said. With none it is abapit's report. And `unreadableEnd`: an active record whose
/// `endDateTime` is there (not null) but isn't a date, counted apart as `QuietServices` counts `unreadable`; abapit
/// quietly took it as never expiring (a deviation recorded in `docs/domains/history.md`, with no golden case: Apple types the field as a date-time).
/// A missing or null end is still never expiring. `days` is held to 0...1825 (abapit's route allowed 1...1825; the
/// golden calls 0).
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
    /// Active records with an `endDateTime` that isn't a date (not a string, an empty one, or one that doesn't read):
    /// covered, but when they end is not known.
    public let unreadableEnd: [Resource]
    public let days: Int

    /// The most days a window looks ahead (abapit's route: `min(days, 1825)`).
    public static let maximumDays = 1825

    public init(applecare: [Resource], devices: [Resource], days requested: Int, now: Date, notRead unread: [String]) {
        let days = min(max(requested, 0), Self.maximumDays)
        var unreadable: [Resource] = []
        let start = Instant.micros(now)
        let cutoff = start + days * Instant.day
        var rows: [(offset: Int, row: Expiring)] = []
        var covered: Set<[UInt8]> = []
        for item in applecare where item.attributes["status"]?.string.map(Instant.bytes) == Instant.bytes("ACTIVE") {
            if let serial = item.attributes["serialNumber"]?.string { covered.insert(Instant.bytes(serial)) }
            guard let end = ISODate.parse(item.attributes["endDateTime"]?.string).map(Instant.micros) else {
                if let value = item.attributes["endDateTime"], value != .null { unreadable.append(item) }
                continue
            }
            guard start <= end, end <= cutoff else { continue }
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
        unreadableEnd = unreadable
        self.days = days
    }
}
