import Testing
@testable import Reports

@Suite("Report catalog")
struct ReportCatalogTests {
    @Test func everyIdHasOneEntryWithTitleAndInputs() {
        #expect(ReportCatalog.entries.map(\.id) == ReportCatalog.ID.allCases)
        #expect(Set(ReportCatalog.entries.map(\.id.rawValue)).count == ReportCatalog.entries.count)
        for entry in ReportCatalog.entries {
            #expect(!entry.title.isEmpty && !entry.summary.isEmpty && !entry.inputs.isEmpty, "\(entry.id)")
        }
    }

    /// The tokens a report accepts are the ones its rows carry: nothing listed that no row can have, no row key unlisted.
    @Test func theCatalogTokensAreTheReportsOwnGroups() throws {
        func values(_ id: ReportCatalog.ID) throws -> [String] { try #require(ReportCatalog.entry(id).filters.first { $0.name == "group" }).values }
        #expect(try values(.activationLock) == ActivationLockReport.fixedGroups)
        #expect(try values(.migration) == MigrationReport.fixedGroups + ["past-due"])
        #expect(try values(.serviceHealth) == ServiceHealth.fixedGroups)
        #expect(try values(.outOfWarranty) == WarrantyReport.fixedGroups + ["estimated-past-limit"])
        // Every group a report emits is listed, or is an open `lock:`/`status:` raw value.
        for row in ActivationLockReportTests.report.rows {
            #expect(ReportCatalog.problems(.activationLock, tokens: ["group": row.group]).isEmpty, "\(row.group)")
        }
        for row in WarrantyReportTests.report.rows { #expect(ReportCatalog.problems(.outOfWarranty, tokens: ["group": row.group]).isEmpty) }
    }

    @Test func aTokenOffTheListIsRefused() {
        #expect(ReportCatalog.problems(.activationLock, tokens: ["group": "lock:USER"]).isEmpty)
        #expect(ReportCatalog.problems(.activationLock, tokens: ["group": "lock:SOMETHING_NEW"]).isEmpty)
        #expect(ReportCatalog.problems(.activationLock, tokens: ["group": "lock:"]).count == 1)
        #expect(ReportCatalog.problems(.activationLock, tokens: ["group": "everything"]).count == 1)
        #expect(ReportCatalog.problems(.activationLock, tokens: ["days": "30"]).count == 1)
        #expect(ReportCatalog.problems(.outOfWarranty, tokens: ["group": "expired"]).count == 1)
        #expect(ReportCatalog.problems(.outOfWarranty, tokens: ["group": "no-record"]).isEmpty)
        #expect(ReportCatalog.problems(.migration, tokens: ["group": "past-due"]).isEmpty)
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["days": "7", "group": "quiet"]).isEmpty)
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["days": "0"]).count == 1)
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["days": "soon"]).count == 1)
        #expect(ReportCatalog.problems(.quietServices, tokens: ["days": "30"]).isEmpty)
        #expect(ReportCatalog.problems(.quietServices, tokens: [:]).isEmpty)
    }

    @Test func csvColumnsAreTheExportsAndNeverSecretShaped() {
        #expect(ReportCatalog.entry(.quietServices).csvColumns == nil)
        for entry in ReportCatalog.entries {
            for column in entry.csvColumns ?? [] {
                #expect(ExportPolicy.permits(column, includeNotByDefault: false), "\(entry.id): \(column)")
            }
        }
        for columns in [ExportPolicy.activationLockReport, ExportPolicy.migrationReport, ExportPolicy.serviceHealth, ExportPolicy.warrantyReport] {
            #expect(Set(columns.names).count == columns.names.count)
        }
    }
}
