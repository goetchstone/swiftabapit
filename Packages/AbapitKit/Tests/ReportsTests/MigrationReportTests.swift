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

    /// An overdue deadline is its own column, "overdue N days"; never bare days beside the countdown; a completed migration's
    /// passed deadline is never called overdue.
    @Test func theCSVHasTheCountdownAndTheOverdueColumn() throws {
        let ahead = OrgDevice(resource: Resource(type: "orgDevices", id: "A", attributes:
            Self.device("A", status: "REQUESTED", capable: true, deadline: Fleet.stamp(3 * Self.day)).attributes.merging(["accessToken": .string("canary-token")])))
        let late = Self.device("L", status: "FAILED", deadline: Fleet.stamp(-Self.day - 60))
        let done = Self.device("D", status: "SUCCESS", deadline: Fleet.stamp(-3 * Self.day))
        let unknown = Self.device("U", status: "PAUSED", deadline: Fleet.stamp(-Self.day))
        let text = CSV.text(MigrationReport([ahead, late, done, unknown], now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport)
        #expect(Fleet.header(text) == "id,listRead,serialNumber,deviceModel,productFamily,state,mdmMigrationStatus,isMdmMigrationCapable,mdmMigrationDeadlineDateTime,daysToDeadline,overdue,pastDue")
        let table = Fleet.table(text)
        #expect(table["A"]?["daysToDeadline"] == "3" && table["A"]?["overdue"] == "" && table["A"]?["pastDue"] == "no")
        #expect(table["L"]?["daysToDeadline"] == "" && table["L"]?["overdue"] == "overdue 2 days" && table["L"]?["pastDue"] == "yes")
        #expect(table["D"]?["overdue"] == "deadline passed 3 days ago" && table["D"]?["pastDue"] == "no")
        #expect(table["U"]?["overdue"] == "deadline passed 1 day ago" && table["U"]?["pastDue"] == "status unknown")
        #expect(!text.contains("canary-token"))
    }

    /// Yes or no only where Apple sent a boolean; anything else it sent is written as sent, and nothing sent is blank.
    @Test func theCapableCellIsNeverGuessed() {
        let devices = [Self.device("T", capable: true), Self.device("F", capable: false), Self.device("N"),
                       Fleet.device("S", ["isMdmMigrationCapable": .string("true")]), Fleet.device("Z", ["isMdmMigrationCapable": .number("1")]),
                       Fleet.device("X", ["isMdmMigrationCapable": .null])]
        let table = Fleet.table(CSV.text(MigrationReport(devices, now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport))
        #expect(table["T"]?["isMdmMigrationCapable"] == "yes")
        #expect(table["F"]?["isMdmMigrationCapable"] == "no")
        #expect(table["N"]?["isMdmMigrationCapable"] == "")
        #expect(table["X"]?["isMdmMigrationCapable"] == "")
        #expect(table["S"]?["isMdmMigrationCapable"] == "\"true\"")
        #expect(table["Z"]?["isMdmMigrationCapable"] == "1")
        #expect(MigrationReport(devices, now: Fleet.now).capableNotSent == 4)
    }

    /// An unreadable deadline's raw value stays in the CSV, quoted as the Services screen shows it.
    @Test func anUnreadableDeadlineKeepsItsRawValueInTheCSV() {
        let odd = Self.device("A", status: "REQUESTED", deadline: "soon")
        let table = Fleet.table(CSV.text(MigrationReport([odd], now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport))
        #expect(table["A"]?["mdmMigrationDeadlineDateTime"] == "\"soon\"")
        #expect(table["A"]?["pastDue"] == "deadline not readable")
    }

    /// The order is total and stable: every arrangement of the same devices gives one order (equal instants in different
    /// offsets, one with no deadline, one with an unreadable one all included).
    @Test func theOrderIsTotalWhateverTheInputOrder() {
        let a = Self.device("D1", status: "REQUESTED", deadline: "2026-12-01T10:00:00+02:00")
        let b = Self.device("D2", status: "REQUESTED", deadline: "2026-12-01T08:00:00Z")
        let c = Self.device("D3", status: "REQUESTED", deadline: "2026-11-30T08:00:00Z")
        let d = Self.device("A1", status: "REQUESTED")
        let e = Self.device("A2", status: "REQUESTED", deadline: "soon")
        let devices = [a, b, c, d, e]
        func orders(_ items: [OrgDevice]) -> [[OrgDevice]] {
            items.count <= 1 ? [items] : items.indices.flatMap { i in
                var rest = items; let head = rest.remove(at: i)
                return orders(rest).map { [head] + $0 }
            }
        }
        let results = Set(orders(devices).map { MigrationReport($0, now: Fleet.now).rows.map(\.device.serialNumber).joined(separator: ",") })
        #expect(results == ["D3,D1,D2,A1,A2"])
    }

    @Test func theCSVOfAnUnreadListJudgesNothing() throws {
        let late = Self.device("L", status: "FAILED", deadline: Fleet.stamp(-Self.day - 60))
        let row = try #require(Fleet.table(CSV.text(MigrationReport([late], now: Fleet.now, list: .notRead("failed")).csvItems, columns: ExportPolicy.migrationReport))["L"])
        #expect(row["listRead"] == "not read: failed")
        #expect(row["pastDue"] == "not read" && row["overdue"] == "not read" && row["state"] == "not read")
        #expect(row["mdmMigrationStatus"] == "" && row["mdmMigrationDeadlineDateTime"] == "")
    }
}
