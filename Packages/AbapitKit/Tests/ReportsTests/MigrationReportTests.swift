import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

@Suite("MDM migration report")
struct MigrationReportTests {
    static func device(_ serial: String, status: String? = nil, capable: Bool? = nil, deadline: String? = nil) -> OrgDevice {
        var extra: JSONObject = [:]
        if let status { extra = extra.merging(["mdmMigrationStatus": .string(status)]) }
        if let capable { extra = extra.merging(["isMdmMigrationCapable": .bool(capable)]) }
        if let deadline { extra = extra.merging(["mdmMigrationDeadlineDateTime": .string(deadline)]) }
        return Fleet.device(serial, extra)
    }

    static let day: TimeInterval = 86_400

    static func deadline(_ offset: TimeInterval) -> MigrationReport.Deadline {
        MigrationReport([device("A", status: "REQUESTED", deadline: Fleet.stamp(offset))], now: Fleet.now).rows[0].deadline
    }

    @Test func devicesAreCountedByStatusWithUnknownValuesRaw() {
        let report = MigrationReport([
            Self.device("A", status: "REQUESTED", capable: true), Self.device("B", status: "STARTED"), Self.device("C", status: "SUCCESS"),
            Self.device("D", status: "FAILED"), Self.device("E", status: "PAUSED"), Self.device("F", capable: false),
            Self.device("G"),
        ], now: Fleet.now)
        #expect(report.counts.map(\.group) == ["status:REQUESTED", "status:STARTED", "status:FAILED", "status:SUCCESS", "status:PAUSED", "no-status", "no-data"])
        #expect(report.counts.map(\.count) == [1, 1, 1, 1, 1, 1, 1])
        #expect(report.rows(group: "status:PAUSED").map(\.device.serialNumber) == ["E"])
        #expect(report.rows(group: "status:other").map(\.device.serialNumber) == ["E"])
        #expect(report.words.contains("Status PAUSED: 1"))
        #expect(report.words.contains("Migration data, but no status: 1"))
        #expect(report.words.contains("No migration data from Apple: 1"))
        #expect(report.capable == 1 && report.notCapable == 1 && report.capableNotSent == 5)
    }

    /// A status Apple sent as something other than text is an unknown value, shown as sent, not "no data".
    @Test func aNonTextStatusIsShownAsSent() {
        let odd = Fleet.device("X", ["mdmMigrationStatus": .number("3")])
        let report = MigrationReport([odd], now: Fleet.now)
        #expect(report.rows[0].status == .unknown("3"))
        #expect(report.rows[0].group == "status:3")
    }

    /// 24-hour periods from now: left rounds down, overdue rounds up and is at least 1.
    @Test func theDeadlineCountsPeriodsWithoutDrift() {
        #expect(Self.deadline(10 * Self.day) == .left(10))
        #expect(Self.deadline(10 * Self.day - 1) == .left(9))
        #expect(Self.deadline(1) == .left(0))
        #expect(Self.deadline(0) == .left(0))
        #expect(Self.deadline(-1) == .overdue(1))
        #expect(Self.deadline(-60) == .overdue(1))
        #expect(Self.deadline(-Self.day) == .overdue(1))
        #expect(Self.deadline(-Self.day - 1) == .overdue(2))
        #expect(Self.deadline(-2 * Self.day) == .overdue(2))
    }

    @Test func pastDueIsBeforeNowAndAKnownStatusNotSuccess() {
        let report = MigrationReport([
            Self.device("on-time", status: "STARTED", deadline: Fleet.stamp(0)),
            Self.device("late", status: "STARTED", deadline: Fleet.stamp(-1)),
            Self.device("failed-late", status: "FAILED", deadline: Fleet.stamp(-5 * Self.day)),
            Self.device("done-late", status: "SUCCESS", deadline: Fleet.stamp(-5 * Self.day)),
            Self.device("unknown-late", status: "PAUSED", deadline: Fleet.stamp(-Self.day)),
            Self.device("no-status-late", capable: true, deadline: Fleet.stamp(-Self.day)),
            Self.device("future", status: "REQUESTED", deadline: Fleet.stamp(Self.day)),
        ], now: Fleet.now)
        #expect(Set(report.pastDue.map(\.device.serialNumber)) == ["late", "failed-late"])
        #expect(Set(report.pastDueStatusUnknown.map(\.device.serialNumber)) == ["unknown-late", "no-status-late"])
        #expect(report.rows(group: MigrationReport.pastDueToken).count == 2)
        #expect(report.rows(group: MigrationReport.pastDueStatusUnknownToken).count == 2)
        #expect(report.words.contains("2 past the deadline and not migrated (requested, started or failed)."))
        #expect(report.words.contains("2 past the deadline with no known status: not counted as past due."))
        let cells = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.device.serialNumber, $0.pastDueWords) })
        #expect(cells["late"] == "yes" && cells["done-late"] == "no" && cells["on-time"] == "no" && cells["unknown-late"] == "status unknown")
    }

    @Test func aDeadlineThatIsNotADateIsShownAsSentCountedAndNeverJudged() throws {
        let numeric = Fleet.device("N", ["mdmMigrationStatus": .string("REQUESTED"), "mdmMigrationDeadlineDateTime": .number("12")])
        let report = MigrationReport([Self.device("A", status: "REQUESTED", deadline: "soon"), numeric, Self.device("B", status: "REQUESTED")], now: Fleet.now)
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.device.serialNumber, $0) })
        #expect(rows["A"]?.deadline == .unreadable("\"soon\""))
        #expect(rows["N"]?.deadline == .unreadable("12"))
        #expect(rows["A"]?.pastDue == false)
        #expect(rows["B"]?.deadline == MigrationReport.Deadline.none)
        #expect(report.words.contains("2 have a deadline that isn't a readable date: not counted as past due."))
        let lines = CSV.text(report.csvItems, columns: ExportPolicy.migrationReport).components(separatedBy: "\r\n")
        let line = try #require(lines.first { $0.hasPrefix("A,") })
        #expect(line.hasSuffix("deadline not readable"))
        #expect(!line.hasSuffix(",no"))
    }

    @Test func theListsReadIsSaid() {
        #expect(MigrationReport([], now: Fleet.now, list: .partly("showing 500 of at least 900")).words.first?.contains("500 of at least 900") == true)
        // Not read: that line only, no zero counts.
        #expect(MigrationReport([], now: Fleet.now, list: .notRead("failed")).words == ["Not read: failed. Nothing below can be judged."])
    }

    /// An overdue deadline is its own column, "overdue N days"; never bare days beside the countdown.
    @Test func theCSVHasTheCountdownAndTheOverdueColumn() throws {
        let ahead = OrgDevice(resource: Resource(type: "orgDevices", id: "A", attributes:
            Self.device("A", status: "REQUESTED", capable: true, deadline: Fleet.stamp(3 * Self.day)).attributes.merging(["accessToken": .string("canary-token")])))
        let late = Self.device("L", status: "FAILED", deadline: Fleet.stamp(-Self.day - 60))
        let text = CSV.text(MigrationReport([ahead, late], now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,serialNumber,deviceModel,productFamily,state,mdmMigrationStatus,isMdmMigrationCapable,mdmMigrationDeadlineDateTime,daysToDeadline,overdue,pastDue")
        let a = Fleet.fields(try #require(lines.first { $0.hasPrefix("A,") }))
        #expect(a[8] == "3" && a[9] == "" && a[10] == "no")
        let l = Fleet.fields(try #require(lines.first { $0.hasPrefix("L,") }))
        #expect(l[8] == "" && l[9] == "overdue 2 days" && l[10] == "yes")
        #expect(!text.contains("canary-token"))
    }
}
