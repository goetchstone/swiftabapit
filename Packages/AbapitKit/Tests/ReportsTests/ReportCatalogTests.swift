import Testing
@testable import Reports

@Suite("Report catalog")
struct ReportCatalogTests {
    @Test func everyIdHasOneEntryWithTitleAndInputs() {
        #expect(ReportCatalog.entries.map(\.id) == ReportCatalog.ID.allCases)
        #expect(ReportCatalog.ID.allCases.map(\.rawValue) == ["coverage", "fleet-age", "activation-lock", "migration", "service-health", "out-of-warranty"])
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

    // MARK: the six, bounds and the holds lines (S9.1)

    /// Every token the Reports screen makes today (its steppers' defaults and bounds, and each group the picker lists) resolves to
    /// the same canonical tokens it did when the model resolved coverage and fleet age itself.
    @Test func everyTokenTheScreenMakesResolvesAsItDidBefore() {
        var table: [(ReportCatalog.ID, [String: String], [String: String])] = [
            (.coverage, ["days": "90"], ["days": "90"]), (.coverage, ["days": "1"], ["days": "1"]), (.coverage, ["days": "1825"], ["days": "1825"]),
            (.coverage, ["days": " 45 "], ["days": "45"]),
            (.fleetAge, ["years": "4"], ["years": "4"]), (.fleetAge, ["years": "1"], ["years": "1"]), (.fleetAge, ["years": "10"], ["years": "10"]),
            (.serviceHealth, ["days": "30"], ["days": "30"]), (.serviceHealth, ["days": "1825"], ["days": "1825"]),
            (.coverage, [:], [:]), (.fleetAge, [:], [:]), (.activationLock, [:], [:]),
        ]
        for id in [ReportCatalog.ID.activationLock, .migration, .serviceHealth, .outOfWarranty] {
            for group in ReportCatalog.entry(id).filters.first(where: { $0.name == "group" })!.values { table.append((id, ["group": group], ["group": group])) }
        }
        table.append((.serviceHealth, ["group": "quiet", "days": "7"], ["group": "quiet", "days": "7"]))
        for (id, tokens, expected) in table {
            let result = ReportCatalog.resolve(id, tokens: tokens)
            #expect(result.tokens == expected && result.problems.isEmpty, "\(id) \(tokens): \(result)")
        }
    }

    @Test func aProblemIsSaidInWordsForEveryReport() {
        for entry in ReportCatalog.entries {
            let unknown = ReportCatalog.resolve(entry.id, tokens: ["colour": "red"])
            #expect(unknown.problems == ["\(entry.title) has no filter named colour"] && unknown.tokens.isEmpty, "\(entry.id)")
            for filter in entry.filters {
                let twice = ReportCatalog.resolve(entry.id, tokens: [filter.name: filter.bounds.map { String($0.lowerBound) } ?? filter.values[0], filter.name.uppercased(): filter.bounds.map { String($0.lowerBound) } ?? filter.values[0]])
                #expect(twice.problems.count == 1 && twice.problems.first?.contains("given twice") == true, "\(entry.id) \(filter.name)")
                if let bounds = filter.bounds {
                    let words = "\(filter.name) must be a whole number of \(filter.name) from \(bounds.lowerBound) to \(bounds.upperBound)"
                    for bad in ["soon", "", "1.5", "0x10", String(bounds.lowerBound - 1), String(bounds.upperBound + 1), "-3", "99999999999999999999"] {
                        let result = ReportCatalog.resolve(entry.id, tokens: [filter.name: bad])
                        #expect(result.problems == [words] && result.tokens[filter.name] == nil, "\(entry.id) \(filter.name)=\(bad): \(result)")
                    }
                    for good in [bounds.lowerBound, bounds.upperBound] { #expect(ReportCatalog.resolve(entry.id, tokens: [filter.name: String(good)]).tokens == [filter.name: String(good)]) }
                }
            }
        }
    }

    @Test func theBoundsAreTheReportTypes() throws {
        func bounds(_ id: ReportCatalog.ID, _ name: String) throws -> ClosedRange<Int> { try #require(ReportCatalog.entry(id).filters.first { $0.name == name }?.bounds) }
        #expect(try bounds(.coverage, "days") == 1...1825 && CoverageReport.maximumDays == 1825)
        #expect(try bounds(.fleetAge, "years") == 1...10 && FleetAgeReport.maximumYears == 10)
        #expect(try bounds(.serviceHealth, "days") == 1...1825 && QuietServices.maximumDays == 1825)
        #expect(ReportCatalog.entries.flatMap(\.filters).filter(\.isNumber).count == 3)
    }

    @Test func holdsLinesAreBuiltFromTheGroupValuesAndHoldNoListData() throws {
        let exact: [ReportCatalog.ID: String] = [
            .coverage: "AppleCare coverage ending: days is a whole number from 1 to 1825.",
            .fleetAge: "Fleet age: years is a whole number from 1 to 10.",
            .activationLock: "Activation Lock: group is one of: lock:USER, lock:MDM, lock:NONE, lock:other, unlocked, unclear, not-read.",
            .migration: "MDM migration: group is one of: status:REQUESTED, status:STARTED, status:SUCCESS, status:FAILED, status:other, no-status, no-data, past-due, past-due-status-unknown.",
            .serviceHealth: "Device management service health: group is one of: healthy, quiet, inactive, deleted, other-status, cannot-judge; days is a whole number from 1 to 1825.",
            .outOfWarranty: "Out of warranty: group is one of: active, no-active-coverage, no-record, status-unknown, not-read, estimated-past-limit.",
        ]
        #expect(exact.count == ReportCatalog.ID.allCases.count)
        for (id, line) in exact { #expect(ReportCatalog.entry(id).holds == line, Comment(rawValue: id.rawValue)) }
        for entry in ReportCatalog.entries {
            #expect(entry.holds.hasPrefix(entry.title + ": "), "\(entry.id)")
            for filter in entry.filters where filter.bounds == nil { for value in filter.values { #expect(entry.holds.contains(value), "\(entry.id) \(value)") } }
        }
        // Canary list data, as the report types' own fixtures carry: none of it can be in a line.
        let canaries = (ActivationLockReportTests.report.rows.map(\.token) + WarrantyReportTests.report.rows.map(\.group))
        let allowed = Set(ReportCatalog.entries.flatMap(\.filters).flatMap(\.values))
        for token in canaries { #expect(allowed.contains(token), "\(token) is a group value, not list data") }
        let words = ReportCatalog.entries.map(\.holds).joined(separator: " ")
        for canary in ["serial", "C02", "iPad", "MacBook"] { #expect(!words.contains(canary), Comment(rawValue: canary)) }
    }
}
