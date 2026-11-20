import Foundation
import JSONAPI
import Testing
@testable import Reports

/// The two CSVs abapit wrote from the history reports (invariant 11: the columns are an allowlist).
@Suite("History exports")
struct ExportHistoryTests {
    @Test func theColumnsAreAbapitsInItsOrder() {
        #expect(ExportPolicy.refreshCandidates.names == ["serialNumber", "deviceModel", "productFamily", "ordered", "ageYears", "activeCoverage"])
        #expect(ExportPolicy.coverageExpiring.names == ["serialNumber", "description", "paymentType", "startDateTime", "endDateTime", "days_left", "isRenewable"])
        for name in ExportPolicy.refreshCandidates.names + ExportPolicy.coverageExpiring.names {
            #expect(ExportPolicy.permits(name, includeNotByDefault: false), "\(name)")
        }
    }

    @Test func refreshCandidatesAreWrittenAsAbapitWroteThem() {
        let devices = [
            Resource(type: "orgDevices", id: "D1", attributes: ["deviceModel": .string("Mac, 13\""), "productFamily": .string("Mac"),
                                                                  "orderDateTime": .string("2020-01-01T00:00:00Z")]),
            Resource(type: "orgDevices", id: "D2", attributes: ["deviceModel": .string("iPad"), "productFamily": .string("iPad"),
                                                                  "addedToOrgDateTime": .string("2019-01-01T00:00:00Z")]),
        ]
        let care = [Resource(type: "applecare", id: "D1:0", attributes: ["serialNumber": .string("D1"), "status": .string("ACTIVE")])]
        let report = FleetAgeReport(devices: devices, applecare: care, years: 1, now: CoverageFleetAgeTests.now, notRead: [])
        let text = ExportHistory.refreshCandidates(report)
        #expect(text == "id,serialNumber,deviceModel,productFamily,ordered,ageYears,activeCoverage\r\n"
                + "D2,D2,iPad,iPad,2019-01-01T00:00:00Z,7.8,False\r\n"
                + "D1,D1,\"Mac, 13\"\"\",Mac,2020-01-01T00:00:00Z,6.8,True\r\n")
        // No coverage data: nothing, not False.
        let none = ExportHistory.refreshCandidates(FleetAgeReport(devices: devices, applecare: nil, years: 7, now: CoverageFleetAgeTests.now, notRead: []))
        #expect(none == "id,serialNumber,deviceModel,productFamily,ordered,ageYears,activeCoverage\r\nD2,D2,iPad,iPad,2019-01-01T00:00:00Z,7.8,\r\n")
    }

    @Test func expiringCoverageKeepsOnlyTheListedColumnsAndGuardsFormulas() {
        let record = Resource(type: "applecare", id: "D1:0", attributes: [
            "serialNumber": .string("D1"), "status": .string("ACTIVE"), "description": .string("=AppleCare+"),
            "endDateTime": .string("2026-10-26T12:00:00Z"), "isRenewable": .bool(true), "secretToken": .string("CANARY"),
            "nested": .object(["apiKey": .string("CANARY")]),
        ])
        let report = CoverageReport(applecare: [record], devices: [], days: 30, now: CoverageFleetAgeTests.now, notRead: [])
        let text = ExportHistory.coverageExpiring(report)
        #expect(text == "id,serialNumber,description,paymentType,startDateTime,endDateTime,days_left,isRenewable\r\n"
                + "D1,D1,'=AppleCare+,,,2026-10-26T12:00:00Z,10,True\r\n")
        #expect(!text.contains("CANARY"))
    }

    /// A candidate whose sweep failed is written `not read`, not `False` and not empty; no coverage data stays empty.
    @Test func aCandidateNotReadSaysSo() {
        let devices = ["D1", "D2"].map { Resource(type: "orgDevices", id: $0, attributes: ["orderDateTime": .string("2019-01-01T00:00:00Z")]) }
        let report = FleetAgeReport(devices: devices, applecare: [], years: 1, now: CoverageFleetAgeTests.now, notRead: ["D2"])
        let rows = ExportHistory.refreshCandidates(report).split(separator: "\r\n").dropFirst().map(String.init)
        // With no coverage data at all nothing is "not read": the cell is empty for both.
        let none = FleetAgeReport(devices: devices, applecare: nil, years: 1, now: CoverageFleetAgeTests.now, notRead: ["D2"])
        #expect(ExportHistory.refreshCandidates(none).split(separator: "\r\n").dropFirst().map(String.init)
                == ["D1,D1,,,2019-01-01T00:00:00Z,7.8,", "D2,D2,,,2019-01-01T00:00:00Z,7.8,"])
        #expect(rows == ["D1,D1,,,2019-01-01T00:00:00Z,7.8,False", "D2,D2,,,2019-01-01T00:00:00Z,7.8,not read"])
    }
}
