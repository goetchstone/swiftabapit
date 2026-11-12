import Foundation
import JSONAPI
import MosyleModels

/// abapit's `reports.mosyle_os_breakdown` (held to `Tests/Fixtures/parity/reports.json`): how many Mosyle devices run each OS
/// version, the patch posture Apple Business can't see. A missing version is Unknown, and sorts last.
public struct OSBreakdown: Sendable {
    public struct Row: Sendable, Identifiable {
        public let version: String
        public let count: Int
        /// Of every device, in percent to one decimal (Python's `round`).
        public let percent: Double

        public var id: String { version }
    }

    public let rows: [Row]
    public let total: Int
    public var maxCount: Int { rows.map(\.count).max() ?? 0 }

    public init(_ devices: [Resource]) {
        // `attrs.get("osVersion") or "Unknown"`, by the name shown: as `DeviceStats`, a version sent as a number is its text
        // (Python's Counter would key `26` and `26.0` as one, and `"26"` apart; a recorded deviation, no golden holds one).
        var counter = Counter()
        for device in devices { counter.add(DeviceStats.orUnknown(device.attributes["osVersion"])) }
        let tallies = counter.mostCommon()
        let total = tallies.reduce(0) { $0 + $1.count }
        // `(version == "Unknown", -count, version)`: Unknown last, then the most devices, then the version by code points.
        rows = tallies.sorted { a, b in
            let (ua, ub) = (a.name == "Unknown", b.name == "Unknown")
            if ua != ub { return ub }
            if a.count != b.count { return a.count > b.count }
            return Python.precedes(a.name, b.name)
        }.map { Row(version: $0.name, count: $0.count, percent: total == 0 ? 0 : Python.round1(Double($0.count) / Double(total) * 100)) }
        self.total = total
    }
}

/// abapit's `reports.mosyle_stale_devices` (held to the same golden): Mosyle devices that haven't checked in for `days` days,
/// or never have. A device assigned in Apple Business but silent in Mosyle is the strongest "is this really managed?" sign.
public struct StaleDevices: Sendable {
    public struct Row: Sendable, Identifiable {
        public let device: Resource
        public let serial: String
        public let deviceModel: JSONValue
        public let productFamily: JSONValue
        public let osVersion: JSONValue
        public let lastCheckIn: JSONValue
        public let currentUser: JSONValue
        /// Whole days since the last check-in (Python's `timedelta.days`, floored); nil when it never checked in or its date
        /// can't be read.
        public let daysStale: Int?

        public var id: String { device.id }
    }

    /// Never checked in first, then the stalest; ties keep Mosyle's order (Python's sort is stable).
    public let rows: [Row]
    public let total: Int
    public let neverCount: Int
    public let days: Int
    public var staleCount: Int { rows.count }

    public init(_ devices: [Resource], days: Int, now: Date) {
        var rows: [Row] = [], never = 0
        for device in devices {
            let a = device.attributes
            // abapit's `parse_iso`, which a check-in that isn't a string would have crashed: here it never checked in.
            let checkIn = ISODate.parse(a["lastCheckIn"]?.string)
            let stale = checkIn.map { Self.wholeDays(from: $0, to: now) }
            if stale == nil { never += 1 }
            guard stale.map({ $0 >= days }) ?? true else { continue }
            func value(_ key: String) -> JSONValue { a[key] ?? .string("") }
            rows.append(Row(device: device, serial: device.id, deviceModel: value("deviceModel"), productFamily: value("productFamily"),
                            osVersion: value("osVersion"), lastCheckIn: value("lastCheckIn"), currentUser: value("currentUser"),
                            daysStale: stale))
        }
        self.rows = rows.enumerated().sorted { a, b in
            let (da, db) = (a.element.daysStale, b.element.daysStale)
            if (da == nil) != (db == nil) { return da == nil }
            if let da, let db, da != db { return da > db }
            return a.offset < b.offset
        }.map(\.element)
        total = devices.count
        neverCount = never
        self.days = days
    }

    /// `(now - then).days`: whole days, floored, counted in microseconds as Python's `timedelta` counts them (a `Date` is a
    /// `Double`, which can put an instant a microsecond either side of a day's edge).
    static func wholeDays(from then: ISODate, to now: Date) -> Int {
        let thenSeconds = Int((then.date.timeIntervalSince1970 - Double(then.microsecond) / 1_000_000).rounded())
        let thenMicro = thenSeconds * 1_000_000 + then.microsecond
        let nowMicro = Int((now.timeIntervalSince1970 * 1_000_000).rounded(.down))
        let delta = nowMicro - thenMicro, day = 86_400 * 1_000_000
        return delta >= 0 ? delta / day : -((-delta + day - 1) / day)
    }
}
