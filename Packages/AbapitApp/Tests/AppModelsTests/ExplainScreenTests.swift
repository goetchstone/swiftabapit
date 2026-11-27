import AppModels
import Assist
import Foundation
import FoundationModels
import Reports
import Testing
import TestSupport

/// A stand-in for the on-device model for the explanations: every call is recorded, and answered by `reply` from its prompt. It never
/// fails an unscripted call (a screen explains as many rules as have findings); a test that wants none asserts `prompts` is empty.
final class ExplainStub: Picker.Asking, @unchecked Sendable {
    let availability: SystemLanguageModel.Availability
    let supportsLocale = true
    private let lock = NSLock()
    private var made: [String] = []
    private let reply: @Sendable (String) -> [String]
    /// Run during the first call, before it answers: a test switches the client there.
    private let during: (@MainActor () -> Void)?

    init(availability: SystemLanguageModel.Availability = .available, during: (@MainActor () -> Void)? = nil,
         reply: @escaping @Sendable (String) -> [String] = ExplainStub.counted) {
        self.availability = availability
        self.during = during
        self.reply = reply
    }

    var prompts: [String] { lock.withLock { made } }

    func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        let first: Bool = lock.withLock {
            made.append(prompt)
            return made.count == 1
        }
        if first, let during { await during() }
        let json = try JSONSerialization.data(withJSONObject: ["sentences": reply(prompt)])
        return try GeneratedContent(json: String(decoding: json, as: UTF8.self))
    }

    /// The prompt's own count of findings, said back, and one sentence that states a number no fact holds.
    static let counted: @Sendable (String) -> [String] = { prompt in
        let line = prompt.split(separator: "\n").first { $0.hasPrefix("Findings: ") }!
        let count = Int(line.dropFirst("Findings: ".count).split(separator: ";")[0])!
        return ["The check found \(count) findings.", "It found \(count + 500) findings."]
    }
}

/// The Needs-attention screen's explanations (S9.12; the operator's Q3 "Picks + explanations", D7 and D10; the shape is the coordinating
/// session's proposal): each rule with findings explained from code's facts only, shown and never stored, dropped on a switch of client,
/// and off, said, when the model is.
@MainActor
@Suite("Needs-attention explanations", .serialized, .timeLimit(.minutes(1)))
struct ExplainScreenTests {
    static func ready(_ stub: ExplainStub) async throws -> (World, NeedsAttentionModel) {
        let world = try await NeedsAttentionTests.world()
        let model = await NeedsAttentionTests.ready(world)
        model.explainer = stub
        model.explainsOn = true
        return (world, model)
    }

    @Test func eachRuleWithFindingsIsExplainedFromItsFactsAlone() async throws {
        let stub = ExplainStub()
        let (_, model) = try await Self.ready(stub)
        let withFindings = model.lines.filter { !$0.isSkipped && !$0.findings.isEmpty }
        #expect(withFindings.count >= 3, "the world has rules to explain: \(withFindings.map(\.rule))")
        await model.explain()
        #expect(stub.prompts.count == withFindings.count, "one call per rule with findings")
        for line in model.lines {
            if withFindings.contains(where: { $0.rule == line.rule }) {
                #expect(model.explanation(line) == .shown(sentences: ["The check found \(line.findings.count) findings."], dropped: 1), Comment(rawValue: line.rule.rawValue))
            } else {
                #expect(model.explanation(line) == nil, Comment(rawValue: line.rule.rawValue))
            }
        }
        // No finding's subject or reason, and none of the world's names, reaches any prompt.
        let prompts = stub.prompts.joined(separator: "\n")
        for line in model.lines {
            for finding in line.findings {
                #expect(!prompts.contains(finding.subject), Comment(rawValue: finding.subject))
                #expect(!prompts.contains(finding.reason), Comment(rawValue: finding.reason))
            }
            for source in line.source { #expect(!prompts.contains(source), Comment(rawValue: source)) }
        }
        for canary in ["MIG0001", "ADEV000000", "MOSONLY1", "Old MDM", "S1", "S2", "example.com"] { #expect(!prompts.contains(canary), Comment(rawValue: canary)) }
        // Asked again with nothing changed, nothing is asked.
        await model.explain()
        #expect(stub.prompts.count == withFindings.count)
    }

    @Test func allDroppedShowsNoneInWords() async throws {
        let (_, model) = try await Self.ready(ExplainStub(reply: { _ in ["We fixed Contoso's devices."] }))
        await model.explain()
        let line = try #require(model.lines.first { !$0.isSkipped && !$0.findings.isEmpty })
        #expect(model.explanation(line) == .none("The on-device model's explanation didn't match this rule's facts, so none is shown."))
        #expect(NeedsAttentionModel.droppedWords(1) == "1 sentence the model wrote didn't match the facts and was left out.")
        #expect(NeedsAttentionModel.droppedWords(0) == nil)
    }

    /// The client switches while the model writes: what it wrote was for the other client's findings, so it is dropped, and the
    /// explanations held are cleared.
    @Test func aSwitchDuringTheModelCallDropsTheExplanation() async throws {
        let world = try await NeedsAttentionTests.world()
        let model = await NeedsAttentionTests.ready(world)
        let stub = ExplainStub(during: { world.orgs.select("b") })
        model.explainer = stub
        model.explainsOn = true
        let before = model.lines
        await model.explain()
        #expect(stub.prompts.count == 1, "nothing more is asked after the switch")
        world.orgs.select("a")
        let after = await NeedsAttentionTests.ready(world)
        for line in before + after.lines { #expect(after.explanation(line) == nil, Comment(rawValue: line.rule.rawValue)) }
    }

    /// Shown, never stored: not in the CSV, not in the history's kept findings, and gone when the facts change.
    @Test func anExplanationIsNeverStored() async throws {
        let stub = ExplainStub(reply: { _ in ["The check found these canaryword findings worth a look."] })
        let (world, model) = try await Self.ready(stub)
        await model.explain()
        let line = try #require(model.lines.first { !$0.isSkipped && !$0.findings.isEmpty })
        guard case .shown? = model.explanation(line) else { Issue.record("not shown: \(String(describing: model.explanation(line)))"); return }
        #expect(!model.csv().contains("canaryword"))
        let kept = try await world.history!.state(org: world.orgs.store["a"]!)
        #expect(!kept.map { "\($0.rule) \($0.subject)" }.joined().contains("canaryword"))
        model.explainsOn = false
        #expect(model.explanation(line) == nil && model.explainKey.isEmpty, "switched off, nothing is shown")
    }

    /// What is held was written from other facts once a finding is dismissed (one more hidden): not shown until explained again.
    @Test func newFactsHideTheOldExplanation() async throws {
        let stub = ExplainStub()
        let (_, model) = try await Self.ready(stub)
        await model.explain()
        let line = try #require(model.lines.first { line in !line.isSkipped && line.open.contains { $0.actionsBlocked == nil } })
        #expect(model.explanation(line) != nil)
        await model.dismiss(line.open.first { $0.actionsBlocked == nil }!)
        let now = model.lines.first { $0.rule == line.rule }!
        #expect(now.hidden == line.hidden + 1)
        #expect(model.explanation(now) == nil, "written for other counts")
        let asked = stub.prompts.count
        await model.explain()
        #expect(stub.prompts.count == asked + 1 && stub.prompts.last!.contains("dismissed or snoozed \(now.hidden) of them"))
        #expect(model.explanation(now) != nil)
    }

    @Test func theModelOffSaysWhyAsksNothingAndTheScreenWorks() async throws {
        let stub = ExplainStub(availability: .unavailable(.appleIntelligenceNotEnabled))
        let (_, model) = try await Self.ready(stub)
        let summary = model.summary?.headline
        #expect(model.explanationsOff == Explain.offWords(.unavailable(.appleIntelligenceNotEnabled)))
        #expect(model.explanationsOff?.hasPrefix("Apple Intelligence is off") == true)
        await model.explain()
        #expect(stub.prompts.isEmpty, "the model is never asked while it is off")
        #expect(model.lines.allSatisfy { model.explanation($0) == nil })
        #expect(model.summary?.headline == summary && summary != nil, "the rules, counts and findings are as before")
    }

    @Test func switchedOffNothingIsAskedOrSaid() async throws {
        let stub = ExplainStub()
        let (_, model) = try await Self.ready(stub)
        model.explainsOn = false
        await model.explain()
        #expect(stub.prompts.isEmpty && model.explanationsOff == nil && model.explainKey.isEmpty)
    }
}
