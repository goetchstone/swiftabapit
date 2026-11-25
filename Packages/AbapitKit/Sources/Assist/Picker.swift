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

    /// A checked pick: a choice on this client's list, and for a report its tokens as the catalog resolved them.
    public struct Pick: Sendable, Equatable {
        public let choice: Choices.Choice
        /// One of the choice's groups, or nil for all of them (and for a choice with none).
        public let group: String?
        /// For a report: the group and any number the sentence holds, as `ReportCatalog.resolve` took them.
        public let tokens: [String: String]
        /// What the catalog refused of the sentence's numbers (out of bounds, given twice), in its words.
        public let problems: [String]
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
        case .picked(let id, let group): return check(id, group: group, sentence: request, against: choices)
        }
    }

    /// The pick held to the list: an id not on it, or a group the choice doesn't have, is refused, never matched to something
    /// near it. A report's number filters are filled from the sentence (`numbers`) and resolved by the catalog.
    static func check(_ id: String, group: String?, sentence: String, against choices: [Choices.Choice]) -> Outcome {
        guard let choice = choices.first(where: { $0.id == id }) else { return .refused(.notOnTheList) }
        if let group, !choice.groups.contains(group) { return .refused(.notOnTheList) }
        guard case .report(let report) = choice.kind else {
            return .picked(Pick(choice: choice, group: nil, tokens: [:], problems: []))
        }
        var tokens: [String: String] = [:], problems: [String] = []
        if let group { tokens["group"] = group }
        let said = numbers(in: sentence)
        for filter in ReportCatalog.entry(report).filters where filter.isNumber {
            guard let values = said[filter.name] else { continue }
            if Set(values).count > 1 {
                problems.append("The sentence gives \(filter.name) more than once: " + values.map(String.init).joined(separator: ", "))
            } else {
                tokens[filter.name] = String(values[0])
            }
        }
        let resolved = ReportCatalog.resolve(report, tokens: tokens)
        return .picked(Pick(choice: choice, group: group, tokens: resolved.tokens, problems: problems + resolved.problems))
    }

    /// The whole numbers the sentence gives in days or years, by filter name, in the order said: a number of weeks is that many
    /// times seven days. A bare number, or one of months (whose days vary), is no filter.
    static func numbers(in sentence: String) -> [String: [Int]] {
        // Runs of digits and runs of letters, so "90-day" and "45days" read as a number and a unit.
        var runs: [String] = [], current = ""
        for character in sentence.lowercased() {
            let kind = character.isASCII && character.isNumber ? 1 : character.isLetter ? 2 : 0
            let last = current.last.map { $0.isASCII && $0.isNumber ? 1 : 2 } ?? 0
            if kind == 0 || kind != last { if !current.isEmpty { runs.append(current) }; current = "" }
            if kind != 0 { current.append(character) }
        }
        if !current.isEmpty { runs.append(current) }
        var found: [String: [Int]] = [:]
        for (number, unit) in zip(runs, runs.dropFirst()) {
            guard number.count <= 6, let value = Int(number) else { continue }
            switch unit {
            case "day", "days": found["days", default: []].append(value)
            case "week", "weeks": found["days", default: []].append(value * 7)
            case "year", "years": found["years", default: []].append(value)
            default: continue
            }
        }
        return found
    }
}
