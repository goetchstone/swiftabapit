import Assist
import Foundation
import Reports

/// A question in words, asked on the Reports screen or through Siri (plan §5; the operator, 2026-11-24: Q3 "Picks + explanations",
/// Q8 "On the Reports screen"; D7 and D10: the model is on-device only and only drafts).
///
/// - **A serial first.** A sentence holding a token shaped like a serial number or an IMEI goes to `Answers.lookUp`, with no model
///   call: the picker would refuse it for its digits.
/// - **Then the picker** (`Picker.pick`): a refusal in its words, a change request in its fixed words with nothing drafted, or a
///   checked pick of a report, the Needs-attention summary or one of its rules.
/// - **Siri** (`ask`): the pick is answered through `Answers`, and the answer starts with what was understood ("I read that as: …").
/// - **The Reports screen** (`submit`, `apply`): the pick is a draft only. It is shown in words, and the report picker and its
///   filters are filled only when the operator clicks, to check and change before anything is shown. Nothing runs by itself.
@MainActor
@Observable
public final class AskModel {
    /// What a sentence was read as.
    public enum Reading: Equatable, Sendable {
        /// A token shaped like a serial number or another identifier, for the lookup.
        case serial(String)
        case picked(Picker.Pick)
        /// A request to change something: nothing is drafted.
        case changeRequest
        case refused(Refusal)
        /// The active org or client changed while the model was asked: what it picked was for the other one, so nothing is
        /// answered or drafted.
        case switched
    }

    /// A report and its filters as the Ask understood them, for the operator to check before they fill the screen.
    public struct Draft: Equatable, Sendable {
        public let report: ReportsModel.Report
        /// One of the report's groups, or nil for all of them.
        public let group: String?
        /// The report's number filter (coverage's days, fleet age's years, service health's quiet days): what the sentence said,
        /// else the report's default, so what is shown is what fills the screen. Nil for a report with none.
        public let number: Int?

        package init(report: ReportsModel.Report, group: String?, number: Int?) {
            (self.report, self.group, self.number) = (report, group, number)
        }
    }

    private let answers: Answers
    private let model: any Picker.Asking

    /// The Ask field's text. An edit clears the draft, which was the last sentence's (the coordinating session, 2026-11-27).
    public var question = "" {
        didSet { if question != oldValue { clear() } }
    }
    /// A sentence is being read.
    public private(set) var working = false
    /// The last sentence's report, once the operator may fill the screen with it.
    public private(set) var draft: Draft?
    /// What the field says about the last sentence: what it was read as, or why nothing was.
    public private(set) var said: String?

    /// Whether the screen's field cleared its draft on a switch yet: registered once, by the first `submit`, so an intent's Ask
    /// (one per request) never adds a handler.
    @ObservationIgnored private var watchesSwitches = false

    public init(answers: Answers, model: any Picker.Asking = ModelPicker.OnDevice()) {
        self.answers = answers
        self.model = model
    }

    /// No draft and nothing said: after an edit of the question, and on a switch of org or client.
    private func clear() {
        draft = nil
        said = nil
    }

    // MARK: the model's availability

    /// Why the Ask is off (each `UnavailableReason`, an unsupported language), or nil when the model can answer. The report list
    /// works either way.
    public var off: String? { Refusals.availability(of: model)?.words }

    /// The fixed Siri phrases, as said with the app's name: each is in `App/AppShortcuts.xcstrings` (a test holds them there).
    public static let sirisPhrases = [
        "Which devices are out of warranty in abapit", "Which AppleCare coverage is ending in abapit", "How old is the fleet in abapit",
        "Which devices are Activation Locked in abapit", "How is the MDM migration going in abapit",
        "How are the device management services in abapit", "What needs attention in abapit", "Look up a serial number in abapit",
    ]

    /// For Siri, with the model off: why, and the phrases that work without it.
    static func withoutTheModel(_ why: String) -> String {
        why + " You can still ask Siri: " + sirisPhrases.map { "\u{201C}\($0)\u{201D}" }.joined(separator: "; ") + "."
    }

    // MARK: reading a sentence

    /// The first token of `sentence` shaped like a serial number, an IMEI or a MEID: 8 to 20 ASCII letters and digits in one case
    /// (never "iPhone15Pro"), with letters before digits ("C02…", "W8…") and never only digits then letters ("1825days", "90days"),
    /// and never ending in a unit word after its last digit ("within90days", "applecare2years"; the coordinating session,
    /// 2026-11-27), or 14 to 17 digits alone. Punctuation around it is dropped. Known false positives, a glued word and number
    /// such as "macbookair2020" or "FY2025Q4", are a lookup that says so first and finds nothing.
    public static func serial(in sentence: String) -> String? {
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            let token = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard (8...20).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            let digits = token.filter(\.isNumber).count
            if digits == token.count {
                if (14...17).contains(digits) { return token }
                continue
            }
            guard digits > 0, token.uppercased() == token || token.lowercased() == token else { continue }
            let tail = String(token.reversed().prefix(while: \.isLetter).reversed()).lowercased()
            if units.contains(tail) { continue }
            var switches = 0, previous: Bool?
            for character in token {
                if let previous, previous != character.isNumber { switches += 1 }
                previous = character.isNumber
            }
            // Only digits then letters is a number with its unit glued on, not an identifier.
            if switches >= 2 || (switches == 1 && token.first?.isLetter == true) { return token }
        }
        return nil
    }

    /// The unit words a token may end in after its digits: a number of days, weeks, years or months glued on, never a serial.
    static let units: Set = ["day", "days", "week", "weeks", "wk", "wks", "year", "years", "yr", "yrs", "month", "months", "mo", "mos"]

    /// Words a lookup's sentence may hold besides the serial without asking anything more.
    static let filler: Set = ["look", "up", "lookup", "find", "search", "for", "serial", "number", "no", "imei", "meid", "identifier", "id",
                              "the", "a", "an", "this", "that", "device", "devices", "which", "what", "where", "is", "it", "show", "me",
                              "please", "check", "in", "abapit", "of", "with", "has", "have", "where's", "where\u{2019}s", "wheres", "whereis"]

    /// Said after a lookup when the sentence held more than the serial and filler (the coordinating session, 2026-11-27).
    public static let onlyTheLookUp = "Only the serial lookup was run; the rest of the question wasn't read."

    /// Whether `sentence` holds words besides `serial` and `filler`.
    static func asksMore(_ sentence: String, serial: String) -> Bool {
        sentence.split(whereSeparator: \.isWhitespace).contains { word in
            let token = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard !token.isEmpty, token != serial else { return false }
            return !filler.contains(token.lowercased())
        }
    }

    /// What `sentence` is read as: a serial with no model call, else the picker's outcome, or `switched` when the org or client
    /// changed while the model was asked. Throws only `CancellationError`.
    public func read(_ sentence: String) async throws -> Reading {
        if let serial = Self.serial(in: Picker.tidy(sentence)) { return .serial(serial) }
        let generation = answers.generation
        let outcome = try await Picker.pick(sentence, for: answers.assistClient, using: model)
        guard answers.generation == generation else { return .switched }
        switch outcome {
        case .picked(let pick): return .picked(pick)
        case .changeRequest: return .changeRequest
        case .refused(let refusal): return .refused(refusal)
        }
    }

    /// The report a pick of a report stands for, with its number filled (the sentence's, else the default).
    static func draft(_ pick: Picker.Pick) -> Draft? {
        guard case .report(let id) = pick.choice.kind, let report = ReportsModel.Report(rawValue: id.rawValue) else { return nil }
        let number: Int? = switch report {
        case .coverage: pick.tokens["days"].flatMap(Int.init) ?? ReportsModel.defaultCoverageDays
        case .fleetAge: pick.tokens["years"].flatMap(Int.init) ?? ReportsModel.defaultFleetYears
        case .serviceHealth: pick.tokens["days"].flatMap(Int.init) ?? ReportsModel.defaultQuietDays
        default: nil
        }
        return Draft(report: report, group: pick.group, number: number)
    }

    /// What was understood, said first: "I read that as: <report>, <group>", with the number for a report that takes one.
    static func understood(_ reading: Reading) -> String? {
        switch reading {
        case .serial: return "I read that as: Serial lookup, for the identifier given."
        case .changeRequest, .refused, .switched: return nil
        case .picked(let pick):
            switch pick.choice.kind {
            case .attentionSummary: return "I read that as: \(Choices.summaryLabel), every rule."
            case .rule: return "I read that as: \(Choices.summaryLabel), \(pick.choice.label)."
            case .report:
                guard let draft = draft(pick) else { return nil }
                return "I read that as: " + words(draft) + "."
            }
        }
    }

    /// A draft in words: the report, its group (or all of them) when it has groups, and its number.
    static func words(_ draft: Draft) -> String {
        var parts = [draft.report.title]
        if ReportCatalog.entry(draft.report.catalogID).filters.contains(where: { $0.name == "group" }) {
            parts.append(draft.group.map { "the group \($0)" } ?? "all groups")
        }
        if let number = draft.number {
            switch draft.report {
            case .coverage: parts.append("ending within \(number) days")
            case .fleetAge: parts.append("\(number) or more years old")
            case .serviceHealth: parts.append("quiet after \(number) days")
            default: break
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Siri

    /// `question` answered through `Answers`, what was understood first. A change request drafts nothing and says so; a refusal is
    /// its words, and with the model off, the Siri phrases that work without it.
    public func ask(_ question: String) async -> Answers.Answer {
        let title = "Ask"
        let reading: Reading
        do { reading = try await read(question) } catch { return Answers.Answer(lead: title, spoken: Answers.Phrase.cancelled, rows: [], capNote: nil, estimateNote: nil) }
        let answer: Answers.Answer
        switch reading {
        case .changeRequest:
            return Answers.Answer(lead: title, spoken: Picker.changeRequestWords, rows: [], capNote: nil, estimateNote: nil)
        case .refused(let refusal):
            let words = switch refusal {
            case .unavailable, .unsupportedLocale: Self.withoutTheModel(refusal.words)
            default: refusal.words
            }
            return Answers.Answer(lead: title, spoken: words, rows: [], capNote: nil, estimateNote: nil)
        case .switched:
            return Answers.Answer(lead: title, spoken: Answers.Phrase.switched, rows: [], capNote: nil, estimateNote: nil)
        case .serial(let serial):
            let found = await answers.lookUp(serial: serial)
            guard Self.asksMore(Picker.tidy(question), serial: serial) else { answer = found; break }
            answer = Answers.Answer(lead: found.lead, spoken: found.spoken + " " + Self.onlyTheLookUp, rows: found.rows, capNote: found.capNote,
                                    estimateNote: found.estimateNote, rowsNote: found.rowsNote)
        case .picked(let pick):
            switch pick.choice.kind {
            case .report(let id):
                guard let report = ReportsModel.Report(rawValue: id.rawValue) else {
                    return Answers.Answer(lead: title, spoken: Refusal.notOnTheList.words, rows: [], capNote: nil, estimateNote: nil)
                }
                answer = await answers.answer(report: report, tokens: pick.tokens)
            case .attentionSummary, .rule:
                answer = await answers.attention()
            }
        }
        guard let understood = Self.understood(reading) else { return answer }
        var said = Answers.Answer(lead: answer.lead, spoken: understood + " " + answer.spoken, rows: answer.rows, capNote: answer.capNote,
                                  estimateNote: answer.estimateNote)
        said.rowsNote = answer.rowsNote
        return said
    }

    // MARK: the Reports screen

    /// Reads the field's sentence and says what it was read as; a report is kept as a draft for `apply`. Runs nothing: a serial
    /// is pointed to the Devices screen's Find, and Needs attention to its own screen.
    public func submit() async {
        guard !working, off == nil else { return }
        if !watchesSwitches {
            watchesSwitches = true
            answers.onSwitch { [weak self] in self?.clear() }
        }
        working = true
        defer { working = false }
        clear()
        let asked = question
        let reading: Reading
        do { reading = try await read(asked) } catch { return }
        // Edited while the model was asked: the answer is to a sentence no longer in the field.
        guard question == asked else { return }
        switch reading {
        case .switched:
            said = Answers.Phrase.switched
        case .serial:
            said = "That looks like a serial number or another identifier: find it on the Devices screen. Nothing was run."
        case .changeRequest:
            said = Picker.changeRequestWords
        case .refused(let refusal):
            said = refusal.words
        case .picked(let pick):
            let understood = Self.understood(reading) ?? ""
            if let made = Self.draft(pick) {
                draft = made
                said = understood + " Check it, then fill the report with it."
            } else {
                said = understood + " Needs attention has its own screen in the sidebar. Nothing was run."
            }
        }
    }

    /// Fills the report picker and its filters with the draft, for the operator to check and change: the operator's click.
    public func apply(to reports: ReportsModel) {
        guard let draft else { return }
        reports.select(draft.report)
        reports.setGroup(draft.group)
        if let number = draft.number {
            switch draft.report {
            case .coverage: reports.coverageDays = number
            case .fleetAge: reports.fleetYears = number
            case .serviceHealth: reports.quietDays = number
            default: break
            }
        }
        self.draft = nil
        said = nil
    }
}
