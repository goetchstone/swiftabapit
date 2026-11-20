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
/// Only a record whose `status` is exactly `ACTIVE` covers its device; a missing or unreadable `endDateTime`
/// is covered and never expiring. An id is compared by bytes. `days_left` is `timedelta.days`, so a coverage ending in 29 days and a second is 29.
///
/// Two additions to abapit's report, so that it reads as the fleet reports do (invariant 8). `list` says how much of the device
/// list it was given, and `coverage` holds the sweep's read of each device by device id: `.read(records)` is the device's
/// own AppleCare records, `.notRead(why)` a read that failed, and a device with no entry is one the sweep never reached, which
/// is also not read. A device not read is never covered and never uncovered: it is in `notRead`. Records are the device's
/// by the key they sit under, so a record whose `serialNumber` differs is still that device's; keys that match no listed
/// device (abapit's golden has such records) still count toward `expiring`. With every device read and the list whole it
/// is abapit's report. Equal `days_left` keep the device list's order, then the other keys by bytes, then the record's.
/// And `unreadableEnd`: an active record whose
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

    /// How much of the device list this was given. A list that wasn't read judges nothing.
    public let list: ListRead
    public let expiring: [Expiring]
    public let uncovered: [Resource]
    /// Devices whose coverage wasn't read (a failed read, or no entry: the sweep never reached them); never in `uncovered`.
    public let notRead: [Resource]
    /// Devices with an active coverage, each counted once by its id.
    public let coveredCount: Int
    /// Active records with an `endDateTime` that isn't a date (not a string, an empty one, or one that doesn't read):
    /// covered, but when they end is not known.
    public let unreadableEnd: [Resource]
    public let days: Int

    /// The most days a window looks ahead (abapit's route: `min(days, 1825)`).
    public static let maximumDays = 1825

    public init(devices listed: [Resource], coverage: [String: DeviceRead<[Resource]>], days requested: Int, now: Date, list: ListRead = .whole) {
        self.list = list
        let devices = list.isNotRead ? [] : listed
        let days = min(max(requested, 0), Self.maximumDays)
        var unreadable: [Resource] = []
        let start = Instant.micros(now)
        let cutoff = start + days * Instant.day
        var rows: [(offset: Int, row: Expiring)] = []
        var covered: Set<[UInt8]> = []
        var seen: Set<[UInt8]> = []
        var keys: [String] = []
        for device in devices where seen.insert(Instant.bytes(device.id)).inserted { keys.append(device.id) }
        if !list.isNotRead { keys += coverage.keys.filter { !seen.contains(Instant.bytes($0)) }.sorted { Instant.bytes($0).lexicographicallyPrecedes(Instant.bytes($1)) } }
        for key in keys {
            guard case .read(let records)? = coverage[key] else { continue }
            for item in records where item.attributes["status"]?.string.map(Instant.bytes) == Instant.bytes("ACTIVE") {
                covered.insert(Instant.bytes(key))
                guard let end = ISODate.parse(item.attributes["endDateTime"]?.string).map(Instant.micros) else {
                    if let value = item.attributes["endDateTime"], value != .null { unreadable.append(item) }
                    continue
                }
                guard start <= end, end <= cutoff else { continue }
                let left = Instant.days(end - start)
                rows.append((rows.count, Expiring(attributes: item.attributes.merging(["days_left": .number(String(left))]), daysLeft: left)))
            }
        }
        // Python's sort is stable: equal days_left keep the input order.
        expiring = rows.sorted { $0.row.daysLeft != $1.row.daysLeft ? $0.row.daysLeft < $1.row.daysLeft : $0.offset < $1.offset }.map(\.row)
        let unreadBytes = Set(devices.filter { if case .read? = coverage[$0.id] { false } else { true } }.map { Instant.bytes($0.id) })
        let missing = devices.filter { !covered.contains(Instant.bytes($0.id)) }
        uncovered = missing.filter { !unreadBytes.contains(Instant.bytes($0.id)) }
        notRead = missing.filter { unreadBytes.contains(Instant.bytes($0.id)) }
        coveredCount = Set(devices.map { Instant.bytes($0.id) }).intersection(covered).count
        unreadableEnd = unreadable
        self.days = days
    }

    /// The list's read state first, then the counts. A list that wasn't read says only that.
    public var words: [String] {
        if list.isNotRead { return [list.words] }
        return [list.words,
                "\(coveredCount) devices have ACTIVE coverage; \(uncovered.count) have none among the records read; \(notRead.count) had their coverage unread: counted as neither covered nor uncovered.",
                "\(expiring.count) active coverages end within \(days) days; \(unreadableEnd.count) active coverages have an end date this app can't read."]
    }
}
