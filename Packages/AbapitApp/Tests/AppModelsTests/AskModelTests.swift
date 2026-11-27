import AppleModels
import AppModels
import Assist
import Foundation
import FoundationModels
import JSONAPI
import Reports
import Testing
import TestSupport

/// A strict stand-in for the on-device model, for the Ask: each call takes the next scripted reply, a call with none fails the test
/// (so a test with none scripted proves the model was never asked), and its availability and language are set per test.
final class AskStub: Picker.Asking, @unchecked Sendable {
    let availability: SystemLanguageModel.Availability
    let supportsLocale: Bool
    private let lock = NSLock()
    private var replies: [String]
    private var made = 0

    init(_ replies: [String] = [], availability: SystemLanguageModel.Availability = .available, supportsLocale: Bool = true) {
        self.replies = replies
        self.availability = availability
        self.supportsLocale = supportsLocale
    }

    var calls: Int { lock.withLock { made } }
    var unused: Int { lock.withLock { replies.count } }

    enum Unscripted: Error { case call }

    func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        let reply: String? = lock.withLock {
            made += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else {
            Issue.record("an unscripted call to the model")
            throw Unscripted.call
        }
        return try GeneratedContent(json: reply)
    }

    /// The model's two picks for a report question: see, then the report by its label.
    static func reads(_ label: String, words: String) -> [String] {
        [#"{"pick": "See or list something", "words": "\#(words)"}"#, #"{"pick": "\#(label)", "words": "\#(words)"}"#]
    }
}

/// The Ask (S9.7; the operator, 2026-11-24: Q3 "Picks + explanations", Q8 "On the Reports screen"; D7 and D10, on-device only and
/// drafts only): a serial goes to the lookup before any model call; a change request drafts nothing; Siri's answer says what was
/// understood first; the Reports screen's field only drafts, and fills the screen on the operator's click; with the model off, each
/// reason is worded in the field and in Siri's answer, which names the fixed phrases.
@MainActor
@Suite("Ask", .serialized, .timeLimit(.minutes(1)))
struct AskModelTests {
    static let question = "which devices are out of warranty"

    static func world() async throws -> World {
        let world = try await AnswersTests.world()
        try await AnswersTests.snapshot(world)
        _ = AnswersTests.answers(world, fixed: true)
        return world
    }

    // MARK: the model's availability

    static let reasons: [(SystemLanguageModel.Availability, Bool, Refusal)] = [
        (.unavailable(.deviceNotEligible), true, .unavailable(.deviceNotEligible)),
        (.unavailable(.appleIntelligenceNotEnabled), true, .unavailable(.appleIntelligenceNotEnabled)),
        (.unavailable(.modelNotReady), true, .unavailable(.modelNotReady)),
        (.available, false, .unsupportedLocale),
    ]

    /// Each reason the model can't answer is worded, in the field and in Siri's answer, which also names the fixed phrases; the model
    /// is never asked, and the field drafts nothing.
    @Test func eachAvailabilityStateIsWorded() async throws {
        let world = try await Self.world()
        var said: Set<String> = []
        for (availability, locale, refusal) in Self.reasons {
            let stub = AskStub(availability: availability, supportsLocale: locale)
            let ask = AskModel(answers: world.screens.answers, model: stub)
            #expect(ask.off == refusal.words, "\(refusal)")
            said.insert(try #require(ask.off))
            let answer = await ask.ask(Self.question)
            #expect(answer.spoken.hasPrefix(refusal.words), "\(answer.spoken)")
            for phrase in AskModel.sirisPhrases { #expect(answer.spoken.contains("\u{201C}\(phrase)\u{201D}"), "\(phrase)") }
            ask.question = Self.question
            await ask.submit()
            #expect(ask.draft == nil && ask.said == nil)
            #expect(stub.calls == 0)
        }
        #expect(said.count == Self.reasons.count, "each reason has its own words")
        #expect(AskModel(answers: world.screens.answers, model: AskStub()).off == nil)
    }

    /// The phrases Siri's answer names are the catalog's, as said with the app's name.
    @Test func theNamedPhrasesAreInTheCatalog() throws {
        let data = try Data(contentsOf: Fixtures.repoRoot.appending(path: "App/AppShortcuts.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set((catalog["strings"] as? [String: Any] ?? [:]).keys)
        #expect(AskModel.sirisPhrases.count == 8)
        for phrase in AskModel.sirisPhrases {
            #expect(phrase.hasSuffix(" in abapit"))
            #expect(keys.contains(String(phrase.dropLast("abapit".count)) + "${applicationName}"), "\(phrase)")
        }
    }

    // MARK: a change request

    /// A request to change something is answered with the picker's fixed words, and nothing is drafted or filled.
    @Test func aChangeRequestDraftsNothing() async throws {
        let world = try await Self.world()
        let change = #"{"pick": "Change something", "words": "wipe the old laptops"}"#
        let siri = AskStub([change])
        let answer = await AskModel(answers: world.screens.answers, model: siri).ask("wipe the old laptops")
        #expect(answer.spoken == Picker.changeRequestWords && answer.rows.isEmpty, "\(answer.spoken)")
        #expect(siri.calls == 1 && siri.unused == 0)
        let field = AskModel(answers: world.screens.answers, model: AskStub([change]))
        field.question = "wipe the old laptops"
        await field.submit()
        #expect(field.draft == nil && field.said == Picker.changeRequestWords)
        field.apply(to: world.screens.reports)
        #expect(world.screens.reports.report == .coverage, "nothing was filled")
    }

    // MARK: what was understood

    /// Siri's answer starts with what was understood, then is `Answers`' own answer, word for word (the client's name after it).
    @Test func theUnderstoodLineComesFirst() async throws {
        let world = try await Self.world()
        let answers = world.screens.answers
        let direct = await answers.answer(report: .outOfWarranty, tokens: [:])
        let stub = AskStub(AskStub.reads("Out of warranty", words: "out of warranty"))
        let answer = await AskModel(answers: answers, model: stub).ask(Self.question)
        let line = "I read that as: Out of warranty, all groups."
        #expect(answer.spoken == line + " " + direct.spoken, "\(answer.spoken)")
        #expect(answer.rows == direct.rows && answer.rowsNote == direct.rowsNote && answer.lead == direct.lead)
        // A report that takes a number says it, the sentence's or the default.
        let coverage = AskStub(AskStub.reads("AppleCare coverage ending", words: "AppleCare ends"))
        let ending = await AskModel(answers: answers, model: coverage).ask("devices whose AppleCare ends within 45 days")
        #expect(ending.spoken.hasPrefix("I read that as: AppleCare coverage ending, ending within 45 days. "), "\(ending.spoken)")
        // The summary and a rule: Needs attention.
        let summary = AskStub(AskStub.reads("Needs attention", words: "needs attention"))
        let attention = await AskModel(answers: answers, model: summary).ask("what needs attention")
        #expect(attention.spoken.hasPrefix("I read that as: Needs attention, every rule. "), "\(attention.spoken)")
        #expect(attention.spoken.contains("open finding"), "\(attention.spoken)")
        let rule = try #require(answers.assistClient?.choices.first { if case .rule = $0.kind { true } else { false } })
        let one = await AskModel(answers: answers, model: AskStub(AskStub.reads(rule.label, words: rule.label))).ask(rule.label)
        #expect(one.spoken.hasPrefix("I read that as: Needs attention, \(rule.label). "), "\(one.spoken)")
        #expect(one.spoken.contains("open finding"), "\(one.spoken)")
    }

    // MARK: a serial

    /// A sentence holding a serial goes to the lookup, with no model call (the stub has nothing scripted: a call fails the test).
    @Test func aSerialGoesToTheLookUpWithNoModelCall() async throws {
        let world = try await Self.world()
        let answers = world.screens.answers
        let stub = AskStub()
        let ask = AskModel(answers: answers, model: stub)
        let answer = await ask.ask("look up ADEV0000001 please")
        let direct = await answers.lookUp(serial: "ADEV0000001")
        #expect(answer.spoken == "I read that as: Serial lookup, for the identifier given. " + direct.spoken, "\(answer.spoken)")
        #expect(answer.rows.map(\.serial) == ["ADEV0000001"] && !answer.spoken.contains("ADEV"))
        // With the model off too: the lookup needs none.
        let off = await AskModel(answers: answers, model: AskStub(availability: .unavailable(.modelNotReady))).ask("where is ADEV0000001?")
        #expect(off.rows.map(\.serial) == ["ADEV0000001"])
        // On the Reports screen it runs nothing and drafts nothing.
        ask.question = "ADEV0000001"
        await ask.submit()
        #expect(ask.draft == nil && ask.said?.contains("Devices screen") == true)
        #expect(stub.calls == 0)
    }

    @Test(arguments: [
        ("look up C02ZX1ABJG5H", "C02ZX1ABJG5H"), ("serial xg7hq2kd9v?", "xg7hq2kd9v"), ("imei 356938035643809.", "356938035643809"),
        ("\u{201C}ADEV0000001\u{201D}", "ADEV0000001"),
    ])
    func aSerialIsFound(_ sentence: String, _ serial: String) {
        #expect(AskModel.serial(in: sentence) == serial)
    }

    @Test(arguments: ["devices older than 1825days", "which iPhone15Pro are locked", "AppleCare ending in 90 days", "at 3pm",
                      "out of warranty", "devices 14in or larger", "1234567"])
    func noSerialIsFound(_ sentence: String) {
        #expect(AskModel.serial(in: sentence) == nil)
    }

    // MARK: the Reports screen

    /// The field drafts: it says what it understood and fills nothing until the operator applies it; then the picker and filters
    /// hold the draft, to check and change.
    @Test func theFieldDraftsAndFillsOnlyOnTheOperatorsClick() async throws {
        let world = try await Self.world()
        let reports = world.screens.reports
        let ask = AskModel(answers: world.screens.answers, model: AskStub(AskStub.reads("AppleCare coverage ending", words: "AppleCare ends")))
        ask.question = "devices whose AppleCare ends within 45 days"
        await ask.submit()
        #expect(ask.draft == AskModel.Draft(report: .coverage, group: nil, number: 45))
        #expect(ask.said?.hasPrefix("I read that as: AppleCare coverage ending, ending within 45 days.") == true, "\(ask.said ?? "")")
        #expect(reports.coverageDays == ReportsModel.defaultCoverageDays, "nothing is filled before the click")
        ask.apply(to: reports)
        #expect(reports.report == .coverage && reports.coverageDays == 45 && ask.draft == nil)

        let lock = AskModel(answers: world.screens.answers, model: AskStub(AskStub.reads("Activation Lock", words: "Activation Lock")))
        lock.question = "Activation Lock"
        await lock.submit()
        #expect(lock.draft == AskModel.Draft(report: .activationLock, group: nil, number: nil))
        #expect(reports.report == .coverage)
        lock.apply(to: reports)
        #expect(reports.report == .activationLock && reports.group == nil)

        // Needs attention isn't a report here: said, nothing drafted.
        let attention = AskModel(answers: world.screens.answers, model: AskStub(AskStub.reads("Needs attention", words: "needs attention")))
        attention.question = "what needs attention"
        await attention.submit()
        #expect(attention.draft == nil && attention.said?.hasPrefix("I read that as: Needs attention, every rule.") == true)
    }

    // MARK: the follow-ups

    /// The history's still-reading words follow the wait's bound, never a number written in.
    @Test func theHistorysWaitIsTheBound() {
        #expect(Answers.Phrase.historyStillReading(after: .seconds(7)).contains("after 7 seconds"))
        #expect(Answers.Phrase.historyStillReading().contains("after \(LiveWait.bound.components.seconds) seconds"))
    }

    /// Migration with no group shows a device past the deadline whose status is unknown too, and the note says so.
    @Test func migrationsNoteCoversAStatusUnknown() async throws {
        let world = try await AnswersTests.world(devices: 0, mosyle: false)
        var attributes = NeedsAttentionTests.migrating("ADEV0000998", deadlineInDays: -5).attributes
        attributes["mdmMigrationStatus"] = nil
        world.stubs["a"]!.add(devices: [Resource(type: "orgDevices", id: "ADEV0000998", attributes: attributes),
                                        NeedsAttentionTests.migrating("ADEV0000100", deadlineInDays: 30)])
        let answer = await AnswersTests.answers(world, fixed: true).answer(report: .migration, tokens: [:])
        #expect(answer.rows.map(\.serial) == ["ADEV0000998"], "\(answer.rows) \(answer.spoken)")
        #expect(answer.rowsNote == Answers.shownPastDue)
        #expect(Answers.shownPastDue.contains("whose status is unknown"), "\(Answers.shownPastDue)")
    }
}
