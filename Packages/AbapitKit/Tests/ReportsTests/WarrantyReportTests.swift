import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

@Suite("Out of warranty report")
struct WarrantyReportTests {
    /// Entries as `(serial, coverage?, order date)`; a nil coverage is a device the sweep never reached.
    static func make(_ entries: [(String, DeviceRead<[AppleCareCoverage]>?, String?)], now: Date = Fleet.now, list: ListRead = .whole) -> WarrantyReport {
        let devices = entries.map { Fleet.device($0.0, $0.2.map { ["orderDateTime": .string($0)] } ?? [:]) }
        var coverage: [String: DeviceRead<[AppleCareCoverage]>] = [:]
        for (serial, read, _) in entries { if let read { coverage[serial] = read } }
        return WarrantyReport(devices, coverage: coverage, now: now, list: list)
    }

    /// An order stamp `days` before `now`.
    static func ordered(daysAgo days: Double) -> String { Fleet.stamp(-days * 86_400) }

    static let report = make([
        ("ACTIVE", .read([Fleet.coverage("INACTIVE"), Fleet.coverage("ACTIVE", end: "2027-06-01T00:00:00Z")]), nil),
        ("EXPIRED", .read([Fleet.coverage("INACTIVE")]), "2020-01-01T00:00:00Z"),
        ("ODD", .read([Fleet.coverage("SUSPENDED"), Fleet.coverage(nil)]), "2020-01-01T00:00:00Z"),
        ("EMPTY", .read([]), "2020-01-01T00:00:00Z"),
        ("FRESH-EMPTY", .read([]), ordered(daysAgo: 30)),
        ("NODATE", .read([]), nil),
        ("UNREAD", .notRead("your role can't read this"), "2020-01-01T00:00:00Z"),
    ])

    @Test func theFiveKindsStayApart() {
        #expect(Self.report.rows(group: "active").map(\.device.serialNumber) == ["ACTIVE"])
        #expect(Self.report.rows(group: "no-active-coverage").map(\.device.serialNumber) == ["EXPIRED"])
        #expect(Self.report.rows(group: "status-unknown").map(\.device.serialNumber) == ["ODD"])
        #expect(Self.report.rows(group: "no-record").map(\.device.serialNumber) == ["EMPTY", "FRESH-EMPTY", "NODATE"])
        #expect(Self.report.rows(group: "not-read").map(\.device.serialNumber) == ["UNREAD"])
        #expect(Self.report.withoutActiveCoverage == 4)
    }

    /// A status this version doesn't know, or none: shown raw, never estimated, never counted as without coverage.
    @Test func anUnknownCoverageStatusIsNeitherEstimatedNorOutOfWarranty() throws {
        let odd = try #require(Self.report.rows(group: "status-unknown").first)
        #expect(odd.kind == .statusUnknown(statuses: ["SUSPENDED", "not sent"]))
        #expect(odd.estimate == .notMade)
        #expect(!Self.report.rows(group: WarrantyReport.estimatedPastToken).map(\.device.serialNumber).contains("ODD"))
        #expect(Self.report.words.contains("1 have coverage records whose status this version doesn't know: not counted as out of warranty, and not estimated."))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("ODD,") })
        #expect(line.contains("SUSPENDED; not sent") && line.contains("not estimated"))
        #expect(!line.contains("estimate:"))
        // A known INACTIVE next to an unknown one is still unknown; INACTIVE alone is no active coverage.
        let mixed = Self.make([("M", .read([Fleet.coverage("INACTIVE"), Fleet.coverage("NEW_STATE")]), nil)])
        #expect(mixed.rows[0].kind == .statusUnknown(statuses: ["NEW_STATE"]))
    }

    @Test func noRecordIsNotCalledExpired() throws {
        #expect(Self.report.words.contains("3 have no coverage record at all: that may mean no AppleCare, not that it expired."))
        #expect(Self.report.words.contains("1 have coverage records but none ACTIVE."))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("EMPTY,") })
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
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("UNREAD,") })
        #expect(line.contains("not read: your role can't read this"))
        #expect(!line.contains("estimate"))
    }

    /// A cut sweep (2 of 5 read): the devices it never reached are not read, never out of warranty.
    @Test func aDeviceTheSweepNeverReachedIsNotRead() {
        let report = Self.make([("A", .read([Fleet.coverage("ACTIVE")]), nil), ("B", .read([]), "2020-01-01T00:00:00Z"),
                                ("C", nil, "2020-01-01T00:00:00Z"), ("D", nil, nil), ("E", nil, nil)], list: .partly("2 of 5 read"))
        #expect(report.rows.count == 5)
        #expect(report.rows(group: "not-read").map(\.device.serialNumber) == ["C", "D", "E"])
        #expect(report.withoutActiveCoverage == 1)
        #expect(report.words.contains("3 had their coverage unread: not counted as out of warranty."))
    }

    @Test func anActiveRecordIsActiveWhateverElseIsListed() throws {
        let active = try #require(Self.report.rows(group: "active").first)
        #expect(active.kind == .active(ends: ISODate.parse("2027-06-01T00:00:00Z")))
        #expect(active.estimate == .notMade)
    }

    /// The estimate: order date plus one calendar year, labelled and with its assumption.
    @Test func theEstimateIsLabelledAndHasItsBoundary() throws {
        func estimate(_ ordered: String?) -> WarrantyReport.Estimate { Self.make([("E", .read([]), ordered)]).rows[0].estimate }
        if case .withinAssumedLimit = estimate("2025-11-20T12:00:00Z") {} else { Issue.record("exactly a year is not past") }
        if case .pastAssumedLimit = estimate("2025-11-20T11:59:59Z") {} else { Issue.record("a second more is past") }
        if case .withinAssumedLimit = estimate(Self.ordered(daysAgo: 30)) {} else { Issue.record("30 days ago is within") }
        #expect(estimate(nil) == .noOrderDate)
        #expect(estimate("last spring") == .unreadableOrderDate("\"last spring\""))
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.warrantyReport)
        let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("EXPIRED,") })
        #expect(line.contains("estimate: past the assumed one year"))
        #expect(line.contains("Estimate only"))
    }

    /// 29 February plus one calendar year is 28 February; the boundary is that instant.
    @Test func aLeapDayOrderEndsOnThe28th() throws {
        let end = try #require(ISODate.parse("2025-02-28T00:00:00Z")).date
        let before = try #require(ISODate.parse("2025-02-27T23:59:59Z")).date
        let after = try #require(ISODate.parse("2025-02-28T00:00:01Z")).date
        #expect(Self.make([("L", .read([]), "2024-02-29T00:00:00Z")], now: before).rows[0].estimate == .withinAssumedLimit(until: end))
        #expect(Self.make([("L", .read([]), "2024-02-29T00:00:00Z")], now: after).rows[0].estimate == .pastAssumedLimit(end))
    }

    /// An order date that isn't a date: counted in the words as having no readable order date, and written as Apple sent it
    /// (quoted, as every unreadable date is).
    @Test func anUnreadableOrderDateIsCountedAndKeptInTheCSV() throws {
        let report = Self.make([("A", .read([]), "last spring"), ("B", .read([]), nil), ("C", .read([]), "2020-01-01T00:00:00Z")])
        let line = try #require(report.words.last)
        #expect(line.contains("2 have no readable order date, so no estimate"))
        #expect(report.rows.filter(\.lacksReadableOrderDate).count == 2)
        let table = Fleet.table(CSV.text(report.csvItems, columns: ExportPolicy.warrantyReport))
        #expect(table["A"]?["orderDateTime"] == "\"last spring\"")
        #expect(table["A"]?["estimate"] == "estimate not possible: order date not readable")
        #expect(table["B"]?["orderDateTime"] == "")
    }

    /// An order date that isn't a date is written the same quoted way on every kind of row, not only where an estimate is made.
    @Test func anUnreadableOrderDateIsQuotedOnEveryKindOfRow() {
        let odd = "last spring"
        let report = Self.make([
            ("ACTIVE", .read([Fleet.coverage("ACTIVE", end: "2027-06-01T00:00:00Z")]), odd),
            ("UNKNOWN", .read([Fleet.coverage("NEW_STATE")]), odd),
            ("UNREAD", .notRead("failed"), odd),
            ("NORECORD", .read([]), odd),
            ("NONE", .read([Fleet.coverage("INACTIVE")]), odd),
            ("MISSING", nil, odd),
        ])
        #expect(Set(report.rows.map(\.group)) == ["active", "status-unknown", "not-read", "no-record", "no-active-coverage"])
        let table = Fleet.table(CSV.text(report.csvItems, columns: ExportPolicy.warrantyReport))
        #expect(table.count == 6)
        for (serial, row) in table { #expect(row["orderDateTime"] == "\"last spring\"", "\(serial)") }
        // A readable one is as sent, and a number Apple sent is its JSON text, on a row that makes no estimate too.
        let readable = Self.make([("R", .notRead("failed"), "2020-01-01T00:00:00Z")])
        #expect(Fleet.table(CSV.text(readable.csvItems, columns: ExportPolicy.warrantyReport))["R"]?["orderDateTime"] == "2020-01-01T00:00:00Z")
        let number = WarrantyReport([Fleet.device("N", ["orderDateTime": .number("5")])], coverage: ["N": .read([Fleet.coverage("ACTIVE")])], now: Fleet.now)
        #expect(Fleet.table(CSV.text(number.csvItems, columns: ExportPolicy.warrantyReport))["N"]?["orderDateTime"] == "5")
        // Even a list that wasn't read keeps the value as sent.
        let unread = Self.make([("U", .read([]), odd)], list: .notRead("no role"))
        #expect(Fleet.table(CSV.text(unread.csvItems, columns: ExportPolicy.warrantyReport))["U"]?["orderDateTime"] == "\"last spring\"")
    }

    /// An ACTIVE record whose end isn't a date is covered, but the CSV never leaves the end blank: Apple's value, as sent.
    @Test func anActiveRecordWithAnUnreadableEndIsNeverExportedBlank() throws {
        func end(_ value: JSONValue?, others: [AppleCareCoverage] = []) throws -> String? {
            var attributes: JSONObject = ["status": .string("ACTIVE")]
            if let value { attributes = attributes.merging(["endDateTime": value]) }
            let record = AppleCareCoverage(resource: Resource(type: "appleCareCoverage", id: "c", attributes: attributes))
            let report = WarrantyReport([Fleet.device("E")], coverage: ["E": .read([record] + others)], now: Fleet.now)
            #expect(report.rows[0].group == "active")
            return Fleet.table(CSV.text(report.csvItems, columns: ExportPolicy.warrantyReport))["E"]?["activeCoverageEnds"]
        }
        #expect(try end(.string("someday")) == "end date not readable: \"someday\"")
        #expect(try end(.string("")) == "end date not readable: \"\"")
        #expect(try end(.number("5")) == "end date not readable: 5")
        #expect(try end(.bool(true)) == "end date not readable: true")
        // A missing or null end is open-ended: blank, as before. A readable one is as before.
        #expect(try end(nil) == "")
        #expect(try end(.null) == "")
        let readable = try #require(ISODate.parse("2027-06-01T00:00:00Z")).isoformat
        #expect(try end(.string("2027-06-01T00:00:00Z")) == readable)
        // A readable end beside an unreadable one keeps both: the latest known end, then what couldn't be read.
        let both = try end(.string("someday"), others: [Fleet.coverage("ACTIVE", end: "2027-06-01T00:00:00Z")])
        #expect(both == "\(readable); end date not readable: \"someday\"")
        // An unreadable end on a record that isn't ACTIVE says nothing.
        let inactive = AppleCareCoverage(resource: Resource(type: "appleCareCoverage", id: "c", attributes: ["status": .string("INACTIVE"), "endDateTime": .string("junk")]))
        let report = WarrantyReport([Fleet.device("E")], coverage: ["E": .read([inactive, Fleet.coverage("ACTIVE", end: "2027-06-01T00:00:00Z")])], now: Fleet.now)
        #expect(report.rows[0].unreadableEnds.isEmpty)
    }

    /// A list that wasn't read exports no judgment cells and says so; a partly read one says that.
    @Test func theCSVCarriesTheListsReadState() throws {
        let unread = Self.make([("A", .read([]), "2020-01-01T00:00:00Z")], list: .notRead("your role can't read this"))
        let row = try #require(Fleet.table(CSV.text(unread.csvItems, columns: ExportPolicy.warrantyReport))["A"])
        #expect(row["listRead"] == "not read: your role can't read this")
        #expect(row["coverage"] == "not read" && row["estimate"] == "" && row["estimatedEnd"] == "")
        let part = Self.make([("A", .read([]), nil)], list: .partly("2 of 5 read"))
        #expect(Fleet.table(CSV.text(part.csvItems, columns: ExportPolicy.warrantyReport))["A"]?["listRead"] == "read in part: 2 of 5 read")
    }

    /// A calendar year, not 365 days: an order on 1 March 2023 is still inside its year on 29 February 2024.
    @Test func aYearIsACalendarYearNotThreeHundredSixtyFiveDays() throws {
        let now = try #require(ISODate.parse("2024-02-29T12:00:00Z")).date
        let end = try #require(ISODate.parse("2024-03-01T00:00:00Z")).date
        #expect(Self.make([("Y", .read([]), "2023-03-01T00:00:00Z")], now: now).rows[0].estimate == .withinAssumedLimit(until: end))
    }

    /// The assumption is in the words and the catalog, not only the CSV; and devices without a readable order date are counted.
    @Test func theWordsCarryTheAssumptionAndCountTheMissingDates() throws {
        let line = try #require(Self.report.words.last)
        #expect(line.contains(WarrantyReport.assumption))
        #expect(line.contains("2 of the 4 without active coverage are past an estimated year"))
        #expect(line.contains("1 have no readable order date, so no estimate"))
        #expect(WarrantyReport.assumption.contains("varies by country and product"))
        #expect(WarrantyReport.assumption.contains("starts at purchase or delivery, not the order date"))
        #expect(ReportCatalog.entry(.outOfWarranty).summary.contains("varies by country and product"))
    }

    @Test func theListsReadIsSaid() {
        #expect(Self.make([], list: .partly("showing 500 of at least 900")).words.first?.contains("500 of at least 900") == true)
        // Not read: that line only, no zero counts.
        #expect(Self.make([("A", .read([]), nil)], list: .notRead("your role can't read this")).words == ["Not read: your role can't read this. Nothing below can be judged."])
    }

    @Test func noSecretLeavesTheCSV() {
        let report = WarrantyReportTests.make([("S", .read([]), nil)])
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "S", attributes: report.rows[0].device.attributes.merging([
            "activationLockBypassCode": .string("canary-bypass"), "nested": .object(["password": .string("canary-pw")])])))
        let text = CSV.text(WarrantyReport([device], coverage: ["S": .read([])], now: Fleet.now).csvItems, columns: ExportPolicy.warrantyReport)
        #expect(!text.contains("canary"))
    }
}
