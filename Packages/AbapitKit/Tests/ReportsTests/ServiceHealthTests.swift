import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

@Suite("Service health report")
struct ServiceHealthTests {
    static let recent = JSONValue.string(Fleet.stamp(-86_400))
    static let old = JSONValue.string(Fleet.stamp(-40 * 86_400))

    @Test func healthIsActiveAndRecentAndADeletedServiceIsNeverHealthy() {
        let report = ServiceHealth([
            Fleet.service("ok", last: Self.recent), Fleet.service("quiet", last: Self.old), Fleet.service("never"),
            Fleet.service("gone", status: "DELETED", last: Self.recent), Fleet.service("gone-never", status: "DELETED"),
            Fleet.service("off", status: "INACTIVE", last: Self.recent), Fleet.service("odd", status: "PAUSED", last: Self.recent),
            Fleet.service("garbled", last: .string("yesterday")),
        ], now: Fleet.now)
        #expect(report.rows(group: "healthy").map(\.service.id) == ["ok"])
        #expect(report.healthy == 1)
        #expect(report.rows(group: "quiet").map(\.service.id) == ["quiet", "never", "garbled"])
        #expect(report.rows(group: "deleted").map(\.service.id) == ["gone", "gone-never"])
        #expect(report.rows(group: "inactive").map(\.service.id) == ["off"])
        #expect(report.rows(group: "other-status").map(\.service.id) == ["odd"])
        #expect(report.words.contains("Deleted (not counted as healthy): 2"))
        #expect(report.rows.first { $0.service.id == "odd" }?.health == .otherStatus("PAUSED"))
        #expect(report.rows.first { $0.service.id == "never" }?.lastConnected == .never)
        #expect(report.rows.first { $0.service.id == "garbled" }?.lastConnected == .unreadable("yesterday"))
    }

    @Test func theDaysWindowFollowsQuietServicesRule() {
        let edge = JSONValue.string(Fleet.stamp(-7 * 86_400))
        #expect(ServiceHealth([Fleet.service("a", last: edge)], now: Fleet.now, days: 7).rows[0].health == .healthy)
        let over = JSONValue.string(Fleet.stamp(-7 * 86_400 - 1))
        #expect(ServiceHealth([Fleet.service("a", last: over)], now: Fleet.now, days: 7).rows[0].health == .quiet)
        guard case .at(_, let days) = ServiceHealth([Fleet.service("a", last: Self.old)], now: Fleet.now).rows[0].lastConnected else { Issue.record("no date"); return }
        #expect(days == 40)
    }

    /// Services read with default fields: what Apple didn't send is said, and never read as "never" or "not deleted".
    @Test func fieldsAppleDidNotSendAreSaidAndNotGuessed() {
        let lastMissing = ServiceHealth([Fleet.service("a")], notSent: ["lastConnectedDateTime", "deviceCount"], now: Fleet.now)
        #expect(lastMissing.rows[0].lastConnected == .notSent)
        #expect(lastMissing.rows[0].health == .cannotJudge("Apple didn't send when the service last connected"))
        #expect(lastMissing.notSent == ["deviceCount", "lastConnectedDateTime"])
        #expect(lastMissing.words.contains { $0.contains("didn't send deviceCount, lastConnectedDateTime") })
        let statusMissing = ServiceHealth([Fleet.service("a", status: nil, last: Self.recent), Fleet.service("b", status: "DELETED", last: Self.recent)],
                                          notSent: ["status"], now: Fleet.now)
        #expect(statusMissing.rows.allSatisfy { $0.group == "cannot-judge" })
        // A service with no status of its own, though Apple sent the field for others.
        #expect(ServiceHealth([Fleet.service("a", status: nil, last: Self.recent)], now: Fleet.now).rows[0].health == .cannotJudge("this service has no status"))
    }

    @Test func deviceCountsComeFromTheRelationshipThenTheAttributeThenAreNotRead() {
        let report = ServiceHealth([Fleet.service("rel", last: Self.recent, count: 9), Fleet.service("attr", last: Self.recent, count: 4),
                                    Fleet.service("none", last: Self.recent), Fleet.service("cut", last: Self.recent)], deviceCounts: ["rel": .exactly(12), "cut": .atLeast(200)],
                                   now: Fleet.now)
        let counts = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.service.id, $0.deviceCount) })
        #expect(counts["rel"] == .some(.exactly(12)))
        #expect(counts["attr"] == .some(.exactly(4)))
        #expect(counts["none"] == .some(nil))
        #expect(counts["cut"] == .some(.atLeast(200)))
        let text = CSV.text(report.csvItems, columns: ExportPolicy.serviceHealth)
        #expect(text.contains("not read"))
        #expect(text.contains("at least"))
    }

    @Test func theCSVNeverCarriesTheIPAndSaysWhatWasNotSent() {
        let service = MDMService(resource: Resource(type: "mdmServers", id: "s", attributes: [
            "serverName": .string("Mosyle"), "status": .string("ACTIVE"), "lastConnectedDateTime": Self.recent, "lastConnectedIp": .string("192.0.2.1"),
            "apiToken": .string("canary-token"),
        ]))
        let text = CSV.text(ServiceHealth([service], notSent: ["deviceCount"], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth)
        #expect(!text.contains("192.0.2.1"))
        #expect(!text.contains("canary-token"))
        #expect(text.components(separatedBy: "\r\n")[0] == "id,serverName,serverType,status,health,healthReason,lastConnectedDateTime,lastConnected,deviceCount,deviceCountIs,notSentByApple")
        #expect(text.contains("deviceCount"))
    }

    @Test func theListsReadIsSaid() {
        #expect(ServiceHealth([], now: Fleet.now, list: .notRead("your role can't read this")).words.first == "Not read: your role can't read this. Nothing below can be judged.")
    }
}
