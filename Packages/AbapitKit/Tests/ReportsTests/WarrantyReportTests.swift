import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

@Suite("Out of warranty report")
struct WarrantyReportTests {
    static func entry(_ serial: String, _ coverage: DeviceRead<[AppleCareCoverage]>, ordered: String? = nil) -> WarrantyReport.Entry {
        let extra: JSONObject = ordered.map { ["orderDateTime": .string($0)] } ?? [:]
        return .init(device: Fleet.device(serial, extra), coverage: coverage)
    }

    /// An order stamp `days` before `now`.
    static func ordered(daysAgo days: Double) -> String { Fleet.stamp(-days * 86_400) }

    static let report = WarrantyReport([
        entry("ACTIVE", .read([Fleet.coverage("INACTIVE"), Fleet.coverage("ACTIVE", end: "2027-06-01T00:00:00Z")])),
        entry("EXPIRED", .read([Fleet.coverage("INACTIVE")]), ordered: "2020-01-01T00:00:00Z"),
        entry("ODD", .read([Fleet.coverage("SUSPENDED"), Fleet.coverage(nil)])),
        entry("EMPTY", .read([]), ordered: "2020-01-01T00:00:00Z"),
        entry("FRESH-EMPTY", .read([]), ordered: ordered(daysAgo: 30)),
        entry("UNREAD", .notRead("your role can't read this"), ordered: "2020-01-01T00:00:00Z"),
    ], now: Fleet.now)

    @Test func theFourKindsStayApart() {
        #expect(Self.report.rows(group: "active").map(\.device.serialNumber) == ["ACTIVE"])
        #expect(Self.report.rows(group: "no-active-coverage").map(\.device.serialNumber) == ["EXPIRED", "ODD"])
        #expect(Self.report.rows(group: "no-record").map(\.device.serialNumber) == ["EMPTY", "FRESH-EMPTY"])
        #expect(Self.report.rows(group: "not-read").map(\.device.serialNumber) == ["UNREAD"])
        #expect(Self.report.withoutActiveCoverage == 4)
    }

    /// No record is not expired: its own words say so, and no row calls it expired.
    @Test func noRecordIsNotCalledExpired() {
        #expect(Self.report.words.contains("2 have no coverage record at all: that may mean no AppleCare, not that it expired."))
        #expect(Self.report.words.contains("2 have coverage records but none ACTIVE."))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = text.components(separatedBy: "\r\n").first { $0.hasPrefix("EMPTY,") } ?? ""
        #expect(line.contains("may mean no AppleCare, not expired"))
        #expect(!line.contains("expired,") && !line.contains("out of warranty"))
    }

    /// Not read is never out of warranty: no estimate, no count among those without coverage.
    @Test func notReadIsNeverOutOfWarranty() throws {
        let row = try #require(Self.report.rows(group: "not-read").first)
        #expect(row.estimate == .notMade)
        #expect(!row.estimatedPast)
        #expect(Self.report.rows(group: WarrantyReport.estimatedPastToken).map(\.device.serialNumber) == ["EXPIRED", "EMPTY"])
        #expect(Self.report.words.contains("1 had their coverage unread: not counted as out of warranty."))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = text.components(separatedBy: "\r\n").first { $0.hasPrefix("UNREAD,") } ?? ""
        #expect(line.contains("not read: your role can't read this"))
        #expect(!line.contains("estimate"))
    }

    @Test func anActiveRecordIsActiveWhateverElseIsListed() {
        #expect(Self.report.rows(group: "active")[0].kind == .active(ends: ISODate.parse("2027-06-01T00:00:00Z")))
        #expect(Self.report.rows(group: "active")[0].estimate == .notMade)
        #expect(Self.report.rows(group: "no-active-coverage").last?.kind == .noActiveCoverage(statuses: ["SUSPENDED", "not sent"]))
    }

    /// The estimate: order date plus one calendar year, labelled and with its assumption.
    @Test func theEstimateIsLabelledAndHasItsBoundary() throws {
        func estimate(_ ordered: String?) -> WarrantyReport.Estimate {
            WarrantyReport([Self.entry("E", .read([]), ordered: ordered)], now: Fleet.now).rows[0].estimate
        }
        // Ordered 2025-11-20T12:00:00Z: its year ends exactly now, which is not yet past.
        if case .withinAssumedLimit = estimate("2025-11-20T12:00:00Z") {} else { Issue.record("exactly a year is not past") }
        if case .pastAssumedLimit = estimate("2025-11-20T11:59:59Z") {} else { Issue.record("a second more is past") }
        if case .withinAssumedLimit = estimate(Self.ordered(daysAgo: 30)) {} else { Issue.record("30 days ago is within") }
        #expect(estimate(nil) == .noOrderDate)
        #expect(estimate("last spring") == .unreadableOrderDate("last spring"))
        #expect(WarrantyReport.assumption.contains("Estimate only"))
        #expect(WarrantyReport.assumption.contains("one-year limited warranty"))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("EXPIRED,") })
        #expect(line.contains("estimate: past the assumed one year"))
        #expect(line.contains("Estimate only"))
    }

    @Test func theListsReadIsSaid() {
        #expect(WarrantyReport([], now: Fleet.now, list: .partly("showing 500 of at least 900")).words.first?.contains("500 of at least 900") == true)
    }

    @Test func noSecretLeavesTheCSV() {
        let entry = Self.entry("S", .read([]))
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "S", attributes: entry.device.attributes.merging([
            "activationLockBypassCode": .string("canary-bypass"), "nested": .object(["password": .string("canary-pw")])])))
        let text = CSV.text(WarrantyReport([.init(device: device, coverage: .read([]))], now: Fleet.now).csvItems, columns: ExportPolicy.warrantyReport)
        #expect(!text.contains("canary"))
    }
}
