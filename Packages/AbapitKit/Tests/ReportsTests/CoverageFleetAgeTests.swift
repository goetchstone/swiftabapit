import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport
@testable import Reports

/// abapit's `coverage_report` and `fleet_age_report`, held to `Tests/Fixtures/parity/reports.json` (invariant 6):
/// 32 coverage cases with no deviation, and 35 fleet-age cases of which two carry the operator's decision of
/// 2026-11-20 (a device ordered more than 365 days ahead is "< 1 yr") beside abapit's output.
@Suite("Coverage and fleet age")
struct CoverageFleetAgeTests {
    static func resources(_ value: JSONValue?) -> [Resource] { (value?.array ?? []).compactMap(Resource.init) }

    static func coverageJSON(_ report: CoverageReport) -> JSONValue {
        .object(["expiring": .array(report.expiring.map { .object($0.attributes) }),
                 "uncovered": .array(report.uncovered.map(\.asJSON)),
                 "covered_count": .number(String(report.coveredCount)), "days": .number(String(report.days))])
    }

    static func fleetJSON(_ report: FleetAgeReport) -> JSONValue {
        .object(["buckets": .array(report.buckets.map { .array([.string($0.label), .number(String($0.count))]) }),
                 "bucket_max": .number(String(report.bucketMax)),
                 "candidates": .array(report.candidates.map { candidate in
                     .object(["serial": .string(candidate.serial), "model": candidate.model, "family": candidate.family,
                              "ordered": candidate.ordered, "age_years": .number(String(candidate.ageYears)),
                              "covered": candidate.covered.map(JSONValue.bool) ?? .null])
                 }),
                 "uncovered_candidates": report.uncoveredCandidates.map { .number(String($0)) } ?? .null,
                 "undated": .number(String(report.undated)), "years": .number(String(report.years)),
                 "has_coverage_data": .bool(report.hasCoverageData)])
    }

    @Test func coverageMatchesTheGolden() throws {
        let cases = try ReportsParityTests.cases("reports", "coverage_report")
        #expect(cases.count == 32)
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let care = Self.resources(input["applecare_items"]), devices = Self.resources(input["devices"])
            #expect(care.count == input["applecare_items"]?.array?.count && devices.count == input["devices"]?.array?.count)
            let report = CoverageReport(applecare: care, devices: devices, days: try #require(input["days"]?.int), now: ReportsParityTests.now, notRead: [])
            #expect(Self.coverageJSON(report) == item["expected"]?["ok"], "case \(index)")
            #expect(report.notRead.isEmpty)
        }
        #expect(cases.filter { $0["abapit"] != nil }.isEmpty)
    }

    @Test func fleetAgeMatchesTheGolden() throws {
        let cases = try ReportsParityTests.cases("reports", "fleet_age_report")
        #expect(cases.count == 35)
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let devices = Self.resources(input["devices"])
            let care = input["applecare_items"]?.array == nil ? nil : Self.resources(input["applecare_items"])
            #expect(devices.count == input["devices"]?.array?.count)
            let report = FleetAgeReport(devices: devices, applecare: care, years: try #require(input["years"]?.int), now: ReportsParityTests.now, notRead: [])
            #expect(Self.fleetJSON(report) == item["expected"]?["ok"], "case \(index)")
        }
    }

    /// The two fleets abapit buckets wrongly: the golden keeps its output, and the port isn't it.
    @Test func twoFleetsDeviateFromAbapit() throws {
        let deviating = try ReportsParityTests.cases("reports", "fleet_age_report").filter { $0["abapit"] != nil }
        #expect(deviating.count == 2)
        for item in deviating {
            let input = try #require(item["input"])
            let care = input["applecare_items"]?.array == nil ? nil : Self.resources(input["applecare_items"])
            let report = FleetAgeReport(devices: Self.resources(input["devices"]), applecare: care, years: try #require(input["years"]?.int),
                                        now: ReportsParityTests.now, notRead: [])
            #expect(Self.fleetJSON(report) != item["abapit"]?["ok"])
            #expect(report.buckets.last?.count == 0)
            #expect(report.candidates.allSatisfy { $0.ageYears >= 0 })
        }
    }

    // MARK: what the goldens can't hold by themselves

    static let now = Date(timeIntervalSince1970: 1_792_152_000)
    static func care(_ serial: String, end: String?, status: String = "ACTIVE") -> Resource {
        var attrs: JSONObject = ["serialNumber": .string(serial), "status": .string(status)]
        if let end { attrs["endDateTime"] = .string(end) }
        return Resource(type: "applecare", id: "\(serial):0", attributes: attrs)
    }
    static func device(_ id: String, order: String? = nil, added: String? = nil) -> Resource {
        var attrs: JSONObject = ["serialNumber": .string(id)]
        if let order { attrs["orderDateTime"] = .string(order) }
        if let added { attrs["addedToOrgDateTime"] = .string(added) }
        return Resource(type: "orgDevices", id: id, attributes: attrs)
    }
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    static func stamp(_ seconds: Int) -> String {
        Self.formatter.string(from: Self.now.addingTimeInterval(TimeInterval(seconds)))
    }

    /// A sweep that failed is not an unprotected device: it is counted apart, and a device that has an active record is
    /// covered whatever the sweep said.
    @Test func aDeviceNotReadIsNeverUncovered() {
        let devices = ["D1", "D2", "D3", "D4"].map { Self.device($0) }
        let report = CoverageReport(applecare: [Self.care("D1", end: nil)], devices: devices, days: 30, now: Self.now, notRead: ["D1", "D3"])
        #expect(report.uncovered.map(\.id) == ["D2", "D4"])
        #expect(report.notRead.map(\.id) == ["D3"])
        #expect(report.coveredCount == 1)
        let plain = CoverageReport(applecare: [Self.care("D1", end: nil)], devices: devices, days: 30, now: Self.now, notRead: [])
        #expect(plain.uncovered.map(\.id) == ["D2", "D3", "D4"] && plain.notRead.isEmpty)
    }

    @Test func theWindowIsClosedAtBothEndsToTheMicrosecond() {
        let devices = [Self.device("D1")]
        func expiring(_ end: String) -> Int {
            CoverageReport(applecare: [Self.care("D1", end: end)], devices: devices, days: 1, now: Self.now, notRead: []).expiring.count
        }
        #expect(expiring(Self.stamp(0)) == 1)
        #expect(expiring(Self.stamp(86_400)) == 1)
        #expect(expiring(Self.stamp(86_401)) == 0)
        #expect(expiring(Self.stamp(-1)) == 0)
        // One microsecond either side of the cutoff, which a Double of seconds since 1970 can't tell apart.
        #expect(expiring("2026-10-17T12:00:00.000001Z") == 0)
        #expect(expiring("2026-10-17T11:59:59.999999Z") == 1)
        #expect(expiring("2026-10-16T11:59:59.999999Z") == 0)
        #expect(expiring("2026-10-16T12:00:00.000001Z") == 1)
    }

    @Test func daysLeftFloorsAndEqualOnesKeepInputOrder() {
        let records = [Self.care("A", end: Self.stamp(5 * 86_400 + 86_399)), Self.care("B", end: Self.stamp(5 * 86_400)),
                       Self.care("C", end: Self.stamp(2 * 86_400)), Self.care("D", end: Self.stamp(5 * 86_400 + 1))]
        let report = CoverageReport(applecare: records, devices: [], days: 30, now: Self.now, notRead: [])
        #expect(report.expiring.map { $0.attributes["serialNumber"]?.string } == ["C", "A", "B", "D"])
        #expect(report.expiring.map(\.daysLeft) == [2, 5, 5, 5])
        #expect(report.expiring.first?.attributes["days_left"] == .number("2"))
    }

    @Test func coveredIsCountedOverTheDevicesOnly() {
        let report = CoverageReport(applecare: [Self.care("D1", end: nil), Self.care("D1", end: nil), Self.care("X9", end: nil)],
                                    devices: [Self.device("D1"), Self.device("D2")], days: 30, now: Self.now, notRead: [])
        #expect(report.coveredCount == 1)
    }

    /// 365.25 days is 365 whole days (timedelta.days drops the six hours), so a device ordered 100.5 days ahead is -101 days.
    @Test func fleetAgeFloorsDaysAndNeverBucketsTheFutureAsOld() {
        func report(_ order: String, years: Int = 0) -> FleetAgeReport {
            FleetAgeReport(devices: [Self.device("D1", order: order)], applecare: nil, years: years, now: Self.now, notRead: [])
        }
        #expect(report(Self.stamp(-Int(365.25 * 86_400))).buckets.map(\.count) == [1, 0, 0, 0, 0])   // 365 days: the six hours floor away
        #expect(report(Self.stamp(-366 * 86_400)).buckets.map(\.count) == [0, 1, 0, 0, 0])
        #expect(report(Self.stamp(-366 * 86_400 + 1)).buckets.map(\.count) == [1, 0, 0, 0, 0])   // 365 days and 86,399 seconds floors to 365
        #expect(report(Self.stamp(-364 * 86_400)).buckets.map(\.count) == [1, 0, 0, 0, 0])
        #expect(report(Self.stamp(400 * 86_400)).buckets.map(\.count) == [1, 0, 0, 0, 0])   // ahead by more than a year: "< 1 yr"
        #expect(report(Self.stamp(400 * 86_400)).candidates.isEmpty)
        #expect(report(Self.stamp(30 * 86_400)).buckets.map(\.count) == [1, 0, 0, 0, 0])
        #expect(report(Self.stamp(30 * 86_400), years: 0).candidates.isEmpty)   // age -0.08 is below 0 years
        #expect(report(Self.stamp(-5 * 365 * 86_400)).buckets.map(\.count) == [0, 0, 0, 0, 1])
    }

    @Test func candidatesAreOldestFirstByTheRoundedAgeAndAtLeastYearsOld() {
        // 1461 days is exactly 4.0 years (a candidate at years 4); 1460 days is 3.997 (not).
        func devices(_ days: [Int]) -> [Resource] { days.enumerated().map { Self.device("D\($0.offset)", order: Self.stamp(-$0.element * 86_400)) } }
        let report = FleetAgeReport(devices: devices([1460, 1461, 2000, 1999, 1998]), applecare: nil, years: 4, now: Self.now, notRead: [])
        #expect(report.candidates.map(\.serial) == ["D2", "D3", "D4", "D1"])   // 5.5, 5.5 (1999/365.25 = 5.47), 5.5 (5.47), 4.0
        #expect(report.candidates.map(\.ageYears) == [5.5, 5.5, 5.5, 4.0])
        #expect(report.uncoveredCandidates == nil && !report.hasCoverageData)
    }

    // MARK: review fixes

    /// A candidate whose sweep failed is not an uncovered one: `covered` is nil and it is counted apart.
    @Test func aCandidateNotReadIsNeitherCoveredNorUncovered() {
        let devices = ["D1", "D2", "D3", "D4"].map { Self.device($0, order: Self.stamp(-5 * 365 * 86_400)) }
        let care = [Self.care("D1", end: nil), Self.care("D4", end: nil, status: "INACTIVE")]
        let report = FleetAgeReport(devices: devices, applecare: care, years: 4, now: Self.now, notRead: ["D1", "D2", "D4"])
        #expect(report.candidates.map(\.covered) == [true, nil, false, nil])
        #expect(report.uncoveredCandidates == 1 && report.notReadCandidates == 2)
        let plain = FleetAgeReport(devices: devices, applecare: care, years: 4, now: Self.now, notRead: [])
        #expect(plain.candidates.map(\.covered) == [true, false, false, false] && plain.uncoveredCandidates == 3 && plain.notReadCandidates == 0)
        // Without coverage data nothing is known, so nothing is "not read" either.
        let none = FleetAgeReport(devices: devices, applecare: nil, years: 4, now: Self.now, notRead: ["D2"])
        #expect(none.candidates.allSatisfy { $0.covered == nil } && none.notReadCandidates == 0 && none.uncoveredCandidates == nil)
    }

    /// Ordered three hours ahead is -1 day by `timedelta.days` (floor), so it is not a candidate even at years 0: a
    /// truncating `days` would call it 0 days, an age of 0, and a candidate. (At years 1 a future device is never one.)
    @Test func aDeviceOrderedHoursAheadIsNotACandidate() {
        for years in [0, 1] {
            let report = FleetAgeReport(devices: [Self.device("D1", order: Self.stamp(3 * 3_600))], applecare: nil, years: years,
                                        now: Self.now, notRead: [])
            #expect(report.candidates.isEmpty, "years \(years)")
            #expect(report.buckets.map(\.count) == [1, 0, 0, 0, 0])
        }
    }

    @Test func yearsAndDaysAreBoundedWithoutATrap() {
        let old = [Self.device("D1", order: Self.stamp(-11 * 365 * 86_400))]
        func report(_ years: Int) -> FleetAgeReport { FleetAgeReport(devices: old, applecare: nil, years: years, now: Self.now, notRead: []) }
        #expect(report(99).years == 10 && report(Int.max).years == 10 && report(10).candidates.count == 1)
        #expect(report(-5).years == 0 && report(Int.min).years == 0)
        let care = [Self.care("D1", end: Self.stamp(1_825 * 86_400)), Self.care("D2", end: Self.stamp(1_826 * 86_400))]
        func coverage(_ days: Int) -> CoverageReport { CoverageReport(applecare: care, devices: [], days: days, now: Self.now, notRead: []) }
        #expect(coverage(10_000).days == 1_825 && coverage(10_000).expiring.map(\.daysLeft) == [1_825])
        #expect(coverage(-1).days == 0 && coverage(-1).expiring.isEmpty)
        #expect(coverage(1_825).days == 1_825 && coverage(0).days == 0)
    }

    /// The extremes don't overflow the window (a trap would end the run, so this is its own test).
    @Test func extremeDaysDoNotTrap() {
        let care = [Self.care("D1", end: Self.stamp(86_400))]
        #expect(CoverageReport(applecare: care, devices: [], days: Int.max, now: Self.now, notRead: []).days == 1_825)
        #expect(CoverageReport(applecare: care, devices: [], days: Int.min, now: Self.now, notRead: []).days == 0)
    }

    /// An active record whose end is there but isn't a date is counted apart; a missing or null end is open-ended.
    @Test func anEndThatIsNotADateIsCountedApart() {
        func record(_ id: String, _ end: JSONValue?, status: String = "ACTIVE") -> Resource {
            var attrs: JSONObject = ["serialNumber": .string(id), "status": .string(status)]
            if let end { attrs["endDateTime"] = end }
            return Resource(type: "applecare", id: id, attributes: attrs)
        }
        let report = CoverageReport(applecare: [record("A", .string("not a date")), record("B", .string("")), record("C", .number("5")),
                                                record("D", .null), record("E", nil), record("F", .string("garbage"), status: "INACTIVE"),
                                                record("G", .string(Self.stamp(86_400)))],
                                    devices: ["A", "B", "C", "D", "E", "F", "G"].map { Self.device($0) }, days: 30, now: Self.now, notRead: [])
        #expect(report.unreadableEnd.map(\.id) == ["A", "B", "C"])
        #expect(report.expiring.count == 1 && report.coveredCount == 6)
    }
}
