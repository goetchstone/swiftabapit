import Foundation
import FoundationModels
import Reports
import Testing
import TestSupport
@testable import Assist

/// A rule's findings explained (S9.12; the operator's Q3 "Picks + explanations", D7 and D10; the shape is the coordinating
/// session's proposal): the prompt holds code's facts only, every sentence is checked against them, every drop is counted, and
/// nothing is shown when nothing holds. Over the strict stub model.
@Suite("Explain")
struct ExplainTests {
    static let thresholds = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 14, quietServiceDays: 30)

    static func facts(_ rule: NeedsAttention.Rule = .appleCareExpiring, found: Int = 5, hidden: Int = 2, read: Explain.Read = .whole,
                      ageDays: Int? = 3) -> Explain.Facts {
        Explain.Facts(rule: rule, thresholds: thresholds, found: found, hidden: hidden, read: read, ageDays: ageDays)
    }

    static func reply(_ sentences: [String]) -> StubModel.Reply {
        .json(String(data: try! JSONSerialization.data(withJSONObject: ["sentences": sentences]), encoding: .utf8)!)
    }

    // MARK: the prompt

    /// Each call's prompt taken apart: every line is a fixed heading and code's words for these facts, the task last; the
    /// instructions are the fixed ones; the schema is one array field. Nothing else reaches the model.
    @Test(arguments: NeedsAttention.Rule.allCases)
    func thePromptHoldsOnlyTheFacts(rule: NeedsAttention.Rule) async throws {
        let facts = Self.facts(rule, found: 1043, hidden: 7, read: .partial, ageDays: rule.thresholdDays(Self.thresholds) == nil ? nil : 21)
        let model = StubModel([Self.reply(["This check found 1,043 findings."])])
        _ = try await Explain.explain(facts, using: model)
        let call = try #require(model.calls.first)
        #expect(model.calls.count == 1, "one call per rule")
        #expect(call.instructions == Explain.instructions)
        var lines = call.prompt.components(separatedBy: "\n")
        #expect(lines.removeLast() == Explain.task)
        var expected = ["Check: \(rule.title(Self.thresholds))", "What it finds: \(rule.about)"]
        if let days = rule.thresholdDays(Self.thresholds) { expected.append("Threshold: \(days) days") }
        expected += ["Findings: 1043; the administrator dismissed or snoozed 7 of them",
                     "Read: in part: some of what the check needs wasn't read, so it may have missed some",
                     facts.ageDays == nil ? "Data: read live" : "Data: from a snapshot 21 days old"]
        #expect(lines == expected)
        // Every digit in the prompt is a fact's.
        let digits = Set(call.prompt.matches(of: /\d+/).map { Int($0.output)! })
        #expect(digits.isSubset(of: Set(facts.numbers.map(\.value))), "\(digits)")
        let shape = try StubModel.shape(call.schema)
        #expect(shape.required == ["sentences"] && shape.enums.isEmpty)
    }

    @Test func theDataLineSaysTodayAndLive() {
        #expect(Explain.prompt(Self.facts(ageDays: 0)).contains("Data: from a snapshot taken today"))
        #expect(Explain.prompt(Self.facts(ageDays: 1)).contains("Data: from a snapshot 1 day old"))
        #expect(Explain.prompt(Self.facts(.quietService, ageDays: nil)).contains("Data: read live"))
        #expect(Explain.prompt(Self.facts(read: .whole)).contains("Read: in full: every list the check needs was read whole"))
        #expect(Explain.prompt(Self.facts(hidden: 0)).contains("Findings: 5; the administrator dismissed or snoozed none of them"))
        #expect(!Explain.prompt(Self.facts(.fileVaultOff)).contains("Threshold:"), "a rule with no threshold has no threshold line")
    }

    /// No rule's description holds a number: the threshold is the title's, so the description can't state a different one.
    @Test func noDescriptionHoldsANumber() {
        for rule in NeedsAttention.Rule.allCases {
            #expect(rule.about.firstMatch(of: /\d/) == nil, Comment(rawValue: rule.rawValue))
            #expect(Explain.numbersHold(rule.about, Self.facts(rule)), Comment(rawValue: rule.rawValue))
            #expect(Explain.namesHold(rule.about, Self.facts(rule)), Comment(rawValue: rule.rawValue))
        }
    }

    /// `Facts` takes a rule, the thresholds, whole numbers and two small enums; Explain.swift names no list type and imports no
    /// module that has one. A list type added to the signature or the imports fails this.
    @Test func noListDataReachesThePromptBuilder() throws {
        let text = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/Assist/Explain.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(code.contains("public init(rule: NeedsAttention.Rule, thresholds: NeedsAttention.Thresholds, found: Int, hidden: Int, read: Read, ageDays: Int?)"))
        #expect(code.components(separatedBy: "public init(").count == 3 && code.contains("public init() {}"),
                "two public initializers: the facts', and the on-device model's, which takes nothing")
        #expect(code.contains("static func prompt(_ facts: Facts) -> String"))
        let imports = code.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
        #expect(imports == ["import Foundation", "import FoundationModels", "import Reports"])
        for word in ["Resource", "OrgDevice", "MDMDevice", "MDMService", "Listed", "Swept", "Finding(", "NeedsAttention.Finding", "subject",
                     "reason", "serial", "Input", "RuleResult", "Line", "notes", "takenAt"] {
            #expect(!code.contains(word), Comment(rawValue: word))
        }
        // Facts' stored properties are exactly these.
        let mirror = Mirror(reflecting: Self.facts())
        #expect(mirror.children.map { $0.label ?? "" } == ["rule", "thresholds", "found", "hidden", "read", "ageDays"])
    }

    // MARK: the checks, one by one

    @Test func aNumberMustBeAFactsWithItsUnit() {
        let f = Self.facts() // 90 days threshold, 5 found, 2 hidden, 3 days old
        for kept in ["This check found 5 devices whose AppleCare coverage ends within 90 days.", "5 findings in all, and 2 findings are dismissed or snoozed.",
                     "Of the 5 findings, 2 dismissed devices are hidden.", "The snapshot is 3 days old.", "Five devices were found, two hidden findings among them.",
                     "Each one is listed below.", "The 90-day window counts from today.", "The administrator dismissed or snoozed 2 of them.", "It raised 5 alerts.", "There are no more than 90 days left on these devices."] {
            #expect(Explain.numbersHold(kept, f), Comment(rawValue: kept))
        }
        for dropped in ["This check found 6 devices.", "It found 5 days of findings.", "Coverage ends within 60 days.", "About 1.5 devices.",
                        "40% of devices.", "Coverage ends in 3 weeks.", "The check ran in 2026.", "Twenty devices were found.",
                        "A dozen devices were found.", "Thousands of devices.", "No devices were found.", "None of the findings are open.",
                        "It found 5.", "Half of the devices.", "One hundred devices.", "It found twenty five devices.", "3 open devices remain.", "It found 5 services."] {
            #expect(!Explain.numbersHold(dropped, f), Comment(rawValue: dropped))
        }
        #expect(Explain.numbersHold("It found 2 services.", Self.facts(.quietService, found: 2, hidden: 0, ageDays: nil)))
        #expect(!Explain.numbersHold("It found 2 devices.", Self.facts(.quietService, found: 2, hidden: 0, ageDays: nil)), "a quiet service is a service")
        let thousands = Self.facts(found: 1043, hidden: 0)
        #expect(Explain.numbersHold("It found 1,043 devices.", thousands))
        #expect(Explain.numbersHold("It found one thousand and forty three devices.", thousands))
        #expect(Explain.numbersHold("None of them are dismissed or snoozed: no findings are hidden.", thousands), "a zero the facts hold")
        #expect(!Explain.numbersHold("It found 1,042 devices.", thousands))
        #expect(Explain.numbersHold("No check-in was recorded.", f), "\"no\" before a word that isn't a unit states no number")
    }

    @Test func aCapitalizedWordMustBeTheRulesOrTheVocabulary() {
        let f = Self.facts(.activationLock)
        for kept in ["Activation Lock is held by a person's Apple Account on these devices.", "These iPhones and iPads can't be redeployed.",
                     "Devices with Activation Lock block a release.", "Each one needs its owner's Apple Account.", "Mosyle and AppleCare aren't involved."] {
            #expect(Explain.namesHold(kept, f), Comment(rawValue: kept))
        }
        for dropped in ["Jane Doe holds the lock.", "The devices at Contoso are locked.", "This affects the Marketing group.",
                        "Find My keeps them locked.", "Mac-Lab-07 is one of them.", "Contoso devices are locked."] {
            #expect(!Explain.namesHold(dropped, f), Comment(rawValue: dropped))
        }
    }

    @Test func theAppNeverSpeaksAsIfItActed() {
        for dropped in ["We found 5 devices.", "I checked the list.", "Our records show 5 devices."] {
            #expect(Explain.check(dropped, Self.facts()) == .person, Comment(rawValue: dropped))
        }
    }

    @Test func adviceAndCommandsAreDropped() {
        for dropped in ["Renew AppleCare on these devices.", "You should renew the coverage.", "Contact the device's owner.", "Please review them.",
                        "The coverage needs to be renewed.", "Consider extending AppleCare.", "Make sure the coverage is renewed.",
                        "It is recommended to renew these.", "Turn on FileVault for these Macs.", "You can renew it in Apple's portal."] {
            #expect(Explain.check(dropped, Self.facts()) == .advice, Comment(rawValue: dropped))
        }
        #expect(Explain.check("These devices need attention before their coverage ends.", Self.facts()) == nil)
    }

    @Test func aClaimOfSomethingDoneIsDropped() {
        for dropped in ["The coverage has been renewed.", "These devices were removed.", "The devices are now enrolled.", "abapit will notify the owner.",
                        "The app dismissed 2 findings.", "The issue was fixed.", "These findings will be resolved."] {
            #expect(Explain.check(dropped, Self.facts()) == .done || Explain.check(dropped, Self.facts()) == .number, Comment(rawValue: dropped))
            #expect(Explain.claimsDone(Explain.lowerTokens(dropped)), Comment(rawValue: dropped))
        }
        // A state is not a claim: "enrolled", "assigned" and "locked" describe devices.
        for kept in ["These devices are assigned to an Apple MDM service.", "A device enrolled in Apple MDM is missing from Apple's list.",
                     "These devices are locked to a person's Apple Account.", "abapit reads Apple's device list."] {
            #expect(!Explain.claimsDone(Explain.lowerTokens(kept)), Comment(rawValue: kept))
        }
    }

    @Test func wordsAgainstTheReadAreDropped() {
        let partial = Self.facts(read: .partial), whole = Self.facts(read: .whole), live = Self.facts(.quietService, ageDays: nil)
        #expect(Explain.check("Every device was read.", partial) == .read)
        #expect(Explain.check("The check is complete.", partial) == .read)
        #expect(Explain.check("Only part of the devices were read, so it may have missed some.", partial) == nil)
        #expect(Explain.check("The read was partial.", whole) == .read)
        #expect(Explain.check("Some devices were not read.", whole) == .read)
        #expect(Explain.check("It may have missed some devices.", whole) == .read)
        #expect(Explain.check("It may have missed some devices.", partial) == nil)
        #expect(Explain.check("Every device was read.", whole) == nil)
        #expect(Explain.check("The snapshot is old.", live) == .read)
        #expect(Explain.check("The list was read live.", whole) == .read)
        #expect(Explain.check("The list was read live.", live) == nil)
    }

    @Test func emptyLongEchoedAndRepeatedAreDropped() {
        let f = Self.facts()
        #expect(Explain.check("", f) == .empty)
        #expect(Explain.check(String(repeating: "devices ", count: 40), f) == .long)
        #expect(Explain.check("One to three short sentences.", f) == .echoed)
        #expect(Explain.check("These devices matter.", f, earlier: ["These devices matter."]) == .repeated)
    }

    // MARK: drops counted, nothing shown when nothing holds

    @Test func everyDropIsCounted() async throws {
        let model = StubModel([Self.reply(["This check found 5 devices whose coverage ends within 90 days.", "It found 6 devices.",
                                           "Renew them now."])])
        let outcome = try await Explain.explain(Self.facts(), using: model)
        #expect(outcome == .explained(sentences: ["This check found 5 devices whose coverage ends within 90 days."], dropped: [.number, .advice]))
        #expect(outcome.note == nil)
    }

    @Test func moreThanThreeSentencesAreCountedAsExtra() {
        let outcome = Explain.judge(["These devices matter.", "They are listed below.", "Each one has a date.", "More follows."], Self.facts())
        #expect(outcome.sentences.count == 3 && outcome.dropped == [.extra])
    }

    @Test func allDroppedShowsNothing() async throws {
        let model = StubModel([Self.reply(["We found 7 devices.", "Contoso owns them."])])
        let outcome = try await Explain.explain(Self.facts(), using: model)
        #expect(outcome == .nothingKept(dropped: [.person, .name]))
        #expect(outcome.sentences.isEmpty)
        #expect(outcome.note == "The on-device model's explanation didn't match this rule's facts, so none is shown.")
    }

    /// A thrown error, an answer with no sentences or one the stub must throw for a missing field: nothing is shown, worded by kind.
    @Test func aFailureShowsNothing() async throws {
        let refused = try await Explain.explain(Self.facts(), using: StubModel([.error(LanguageModelError.refusal(.init(explanation: "CANARY", debugDescription: "CANARY")))]))
        #expect(refused == .failed(.refused) && refused.sentences.isEmpty)
        let guardrail = try await Explain.explain(Self.facts(), using: StubModel([.error(LanguageModelError.guardrailViolation(.init(debugDescription: "x")))]))
        #expect(guardrail == .failed(.guardrail))
        let missing = try await Explain.explain(Self.facts(), using: StubModel([.json(#"{"other": "x"}"#)]))
        #expect(missing == .failed(.unreadable))
        let empty = try await Explain.explain(Self.facts(), using: StubModel([.unchecked(#"{"sentences": []}"#)]))
        #expect(empty == .failed(.unreadable))
        #expect(refused.note == "The on-device model couldn't explain this rule: the model declined to answer.")
    }

    @Test func cancellationIsThrown() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Explain.explain(Self.facts(), using: StubModel())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: availability

    @Test func theModelOffAsksNothingAndSaysWhy() async throws {
        let cases: [(SystemLanguageModel.Availability, Bool, String)] = [
            (.unavailable(.deviceNotEligible), true, "This Mac can't run Apple's on-device model"),
            (.unavailable(.appleIntelligenceNotEnabled), true, "Apple Intelligence is off"),
            (.unavailable(.modelNotReady), true, "still being set up"),
            (.available, false, "doesn't support this Mac's language"),
        ]
        for (availability, locale, words) in cases {
            let model = StubModel(availability: availability, supportsLocale: locale)
            let outcome = try await Explain.explain(Self.facts(), using: model)
            guard case .off(let refusal) = outcome else { Issue.record("not off: \(outcome)"); continue }
            #expect(refusal == Refusals.availability(of: model))
            #expect(outcome.note?.contains(words) == true && outcome.note?.hasSuffix("Everything else on this screen works as before.") == true,
                    Comment(rawValue: outcome.note ?? ""))
            #expect(model.calls.isEmpty, "the model is never asked while it is off")
        }
    }

    /// On-device only: the explainer's model is the system's on-device model, never Private Cloud Compute, and it is given no tools.
    @Test func onDeviceOnly() throws {
        let text = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/Assist/Explain.swift"), encoding: .utf8)
        #expect(text.contains("LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)"))
        for word in ["PrivateCloudCompute", "tools:", "Tool"] { #expect(!text.contains(word), Comment(rawValue: word)) }
        #expect(Explain.options.maximumResponseTokens == Explain.responseCap)
    }

    /// Explain writes nothing anywhere: no log, no file, no store.
    @Test func explainWritesNothing() throws {
        let text = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/Assist/Explain.swift"), encoding: .utf8)
        for word in ["print(", "Logger", "os_log", "NSLog", "FileManager", ".write(", "UserDefaults", "SnapshotStore", "debugPrint", "dump("] {
            #expect(!text.contains(word), Comment(rawValue: word))
        }
    }
}
