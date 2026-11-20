import AppleModels
import Foundation
import JSONAPI

/// The MDM migration report (plan Phase 3): devices by `mdmMigrationStatus` (requested, started, success, failed; a value
/// this version doesn't know shown raw), the days to each device's deadline, and which are past it. No abapit counterpart.
///
/// A device Apple sent no migration fields for is `no-data`, counted apart; one with the capable flag or a deadline but
/// no status is `no-status`. Neither is read as a status. The countdown counts whole days: a deadline 10 days ahead
/// reads 10, one second short of that reads 9. Past due means the deadline is before `now` and the status isn't
/// `SUCCESS`; a migration that succeeded is done, however late it was.
public struct MigrationReport: Sendable {
    public enum Deadline: Sendable, Equatable {
        case none
        /// Apple sent something that isn't a date `ISODate` reads: shown raw.
        case unreadable(String)
        /// Whole days left; 0 on the day itself, the instant included.
        case left(Int)
        /// Whole days past it; 0 for the first day after.
        case overdue(Int)
    }

    public struct Row: Sendable, Identifiable {
        public let device: OrgDevice
        public let deadline: Deadline
        public var id: String { device.id }

        public var status: OpenEnum<MigrationStatus>? { device.migrationStatus }
        public var hasAnyData: Bool {
            device.isMigrationCapable != nil || device.migrationStatus != nil || device.attributes["mdmMigrationDeadlineDateTime"].map { $0 != .null } == true
        }

        /// The filter token: `status:REQUESTED`, `status:<raw>`, `no-status` or `no-data`.
        public var group: String {
            if let status { return "status:\(status.rawValue)" }
            return hasAnyData ? "no-status" : "no-data"
        }

        public var pastDue: Bool {
            if case .overdue = deadline { return status != .known(.success) }
            return false
        }
    }

    public static let fixedGroups = ["status:REQUESTED", "status:STARTED", "status:SUCCESS", "status:FAILED", "no-status", "no-data"]
    /// A filter token that spans groups.
    public static let pastDueToken = "past-due"

    public let list: ListRead
    public let rows: [Row]
    public let capable: Int
    public let notCapable: Int
    /// Devices Apple sent no `isMdmMigrationCapable` for.
    public let capableNotSent: Int

    public init(_ devices: [OrgDevice], now: Date, list: ListRead = .whole) {
        self.list = list
        let built = devices.map { Row(device: $0, deadline: Self.deadline($0, now: now)) }
        rows = built.sorted { a, b in
            let (x, y) = (Self.rank(a), Self.rank(b))
            if x != y { return x < y }
            if a.group != b.group { return byBytes(a.group, b.group) }
            switch (a.device.migrationDeadline, b.device.migrationDeadline) {
            case let (p?, q?) where p != q: return p < q
            default: return byBytes(a.device.serialNumber, b.device.serialNumber)
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
            guard let date = ISODate.parse(value.string) else { return .unreadable(value.string ?? "not text") }
            let seconds = date.date.timeIntervalSince(now)
            return seconds >= 0 ? .left(Int((seconds / 86_400).rounded(.down))) : .overdue(Int(((-seconds) / 86_400).rounded(.down)))
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
        group == Self.pastDueToken ? rows.filter(\.pastDue) : rows.filter { $0.group == group }
    }

    public var pastDue: [Row] { rows.filter(\.pastDue) }

    /// Group keys that have devices, in order, with their counts.
    public var counts: [(group: String, count: Int)] {
        var order: [String] = []
        for row in rows where !order.contains(row.group) { order.append(row.group) }
        return order.map { ($0, rows(group: $0).count) }
    }

    public var words: [String] {
        var lines = [list.words]
        lines += counts.map { "\(Self.title($0.group)): \($0.count)" }
        lines.append("Migration-capable: \(capable); not capable: \(notCapable); not sent by Apple: \(capableNotSent).")
        if !pastDue.isEmpty { lines.append("\(pastDue.count) past the deadline and not migrated.") }
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
