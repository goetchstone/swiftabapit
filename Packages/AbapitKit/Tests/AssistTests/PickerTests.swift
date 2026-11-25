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
        let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:activation-lock")), StubModel.pick("lock:USER")])
        let outcome = try await Picker.pick("devices with a user's Activation Lock", for: Self.full, using: model)
        let choice = Self.full.choices.first { $0.id == "report:activation-lock" }!
        #expect(outcome == .picked(Picker.Pick(choice: choice, group: "lock:USER", tokens: ["group": "lock:USER"], problems: [])))
        #expect(model.calls.count == 3)
        let schemas = try model.calls.map { try StubModel.shape($0.schema) }
        #expect(schemas[1].enums["pick"] == Self.full.choices.map(\.label) + [ModelPicker.none])
        #expect(schemas[2].enums["pick"] == choice.groups + [ModelPicker.all])
        #expect(schemas.allSatisfy { $0.required == ["pick", "words"] })
    }

    @Test func allIsEveryGroup() async throws {
        let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:migration")), StubModel.pick(ModelPicker.all)])
        guard case .picked(let pick) = try await Picker.pick("the migration of the devices", for: Self.full, using: model) else {
            Issue.record("no pick"); return
        }
        #expect(pick.choice.id == "report:migration" && pick.group == nil && pick.tokens.isEmpty && pick.problems.isEmpty)
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

    /// Numbers come from code's parse of the sentence, and the catalog takes or refuses them; the model is never asked one.
    @Test func numbersComeFromTheSentence() async throws {
        func picked(_ sentence: String, _ id: String) async throws -> Picker.Pick? {
            let model = StubModel([StubModel.pick(Self.see), StubModel.pick(label(id))])
            if case .picked(let pick) = try await Picker.pick(sentence, for: Self.full, using: model) { return pick }
            return nil
        }
        #expect(try await picked("devices whose AppleCare ends within 45 days", "report:coverage")?.tokens == ["days": "45"])
        #expect(try await picked("devices whose AppleCare ends in 2 weeks", "report:coverage")?.tokens == ["days": "14"])
        #expect(try await picked("devices 4 years old or more", "report:fleet-age")?.tokens == ["years": "4"])
        #expect(try await picked("devices 4 years old", "report:coverage")?.tokens == [:], "years are no filter of coverage")
        let far = try await picked("devices whose AppleCare ends within 4000 days", "report:coverage")
        #expect(far?.tokens == [:] && far?.problems == ["days must be a whole number of days from 1 to 1825"])
        let twice = try await picked("devices ending in 30 days or 60 days", "report:coverage")
        #expect(twice?.tokens == [:] && twice?.problems.first?.contains("more than once") == true)
        #expect(try await picked("devices ending in 30 days, so 30 days", "report:coverage")?.tokens == ["days": "30"])
        #expect(try await picked("devices with rules for 12 days", "rule:firewall_off")?.tokens == [:], "a rule's window is its own")
        // The model's schemas never hold a number.
        #expect(Picker.numbers(in: "in 3 months, 10 devices, 90-day, 1 year") == ["days": [90], "years": [1]])
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
            let outcome = try await Picker.pick("migration of the devices", for: Self.full, using: model)
            #expect(outcome == .refused(.notUnderstood(why)), Comment(rawValue: "\(error) at pick \(replies.count + 1)"))
            #expect(model.calls.count == replies.count + 1, "no re-ask after an error")
            if case .refused(let refusal) = outcome { #expect(!refusal.words.contains("CANARY")) }
        }
    }

    /// Every case of `LanguageModelError` in this SDK is in the table above, so a new one fails here first.
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
        #expect(Picker.check("report:not-a-report", group: nil, sentence: "x", against: choices) == .refused(.notOnTheList))
        #expect(Picker.check("report:activation-lock", group: "lock:SOMEONE", sentence: "x", against: choices) == .refused(.notOnTheList))
        #expect(Picker.check("rule:mosyle_check_in", group: nil, sentence: "x", against: Self.noMosyle.choices) == .refused(.notOnTheList))
        #expect(Picker.check("report:coverage", group: "lock:USER", sentence: "x", against: choices) == .refused(.notOnTheList))
        // An off-list group from the model is the same fault.
        let group = StubModel([StubModel.pick(Self.see), StubModel.pick(label("report:migration")),
                               .unchecked(#"{"pick": "status:LOST", "words": "devices"}"#), .unchecked(#"{"pick": "status:LOST", "words": "devices"}"#)])
        #expect(try await Picker.pick("migration of the devices", for: Self.full, using: group) == .refused(.notUnderstood(.faultTwice)))
    }

    // MARK: what the model is given

    /// A canary sentence, and every call's words taken apart: the standing instructions, the frame's fixed words, the catalog's
    /// labels, holds lines and group summaries, and the sentence. Nothing else is left, and each prompt holds the sentence once.
    @Test func thePromptIsTheSentenceAndTheCatalogOnly() async throws {
        let sentence = "CANARY-7Q which devices have a user lock"
        let fault = StubModel.Reply.unchecked(#"{"pick": "elsewhere", "words": "devices"}"#)
        let model = StubModel([fault, StubModel.pick(Self.see), StubModel.pick(label("report:activation-lock")), StubModel.pick("lock:USER")])
        _ = try await Picker.pick(sentence, for: Self.full, using: model)
        #expect(model.calls.count == 4)
        var known = [ModelPicker.choicesHeading, ModelPicker.reportHeading, ModelPicker.groupsHeading, ModelPicker.requestHeading,
                     ModelPicker.faultLead, ModelPicker.faultTail, ModelPicker.none, ModelPicker.all]
        known += ModelPicker.Step.allCases.map(\.task) + ModelPicker.Asks.allCases.map(\.rawValue)
        known += [ModelPicker.Fault.noPick, .offList, .noWords, .echoed, .notFromRequest].map(\.words)
        for choice in Self.full.choices { known += [choice.label] + (choice.holds.map { [$0] } ?? []) + choice.groups }
        for entry in ReportCatalog.entries { known += entry.filters.map(\.summary) }
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
            try call("group", groupChoice.groups + [ModelPicker.all], .group, about: groupChoice.label, holds: ModelPicker.groupHolds(groupChoice)),
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
