import AppleModels
import Foundation
import JSONAPI

/// How many devices a service holds, as the read said it.
public enum ServiceDeviceCount: Sendable, Equatable {
    case exactly(Int)
    /// The relationship read was cut at the page cap.
    case atLeast(Int)
    /// Apple's `deviceCount` attribute isn't a whole number: shown as sent, as JSON text.
    case unreadable(String)
}

/// The MDM service health report (plan Phase 3): per service, when it last connected, its status, its device count and a
/// verdict. No abapit counterpart.
///
/// **One quiet rule.** The `quiet` group is exactly `QuietServices`' rows for the same services, `now` and `days` (the
/// Overview's card and the Services screen's column use them): never connected, a date this app can't read, or silent more
/// than `days` days, a `DELETED` service excepted. Status is a column beside it: a quiet service may be inactive. A service
/// that isn't quiet is `healthy` when `ACTIVE`, else `inactive`, `other-status` (raw) or, with no status, `cannot-judge`.
///
/// Services read with default fields (apple-reads, "Answered live 2026-11-19/-20"): `notSent` is the attributes Apple sent
/// for no service. A service whose `lastConnectedDateTime` wasn't sent is `cannot-judge`, never quiet and never "never
/// connected" (a known `DELETED` one is still `deleted`). The device count is the relationship's count when the screen
/// read it, else Apple's `deviceCount`, else not read.
public struct ServiceHealth: Sendable {
    public enum Health: Sendable, Equatable {
        /// `ACTIVE` and not quiet.
        case healthy
        /// In `QuietServices`' result.
        case quiet
        case inactive
        case deleted
        /// A status this version doesn't know: raw.
        case otherStatus(String)
        /// A field the verdict needs wasn't sent; the text says which.
        case cannotJudge(String)
    }

    public enum Connected: Sendable, Equatable {
        /// Apple didn't send the attribute for any service: not "never connected".
        case notSent
        case never
        /// Not a date this app reads: as Apple sent it, as JSON text.
        case unreadable(String)
        /// Whole 24-hour periods ago, truncated as the Services screen does: 0 is today.
        case at(ISODate, daysAgo: Int)
        /// A stamp after `now`.
        case inFuture(ISODate)

        public var words: String {
            switch self {
            case .notSent: "not sent by Apple"
            case .never: "never connected"
            case .unreadable(let raw): "unreadable date: \(raw)"
            case .at(_, let days): days <= 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"
            case .inFuture: "in the future"
            }
        }
    }

    public struct Row: Sendable, Identifiable {
        public let service: MDMService
        public let health: Health
        public let lastConnected: Connected
        public let deviceCount: ServiceDeviceCount?
        public var id: String { service.id }

        /// The filter token: `healthy`, `quiet`, `inactive`, `deleted`, `other-status`, `cannot-judge`.
        public var group: String {
            switch health {
            case .healthy: "healthy"
            case .quiet: "quiet"
            case .inactive: "inactive"
            case .deleted: "deleted"
            case .otherStatus: "other-status"
            case .cannotJudge: "cannot-judge"
            }
        }
    }

    public static let fixedGroups = ["healthy", "quiet", "inactive", "deleted", "other-status", "cannot-judge"]

    public let list: ListRead
    public let days: Int
    /// The attributes Apple sent for no service, by name, sorted.
    public let notSent: [String]
    /// In group order (`fixedGroups`); within `quiet`, `QuietServices`' order (most stale first), within the rest the order given.
    public let rows: [Row]

    /// `deviceCounts` is keyed by service id (the relationship counts); `notSent` is `Page.absent`.
    public init(_ services: [MDMService], deviceCounts: [String: ServiceDeviceCount] = [:], notSent: Set<String> = [],
                now: Date, days: Int = QuietServices.defaultDays, list: ListRead = .whole) {
        self.list = list
        self.days = days
        self.notSent = notSent.sorted(by: byBytes)
        let quietOrder = notSent.contains("lastConnectedDateTime") ? [] : QuietServices(services, now: now, days: days).rows.map(\.service.id)
        let built = services.map { service -> Row in
            let connected = Self.connected(service, notSent: notSent, now: now)
            return Row(service: service, health: Self.health(service, quiet: quietOrder.contains(service.id), connected: connected, notSent: notSent),
                       lastConnected: connected, deviceCount: deviceCounts[service.id] ?? Self.attributeCount(service))
        }
        let order = Self.fixedGroups
        rows = built.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.group) ?? order.count, order.firstIndex(of: b.element.group) ?? order.count)
            if x != y { return x < y }
            if a.element.group == "quiet", let p = quietOrder.firstIndex(of: a.element.id), let q = quietOrder.firstIndex(of: b.element.id) { return p < q }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func attributeCount(_ service: MDMService) -> ServiceDeviceCount? {
        if let count = service.deviceCount { return .exactly(count) }
        return sentRaw(service.attributes, "deviceCount").map { .unreadable($0) }
    }

    static func connected(_ service: MDMService, notSent: Set<String>, now: Date) -> Connected {
        if notSent.contains("lastConnectedDateTime") { return .notSent }
        switch QuietServices.lastConnected(service) {
        case .never: return .never
        case .unreadable: return .unreadable(service.attributes["lastConnectedDateTime"].map(unreadableDate) ?? "")
        case .at(let date):
            let seconds = now.timeIntervalSince(date.date)
            return seconds < 0 ? .inFuture(date) : .at(date, daysAgo: Int(seconds / 86_400))
        }
    }

    static func health(_ service: MDMService, quiet: Bool, connected: Connected, notSent: Set<String>) -> Health {
        if service.status == .known(.deleted) { return .deleted }
        if case .notSent = connected { return .cannotJudge("Apple didn't send when the service last connected") }
        if quiet { return .quiet }
        if notSent.contains("status") { return .cannotJudge("Apple didn't send the service's status") }
        switch service.status {
        case nil:
            // A status that is present but not text is shown as Apple sent it.
            if let raw = sent(service.attributes, "status") { return .otherStatus(raw) }
            return .cannotJudge("this service has no status")
        case .known(.active)?: return .healthy
        case .known(.inactive)?: return .inactive
        case .known(.deleted)?: return .deleted
        case .unknown(let raw)?: return .otherStatus(raw)
        }
    }

    public func rows(group: String) -> [Row] { rows.filter { $0.group == group } }

    public var healthy: Int { rows(group: "healthy").count }

    /// A list that wasn't read says only that.
    public var words: [String] {
        if case .notRead = list { return [list.words] }
        var lines = [list.words]
        if !notSent.isEmpty {
            lines.append("Apple didn't send \(notSent.joined(separator: ", ")) for any service (read with default fields): services that need it can't be judged.")
        }
        if notSent.contains("status") {
            lines.append("Apple didn't send the services' status, so deleted services can't be told apart and are counted.")
        }
        for key in Self.fixedGroups {
            let count = rows(group: key).count
            if count > 0 { lines.append("\(title(key)): \(count)") }
        }
        return lines
    }

    func title(_ key: String) -> String {
        switch key {
        case "healthy": "Active and connected within the last \(days) days"
        case "quiet": "Quiet: never connected, a last-connected value this app can't read, or silent more than \(days) days (the Overview's rule; the status is beside it)"
        case "inactive": "Inactive, and not quiet"
        case "deleted": "Deleted (not counted as healthy)"
        case "other-status": "A status this version doesn't know, and not quiet"
        default: "Can't be judged (Apple didn't send what's needed)"
        }
    }
}
