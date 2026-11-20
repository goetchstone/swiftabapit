import AppleModels
import Foundation
import JSONAPI

/// How many devices a service holds, as the read said it.
public enum ServiceDeviceCount: Sendable, Equatable {
    case exactly(Int)
    /// The relationship read was cut at the page cap.
    case atLeast(Int)
}

/// The MDM service health report (plan Phase 3): per service, when it last connected (`QuietServices.lastConnected`,
/// the rule the Overview and the Services screen use), its status, its device count and a verdict. No abapit counterpart.
///
/// The services list may have been read with default fields (apple-reads, "Answered live 2026-11-19/-20"): `notSent`
/// is the attributes no service came back with (`Page.absent`), and a service that needs one to be judged is
/// `cannot-judge`, never healthy and never "never connected". The device count is the relationship's count when the
/// screen read it, else Apple's `deviceCount` attribute, else not read. A `DELETED` service is its own group: it
/// can't connect again, so it's neither healthy nor quiet.
public struct ServiceHealth: Sendable {
    public enum Health: Sendable, Equatable {
        /// `ACTIVE` and not quiet.
        case healthy
        /// `ACTIVE` and quiet by `QuietServices`' rule (never connected, unreadable, or older than `days`).
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
        case unreadable(String)
        case at(ISODate, daysAgo: Int)
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
    /// Quiet first, then the rest in the order given; see `fixedGroups` for the order of groups.
    public let rows: [Row]

    /// `deviceCounts` is keyed by service id (the relationship counts); `notSent` is `Page.absent`.
    public init(_ services: [MDMService], deviceCounts: [String: ServiceDeviceCount] = [:], notSent: Set<String> = [],
                now: Date, days: Int = QuietServices.defaultDays, list: ListRead = .whole) {
        self.list = list
        self.days = days
        self.notSent = notSent.sorted(by: byBytes)
        let built = services.map { service -> Row in
            let connected = Self.connected(service, notSent: notSent, now: now)
            let count = deviceCounts[service.id] ?? service.deviceCount.map(ServiceDeviceCount.exactly)
            return Row(service: service, health: Self.health(service, connected: connected, notSent: notSent, now: now, days: days),
                       lastConnected: connected, deviceCount: count)
        }
        let order = Self.fixedGroups
        rows = built.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.group) ?? order.count, order.firstIndex(of: b.element.group) ?? order.count)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    static func connected(_ service: MDMService, notSent: Set<String>, now: Date) -> Connected {
        if notSent.contains("lastConnectedDateTime") { return .notSent }
        switch QuietServices.lastConnected(service) {
        case .never: return .never
        case .unreadable: return .unreadable(service.attributes["lastConnectedDateTime"]?.string ?? "not text")
        case .at(let date): return .at(date, daysAgo: Int((now.timeIntervalSince(date.date) / 86_400).rounded(.down)))
        }
    }

    static func health(_ service: MDMService, connected: Connected, notSent: Set<String>, now: Date, days: Int) -> Health {
        if notSent.contains("status") { return .cannotJudge("Apple didn't send the service's status") }
        switch service.status {
        case nil: return .cannotJudge("this service has no status")
        case .known(.deleted)?: return .deleted
        case .known(.inactive)?: return .inactive
        case .unknown(let raw)?: return .otherStatus(raw)
        case .known(.active)?: break
        }
        if case .notSent = connected { return .cannotJudge("Apple didn't send when the service last connected") }
        return QuietServices([service], now: now, days: days).rows.isEmpty ? .healthy : .quiet
    }

    public func rows(group: String) -> [Row] { rows.filter { $0.group == group } }

    public var healthy: Int { rows(group: "healthy").count }

    public var words: [String] {
        var lines = [list.words]
        if !notSent.isEmpty {
            lines.append("Apple didn't send \(notSent.joined(separator: ", ")) for any service (read with default fields): services that need it can't be judged.")
        }
        for key in Self.fixedGroups {
            let count = rows(group: key).count
            if count > 0 { lines.append("\(Self.title(key)): \(count)") }
        }
        return lines
    }

    static func title(_ key: String) -> String {
        switch key {
        case "healthy": "Active and connected within the last days window"
        case "quiet": "Active but quiet (never connected, or silent past the window)"
        case "inactive": "Inactive"
        case "deleted": "Deleted (not counted as healthy)"
        case "other-status": "A status this version doesn't know"
        default: "Can't be judged (Apple didn't send what's needed)"
        }
    }
}
