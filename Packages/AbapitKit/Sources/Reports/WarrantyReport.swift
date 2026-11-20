import AppleModels
import Foundation
import JSONAPI

/// The "out of warranty" report (plan Phase 3, with its caution: on the operator's acceptance passes the one device
/// read had no AppleCare records at all, so "no record" may mean no AppleCare, not expired). Three things stay apart:
///
/// 1. **No ACTIVE AppleCare coverage among the records read** (`noActiveCoverage`): records came back, none `ACTIVE`.
/// 2. **No coverage record at all** (`noRecord`): the read worked and was empty. That may mean the device never had
///    AppleCare, or has only the limited warranty Apple may not list; it is not "expired".
/// 3. **An estimate from the order date** (`Estimate`), labelled as one: ASSUMED, not known, that the device's
///    warranty is Apple's one-year limited warranty from `orderDateTime`. Only a device with no active coverage gets
///    one; an active one doesn't need it, and a device whose coverage wasn't read gets none.
///
/// A device whose coverage wasn't read is `notRead`: never out of warranty, never in. The report never prints a single
/// "out of warranty" number, because there isn't one.
public struct WarrantyReport: Sendable {
    public struct Entry: Sendable {
        public let device: OrgDevice
        public let coverage: DeviceRead<[AppleCareCoverage]>

        public init(device: OrgDevice, coverage: DeviceRead<[AppleCareCoverage]>) {
            self.device = device
            self.coverage = coverage
        }
    }

    public enum Kind: Sendable, Equatable {
        /// At least one record is `ACTIVE`; the latest end it states, if any.
        case active(ends: ISODate?)
        /// Records read, none `ACTIVE`; their statuses, raw, sorted.
        case noActiveCoverage(statuses: [String])
        case noRecord
        case notRead(String)
    }

    public enum Estimate: Sendable, Equatable {
        /// Not made: the device has active coverage, or its coverage wasn't read.
        case notMade
        case noOrderDate
        case unreadableOrderDate(String)
        /// The assumed limited warranty ended before `now`, at this instant.
        case pastAssumedLimit(Date)
        case withinAssumedLimit(until: Date)
    }

    public struct Row: Sendable, Identifiable {
        public let device: OrgDevice
        public let kind: Kind
        public let estimate: Estimate
        public var id: String { device.id }

        /// The filter token: `active`, `no-active-coverage`, `no-record`, `not-read`.
        public var group: String {
            switch kind {
            case .active: "active"
            case .noActiveCoverage: "no-active-coverage"
            case .noRecord: "no-record"
            case .notRead: "not-read"
            }
        }

        public var estimatedPast: Bool { if case .pastAssumedLimit = estimate { true } else { false } }
    }

    /// The assumption behind every estimate, said wherever one is shown.
    public static let assumption = "Estimate only: assumes Apple's one-year limited warranty from the order date. Apple's API doesn't say whether it lists that warranty as a coverage."

    public static let fixedGroups = ["active", "no-active-coverage", "no-record", "not-read"]
    /// A filter token that spans groups: no active coverage and the estimate says the assumed year is over.
    public static let estimatedPastToken = "estimated-past-limit"

    public let list: ListRead
    public let rows: [Row]

    public init(_ entries: [Entry], now: Date, list: ListRead = .whole) {
        self.list = list
        let built = entries.map { entry -> Row in
            let kind = Self.kind(entry.coverage)
            let estimate: Estimate
            switch kind {
            case .active, .notRead: estimate = .notMade
            case .noActiveCoverage, .noRecord: estimate = Self.estimate(entry.device, now: now)
            }
            return Row(device: entry.device, kind: kind, estimate: estimate)
        }
        let order = Self.fixedGroups
        rows = built.sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.group) ?? 0, order.firstIndex(of: b.group) ?? 0)
            return x != y ? x < y : byBytes(a.device.serialNumber, b.device.serialNumber)
        }
    }

    static func kind(_ coverage: DeviceRead<[AppleCareCoverage]>) -> Kind {
        switch coverage {
        case .notRead(let why): return .notRead(why)
        case .read(let records):
            if records.isEmpty { return .noRecord }
            let active = records.filter { $0.status == .known(.active) }
            if active.isEmpty {
                return .noActiveCoverage(statuses: Set(records.map { $0.status?.rawValue ?? "not sent" }).sorted(by: byBytes))
            }
            return .active(ends: active.compactMap(\.end).max())
        }
    }

    /// Order date plus one year (UTC calendar), against `now`.
    static func estimate(_ device: OrgDevice, now: Date) -> Estimate {
        switch device.attributes["orderDateTime"] {
        case nil, .null?: return .noOrderDate
        case let value?:
            guard let ordered = ISODate.parse(value.string) else { return .unreadableOrderDate(value.string ?? "not text") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let end = calendar.date(byAdding: .year, value: 1, to: ordered.date) else { return .noOrderDate }
            return end < now ? .pastAssumedLimit(end) : .withinAssumedLimit(until: end)
        }
    }

    public func rows(group: String) -> [Row] {
        group == Self.estimatedPastToken ? rows.filter(\.estimatedPast) : rows.filter { $0.group == group }
    }

    public var withoutActiveCoverage: Int { rows(group: "no-active-coverage").count + rows(group: "no-record").count }

    public var words: [String] {
        var lines = [list.words]
        lines.append("\(rows(group: "active").count) have ACTIVE AppleCare coverage.")
        lines.append("\(rows(group: "no-active-coverage").count) have coverage records but none ACTIVE.")
        lines.append("\(rows(group: "no-record").count) have no coverage record at all: that may mean no AppleCare, not that it expired.")
        lines.append("\(rows(group: "not-read").count) had their coverage unread: not counted as out of warranty.")
        lines.append("\(rows(group: Self.estimatedPastToken).count) of those without active coverage are past an estimated year from their order date. \(Self.assumption)")
        return lines
    }
}
