import AppleModels
import Foundation
import JSONAPI

/// The dashboard's "services not connected in N days" (plan §2.1's health fields, Phase 2 "Dashboard"): every
/// service whose `lastConnectedDateTime` is more than `days` before `now`, and every one that never connected, most
/// stale first. No abapit counterpart. A `DELETED` service is skipped: `MdmServerStatus` is the service's
/// operational status, and a deleted one can't connect again, so its silence isn't news. `INACTIVE`, a status
/// Apple adds and a missing one are kept: nothing documents that an inactive service stops connecting, and an
/// inactive one that still holds devices is what the operator should see.
public struct QuietServices: Sendable {
    /// The Overview's N, the Services screen's `staleAfter`.
    public static let defaultDays = 30

    public enum LastConnected: Sendable, Equatable {
        /// Apple sent no `lastConnectedDateTime` (absent or null): said as "never".
        case never
        /// Apple sent one that isn't a date `ISODate` reads (an empty string included): shown raw from the service,
        /// never as "never" or as a date. It ranks with `never`.
        case unreadable
        case at(ISODate)
    }

    public struct Row: Sendable {
        public let service: MDMService
        public let lastConnected: LastConnected
    }

    /// Never-connected and unreadable first, in the order given; then the oldest connection first, equal instants in
    /// the order given.
    public let rows: [Row]

    /// Quiet means more than `days` (exactly `days` isn't), by the instant, whatever offset Apple wrote it in. A
    /// stamp after `now` is recent.
    public init(_ services: [MDMService], now: Date, days: Int = defaultDays) {
        let limit = TimeInterval(days) * 86_400
        let quiet = services.enumerated().compactMap { offset, service -> (offset: Int, date: Date?, row: Row)? in
            guard service.status != .known(.deleted) else { return nil }
            let last = Self.lastConnected(service)
            guard case .at(let date) = last else { return (offset, nil, Row(service: service, lastConnected: last)) }
            return now.timeIntervalSince(date.date) > limit ? (offset, date.date, Row(service: service, lastConnected: last)) : nil
        }
        rows = quiet.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: x < y
            case (.none, .some): true
            case (.some, .none): false
            default: a.offset < b.offset
            }
        }.map(\.row)
    }

    static func lastConnected(_ service: MDMService) -> LastConnected {
        switch service.attributes["lastConnectedDateTime"] {
        case nil, .null?: .never
        case let value?: ISODate.parse(value.string).map(LastConnected.at) ?? .unreadable
        }
    }
}
