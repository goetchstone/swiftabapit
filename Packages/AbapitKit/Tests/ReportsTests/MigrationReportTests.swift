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

    @Test func devicesAreCountedByStatusWithUnknownValuesRaw() {
        let report = MigrationReport([
            Self.device("A", status: "REQUESTED", capable: true), Self.device("B", status: "STARTED"), Self.device("C", status: "SUCCESS"),
            Self.device("D", status: "FAILED"), Self.device("E", status: "PAUSED"), Self.device("F", capable: false),
            Self.device("G"),
        ], now: Fleet.now)
        #expect(report.counts.map(\.group) == ["status:REQUESTED", "status:STARTED", "status:FAILED", "status:SUCCESS", "status:PAUSED", "no-status", "no-data"])
        #expect(report.counts.map(\.count) == [1, 1, 1, 1, 1, 1, 1])
        #expect(report.rows(group: "status:PAUSED").map(\.device.serialNumber) == ["E"])
        #expect(report.words.contains("Status PAUSED: 1"))
        #expect(report.words.contains("Migration data, but no status: 1"))
        #expect(report.words.contains("No migration data from Apple: 1"))
        #expect(report.capable == 1 && report.notCapable == 1 && report.capableNotSent == 5)
    }

    /// Whole days: exactly N days ahead is N, a second short is N-1; the instant itself is 0 left; a second after is overdue.
    @Test func theDeadlineCountsWholeDaysWithoutDrift() {
        func deadline(_ offset: TimeInterval) -> MigrationReport.Deadline {
            MigrationReport([Self.device("A", status: "REQUESTED", deadline: Fleet.stamp(offset))], now: Fleet.now).rows[0].deadline
        }
        #expect(deadline(10 * Self.day) == .left(10))
        #expect(deadline(10 * Self.day - 1) == .left(9))
        #expect(deadline(1) == .left(0))
        #expect(deadline(0) == .left(0))
        #expect(deadline(-1) == .overdue(0))
        #expect(deadline(-Self.day) == .overdue(1))
        #expect(deadline(-Self.day - 1) == .overdue(1))
        #expect(deadline(-2 * Self.day + 1) == .overdue(1))
    }

    @Test func pastDueIsBeforeNowAndNotMigrated() {
        let report = MigrationReport([
            Self.device("on-time", status: "STARTED", deadline: Fleet.stamp(0)),
            Self.device("late", status: "STARTED", deadline: Fleet.stamp(-1)),
            Self.device("failed-late", status: "FAILED", deadline: Fleet.stamp(-5 * Self.day)),
            Self.device("done-late", status: "SUCCESS", deadline: Fleet.stamp(-5 * Self.day)),
            Self.device("unknown-late", status: "PAUSED", deadline: Fleet.stamp(-Self.day)),
            Self.device("no-status-late", capable: true, deadline: Fleet.stamp(-Self.day)),
            Self.device("future", status: "REQUESTED", deadline: Fleet.stamp(Self.day)),
        ], now: Fleet.now)
        #expect(Set(report.pastDue.map(\.device.serialNumber)) == ["late", "failed-late", "unknown-late", "no-status-late"])
        #expect(report.rows(group: MigrationReport.pastDueToken).count == 4)
        #expect(report.words.contains("4 past the deadline and not migrated."))
    }

    @Test func aDeadlineThatIsNotADateIsShownRawAndAbsentIsNone() {
        let report = MigrationReport([Self.device("A", status: "REQUESTED", deadline: "soon"), Self.device("B", status: "REQUESTED")], now: Fleet.now)
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.device.serialNumber, $0) })
        #expect(rows["A"]?.deadline == .unreadable("soon"))
        #expect(rows["A"]?.pastDue == false)
        #expect(rows["B"]?.deadline == MigrationReport.Deadline.none)
        let text = CSV.text(report.csvItems, columns: ExportPolicy.migrationReport)
        #expect(text.contains("deadline not readable"))
    }

    @Test func theListsReadIsSaid() {
        #expect(MigrationReport([], now: Fleet.now, list: .partly("showing 500 of at least 900")).words.first?.contains("500 of at least 900") == true)
        #expect(MigrationReport([], now: Fleet.now, list: .notRead("failed")).words.first == "Not read: failed. Nothing below can be judged.")
    }

    @Test func theCSVHasTheCountdownAndNoUnlistedKey() throws {
        let device = Self.device("A", status: "REQUESTED", capable: true, deadline: Fleet.stamp(3 * Self.day))
        let withSecret = OrgDevice(resource: Resource(type: "orgDevices", id: "A", attributes: device.attributes.merging(["accessToken": .string("canary-token")])))
        let text = CSV.text(MigrationReport([withSecret], now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,serialNumber,deviceModel,productFamily,state,mdmMigrationStatus,isMdmMigrationCapable,mdmMigrationDeadlineDateTime,daysToDeadline,pastDue")
        #expect(lines[1].hasSuffix(",3,no"))
        #expect(!text.contains("canary-token"))
    }
}
