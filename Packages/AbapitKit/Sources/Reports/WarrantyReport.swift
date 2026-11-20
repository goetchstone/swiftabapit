import AppleModels
import Foundation
import JSONAPI

/// The "out of warranty" report (plan Phase 3, with its caution: on the operator's acceptance passes the one device
/// read had no AppleCare records at all, so "no record" may mean no AppleCare, not expired). Kept apart:
///
/// 1. **No ACTIVE AppleCare coverage among the records read** (`no-active-coverage`): records came back, each a status this
///    version knows, none `ACTIVE`.
/// 2. **No coverage record at all** (`no-record`): the read worked and was empty. That may mean the device never had
///    AppleCare, or has only the limited warranty Apple may not list; it is not "expired".
/// 3. **Coverage status unknown** (`status-unknown`): a record has no status, or one this version doesn't know, and none is
///    `ACTIVE`. Shown raw, never estimated and never counted toward out of warranty.
/// 4. **An estimate from the order date** (`Estimate`), labelled as one (`assumption`): only for devices in 1 and 2.
///
/// A device whose coverage wasn't read, or that a cut sweep never reached (it has no entry in `coverage`), is `not-read`:
/// never out of warranty, never in. The report never prints a single "out of warranty" number, because there isn't one.
public struct WarrantyReport: Sendable {
    public enum Kind: Sendable, Equatable {
        /// At least one record is `ACTIVE`; the latest end it states, if any.
        case active(ends: ISODate?)
        /// Records read, all known and none `ACTIVE`; their statuses, raw, sorted.
        case noActiveCoverage(statuses: [String])
        /// A record with no status or one this version doesn't know, and none `ACTIVE`; those statuses, raw, sorted.
        case statusUnknown(statuses: [String])
        case noRecord
        case notRead(String)
    }

    public enum Estimate: Sendable, Equatable {
        /// Not made: the device has active coverage, an unknown status, or its coverage wasn't read.
        case notMade
        case noOrderDate
        /// Not a date: Apple's value as JSON text.
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

        /// The filter token: `active`, `no-active-coverage`, `no-record`, `status-unknown`, `not-read`.
        public var group: String {
            switch kind {
            case .active: "active"
            case .noActiveCoverage: "no-active-coverage"
            case .noRecord: "no-record"
            case .statusUnknown: "status-unknown"
            case .notRead: "not-read"
            }
        }

        public var estimatedPast: Bool { if case .pastAssumedLimit = estimate { true } else { false } }
        public var lacksReadableOrderDate: Bool {
            switch estimate {
            case .noOrderDate, .unreadableOrderDate: true
            default: false
            }
        }
    }

    /// The assumption behind every estimate, said wherever one is shown.
    public static let assumption = "Estimate only: assumes Apple's one-year limited warranty counted from the order date. The real term varies by country and product and starts at purchase or delivery, not the order date, and Apple's API doesn't say whether it lists that warranty as a coverage."

    public static let fixedGroups = ["active", "no-active-coverage", "no-record", "status-unknown", "not-read"]
    /// A filter token that spans groups: no active coverage and the estimate says the assumed year is over.
    public static let estimatedPastToken = "estimated-past-limit"

    public let list: ListRead
    public let rows: [Row]

    /// `coverage` is keyed by device id; a device with no entry wasn't reached.
    public init(_ devices: [OrgDevice], coverage: [String: DeviceRead<[AppleCareCoverage]>], now: Date, list: ListRead = .whole) {
        self.list = list
        let built = devices.map { device -> Row in
            let kind = Self.kind(coverage[device.id] ?? .notRead("the sweep didn't reach this device"))
            let estimate: Estimate
            switch kind {
            case .active, .notRead, .statusUnknown: estimate = .notMade
            case .noActiveCoverage, .noRecord: estimate = Self.estimate(device, now: now)
            }
            return Row(device: device, kind: kind, estimate: estimate)
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
            if !active.isEmpty { return .active(ends: active.compactMap(\.end).max()) }
            let unknown = records.filter { $0.status != .known(.inactive) }
            if unknown.isEmpty { return .noActiveCoverage(statuses: ["INACTIVE"]) }
            return .statusUnknown(statuses: Set(unknown.map { sent($0.attributes, "status") ?? "not sent" }).sorted(by: byBytes))
        }
    }

    /// Order date plus one calendar year (UTC; 29 February becomes 28), against `now`.
    static func estimate(_ device: OrgDevice, now: Date) -> Estimate {
        switch device.attributes["orderDateTime"] {
        case nil, .null?: return .noOrderDate
        case let value?:
            guard let ordered = ISODate.parse(value.string) else { return .unreadableOrderDate(unreadableDate(value)) }
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

    /// A list that wasn't read says only that.
    public var words: [String] {
        if case .notRead = list { return [list.words] }
        var lines = [list.words]
        lines.append("\(rows(group: "active").count) have ACTIVE AppleCare coverage.")
        lines.append("\(rows(group: "no-active-coverage").count) have coverage records but none ACTIVE.")
        lines.append("\(rows(group: "no-record").count) have no coverage record at all: that may mean no AppleCare, not that it expired.")
        lines.append("\(rows(group: "status-unknown").count) have coverage records whose status this version doesn't know: not counted as out of warranty, and not estimated.")
        lines.append("\(rows(group: "not-read").count) had their coverage unread: not counted as out of warranty.")
        let missingDate = rows.filter(\.lacksReadableOrderDate).count
        lines.append("\(rows(group: Self.estimatedPastToken).count) of the \(withoutActiveCoverage) without active coverage are past an estimated year from their order date; \(missingDate) have no readable order date, so no estimate. \(Self.assumption)")
        return lines
    }
}
