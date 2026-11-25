import Foundation
import Reports
import Testing
import TestSupport
@testable import Assist

@Suite("Choices")
struct ChoicesTests {
    static let thresholds = Samples.thresholds

    func ids(_ scope: Choices.Scope, mosyle: Bool) -> [String] {
        Choices.build(scope: scope, hasMosyle: mosyle, thresholds: Self.thresholds).map(\.id)
    }

    @Test func aBusinessClientWithMosyleGetsEverything() {
        let choices = Choices.build(scope: .business, hasMosyle: true, thresholds: Self.thresholds)
        #expect(choices.count == Choices.largest)
        #expect(choices.count == 6 + 1 + NeedsAttention.Rule.allCases.count)
        #expect(Set(choices.map(\.id)).count == choices.count, "ids are unique")
        #expect(Set(choices.map(\.label)).count == choices.count, "labels are unique")
        #expect(choices.count <= Choices.limit)
    }

    @Test func noMosyleRulesWithoutAMosyleOrg() {
        let without = ids(.business, mosyle: false)
        for rule in NeedsAttention.Rule.allCases where rule.needsMosyle { #expect(!without.contains("rule:\(rule.rawValue)"), "\(rule)") }
        #expect(without.count == Choices.largest - 3)
        for rule in NeedsAttention.Rule.allCases where !rule.needsMosyle { #expect(without.contains("rule:\(rule.rawValue)"), "\(rule)") }
    }

    @Test func noAppleMDMRulesForASchoolOrg() {
        let school = ids(.school, mosyle: true)
        for rule in Choices.appleMDMRules { #expect(!school.contains("rule:\(rule.rawValue)"), "\(rule)") }
        #expect(Choices.appleMDMRules.count == 5)
        #expect(school.count == Choices.largest - 5)
        #expect(school.contains("rule:applecare_expiring"))
        #expect(school.contains("rule:mosyle_check_in"))
        #expect(ids(.school, mosyle: false).count == Choices.largest - 5 - 3)
        // The Needs-attention rules never ask Apple School Manager for Apple MDM's list: the rules list says the same.
        #expect(Choices.rules(scope: .school, hasMosyle: false).allSatisfy { !Choices.appleMDMRules.contains($0) && !$0.needsMosyle })
    }

    @Test func theSixReportsAndTheSummaryAreAlwaysThere() {
        for scope in [Choices.Scope.business, .school] {
            for mosyle in [true, false] {
                let list = ids(scope, mosyle: mosyle)
                for entry in ReportCatalog.entries { #expect(list.contains("report:\(entry.id.rawValue)")) }
                #expect(list.contains("attention"))
                #expect(list.prefix(6).allSatisfy { $0.hasPrefix("report:") }, "reports first, then the summary, then the rules")
                #expect(list[6] == "attention")
            }
        }
    }

    @Test func labelsAndHoldsComeOnlyFromTheCatalogAndTheRuleTitles() {
        let choices = Choices.build(scope: .business, hasMosyle: true, thresholds: Self.thresholds)
        for entry in ReportCatalog.entries {
            let choice = choices.first { $0.id == "report:\(entry.id.rawValue)" }!
            #expect(choice.label == entry.title)
            #expect(choice.holds == entry.holds)
        }
        for rule in NeedsAttention.Rule.allCases {
            let choice = choices.first { $0.id == "rule:\(rule.rawValue)" }!
            #expect(choice.label == rule.title(Self.thresholds))
            #expect(choice.holds == nil)
        }
        let summary = choices.first { $0.id == "attention" }!
        #expect(summary.label == Choices.summaryLabel)
        #expect(summary.holds == "Needs attention: " + NeedsAttention.Rule.allCases.map { $0.title(Self.thresholds) }.joined(separator: "; ") + ".")
    }

    @Test func thresholdsReachTheRuleTitles() {
        let other = NeedsAttention.Thresholds(checkInDays: 7, appleCareExpiringDays: 45, migrationDeadlineDays: 3, quietServiceDays: 60)
        let choices = Choices.build(scope: .business, hasMosyle: true, thresholds: other)
        #expect(choices.first { $0.id == "rule:mosyle_check_in" }!.label == "No check-in to Mosyle for 7 days or more")
        #expect(choices.first { $0.id == "rule:applecare_expiring" }!.label == "AppleCare coverage ending within 45 days")
    }

    @Test func groupsAreTheReportsGroupValuesAndNumbersAreNeverGroups() {
        let choices = Choices.build(scope: .business, hasMosyle: false, thresholds: Self.thresholds)
        func groups(_ id: ReportCatalog.ID) -> [String] { choices.first { $0.id == "report:\(id.rawValue)" }!.groups }
        #expect(groups(.coverage).isEmpty)
        #expect(groups(.fleetAge).isEmpty)
        #expect(groups(.activationLock) == ActivationLockReport.fixedGroups)
        #expect(groups(.serviceHealth) == ServiceHealth.fixedGroups)
        #expect(groups(.migration).contains(MigrationReport.pastDueToken))
        #expect(groups(.outOfWarranty).contains(WarrantyReport.estimatedPastToken))
        #expect(choices.filter { !$0.id.hasPrefix("report:") }.allSatisfy { $0.groups.isEmpty })
    }

    // MARK: no list data

    /// `Choices.build` takes a client's kind, whether it has Mosyle and the thresholds, and nothing else; the source names no
    /// list type and imports no module that has one. A list type added to the signature or the imports fails this.
    @Test func theInputsCarryNoListData() throws {
        let text = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/Assist/Choices.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(code.contains("public static func build(scope: Scope, hasMosyle: Bool, thresholds: NeedsAttention.Thresholds) -> [Choice]"))
        let imports = code.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
        #expect(imports == ["import Foundation", "import Reports"])
        for word in ["Resource", "OrgDevice", "MDMDevice", "MDMService", "Listed", "Swept", "Document", "serial"] {
            #expect(!code.contains(word), Comment(rawValue: word))
        }
        // The label and holds are assigned from the catalog's entries and the rules' titles, nowhere else.
        #expect(code.contains("label: entry.title, holds: entry.holds"))
        #expect(code.contains(".title(thresholds)"))
    }

    @Test func noChoiceHoldsAnythingButCodesWords() {
        let canaries = ["serial", "C02", "iPad", "MacBook", "@", "example.com"]
        for choice in Choices.build(scope: .business, hasMosyle: true, thresholds: Self.thresholds) {
            for canary in canaries { #expect(!(choice.label + (choice.holds ?? "")).contains(canary), Comment(rawValue: "\(choice.id) \(canary)")) }
        }
    }

    /// After a whole demo fleet is made (its serials, order numbers and service names), no label or holds line of any scope holds
    /// one of them: the list is built from code's words, and the fleet is there to show it.
    @Test func noFixtureSerialOrNameReachesALabel() {
        let fleet = DemoFleet.make()
        let text = String(describing: fleet)
        // The demo's serials, order numbers and MAC addresses, found in the fleet's own dump so the test can't go stale.
        let found = text.matches(of: /DEMO[A-Z0-9]{4,}/).map { String($0.output) }
        #expect(Set(found).count >= 84, "the fleet's identifiers were found: \(Set(found).count)")
        let names = ["Jamf Pro (old)", "Apple Configurator", "Mosyle Business"]
        for scope in [Choices.Scope.business, .school] {
            for mosyle in [true, false] {
                for choice in Choices.build(scope: scope, hasMosyle: mosyle, thresholds: Self.thresholds) {
                    let words = choice.label + " " + (choice.holds ?? "") + " " + choice.groups.joined(separator: " ")
                    for token in Array(Set(found)) + names { #expect(!words.contains(token), Comment(rawValue: "\(choice.id) \(token)")) }
                }
            }
        }
    }
}
