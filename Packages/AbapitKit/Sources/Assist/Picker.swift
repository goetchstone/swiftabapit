import Foundation
import FoundationModels
import Reports

/// A person's sentence onto one choice of `Choices` and its group (the operator, 2026-11-24, Q3 "Picks + explanations": the
/// model maps the sentence onto a report or rule and its group from a run-time list, code checks every pick, the model gets no
/// tools). It returns a pick and runs nothing: the caller resolves and builds the report through the catalog, as the Reports
/// screen does. Numbers come from code's parse of the sentence, never from the model.
///
/// The steps: the refusals found before any call (`Refusals.before`), then the model's picks (`ModelPicker`), then code's
/// check of the pick against the list it was given (`check`).
public enum Picker {
    /// The longest sentence read, in characters: a question, not a document. A longer one is refused, never cut.
    public static let longest = 300

    /// What code says to a request to change something.
    public static let changeRequestWords = "This version only reads; nothing was drafted."

    /// The open client, as Assist needs it: no list data, only what decides the list (`Choices.build`).
    public struct Client: Sendable, Equatable {
        public let scope: Choices.Scope
        public let hasMosyle: Bool
        public let thresholds: NeedsAttention.Thresholds

        public init(scope: Choices.Scope, hasMosyle: Bool, thresholds: NeedsAttention.Thresholds) {
            self.scope = scope
            self.hasMosyle = hasMosyle
            self.thresholds = thresholds
        }

        public var choices: [Choices.Choice] { Choices.build(scope: scope, hasMosyle: hasMosyle, thresholds: thresholds) }
    }

    /// A checked pick: a choice on this client's list, and for a report its tokens as the catalog resolved them. A sentence
    /// whose number can't be taken as said is refused (`Refusal.numbers`), never picked with the default window (the
    /// coordinating session's decision, 2026-11-25).
    public struct Pick: Sendable, Equatable {
        public let choice: Choices.Choice
        /// One of the choice's groups, or nil for all of them (and for a choice with none).
        public let group: String?
        /// For a report: the group and any number the sentence holds, as `ReportCatalog.resolve` took them.
        public let tokens: [String: String]
    }

    public enum Outcome: Sendable, Equatable {
        case picked(Pick)
        /// A request to change something: nothing is drafted in this version (`changeRequestWords`).
        case changeRequest
        case refused(Refusal)
    }

    /// Asks a model for one guided answer in a fresh session: the on-device model (`ModelPicker.OnDevice`), or a stub in tests.
    /// It is given the standing instructions, the prompt and the answer's schema, and nothing else: no tools, no transcript.
    public protocol Asking: Sendable {
        var availability: SystemLanguageModel.Availability { get }
        var supportsLocale: Bool { get }
        func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent
    }

    /// The sentence as it is read: one line, trimmed.
    public static func tidy(_ sentence: String) -> String {
        sentence.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `sentence` onto one of `client`'s choices. Throws only `CancellationError`; every other failure is a refusal in words.
    public static func pick(_ sentence: String, for client: Client?, using model: some Asking) async throws -> Outcome {
        let request = tidy(sentence)
        if let refusal = Refusals.before(request, client: client, model: model) { return .refused(refusal) }
        guard let client else { return .refused(.noClient) }
        let choices = client.choices
        switch try await ModelPicker.run(request, choices: choices, using: model) {
        case .changeRequest: return .changeRequest
        case .refused(let refusal): return .refused(refusal)
        case .picked(let id, let group): return check(id, group: group, sentence: request, against: choices, thresholds: client.thresholds)
        }
    }

    /// The pick held to the list: an id not on it, or a group the choice doesn't have, is refused, never matched to something
    /// near it. A number the sentence gives is held to the choice: a report's number filter takes it (resolved by the catalog),
    /// a rule's window must be it, and a choice that takes no number ignores it. A number that can't be taken as said is a
    /// problem, and any problem refuses the pick in its words.
    static func check(_ id: String, group: String?, sentence: String, against choices: [Choices.Choice],
                      thresholds: NeedsAttention.Thresholds) -> Outcome {
        guard let choice = choices.first(where: { $0.id == id }) else { return .refused(.notOnTheList) }
        if let group, !choice.groups.contains(group) { return .refused(.notOnTheList) }
        let said = numbers(in: sentence)
        switch choice.kind {
        case .attentionSummary:
            return .picked(Pick(choice: choice, group: nil, tokens: [:]))
        case .rule(let rule):
            guard let window = window(rule, thresholds) else { return .picked(Pick(choice: choice, group: nil, tokens: [:])) }
            var problems = said.problems
            for (unit, values) in said.values.sorted(by: { $0.key < $1.key }) where unit != "days" || values.contains(where: { $0 != String(window) }) {
                problems.append("\(choice.label) has a window of \(window) days; the sentence gives " + values.map { "\($0) \(unit)" }.joined(separator: ", ") + ".")
            }
            return problems.isEmpty ? .picked(Pick(choice: choice, group: nil, tokens: [:])) : .refused(.numbers(problems))
        case .report(let report):
            var tokens: [String: String] = [:]
            if let group { tokens["group"] = group }
            let filters = ReportCatalog.entry(report).filters.filter(\.isNumber).map(\.name)
            guard !filters.isEmpty else { return .picked(Pick(choice: choice, group: group, tokens: tokens)) }
            var problems = said.problems
            for (unit, values) in said.values.sorted(by: { $0.key < $1.key }) {
                if !filters.contains(unit) {
                    problems.append("\(choice.label) takes \(filters.joined(separator: " or ")), not \(unit).")
                } else if Set(values).count > 1 {
                    problems.append("The sentence gives \(unit) more than once: " + values.joined(separator: ", ") + ".")
                } else {
                    tokens[unit] = values[0]
                }
            }
            let resolved = ReportCatalog.resolve(report, tokens: tokens)
            problems += resolved.problems
            return problems.isEmpty ? .picked(Pick(choice: choice, group: group, tokens: resolved.tokens)) : .refused(.numbers(problems))
        }
    }

    /// A rule's window in days, from the client's thresholds; nil for a rule with none.
    static func window(_ rule: NeedsAttention.Rule, _ thresholds: NeedsAttention.Thresholds) -> Int? {
        switch rule {
        case .appleCareExpiring: min(thresholds.appleCareExpiringDays, CoverageReport.maximumDays)
        case .mosyleCheckIn, .appleMDMCheckIn: thresholds.checkInDays
        case .quietService: thresholds.quietServiceDays
        case .migrationDeadline: thresholds.migrationDeadlineDays
        default: nil
        }
    }

    /// The numbers a sentence gives, as code reads them: plain digits before a unit word.
    struct Said: Equatable {
        /// By filter name (`days`, `years`), each value as its digits (any length: the catalog's bounds refuse what's too big).
        var values: [String: [String]] = [:]
        /// What can't be taken as said, in words.
        var problems: [String] = []
    }

    static let units: [String: String] = ["day": "days", "days": "days", "week": "weeks", "weeks": "weeks", "year": "years",
                                          "years": "years", "month": "months", "months": "months"]
    /// Characters that make a number more than plain digits: a decimal point, a thousands comma, a minus sign or a range dash.
    static let joiners: Set<Character> = [".", ",", "-", "\u{2212}", "\u{2013}"]

    /// The numbers the sentence gives in days, weeks (seven days each) or years. A number written with a joiner ("1.5 years",
    /// "-30 days", "30-60 days", "1,000 days"), a number glued to letters that aren't a unit ("90d"), months (their days vary)
    /// and a unit word with no number in digits ("two weeks", "a year") are problems, never a value. A number with no unit
    /// after it is no filter. "90-day" is 90 days: a hyphen between the digits and the unit is not a joiner.
    static func numbers(in sentence: String) -> Said {
        let text = Array(sentence.lowercased())
        var said = Said(), used: Set<Int> = []
        func letters(from start: Int) -> (word: String, end: Int) {
            var end = start
            while end < text.count, text[end].isLetter { end += 1 }
            return (String(text[start..<end]), end)
        }
        var index = 0
        while index < text.count {
            guard text[index].isASCII, text[index].isNumber else { index += 1; continue }
            // The cluster: digits and joiners around them.
            var start = index, end = index
            while start > 0, joiners.contains(text[start - 1]) || (text[start - 1].isASCII && text[start - 1].isNumber) { start -= 1 }
            while end < text.count, joiners.contains(text[end]) || (text[end].isASCII && text[end].isNumber) { end += 1 }
            // A hyphen right before letters joins the number to its unit ("90-day"); sentence punctuation after it ends it.
            var tail = end
            if tail > index, text[tail - 1] == "-", tail < text.count, text[tail].isLetter { tail -= 1 }
            while tail > index, [".", ","].contains(text[tail - 1]), tail == text.count || text[tail].isWhitespace { tail -= 1 }
            let cluster = String(text[start..<tail])
            index = end
            var next = end, glued = false
            if tail + 1 == end, text[tail] == "-" {
                // "90-day": the hyphen joins the number to the word after it.
            } else if tail == end, end < text.count, text[end].isLetter {
                glued = true
            } else {
                while next < text.count, text[next].isWhitespace { next += 1 }
            }
            let (word, wordEnd) = next < text.count && text[next].isLetter ? letters(from: next) : ("", next)
            guard let unit = units[word] else {
                if glued, !word.isEmpty { said.problems.append("\u{201C}\(cluster)\(word)\u{201D} isn't a number of days, weeks or years abapit reads.") }
                continue
            }
            used.insert(next)
            let phrase = "\(cluster) \(word)"
            if cluster.contains(where: { joiners.contains($0) }) {
                said.problems.append("\u{201C}\(phrase)\u{201D} isn't a whole number in plain digits.")
            } else if unit == "months" {
                said.problems.append("\u{201C}\(phrase)\u{201D}: months aren't read, as their days vary. Give days.")
            } else if unit == "weeks" {
                if let weeks = Int(cluster), case let (days, overflow) = weeks.multipliedReportingOverflow(by: 7), !overflow {
                    said.values["days", default: []].append(String(days))
                } else {
                    said.values["days", default: []].append(cluster)
                }
            } else {
                said.values[unit, default: []].append(cluster)
            }
            index = max(index, wordEnd)
        }
        // A unit word no digits came before.
        var position = 0
        while position < text.count {
            guard text[position].isLetter, position == 0 || !text[position - 1].isLetter else { position += 1; continue }
            let (word, end) = letters(from: position)
            if units[word] != nil, !used.contains(position) {
                said.problems.append("\u{201C}\(word)\u{201D} has no number in digits before it, such as 30 days.")
            }
            position = end
        }
        return said
    }
}
