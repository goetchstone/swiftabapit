import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

@Suite("Service health report")
struct ServiceHealthTests {
    static let recent = JSONValue.string(Fleet.stamp(-86_400))
    static let old = JSONValue.string(Fleet.stamp(-40 * 86_400))

    static let mixed = [
        Fleet.service("ok", last: recent), Fleet.service("quiet", last: old), Fleet.service("never"),
        Fleet.service("gone", status: "DELETED", last: recent), Fleet.service("gone-never", status: "DELETED"),
        Fleet.service("off", status: "INACTIVE", last: recent), Fleet.service("off-old", status: "INACTIVE", last: old),
        Fleet.service("odd", status: "PAUSED", last: recent), Fleet.service("odd-never", status: "PAUSED"),
        Fleet.service("garbled", last: .string("yesterday")), Fleet.service("nostatus-old", status: nil, last: old),
        Fleet.service("old-too", last: .string(Fleet.stamp(-90 * 86_400))),
    ]

    @Test func healthIsActiveAndRecentAndADeletedServiceIsNeverHealthy() {
        let report = ServiceHealth(Self.mixed, now: Fleet.now)
        #expect(report.rows(group: "healthy").map(\.service.id) == ["ok"])
        #expect(report.healthy == 1)
        #expect(report.rows(group: "deleted").map(\.service.id) == ["gone", "gone-never"])
        #expect(report.rows(group: "inactive").map(\.service.id) == ["off"])
        #expect(report.rows(group: "other-status").map(\.service.id) == ["odd"])
        #expect(report.words.contains("Deleted (not counted as healthy): 2"))
        #expect(report.rows.first { $0.service.id == "odd" }?.health == .otherStatus("PAUSED"))
        #expect(report.rows.first { $0.service.id == "never" }?.lastConnected == .never)
        #expect(report.rows.first { $0.service.id == "garbled" }?.lastConnected == .unreadable("\"yesterday\""))
    }

    /// One rule, two screens: the quiet group is exactly QuietServices' rows, in its order, whatever the status.
    @Test func theQuietGroupIsExactlyQuietServices() {
        let report = ServiceHealth(Self.mixed, now: Fleet.now)
        let quiet = QuietServices(Self.mixed, now: Fleet.now)
        #expect(!quiet.rows.isEmpty)
        #expect(report.rows(group: "quiet").map(\.service.id) == quiet.rows.map(\.service.id))
        #expect(Set(quiet.rows.map(\.service.id)) == ["quiet", "never", "off-old", "odd-never", "garbled", "nostatus-old", "old-too"])
        for days in [1, 7, 40, 90] {
            #expect(ServiceHealth(Self.mixed, now: Fleet.now, days: days).rows(group: "quiet").map(\.service.id)
                    == QuietServices(Self.mixed, now: Fleet.now, days: days).rows.map(\.service.id), "\(days)")
        }
    }

    @Test func theDaysWindowFollowsQuietServicesRule() {
        let edge = JSONValue.string(Fleet.stamp(-7 * 86_400))
        #expect(ServiceHealth([Fleet.service("a", last: edge)], now: Fleet.now, days: 7).rows[0].health == .healthy)
        let over = JSONValue.string(Fleet.stamp(-7 * 86_400 - 1))
        #expect(ServiceHealth([Fleet.service("a", last: over)], now: Fleet.now, days: 7).rows[0].health == .quiet)
        guard case .at(_, let days) = ServiceHealth([Fleet.service("a", last: Self.old)], now: Fleet.now).rows[0].lastConnected else { Issue.record("no date"); return }
        #expect(days == 40)
        #expect(ServiceHealth([], now: Fleet.now, days: 12).title("healthy").contains("12 days"))
    }

    /// The Services screen's words: whole days truncated, 0 is today; a stamp after now is said so, never "-1 days ago".
    @Test func theWordsMatchTheServicesColumn() {
        func words(_ seconds: TimeInterval) -> String {
            ServiceHealth([Fleet.service("a", last: .string(Fleet.stamp(seconds)))], now: Fleet.now).rows[0].lastConnected.words
        }
        #expect(words(-60) == "today")
        #expect(words(-86_400 + 1) == "today")
        #expect(words(-86_400) == "1 day ago")
        #expect(words(-3 * 86_400) == "3 days ago")
        #expect(words(3_600) == "in the future")
        let future = ServiceHealth([Fleet.service("a", last: .string(Fleet.stamp(3_600)))], now: Fleet.now).rows[0]
        #expect(future.health == .healthy)
        let text = CSV.text(ServiceHealth([Fleet.service("a", last: .string(Fleet.stamp(3_600)))], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth)
        #expect(text.contains("in the future") && !text.contains("-1 day"))
    }

    /// Services read with default fields: what Apple didn't send is said, and never read as "never" or "quiet".
    @Test func fieldsAppleDidNotSendAreSaidAndNotGuessed() {
        let lastMissing = ServiceHealth([Fleet.service("a"), Fleet.service("b", status: "INACTIVE"), Fleet.service("c", status: "DELETED")],
                                        notSent: ["lastConnectedDateTime", "deviceCount"], now: Fleet.now)
        #expect(lastMissing.rows.allSatisfy { $0.lastConnected == .notSent })
        #expect(lastMissing.rows(group: "quiet").isEmpty)
        #expect(lastMissing.rows.first { $0.service.id == "a" }?.health == .cannotJudge("Apple didn't send when the service last connected"))
        #expect(lastMissing.rows(group: "deleted").map(\.service.id) == ["c"])
        #expect(lastMissing.notSent == ["deviceCount", "lastConnectedDateTime"])
        #expect(lastMissing.words.contains { $0.contains("didn't send deviceCount, lastConnectedDateTime") })
        let statusMissing = ServiceHealth([Fleet.service("a", status: nil, last: Self.recent), Fleet.service("b", status: "DELETED", last: Self.recent)],
                                          notSent: ["status"], now: Fleet.now)
        #expect(statusMissing.rows.first { $0.service.id == "a" }?.health == .cannotJudge("Apple didn't send the service's status"))
        #expect(ServiceHealth([Fleet.service("a", status: nil, last: Self.recent)], now: Fleet.now).rows[0].health == .cannotJudge("this service has no status"))
    }

    /// The CSV says "not sent by Apple" for a last connection Apple didn't send, never "never".
    @Test func theCSVSaysNotSentNeverNever() throws {
        let text = CSV.text(ServiceHealth([Fleet.service("a"), Fleet.service("b")], notSent: ["lastConnectedDateTime"], now: Fleet.now).csvItems,
                            columns: ExportPolicy.serviceHealth)
        #expect(text.contains("not sent by Apple"))
        #expect(!text.contains("never"))
        let never = CSV.text(ServiceHealth([Fleet.service("a")], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth)
        #expect(never.contains("never connected"))
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

    /// A `deviceCount` Apple sent that isn't a whole number is written as sent, never "not read".
    @Test func aDeviceCountSentAsTextIsWrittenAsSent() {
        let odd = MDMService(resource: Resource(type: "mdmServers", id: "o", attributes: ["serverName": .string("o"), "status": .string("ACTIVE"),
                                                                                       "lastConnectedDateTime": Self.recent, "deviceCount": .string("12")]))
        let none = Fleet.service("n", last: Self.recent)
        let report = ServiceHealth([odd, none], now: Fleet.now)
        #expect(report.rows.first { $0.id == "o" }?.deviceCount == .unreadable("\"12\""))
        let table = Fleet.table(CSV.text(report.csvItems, columns: ExportPolicy.serviceHealth))
        #expect(table["o"]?["deviceCount"] == "\"12\"")
        #expect(table["o"]?["deviceCountIs"] == "not a whole number")
        #expect(table["n"]?["deviceCountIs"] == "not read" && table["n"]?["deviceCount"] == "")
        // The relationship's count still wins.
        #expect(ServiceHealth([odd], deviceCounts: ["o": .exactly(3)], now: Fleet.now).rows[0].deviceCount == .exactly(3))
    }

    /// The quiet title says what the rule counts, including a last-connected value this app can't read; a status not sent is said.
    @Test func theWordsSayWhatQuietCountsAndWhatWasNotSent() {
        let report = ServiceHealth(Self.mixed, notSent: ["status"], now: Fleet.now)
        #expect(report.title("quiet").contains("a last-connected value this app can't read"))
        #expect(report.words.contains("Apple didn't send the services' status, so deleted services can't be told apart and are counted."))
        #expect(!ServiceHealth(Self.mixed, now: Fleet.now).words.contains { $0.contains("can't be told apart") })
    }

    /// A list that wasn't read exports no judgment cells and says so.
    @Test func theCSVCarriesTheListsReadState() throws {
        let unread = ServiceHealth([Fleet.service("a", last: Self.old)], now: Fleet.now, list: .notRead("your role can't read this"))
        let row = try #require(Fleet.table(CSV.text(unread.csvItems, columns: ExportPolicy.serviceHealth))["a"])
        #expect(row["listRead"] == "not read: your role can't read this")
        #expect(row["health"] == "not read" && row["lastConnected"] == "not read" && row["lastConnectedDateTime"] == "")
        let whole = Fleet.table(CSV.text(ServiceHealth([Fleet.service("a", last: Self.old)], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth))
        #expect(whole["a"]?["listRead"] == "read in full" && whole["a"]?["health"] == "quiet")
    }

    @Test func aNonTextStatusIsShownAsSent() {
        let odd = MDMService(resource: Resource(type: "mdmServers", id: "o", attributes: ["serverName": .string("o"), "status": .number("4"), "lastConnectedDateTime": Self.recent]))
        let report = ServiceHealth([odd], now: Fleet.now)
        #expect(report.rows[0].health == .otherStatus("4"))
        #expect(CSV.text(report.csvItems, columns: ExportPolicy.serviceHealth).contains("status 4"))
    }

    @Test func theCSVNeverCarriesTheIPAndSaysWhatWasNotSent() {
        let service = MDMService(resource: Resource(type: "mdmServers", id: "s", attributes: [
            "serverName": .string("Mosyle"), "status": .string("ACTIVE"), "lastConnectedDateTime": Self.recent, "lastConnectedIp": .string("192.0.2.1"),
            "apiToken": .string("canary-token"),
        ]))
        let text = CSV.text(ServiceHealth([service], notSent: ["deviceCount"], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth)
        #expect(!text.contains("192.0.2.1"))
        #expect(!text.contains("canary-token"))
        #expect(text.components(separatedBy: "\r\n")[0] == "id,listRead,serverName,serverType,status,health,healthReason,lastConnectedDateTime,lastConnected,deviceCount,deviceCountIs,notSentByApple")
        #expect(text.contains("deviceCount"))
    }

    @Test func theListsReadIsSaid() {
        #expect(ServiceHealth(Self.mixed, now: Fleet.now, list: .notRead("your role can't read this")).words == ["Not read: your role can't read this. Nothing below can be judged."])
    }
}
