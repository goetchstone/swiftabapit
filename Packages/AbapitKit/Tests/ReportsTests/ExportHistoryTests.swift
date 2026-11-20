import Foundation
import JSONAPI
import Testing
@testable import Reports

/// The two CSVs abapit wrote from the history reports (invariant 11: the columns are an allowlist).
@Suite("History exports")
struct ExportHistoryTests {
    @Test func theColumnsAreAbapitsInItsOrderAfterListRead() {
        #expect(ExportPolicy.refreshCandidates.names == ["listRead", "serialNumber", "deviceModel", "productFamily", "ordered", "ageYears", "activeCoverage"])
        #expect(ExportPolicy.coverageExpiring.names == ["listRead", "serialNumber", "description", "paymentType", "startDateTime", "endDateTime", "days_left", "isRenewable"])
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
        let report = CoverageFleetAgeTests.fleetAge(devices: devices, applecare: care, years: 1, now: CoverageFleetAgeTests.now, notRead: [])
        let text = ExportHistory.refreshCandidates(report)
        #expect(text == "id,listRead,serialNumber,deviceModel,productFamily,ordered,ageYears,activeCoverage\r\n"
                + "D2,read in full,D2,iPad,iPad,2019-01-01T00:00:00Z,7.8,False\r\n"
                + "D1,read in full,D1,\"Mac, 13\"\"\",Mac,2020-01-01T00:00:00Z,6.8,True\r\n")
        // No coverage data: nothing, not False.
        let none = ExportHistory.refreshCandidates(CoverageFleetAgeTests.fleetAge(devices: devices, applecare: nil, years: 7, now: CoverageFleetAgeTests.now, notRead: []))
        #expect(none == "id,listRead,serialNumber,deviceModel,productFamily,ordered,ageYears,activeCoverage\r\nD2,read in full,D2,iPad,iPad,2019-01-01T00:00:00Z,7.8,\r\n")
    }

    @Test func expiringCoverageKeepsOnlyTheListedColumnsAndGuardsFormulas() {
        let record = Resource(type: "applecare", id: "D1:0", attributes: [
            "serialNumber": .string("D1"), "status": .string("ACTIVE"), "description": .string("=AppleCare+"),
            "endDateTime": .string("2026-10-26T12:00:00Z"), "isRenewable": .bool(true), "secretToken": .string("CANARY"),
            "nested": .object(["apiKey": .string("CANARY")]),
        ])
        let report = CoverageFleetAgeTests.coverage(applecare: [record], devices: [], days: 30, now: CoverageFleetAgeTests.now, notRead: [])
        let text = ExportHistory.coverageExpiring(report)
        #expect(text == "id,listRead,serialNumber,description,paymentType,startDateTime,endDateTime,days_left,isRenewable\r\n"
                + "D1,read in full,D1,'=AppleCare+,,,2026-10-26T12:00:00Z,10,True\r\n")
        #expect(!text.contains("CANARY"))
    }

    /// A candidate whose sweep failed is written `not read`, not `False` and not empty; no coverage data stays empty.
    @Test func aCandidateNotReadSaysSo() {
        let devices = ["D1", "D2"].map { Resource(type: "orgDevices", id: $0, attributes: ["orderDateTime": .string("2019-01-01T00:00:00Z")]) }
        let report = CoverageFleetAgeTests.fleetAge(devices: devices, applecare: [], years: 1, now: CoverageFleetAgeTests.now, notRead: ["D2"])
        let rows = ExportHistory.refreshCandidates(report).split(separator: "\r\n").dropFirst().map(String.init)
        // With no coverage data at all nothing is "not read": the cell is empty for both.
        let none = CoverageFleetAgeTests.fleetAge(devices: devices, applecare: nil, years: 1, now: CoverageFleetAgeTests.now, notRead: ["D2"])
        #expect(ExportHistory.refreshCandidates(none).split(separator: "\r\n").dropFirst().map(String.init)
                == ["D1,read in full,D1,,,2019-01-01T00:00:00Z,7.8,", "D2,read in full,D2,,,2019-01-01T00:00:00Z,7.8,"])
        #expect(rows == ["D1,read in full,D1,,,2019-01-01T00:00:00Z,7.8,False", "D2,read in full,D2,,,2019-01-01T00:00:00Z,7.8,not read"])
    }

    /// Both exports lead with how much of the list the report was given; a part-read list says so on every row.
    @Test func bothExportsSayTheListsReadOnEveryRow() {
        let devices = [Resource(type: "orgDevices", id: "D1", attributes: ["orderDateTime": .string("2019-01-01T00:00:00Z")])]
        let candidates = CoverageFleetAgeTests.fleetAge(devices: devices, applecare: [], years: 1, now: CoverageFleetAgeTests.now, notRead: [],
                                                        list: .partly("showing 1 of at least 9"))
        #expect(ExportHistory.refreshCandidates(candidates).split(separator: "\r\n").dropFirst().map(String.init)
                == ["D1,read in part: showing 1 of at least 9,D1,,,2019-01-01T00:00:00Z,7.8,False"])
        let record = Resource(type: "applecare", id: "D1:0", attributes: ["serialNumber": .string("D1"), "status": .string("ACTIVE"),
                                                                        "endDateTime": .string("2026-10-26T12:00:00Z"), "listRead": .string("forged")])
        let expiring = CoverageFleetAgeTests.coverage(applecare: [record], devices: devices, days: 30, now: CoverageFleetAgeTests.now, notRead: [], list: .partly("2 of 9"))
        let rows = ExportHistory.coverageExpiring(expiring).split(separator: "\r\n").dropFirst().map(String.init)
        #expect(rows == ["D1,read in part: 2 of 9,D1,,,,2026-10-26T12:00:00Z,10,"])
    }

    /// A list that wasn't read still says so in its CSV: one row, `listRead` saying why, every other cell empty; never a bare header.
    @Test func aNotReadListExportsOneRowThatSaysSo() {
        let why = "your role can't read this"
        let candidates = ExportHistory.refreshCandidates(CoverageFleetAgeTests.fleetAge(devices: [], applecare: [], years: 1, now: CoverageFleetAgeTests.now,
                                                                                         notRead: [], list: .notRead(why)))
        #expect(candidates == "id,listRead,serialNumber,deviceModel,productFamily,ordered,ageYears,activeCoverage\r\n,not read: \(why),,,,,,\r\n")
        let expiring = ExportHistory.coverageExpiring(CoverageFleetAgeTests.coverage(applecare: [], devices: [], days: 30, now: CoverageFleetAgeTests.now,
                                                                                      notRead: [], list: .notRead(why)))
        #expect(expiring == "id,listRead,serialNumber,description,paymentType,startDateTime,endDateTime,days_left,isRenewable\r\n,not read: \(why),,,,,,,\r\n")
        // A list that was read and left no rows stays a header.
        #expect(!ExportHistory.coverageExpiring(CoverageFleetAgeTests.coverage(applecare: [], devices: [], days: 30, now: CoverageFleetAgeTests.now, notRead: [])).contains("not read"))
    }

    /// A list read in part that left no rows says so too: one row, `listRead` saying how much, never a bare header.
    @Test func aPartlyReadEmptyListExportsOneRowThatSaysSo() {
        let how = "showing 0 of at least 9"
        let candidates = ExportHistory.refreshCandidates(CoverageFleetAgeTests.fleetAge(devices: [], applecare: [], years: 1, now: CoverageFleetAgeTests.now,
                                                                                         notRead: [], list: .partly(how)))
        #expect(candidates.hasSuffix("\r\n,read in part: \(how),,,,,,\r\n"))
        let expiring = ExportHistory.coverageExpiring(CoverageFleetAgeTests.coverage(applecare: [], devices: [], days: 30, now: CoverageFleetAgeTests.now,
                                                                                      notRead: [], list: .partly(how)))
        #expect(expiring.hasSuffix("\r\n,read in part: \(how),,,,,,,\r\n"))
    }
}
