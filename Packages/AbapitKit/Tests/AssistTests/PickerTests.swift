import Foundation
import FoundationModels
import Reports
import Testing
import TestSupport
@testable import Assist

@Suite("Picker")
struct PickerTests {
    static let thresholds = Samples.thresholds
    static let full = Picker.Client(scope: .business, hasMosyle: true, thresholds: thresholds)
    static let noMosyle = Picker.Client(scope: .business, hasMosyle: false, thresholds: thresholds)
    static let see = ModelPicker.Asks.see.rawValue
    static let change = ModelPicker.Asks.change.rawValue

    func label(_ id: String, _ client: Picker.Client = full) -> String { client.choices.first { $0.id == id }!.label }

    // MARK: refused before any call

    @Test func theRefusalsBeforeAnyCallMakeNoCall() async throws {
        let cases: [(String, Picker.Client?, StubModel, Refusal)] = [
            ("which devices are out of warranty", nil, StubModel(), .noClient),
            ("", Self.full, StubModel(), .empty),
            ("  \n \t ", Self.full, StubModel(), .empty),
            (String(repeating: "x", count: Picker.longest + 1), Self.full, StubModel(), .tooLong(Picker.longest + 1)),
            ("which devices haven't checked in to Mosyle", Self.noMosyle, StubModel(), .mosyleWithoutOrg),
            ("MOSYLE's devices", Self.noMosyle, StubModel(), .mosyleWithoutOrg),
            ("devices", Self.full, StubModel(availability: .unavailable(.deviceNotEligible)), .unavailable(.deviceNotEligible)),
            ("devices", Self.full, StubModel(availability: .unavailable(.appleIntelligenceNotEnabled)), .unavailable(.appleIntelligenceNotEnabled)),
            ("devices", Self.full, StubModel(availability: .unavailable(.modelNotReady)), .unavailable(.modelNotReady)),
            ("devices", Self.full, StubModel(supportsLocale: false), .unsupportedLocale),
        ]
        for (sentence, client, model, refusal) in cases {
            let outcome = try await Picker.pick(sentence, for: client, using: model)
            #expect(outcome == .refused(refusal), Comment(rawValue: sentence))
            #expect(model.calls.isEmpty, Comment(rawValue: "\(refusal) made a call"))
        }
        // The order: no client first, then the sentence, then Mosyle, then the model.
        let offModel = StubModel(availability: .unavailable(.modelNotReady))
        #expect(try await Picker.pick("", for: nil, using: offModel) == .refused(.noClient))
        #expect(try await Picker.pick("", for: Self.full, using: offModel) == .refused(.empty))
        #expect(try await Picker.pick("mosyle", for: Self.noMosyle, using: offModel) == .refused(.mosyleWithoutOrg))
        #expect(offModel.calls.isEmpty)
        // `Refusals.before` is public: it refuses no client itself, not only through `pick`.
        #expect(Refusals.before("devices", client: nil, model: StubModel()) == .noClient)
        // A client with a Mosyle org may name it.
        let withMosyle = StubModel([StubModel.pick(Self.change, words: "mosyle")])
        #expect(try await Picker.pick("move the iPads to Mosyle", for: Self.full, using: withMosyle) == .changeRequest)
        #expect(withMosyle.calls.count == 1)
    }

    @Test func eachRefusalIsWorded() {
        let all: [Refusal] = [.noClient, .empty, .tooLong(301), .mosyleWithoutOrg, .unavailable(.deviceNotEligible),
                              .unavailable(.appleIntelligenceNotEnabled), .unavailable(.modelNotReady), .unavailable(.other),
                              .unsupportedLocale, .notOnTheList]
            + [Refusal.NotUnderstood.guardrail, .refused, .rateLimited, .timeout, .tooMuchToRead, .unreadable, .unsupported, .language,
               .settingUp, .busy, .faultTwice, .other].map(Refusal.notUnderstood)
        let words = all.map(\.words)
        #expect(Set(words).count == all.count, "each refusal says something of its own")
        #expect(Refusal.tooLong(301).words.contains("301") && Refusal.tooLong(301).words.contains("300"))
        for refusal in all { if case .unavailable = refusal { #expect(refusal.words.contains("reports work as before")) } }
        #expect(Refusal.notUnderstood(.timeout).words.hasSuffix("Nothing was picked."))
    }

    /// Exactly 300 characters is read; the bound is the sentence trimmed and on one line.
    @Test func theLongestSentenceIsRead() async throws {
        let sentence = "devices " + String(repeating: "x", count: Picker.longest - 8)
        let model = StubModel([StubModel.pick(Self.change)])
        #expect(try await Picker.pick("  " + sentence + "\n", for: Self.full, using: model) == .changeRequest)
        #expect(model.calls.count == 1)
        #expect(Picker.tidy("a\nb\r\nc ") == "a b c")
    }

    // MARK: the picks

    @Test func aChangeRequestIsAnsweredByCodeAfterOnePick() async throws {
        let model = StubModel([StubModel.pick(Self.change)])
        #expect(try await Picker.pick("assign the devices to another service", for: Self.full, using: model) == .changeRequest)
        #expect(model.calls.count == 1)
        #expect(Picker.changeRequestWords == "This version only reads; nothing was drafted.")
        // The first pick offers the two labels only: no none, and nothing of the list.
        #expect(try StubModel.shape(model.calls[0].schema).enums["pick"] == [Self.see, Self.change])
    }

    @Test func aReportWithGroupsTakesThreePicks() async throws {
        let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:activation-lock")), StubModel.pick("user lock", words: "user")])
        let outcome = try await Picker.pick("devices with a user's Activation Lock", for: Self.full, using: model)
        let choice = Self.full.choices.first { $0.id == "report:activation-lock" }!
        #expect(outcome == .picked(Picker.Pick(choice: choice, group: "lock:USER", tokens: ["group": "lock:USER"])))
        #expect(model.calls.count == 3)
        let schemas = try model.calls.map { try StubModel.shape($0.schema) }
        #expect(schemas[1].enums["pick"] == Self.full.choices.map(\.label) + [ModelPicker.none])
        // The group pick lists plain words, "all" last, and code maps the answer back to the catalog's token.
        #expect(schemas[2].enums["pick"] == [ModelPicker.all] + choice.groups.map(ModelPicker.groupLabel), "all first")
        #expect(!schemas[2].enums["pick"]!.contains("lock:USER"))
        #expect(schemas.allSatisfy { $0.required == ["pick", "words"] })
    }

    /// Every group of every report has plain words of its own, none of them "all" or a token.
    @Test func everyGroupHasPlainWords() {
        for scope in [Choices.Scope.business, .school] {
            for choice in Choices.build(scope: scope, hasMosyle: true, thresholds: Self.thresholds) where !choice.groups.isEmpty {
                let labels = choice.groups.map(ModelPicker.groupLabel)
                #expect(Set(labels).count == labels.count, Comment(rawValue: choice.id))
                for (group, label) in zip(choice.groups, labels) {
                    #expect(ModelPicker.groupLabels[group] != nil, Comment(rawValue: group))
                    #expect(label != ModelPicker.all && !label.contains(":"), Comment(rawValue: group))
                }
            }
        }
    }

    /// A sentence that shares no word with any group's plain words is every group, decided by code with no third call (the
    /// group pick leaned to the first group listed when a sentence named none).
    @Test func aSentenceNamingNoGroupIsEveryGroupWithNoCall() async throws {
        for (sentence, id) in [("the MDM migration report", "report:migration"), ("Activation Lock report", "report:activation-lock"),
                               ("show service health", "report:service-health"), ("devices out of warranty", "report:out-of-warranty"),
                               // A word several of the report's groups share, or a general one, names no group either.
                               ("show MDM migration status", "report:migration"), ("devices out of AppleCare coverage", "report:out-of-warranty"),
                               ("MDM migration data", "report:migration"), ("activation lock type for each device", "report:activation-lock"),
                               // "status" through the stoplist as `WordRule` reads it ("statu").
                               ("service health status", "report:service-health"), ("warranty status of my devices", "report:out-of-warranty")] {
            let model = StubModel([StubModel.pick(Self.see, words: sentence), StubModel.pick(label(id), words: sentence)])
            guard case .picked(let pick) = try await Picker.pick(sentence, for: Self.full, using: model) else { Issue.record(Comment(rawValue: sentence)); continue }
            #expect(pick.choice.id == id && pick.group == nil && pick.tokens.isEmpty, Comment(rawValue: sentence))
            #expect(model.calls.count == 2, Comment(rawValue: sentence))
        }
        let choice = Self.full.choices.first { $0.id == "report:migration" }!
        #expect(ModelPicker.namesAGroup("which migrations failed", choice))
        #expect(ModelPicker.namesAGroup("the ones requested", choice))
        // A word in two labels counts, "all" being listed first (round 3).
        #expect(ModelPicker.namesAGroup("devices past due", choice))
        #expect(ModelPicker.namesAGroup("the ones that missed the deadline", choice))
        #expect(ModelPicker.namesAGroup("unknown status", choice))
        #expect(!ModelPicker.namesAGroup("migration status", choice), "status is on the stoplist")
        // A word of the report's own label names no group, even where only one label holds it: here "lock" is in one label.
        let two = Choices.Choice(kind: .report(.activationLock), label: "Activation Lock", holds: nil, groups: ["unlocked", "lock:USER"])
        #expect(!ModelPicker.namesAGroup("the Activation Lock report", two))
        #expect(ModelPicker.namesAGroup("the user ones", two))
        #expect(!ModelPicker.namesAGroup("all of the MDM migration", choice), "the report's own words name no group")
    }

    @Test func allIsEveryGroup() async throws {
        let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:migration")), StubModel.pick(ModelPicker.all)])
        guard case .picked(let pick) = try await Picker.pick("failed or started migration of the devices", for: Self.full, using: model) else {
            Issue.record("no pick"); return
        }
        #expect(pick.choice.id == "report:migration" && pick.group == nil && pick.tokens.isEmpty)
        #expect(model.calls.count == 3)
    }

    @Test func aRuleOrTheSummaryTakesTwoPicks() async throws {
        for id in ["rule:firewall_off", "attention", "report:coverage", "report:fleet-age"] {
            let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label(id))])
            guard case .picked(let pick) = try await Picker.pick("which devices need me", for: Self.full, using: model) else {
                Issue.record(Comment(rawValue: id)); continue
            }
            #expect(pick.choice.id == id && pick.group == nil)
            #expect(model.calls.count == 2, Comment(rawValue: id))
        }
    }

    func outcome(_ sentence: String, _ id: String) async throws -> Picker.Outcome {
        let choice = Self.full.choices.first { $0.id == id }!
        let group = !choice.groups.isEmpty && ModelPicker.namesAGroup(sentence, choice) ? [StubModel.pick(ModelPicker.all, words: sentence)] : []
        let model = StubModel([StubModel.pick(Self.see, words: sentence), StubModel.pick(label(id), words: sentence)] + group)
        return try await Picker.pick(sentence, for: Self.full, using: model)
    }

    func problems(_ outcome: Picker.Outcome) -> [String] {
        if case .refused(.numbers(let problems)) = outcome { return problems }
        return []
    }

    /// Numbers come from code's parse of the sentence, and the catalog takes or refuses them; the model is never asked one.
    @Test func numbersComeFromTheSentence() async throws {
        func tokens(_ sentence: String, _ id: String) async throws -> [String: String]? {
            if case .picked(let pick) = try await outcome(sentence, id) { return pick.tokens }
            return nil
        }
        #expect(try await tokens("devices whose AppleCare ends within 45 days", "report:coverage") == ["days": "45"])
        #expect(try await tokens("devices whose AppleCare ends in 2 weeks", "report:coverage") == ["days": "14"])
        #expect(try await tokens("devices 4 years old or more", "report:fleet-age") == ["years": "4"])
        #expect(try await tokens("devices on a 90-day AppleCare window", "report:coverage") == ["days": "90"])
        #expect(try await tokens("devices ending in 30 days, so 30 days.", "report:coverage") == ["days": "30"])
        #expect(try await tokens("devices with firewall off", "rule:firewall_off") == [:], "a rule with no window takes no number")
        #expect(try await tokens("devices 4 yrs old or more", "report:fleet-age") == ["years": "4"])
        #expect(try await tokens("AppleCare ending in 2 wks", "report:coverage") == ["days": "14"])
        #expect(try await tokens("the Activation Lock of every device", "report:activation-lock") == [:])
        #expect(try await tokens("Activation Lock on macOS 15", "report:activation-lock") == [:], "a bare number, where no number is taken, is ignored")
    }

    /// A number that can't be taken as said refuses the pick, in words: never a value read from part of it, never dropped so the
    /// default window runs (the review's cases, each proved wrong before this).
    @Test(arguments: [
        ("devices 1.5 years old", "report:fleet-age", "1.5 years"),
        ("devices whose AppleCare ends in -30 days", "report:coverage", "-30 days"),
        ("devices whose AppleCare ends in 30-60 days", "report:coverage", "30-60 days"),
        ("devices whose AppleCare ends in 1,000 days", "report:coverage", "1,000 days"),
        ("devices whose AppleCare ends in 30\u{2212}60 days", "report:coverage", "60 days"),
        ("devices whose AppleCare ends in 1000000 days", "report:coverage", "from 1 to 1825"),
        ("devices whose AppleCare ends in 99999999999999999999999 days", "report:coverage", "from 1 to 1825"),
        ("devices whose AppleCare ends within 4000 days", "report:coverage", "from 1 to 1825"),
        ("devices ending in 30 days or 60 days", "report:coverage", "more than once"),
        ("devices whose AppleCare ends in 3 months", "report:coverage", "months"),
        ("devices whose AppleCare ends in two weeks", "report:coverage", "\u{201C}weeks\u{201D} has no number"),
        ("devices whose AppleCare ends in 90d", "report:coverage", "90d"),
        ("devices 4 years old", "report:coverage", "not years"),
        ("devices more than a year old", "report:fleet-age", "\u{201C}year\u{201D} has no number"),
        ("AppleCare ending in 60 days", "rule:applecare_expiring", "window of 90 days"),
        ("devices not checked in to Mosyle for 2 years", "rule:mosyle_check_in", "2 years"),
        ("services quiet for days", "rule:quiet_service", "no number"),
        // A range written in words or with spaced or em dashes (the coordinating session, 2026-11-27).
        ("devices whose AppleCare ends in 30 to 60 days", "report:coverage", "\u{201C}30\u{201D} has no unit"),
        ("devices whose AppleCare ends between 30 and 60 days", "report:coverage", "\u{201C}30\u{201D} has no unit"),
        ("devices whose AppleCare ends in 30 - 60 days", "report:coverage", "\u{201C}30\u{201D} has no unit"),
        ("devices whose AppleCare ends in 30\u{2014}60 days", "report:coverage", "plain digits"),
        // A bare number where a number is taken (round 3).
        ("AppleCare ending within 60", "report:coverage", "\u{201C}60\u{201D} has no unit"),
        ("coverage ending in 30 d", "report:coverage", "\u{201C}30\u{201D} has no unit"),
        ("AppleCare ending in 30 dys", "rule:applecare_expiring", "\u{201C}30\u{201D} has no unit"),
        ("devices bought before 2021", "report:fleet-age", "\u{201C}2021\u{201D} has no unit"),
        // Units abapit doesn't read.
        ("devices whose AppleCare ends within 48 hours", "report:coverage", "hours aren't read"),
        ("devices whose AppleCare ends within 48 hrs", "report:coverage", "hours aren't read"),
        ("devices whose AppleCare ends within 90 mins", "report:coverage", "minutes aren't read"),
        ("devices whose AppleCare ends in 3 mos", "report:coverage", "months"),
        // A choice that takes no number refuses one.
        ("firewall off for over 30 days", "rule:firewall_off", "takes no number"),
        ("user locks older than 1.5 years", "report:activation-lock", "takes no number"),
        ("what needs attention in the next 30 days", "attention", "takes no number"),
        ("the Activation Lock of 10 devices this year", "report:activation-lock", "takes no number"),
    ])
    func aNumberThatCantBeTakenRefusesThePick(_ sentence: String, _ id: String, _ said: String) async throws {
        let outcome = try await outcome(sentence, id)
        let problems = problems(outcome)
        #expect(!problems.isEmpty, Comment(rawValue: "\(outcome)"))
        #expect(problems.contains { $0.contains(said) }, Comment(rawValue: "\(problems)"))
        if case .refused(let refusal) = outcome { #expect(refusal.words.hasSuffix("Nothing was picked.")) }
    }

    @Test func aRulesOwnWindowIsTaken() async throws {
        for (sentence, id) in [("AppleCare ending in 90 days", "rule:applecare_expiring"), ("no Mosyle check-in for 30 days", "rule:mosyle_check_in"),
                               ("services silent 30 days", "rule:quiet_service"), ("migration deadline in 2 weeks", "rule:migration_deadline")] {
            guard case .picked(let pick) = try await outcome(sentence, id) else { Issue.record(Comment(rawValue: sentence)); continue }
            #expect(pick.choice.id == id && pick.tokens.isEmpty)
        }
    }

    /// Digits glued to letters that aren't a unit are refused as a filter abapit's reports don't have, never as a number of days the
    /// person didn't mean ("3pm" was never a window; S9.7). The refusal stands; only its words changed.
    @Test(arguments: ["3pm", "14in", "90d"])
    func aGluedTokenIsNoFilter(_ token: String) {
        let said = Picker.numbers(in: "devices at \(token) please")
        #expect(said.problems == ["abapit's reports can't filter by \u{201C}\(token)\u{201D}."], Comment(rawValue: "\(said.problems)"))
        #expect(said.values.isEmpty)
    }

    @Test func theParseReadsPlainDigitsBeforeAUnit() {
        #expect(Picker.numbers(in: "90-day, 1 year").values == ["days": ["90"], "years": ["1"]])
        #expect(Picker.numbers(in: "90-day, 1 year").problems.isEmpty)
        #expect(Picker.numbers(in: "10 devices, 90-day").bare == ["10"], "a bare number is kept apart")
        #expect(Picker.numbers(in: "10 devices").problems.isEmpty && Picker.numbers(in: "10 devices").values.isEmpty)
        #expect(Picker.numbers(in: "a min, an hr, a mo").problems.isEmpty, "an abbreviation alone is no unit word")
        #expect(Picker.numbers(in: "for 45days").values == ["days": ["45"]])
        #expect(Picker.numbers(in: "today, 2024-05-01, version 1.5").values.isEmpty)
        #expect(Picker.numbers(in: "today, 2024-05-01, version 1.5").problems.isEmpty, "a number with no unit is no filter")
        #expect(Picker.numbers(in: "in 1.5 years").values.isEmpty)
    }

    @Test func noneIsNotOnTheList() async throws {
        let model = StubModel([StubModel.pick(Self.see, words: "weather"), StubModel.pick(ModelPicker.none, words: "")])
        #expect(try await Picker.pick("what's the weather like", for: Self.full, using: model) == .refused(.notOnTheList))
        #expect(model.calls.count == 2)
    }

    /// The list is this client's: without Mosyle no Mosyle rule is offered, so none can be picked.
    @Test func theListIsTheClients() async throws {
        let model = StubModel([StubModel.pick(Self.see), .unchecked(#"{"pick": "No check-in to Mosyle for 30 days or more", "words": "devices"}"#),
                               .unchecked(#"{"pick": "No check-in to Mosyle for 30 days or more", "words": "devices"}"#)])
        #expect(try await Picker.pick("devices not checking in", for: Self.noMosyle, using: model) == .refused(.notUnderstood(.faultTwice)))
        let offered = try StubModel.shape(model.calls[1].schema).enums["pick"]!
        #expect(!offered.contains { $0.contains("Mosyle") })
        #expect(offered == Self.noMosyle.choices.map(\.label) + [ModelPicker.none])
    }

    // MARK: never a guess

    static let errors: [(any Error, Refusal.NotUnderstood)] = [
        (LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 9000, debugDescription: "CANARY-ERROR")), .tooMuchToRead),
        (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "CANARY-ERROR")), .rateLimited),
        (LanguageModelError.guardrailViolation(.init(debugDescription: "CANARY-ERROR")), .guardrail),
        (LanguageModelError.refusal(.init(explanation: "CANARY-ERROR", debugDescription: "CANARY-ERROR")), .refused),
        (LanguageModelError.unsupportedCapability(.init(capability: .guidedGeneration, debugDescription: "CANARY-ERROR")), .unsupported),
        (LanguageModelError.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "CANARY-ERROR")), .unsupported),
        (LanguageModelError.unsupportedGenerationGuide(.init(schemaName: "Pick", debugDescription: "CANARY-ERROR")), .unsupported),
        (LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .init("xx"), debugDescription: "CANARY-ERROR")), .language),
        (LanguageModelError.timeout(.init(debugDescription: "CANARY-ERROR")), .timeout),
        (GeneratedContent.ParsingError(rawContent: "CANARY-ERROR", debugDescription: "CANARY-ERROR"), .unreadable),
        (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "CANARY-ERROR")), .settingUp),
        (LanguageModelSession.Error.concurrentRequests, .busy),
        (LanguageModelSession.Error.transcriptMutationWhileResponding, .other),
        (URLError(.unknown), .other),
    ]

    /// Every error the SDK throws is "not understood" in words, at once, at each pick: greedy repeats a failure exactly, so
    /// nothing is asked again and nothing near is picked. The error's own text never reaches the words.
    @Test(arguments: 0..<PickerTests.errors.count)
    func eachModelErrorIsNotUnderstood(_ index: Int) async throws {
        let (error, why) = Self.errors[index]
        let lead: [[StubModel.Reply]] = [[], [StubModel.pick(Self.see)], [StubModel.pick(Self.see), StubModel.pick(label("report:migration"))]]
        for replies in lead {
            let model = StubModel(replies + [.error(error)])
            let outcome = try await Picker.pick("failed migration of the devices", for: Self.full, using: model)
            #expect(outcome == .refused(.notUnderstood(why)), Comment(rawValue: "\(error) at pick \(replies.count + 1)"))
            #expect(model.calls.count == replies.count + 1, "no re-ask after an error")
            if case .refused(let refusal) = outcome { #expect(!refusal.words.contains("CANARY")) }
        }
    }

    /// The table above names every case of `LanguageModelError` in the macOS 27.2 SDK, checked against a hand list read from its
    /// `.swiftinterface` (it can't reflect over the SDK's cases). A case a later SDK adds falls to `@unknown default`, whose
    /// words are fixed ("the model failed"); add it here and to the list when the SDK grows.
    @Test func theTableHasEveryLanguageModelError() {
        let named = Set(Self.errors.compactMap { ($0.0 as? LanguageModelError).flatMap { Mirror(reflecting: $0).children.first?.label } })
        #expect(named == ["contextSizeExceeded", "rateLimited", "guardrailViolation", "refusal", "unsupportedCapability",
                          "unsupportedTranscriptContent", "unsupportedGenerationGuide", "unsupportedLanguageOrLocale", "timeout"])
    }

    @Test func cancellationIsThrownNotWorded() async throws {
        let model = StubModel([StubModel.pick(Self.see), .error(CancellationError())])
        await #expect(throws: CancellationError.self) { try await Picker.pick("migration of the devices", for: Self.full, using: model) }
    }

    /// A required field left out is thrown by the SDK as a parsing error (the shared lessons): not understood, no re-ask.
    @Test func aDroppedFieldIsNotUnderstood() async throws {
        let model = StubModel([StubModel.pick(Self.see), .json(#"{"words": "devices"}"#)])
        #expect(try await Picker.pick("migration of the devices", for: Self.full, using: model) == .refused(.notUnderstood(.unreadable)))
        #expect(model.calls.count == 2)
        // An answer that came back without its pick anyway is a fault, asked about once, named.
        let lax = StubModel([StubModel.pick(Self.see), .unchecked(#"{"words": "devices"}"#), StubModel.pick(label("report:coverage"))])
        guard case .picked(let pick) = try await Picker.pick("coverage of the devices", for: Self.full, using: lax) else {
            Issue.record("no pick after the re-ask"); return
        }
        #expect(pick.choice.id == "report:coverage")
        #expect(lax.calls[2].prompt.hasSuffix("\(ModelPicker.faultLead) \(ModelPicker.Fault.noPick.words). \(ModelPicker.faultTail)"))
        #expect(!lax.calls[1].prompt.contains(ModelPicker.faultLead))
    }

    /// A field's description written back as its value read nothing: asked again once, naming it, then refused.
    @Test func anEchoedDescriptionIsNoAnswer() async throws {
        let echo = StubModel.pick(label("report:coverage"), words: ModelPicker.wordsField.description)
        let once = StubModel([StubModel.pick(Self.see), echo, StubModel.pick(label("report:coverage"))])
        guard case .picked = try await Picker.pick("coverage of the devices", for: Self.full, using: once) else { Issue.record("no pick"); return }
        #expect(once.calls[2].prompt.contains(ModelPicker.Fault.echoed.words))
        let twice = StubModel([StubModel.pick(Self.see), echo, StubModel.pick(label("report:coverage"), words: ModelPicker.wordsField.description.uppercased() + ".")])
        #expect(try await Picker.pick("coverage of the devices", for: Self.full, using: twice) == .refused(.notUnderstood(.faultTwice)))
        #expect(twice.calls.count == 3)
        // Empty words, or words the request doesn't hold, are faults too.
        let empty = StubModel([StubModel.pick(Self.see, words: " "), StubModel.pick(Self.see, words: "nothing said here")])
        #expect(try await Picker.pick("coverage of the devices", for: Self.full, using: empty) == .refused(.notUnderstood(.faultTwice)))
        #expect(empty.calls[1].prompt.contains(ModelPicker.Fault.noWords.words))
    }

    /// A label not on the list is asked about once, then refused; code's own check refuses an id or a group not on it.
    @Test func anOffListPickIsRefused() async throws {
        let off = StubModel.Reply.unchecked(#"{"pick": "Devices out of warranty", "words": "devices"}"#)
        let model = StubModel([StubModel.pick(Self.see), off, off])
        #expect(try await Picker.pick("devices out of warranty", for: Self.full, using: model) == .refused(.notUnderstood(.faultTwice)))
        #expect(model.calls[2].prompt.contains(ModelPicker.Fault.offList.words))
        let choices = Self.full.choices
        #expect(Picker.check("report:not-a-report", group: nil, sentence: "x", against: choices, thresholds: Self.thresholds) == .refused(.notOnTheList))
        #expect(Picker.check("report:activation-lock", group: "lock:SOMEONE", sentence: "x", against: choices, thresholds: Self.thresholds) == .refused(.notOnTheList))
        #expect(Picker.check("rule:mosyle_check_in", group: nil, sentence: "x", against: Self.noMosyle.choices, thresholds: Self.thresholds) == .refused(.notOnTheList))
        #expect(Picker.check("report:coverage", group: "lock:USER", sentence: "x", against: choices, thresholds: Self.thresholds) == .refused(.notOnTheList))
        // An off-list group from the model is the same fault.
        let group = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:migration")),
                               .unchecked(#"{"pick": "status:LOST", "words": "devices"}"#), .unchecked(#"{"pick": "status:LOST", "words": "devices"}"#)])
        #expect(try await Picker.pick("failed migration of the devices", for: Self.full, using: group) == .refused(.notUnderstood(.faultTwice)))
    }

    /// A schema the SDK refuses to build (an empty list) is "not understood", with no call: `pick` throws only cancellation.
    @Test func aSchemaTheSDKWontBuildIsNotUnderstood() async throws {
        #expect(throws: (any Error).self) { try ModelPicker.schema([]) }
        let model = StubModel()
        #expect(try await ModelPicker.ask("devices", labels: [], step: .choice, using: model) == .refused(.notUnderstood(.other)))
        #expect(model.calls.isEmpty)
    }

    // MARK: what the model is given

    /// A canary sentence, and every call's words taken apart: the standing instructions, the frame's fixed words, the catalog's
    /// labels, holds lines and group summaries, and the sentence. Nothing else is left, and each prompt holds the sentence once.
    @Test func thePromptIsTheSentenceAndTheCatalogOnly() async throws {
        let sentence = "CANARY-7Q which devices have a user lock"
        let fault = StubModel.Reply.unchecked(#"{"pick": "elsewhere", "words": "devices"}"#)
        let model = StubModel([fault, StubModel.pick(Self.see), StubModel.pick(label("report:activation-lock")), StubModel.pick("user lock", words: "user")])
        _ = try await Picker.pick(sentence, for: Self.full, using: model)
        #expect(model.calls.count == 4)
        var known = [ModelPicker.choicesHeading, ModelPicker.reportHeading, ModelPicker.requestHeading,
                     ModelPicker.faultLead, ModelPicker.faultTail, ModelPicker.none, ModelPicker.all]
        known += ModelPicker.Step.allCases.map(\.task) + ModelPicker.Asks.allCases.map(\.rawValue)
        known += [ModelPicker.Fault.noPick, .offList, .noWords, .echoed, .notFromRequest].map(\.words)
        for choice in Self.full.choices { known += [choice.label] + (choice.holds.map { [$0] } ?? []) + choice.groups }
        known += ModelPicker.groupLabels.values
        // Longest first, so a label inside a holds line is taken out with its line.
        known = known.sorted { $0.count > $1.count }
        for call in model.calls {
            #expect(call.instructions == ModelPicker.instructions)
            #expect(call.prompt.components(separatedBy: sentence).count == 2, "the sentence once")
            var rest = call.prompt.replacingOccurrences(of: sentence, with: " ")
            for words in known { rest = rest.replacingOccurrences(of: words, with: " ") }
            let left = rest.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }
            #expect(left.isEmpty, Comment(rawValue: "words from nowhere: \(rest)"))
        }
        #expect(!ModelPicker.instructions.contains("\u{201C}"), "no example sentence in the instructions")
    }

    @Test func eachPickIsGreedyAndCapped() {
        #expect(ModelPicker.options == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: ModelPicker.responseCap))
        #expect(ModelPicker.responseCap <= 150)
    }

    /// The largest call, estimated without the model (CI has none): the instructions, the prompt with the longest sentence,
    /// the fault line and the largest list, the schema as JSON, at three characters a token (English runs about four), plus
    /// the response cap. The flagged run measures it with `tokenCount` (`ModelEvaluations.theWholeCallFitsTheBudget`).
    @Test func theLargestCallIsEstimatedUnderTheBudget() throws {
        let largest = try PickerTests.largestCalls()
        for (name, instructions, prompt, schema) in largest {
            let characters = instructions.count + prompt.count + String(data: try JSONEncoder().encode(schema), encoding: .utf8)!.count
            let estimate = characters / 3 + ModelPicker.responseCap
            print("BUDGET estimate \(name): \(characters) characters, about \(estimate) tokens with the cap")
            #expect(estimate <= PickerTests.budget, Comment(rawValue: name))
        }
    }

    static let budget = 1_500

    /// Each pick's largest call: the full list, a 300-character sentence, a fault line; for the group, the longest group list.
    static func largestCalls() throws -> [(String, String, String, GenerationSchema)] {
        let sentence = String(repeating: "devices ", count: Picker.longest / 8)
        let choices = full.choices
        let longestFault = [ModelPicker.Fault.noPick, .offList, .noWords, .echoed, .notFromRequest].map(\.words).max { $0.count < $1.count }!
        let groupChoice = choices.max { $0.groups.count < $1.groups.count }!
        func call(_ name: String, _ labels: [String], _ step: ModelPicker.Step, about: String? = nil, holds: [String] = []) throws -> (String, String, String, GenerationSchema) {
            (name, ModelPicker.instructions,
             ModelPicker.prompt(sentence, labels: labels, step: step, about: about, holds: holds, fault: longestFault),
             try ModelPicker.schema(labels))
        }
        return [
            try call("asks", ModelPicker.Asks.allCases.map(\.rawValue), .asks),
            try call("choice", choices.map(\.label) + [ModelPicker.none], .choice, holds: ModelPicker.holds(choices)),
            try call("group", [ModelPicker.all] + groupChoice.groups.map(ModelPicker.groupLabel), .group, about: groupChoice.label),
        ]
    }

    // MARK: no tools, no Private Cloud Compute

    /// The model gets no tools (the operator, 2026-11-24, Q3), and only the on-device model is named (D7): no source of the
    /// package, the screen models or the app names Private Cloud Compute's model, and no Assist source conforms to `Tool` or
    /// passes `tools:`.
    @Test func noToolAndNoPrivateCloudCompute() throws {
        let pcc = "PrivateCloud" + "Compute"
        for root in ["Packages/AbapitKit/Sources", "Packages/AbapitApp/Sources", "App"] {
            #expect(try SourceScan.files(in: root, matching: [pcc]).isEmpty, Comment(rawValue: root))
        }
        let assist = try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/Assist")
        #expect(assist.count >= 5, "the scan sees Assist")
        for file in assist {
            #expect(!SourceScan.names(file, ["Tool", "ToolOutput", "tools"]), Comment(rawValue: file.path))
            #expect(!SourceScan.mentions(file, ["Tool{", ":Tool", "tools:", "toolCallingMode"]), Comment(rawValue: file.path))
        }
        // The one session is made with the on-device model, and nothing else makes one.
        let sessions = assist.filter { SourceScan.mentions($0, ["LanguageModelSession("]) }
        #expect(sessions.map(\.path) == ["Packages/AbapitKit/Sources/Assist/ModelPicker.swift"])
        #expect(sessions.allSatisfy { SourceScan.mentions($0, ["LanguageModelSession(model:SystemLanguageModel.default,instructions:instructions)"]) })
        // The scan itself sees what it looks for.
        let planted = SourceScan.File(path: "x.swift", text: "struct T: Tool {}\nlet m = \(pcc)LanguageModel()")
        #expect(SourceScan.names(planted, ["Tool"]) && SourceScan.mentions(planted, [pcc]))
    }
}
