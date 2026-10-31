import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

/// The dashboard's "services not connected in N days" (plan Phase 2, "Dashboard"; §2.1's health fields).
@Suite("Quiet services")
struct QuietServicesTests {
    /// The generator's FIXED_NOW, 2026-10-16T12:00:00Z.
    static let now = Date(timeIntervalSince1970: 1_792_152_000)

    static func service(_ id: String, _ last: JSONValue?, status: String? = "ACTIVE") -> MDMService {
        var attributes: JSONObject = ["serverName": .string(id)]
        if let last { attributes = attributes.merging(["lastConnectedDateTime": last]) }
        if let status { attributes = attributes.merging(["status": .string(status)]) }
        return MDMService(resource: Resource(type: "mdmServers", id: id, attributes: attributes))
    }

    static func stamp(_ text: String) -> JSONValue { .string(text) }

    static func ids(_ quiet: QuietServices) -> [String] { quiet.rows.map(\.service.id) }

    /// N defaults to 30, the Services screen's `staleAfter`.
    @Test func theDefaultIsThirtyDays() {
        #expect(QuietServices.defaultDays == 30)
        let services = [Self.service("29", Self.stamp("2026-09-17T12:00:00Z")), Self.service("31", Self.stamp("2026-09-15T12:00:00Z"))]
        #expect(Self.ids(QuietServices(services, now: Self.now)) == ["31"])
    }

    /// Older than N days means more than N days: exactly N days isn't quiet, however its offset spells it, and a
    /// second or a microsecond more is.
    @Test(arguments: [30, 7, 1])
    func exactlyNDaysIsNotQuiet(days: Int) throws {
        let edge = Self.now.addingTimeInterval(-TimeInterval(days) * 86_400)
        func iso(_ date: Date, offset: Int = 0, fraction: String = "") -> String {
            let format = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: offset)!)
            let text = date.formatted(format)
            // `…:SSZ` or `…:SS+05:30`: put the fraction after the seconds.
            let split = text.index(text.startIndex, offsetBy: 19)
            return String(text[..<split]) + fraction + String(text[split...])
        }
        let services = [
            Self.service("exactly", Self.stamp(iso(edge))),
            Self.service("exactly+0530", Self.stamp(iso(edge, offset: 19_800))),
            Self.service("exactly-0800", Self.stamp(iso(edge, offset: -28_800, fraction: ".000000"))),
            Self.service("a second less", Self.stamp(iso(edge.addingTimeInterval(1)))),
            Self.service("a second more", Self.stamp(iso(edge.addingTimeInterval(-1)))),
            Self.service("a microsecond more", Self.stamp(iso(edge.addingTimeInterval(-1), fraction: ".999999"))),
        ]
        try #require(services.compactMap(\.lastConnected).count == services.count, "every stamp reads")
        #expect(Self.ids(QuietServices(services, now: Self.now, days: days)) == ["a second more", "a microsecond more"])
    }

    /// A service that never connected is listed, said as never, and ranks as the most stale; one whose stamp isn't a
    /// date is listed as unreadable, never as "never" or as connected, beside them.
    @Test func neverConnectedIsListedFirst() {
        let services = [
            Self.service("old", Self.stamp("2026-01-01T00:00:00Z")),
            Self.service("absent", nil),
            Self.service("recent", Self.stamp("2026-10-15T00:00:00Z")),
            Self.service("null", .null),
            Self.service("empty", Self.stamp("")),
            Self.service("words", Self.stamp("not a date")),
            Self.service("number", .number("1792152000")),
        ]
        let quiet = QuietServices(services, now: Self.now)
        #expect(Self.ids(quiet) == ["absent", "null", "empty", "words", "number", "old"])
        #expect(quiet.rows.map(\.lastConnected) == [.never, .never, .unreadable, .unreadable, .unreadable,
                                                     .at(ISODate.parse("2026-01-01T00:00:00Z")!)])
    }

    /// Most stale first by the instant, not the string (`2026-03-01T20:00:00-08:00` is 04:00 UTC on 2 March, after
    /// `2026-03-02T01:00:00Z`); equal instants keep their order.
    @Test func mostStaleFirst() {
        let services = [
            Self.service("west", Self.stamp("2026-03-01T20:00:00-08:00")),
            Self.service("utc", Self.stamp("2026-03-02T01:00:00Z")),
            Self.service("tie-a", Self.stamp("2026-05-01T10:00:00Z")),
            Self.service("oldest", Self.stamp("2025-12-31T23:59:59.5+00:00")),
            Self.service("tie-b", Self.stamp("2026-05-01T12:00:00+02:00")),
            Self.service("fraction", Self.stamp("2026-03-02T01:00:00.25Z")),
        ]
        #expect(Self.ids(QuietServices(services, now: Self.now)) == ["oldest", "utc", "fraction", "west", "tie-a", "tie-b"])
    }

    /// A deleted service can't connect again, so its silence isn't news: skipped. Inactive, unknown and missing
    /// statuses are kept, as is a status that only looks deleted.
    @Test func deletedServicesAreSkipped() {
        let old = Self.stamp("2026-01-01T00:00:00Z")
        let services = [
            Self.service("deleted", old, status: "DELETED"), Self.service("deleted-never", nil, status: "DELETED"),
            Self.service("inactive", old, status: "INACTIVE"), Self.service("future", old, status: "SUSPENDED"),
            Self.service("none", old, status: nil), Self.service("lower", old, status: "deleted"),
            Self.service("spaced", old, status: "DELETED "), Self.service("active", nil),
        ]
        #expect(Self.ids(QuietServices(services, now: Self.now)) == ["active", "inactive", "future", "none", "lower", "spaced"])
    }

    /// A stamp after `now` (a clock ahead of ours) is recent, not quiet.
    @Test func aStampAfterNowIsNotQuiet() {
        let services = [Self.service("ahead", Self.stamp("2026-10-17T12:00:00Z")), Self.service("now", Self.stamp("2026-10-16T12:00:00Z"))]
        #expect(QuietServices(services, now: Self.now, days: 0).rows.isEmpty)
        #expect(QuietServices([], now: Self.now).rows.isEmpty)
    }
}
