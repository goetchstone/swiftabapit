import AppleModels
import Foundation
import JSONAPI

/// The MDM migration report (plan Phase 3): devices by `mdmMigrationStatus` (requested, started, success, failed; a value
/// this version doesn't know shown raw), the days to each device's deadline, and which are past it. No abapit counterpart.
///
/// A device Apple sent no migration fields for is `no-data`, counted apart; one with the capable flag or a deadline but
/// no status is `no-status`. Neither is read as a status.
///
/// **The day rule**: days are 24-hour periods counted from `now` to the deadline instant (UTC instants, whatever offset
/// Apple wrote). Days left are the whole periods remaining, rounded down: a deadline 10 periods ahead reads 10, one second
/// short of that reads 9, the instant itself 0. Days overdue are the periods since, rounded up: anything past reads at least
/// 1, exactly one period past reads 1, a second more reads 2.
///
/// **Past due** means the deadline is before `now` and the status is a known one that isn't `SUCCESS` (requested, started or
/// failed). A device past its deadline whose status is unknown to this version, or missing, is counted apart in its own
/// words and is not called past due; a succeeded migration is done however late. A deadline that isn't a date is counted
/// and shown as Apple sent it, and never past due.
public struct MigrationReport: Sendable {
    public enum Deadline: Sendable, Equatable {
        case none
        /// Apple sent something that isn't a date `ISODate` reads: shown as its JSON text.
        case unreadable(String)
        /// Whole periods left, rounded down; 0 for the instant itself.
        case left(Int)
        /// Periods past it, rounded up: at least 1.
        case overdue(Int)
    }

    public struct Row: Sendable, Identifiable {
        public let device: OrgDevice
        public let deadline: Deadline
        public var id: String { device.id }

        public var status: OpenEnum<MigrationStatus>? {
            switch device.attributes["mdmMigrationStatus"] {
            case nil, .null?: nil
            case .string(let raw)?: OpenEnum(raw)
            case let value?: .unknown(value.jsonText)
            }
        }

        public var hasAnyData: Bool {
            ["isMdmMigrationCapable", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime"].contains { key in
                device.attributes[key].map { $0 != .null } == true
            }
        }

        /// The display group: `status:REQUESTED`, `status:<raw>`, `no-status` or `no-data`.
        public var group: String {
            if let status { return "status:\(status.rawValue)" }
            return hasAnyData ? "no-status" : "no-data"
        }

        /// The catalog token: a status this version doesn't know is `status:other`.
        public var token: String {
            if case .unknown = status { return "status:other" }
            return group
        }

        public var isOverdue: Bool { if case .overdue = deadline { true } else { false } }

        /// Past the deadline, and a known status other than `SUCCESS`.
        public var pastDue: Bool {
            guard isOverdue, case .known(let known)? = status else { return false }
            return known != .success
        }

        /// Past the deadline, but the status is unknown to this version or missing: not called past due.
        public var pastDueStatusUnknown: Bool {
            guard isOverdue else { return false }
            switch status {
            case .known?: return false
            case .unknown?, nil: return true
            }
        }

        /// For the CSV: yes or no only where it can be judged.
        public var pastDueWords: String {
            switch deadline {
            case .none: "no deadline"
            case .unreadable: "deadline not readable"
            case .left: "no"
            case .overdue: pastDue ? "yes" : (pastDueStatusUnknown ? "status unknown" : "no")
            }
        }
    }

    public static let fixedGroups = ["status:REQUESTED", "status:STARTED", "status:SUCCESS", "status:FAILED", "status:other", "no-status", "no-data"]
    /// Filter tokens that span groups.
    public static let pastDueToken = "past-due"
    public static let pastDueStatusUnknownToken = "past-due-status-unknown"

    public let list: ListRead
    public let rows: [Row]
    public let capable: Int
    public let notCapable: Int
    /// Devices with no `isMdmMigrationCapable` Apple sent, or one that isn't a yes or no.
    public let capableNotSent: Int

    public init(_ devices: [OrgDevice], now: Date, list: ListRead = .whole) {
        self.list = list
        let built = devices.map { Row(device: $0, deadline: Self.deadline($0, now: now)) }
        rows = built.sorted { a, b in
            let (x, y) = (Self.rank(a), Self.rank(b))
            if x != y { return x < y }
            if a.group != b.group { return byBytes(a.group, b.group) }
            // A total order: a readable deadline first, by instant (not the offset it was written in), then none, then serial, then id.
            switch (a.device.migrationDeadline?.date, b.device.migrationDeadline?.date) {
            case let (p?, q?) where p != q: return p < q
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                if a.device.serialNumber != b.device.serialNumber { return byBytes(a.device.serialNumber, b.device.serialNumber) }
                return byBytes(a.device.id, b.device.id)
            }
        }
        capable = devices.filter { $0.isMigrationCapable == true }.count
        notCapable = devices.filter { $0.isMigrationCapable == false }.count
        capableNotSent = devices.count - capable - notCapable
    }

    static func deadline(_ device: OrgDevice, now: Date) -> Deadline {
        switch device.attributes["mdmMigrationDeadlineDateTime"] {
        case nil, .null?: return .none
        case let value?:
            guard let date = ISODate.parse(value.string) else { return .unreadable(unreadableDate(value)) }
            let seconds = date.date.timeIntervalSince(now)
            return seconds >= 0 ? .left(Int((seconds / 86_400).rounded(.down))) : .overdue(Int(((-seconds) / 86_400).rounded(.up)))
        }
    }

    static func rank(_ row: Row) -> Int {
        switch row.status {
        case .known(.requested)?: 0
        case .known(.started)?: 1
        case .known(.failed)?: 2
        case .known(.success)?: 3
        case .unknown?: 4
        case nil: row.hasAnyData ? 5 : 6
        }
    }

    public func rows(group: String) -> [Row] {
        switch group {
        case Self.pastDueToken: rows.filter(\.pastDue)
        case Self.pastDueStatusUnknownToken: rows.filter(\.pastDueStatusUnknown)
        default: rows.filter { $0.token == group || $0.group == group }
        }
    }

    public var pastDue: [Row] { rows.filter(\.pastDue) }
    public var pastDueStatusUnknown: [Row] { rows.filter(\.pastDueStatusUnknown) }
    public var unreadableDeadlines: [Row] { rows.filter { if case .unreadable = $0.deadline { true } else { false } } }

    /// Display groups that have devices, in order, with their counts.
    public var counts: [(group: String, count: Int)] {
        var order: [String] = []
        for row in rows where !order.contains(row.group) { order.append(row.group) }
        return order.map { key in (key, rows.filter { $0.group == key }.count) }
    }

    /// A list that wasn't read says only that.
    public var words: [String] {
        if case .notRead = list { return [list.words] }
        var lines = [list.words]
        lines += counts.map { "\(Self.title($0.group)): \($0.count)" }
        lines.append("Migration-capable: \(capable); not capable: \(notCapable); not sent or not readable: \(capableNotSent).")
        if !pastDue.isEmpty { lines.append("\(pastDue.count) past the deadline and not migrated (requested, started or failed).") }
        if !pastDueStatusUnknown.isEmpty {
            lines.append("\(pastDueStatusUnknown.count) past the deadline with no known status: not counted as past due.")
        }
        if !unreadableDeadlines.isEmpty { lines.append("\(unreadableDeadlines.count) have a deadline that isn't a readable date: not counted as past due.") }
        return lines
    }

    static func title(_ group: String) -> String {
        switch group {
        case "no-status": "Migration data, but no status"
        case "no-data": "No migration data from Apple"
        default: "Status \(group.dropFirst("status:".count))"
        }
    }
}
