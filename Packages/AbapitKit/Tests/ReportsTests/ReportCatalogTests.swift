import Testing
@testable import Reports

@Suite("Report catalog")
struct ReportCatalogTests {
    @Test func everyIdHasOneEntryWithTitleAndInputs() {
        #expect(ReportCatalog.entries.map(\.id) == ReportCatalog.ID.allCases)
        #expect(ReportCatalog.ID.allCases.map(\.rawValue) == ["activation-lock", "migration", "service-health", "out-of-warranty"])
        for entry in ReportCatalog.entries {
            #expect(!entry.title.isEmpty && !entry.summary.isEmpty && !entry.inputs.isEmpty && !entry.csvColumns.isEmpty, "\(entry.id)")
        }
    }

    /// The tokens a report accepts are the ones its rows carry: every row's token is listed, and every listed group works.
    @Test func theCatalogTokensAreTheReportsOwnGroups() throws {
        func values(_ id: ReportCatalog.ID) throws -> [String] { try #require(ReportCatalog.entry(id).filters.first { $0.name == "group" }).values }
        #expect(try values(.activationLock) == ActivationLockReport.fixedGroups)
        #expect(try values(.migration) == MigrationReport.fixedGroups + ["past-due", "past-due-status-unknown"])
        #expect(try values(.serviceHealth) == ServiceHealth.fixedGroups)
        #expect(try values(.outOfWarranty) == WarrantyReport.fixedGroups + ["estimated-past-limit"])
        for row in ActivationLockReportTests.report.rows { #expect(ReportCatalog.problems(.activationLock, tokens: ["group": row.token]).isEmpty, "\(row.token)") }
        for row in WarrantyReportTests.report.rows { #expect(ReportCatalog.problems(.outOfWarranty, tokens: ["group": row.group]).isEmpty, "\(row.group)") }
        // `lock:other` finds the types this version doesn't know: it matches rows, never nothing.
        #expect(ActivationLockReportTests.report.rows(group: "lock:other").count == 2)
    }

    /// A value is taken only if it's a known one: case and surrounding spaces normalize to the canonical value, the rest is refused.
    @Test func aTokenIsNormalizedOrRefusedNeverSilentlyUnmatched() {
        func resolved(_ id: ReportCatalog.ID, _ value: String) -> ReportCatalog.Resolution { ReportCatalog.resolve(id, tokens: ["group": value]) }
        for spelled in ["lock:user", "lock:USER ", " lock:User", "LOCK:USER", "lock: user"] {
            #expect(resolved(.activationLock, spelled).tokens == ["group": "lock:USER"], "\(spelled)")
            #expect(resolved(.activationLock, spelled).problems.isEmpty)
        }
        #expect(resolved(.migration, "status:success").tokens == ["group": "status:SUCCESS"])
        #expect(resolved(.migration, "status: SUCCESS").tokens == ["group": "status:SUCCESS"])
        #expect(resolved(.migration, "Past-Due").tokens == ["group": "past-due"])
        #expect(resolved(.activationLock, "lock:other").problems.isEmpty)
        #expect(resolved(.activationLock, "lock:NONE").problems.isEmpty)
        for refused in ["lock:bogus", "lock:", "lock:SOMETHING_NEW", "everything", "", "lock:USER:MDM"] {
            let result = resolved(.activationLock, refused)
            #expect(result.problems.count == 1, "\(refused)")
            #expect(result.tokens.isEmpty)
        }
        #expect(resolved(.migration, "status:bogus").problems.count == 1)
        #expect(resolved(.outOfWarranty, "expired").problems.count == 1)
        #expect(resolved(.outOfWarranty, "No-Record").tokens == ["group": "no-record"])
        #expect(ReportCatalog.problems(.activationLock, tokens: ["days": "30"]).count == 1)
        #expect(ReportCatalog.resolve(.serviceHealth, tokens: ["days": " 7 ", "group": "QUIET"]).tokens == ["days": "7", "group": "quiet"])
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["days": "0"]).count == 1)
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["days": "soon"]).count == 1)
    }

    /// What the model reads says what each "other" token means, and the warranty summary carries the whole assumption.
    @Test func theOtherTokensAndTheAssumptionAreDescribed() throws {
        func summary(_ id: ReportCatalog.ID) throws -> String { try #require(ReportCatalog.entry(id).filters.first { $0.name == "group" }).summary }
        #expect(try summary(.activationLock).contains("lock:other (a type this version doesn't know, or locked with no type sent)"))
        #expect(try summary(.migration).contains("status:other (a status this version doesn't know)"))
        #expect(ReportCatalog.entry(.outOfWarranty).summary.contains(WarrantyReport.assumption))
    }

    /// Two spellings of one filter name are a problem, never one silently dropped.
    @Test func aFilterNameGivenTwiceIsRefused() {
        let result = ReportCatalog.resolve(.activationLock, tokens: ["group": "unlocked", "Group": "lock:USER"])
        #expect(result.problems.count == 1)
        #expect(result.problems[0].contains("twice"))
        #expect(ReportCatalog.resolve(.serviceHealth, tokens: ["group": "quiet", "days": "7"]).problems.isEmpty)
    }

    /// The quiet question is answered by the service health report's `quiet` group, one rule.
    @Test func thereIsNoSecondQuietReport() {
        #expect(ReportCatalog.entries.map(\.id.rawValue).contains("quiet-services") == false)
        #expect(ReportCatalog.problems(.serviceHealth, tokens: ["group": "quiet", "days": "30"]).isEmpty)
    }

    @Test func csvColumnsAreTheExportsAndNeverSecretShaped() {
        for entry in ReportCatalog.entries {
            for column in entry.csvColumns { #expect(ExportPolicy.permits(column, includeNotByDefault: false), "\(entry.id): \(column)") }
        }
        for columns in [ExportPolicy.activationLockReport, ExportPolicy.migrationReport, ExportPolicy.serviceHealth, ExportPolicy.warrantyReport] {
            #expect(Set(columns.names).count == columns.names.count)
        }
    }
}
