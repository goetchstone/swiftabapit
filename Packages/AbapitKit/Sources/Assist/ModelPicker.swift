import Foundation
import FoundationModels
import Reports

/// The model's three picks (the shared lessons for Apple's on-device model: code leads, the model does small checked jobs).
/// Each is one guided answer in a fresh session, greedy, with a small response cap, from a list built here at run time
/// (`DynamicGenerationSchema` `anyOf`):
///
/// 1. what the sentence asks: to see something, or to change something. Code answers a change request; the list is offered
///    only to a question, so a question never lands on a change.
/// 2. the report, summary or rule, from `Choices` (at most 19 labels, one pick: the lessons narrow in steps past about 40), or
///    none. A report's holds line follows the list, in the catalog's words.
/// 3. for a report with groups, when the sentence shares a word that names one group's plain label, the group, from "all" (first)
///    and those labels (code maps the label back to the catalog's token); a sentence naming no group is "all" with no call.
///
/// The prompt holds the sentence and the catalog's words only, with no example sentence. The answer's committing field (the
/// pick) is first; a second field copies the words of the request that point to it, so code can tell an answer that read the
/// request from one that didn't. A fault code finds is asked about once, named; a second fault is a refusal. A thrown error
/// (a guardrail stop, a refusal, `rateLimited`, `timeout`, too much to read, an answer that didn't parse) is "not
/// understood" at once: greedy repeats a failure exactly. The model gets no tools and is never Private Cloud Compute.
public enum ModelPicker {
    enum Result: Equatable {
        case picked(String, group: String?)
        case changeRequest
        case refused(Refusal)
    }

    /// The system's on-device model, one fresh session per answer, greedy and capped.
    public struct OnDevice: Picker.Asking {
        public init() {}

        public var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }
        public var supportsLocale: Bool { SystemLanguageModel.default.supportsLocale() }

        public func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            return try await session.respond(to: prompt, schema: schema, options: ModelPicker.options).content
        }
    }

    /// Every answer here is a pick and a few words: the cap bounds what one call can write (and so its time).
    public static let responseCap = 100
    public static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: responseCap)

    // MARK: the words the model reads besides the sentence and the catalog

    /// The standing instructions of every pick: no example sentence (the model copies one), no domain knowledge.
    static let instructions = """
        You read an IT administrator's request about the Apple devices of one organization. Pick the listed choice that \
        matches the request. Pick only a listed choice. Then copy the few words of the request that point to your pick.
        """

    /// The answer's fields: the pick first, as it commits; then the request's own words.
    static let pickField = (name: "pick", description: "One of the listed choices")
    static let wordsField = (name: "words", description: "The words of the request that point to the pick")

    /// The first pick's two labels.
    enum Asks: String, CaseIterable {
        case see = "See or list something"
        case change = "Change something"
    }

    /// The label that says nothing listed fits: offered in the second pick only, where an off-topic request makes it right.
    static let none = "None of these"
    /// The label for every group of a report.
    static let all = "all"

    enum Step: CaseIterable {
        case asks, choice, group

        /// The prompt's last line: what this pick is for.
        var task: String {
            switch self {
            case .asks: "Pick what the request asks for."
            case .choice: "Pick the report or check that answers the request, or \(ModelPicker.none) when none does."
            case .group: "Pick \(ModelPicker.all) for every group of this report, or the one group the request asks for."
            }
        }
    }

    /// The frame around the lists and the sentence, every word of it here.
    static let choicesHeading = "Choices:"
    static let reportHeading = "Report:"
    static let requestHeading = "Request:"
    static let faultLead = "Your last answer can't be used:"
    static let faultTail = "Answer again."

    // MARK: the picks

    static func run(_ request: String, choices: [Choices.Choice], using model: some Picker.Asking) async throws -> Result {
        let asks: String
        switch try await ask(request, labels: Asks.allCases.map(\.rawValue), step: .asks, using: model) {
        case .refused(let why): return .refused(why)
        case .picked(let label): asks = label
        }
        if asks == Asks.change.rawValue { return .changeRequest }

        let chosen: Choices.Choice
        switch try await ask(request, labels: choices.map(\.label) + [none], step: .choice, holds: holds(choices), using: model) {
        case .refused(let why): return .refused(why)
        case .picked(none): return .refused(.notOnTheList)
        case .picked(let label):
            guard let choice = choices.first(where: { $0.label == label }) else { return .refused(.notOnTheList) }
            chosen = choice
        }
        guard !chosen.groups.isEmpty else { return .picked(chosen.id, group: nil) }
        // A sentence that names no group asks for all of them: code decides it, so the pick can't drift to the first group
        // (the coordinating session's decision, 2026-11-25).
        guard namesAGroup(request, chosen) else { return .picked(chosen.id, group: nil) }

        let labels = chosen.groups.map(groupLabel)
        // "all" first: listed last, the pick leaned to the first group (the coordinating session, 2026-11-27).
        switch try await ask(request, labels: [all] + labels, step: .group, about: chosen.label, using: model) {
        case .refused(let why): return .refused(why)
        case .picked(all): return .picked(chosen.id, group: nil)
        case .picked(let label):
            guard let index = labels.firstIndex(of: label) else { return .refused(.notOnTheList) }
            return .picked(chosen.id, group: chosen.groups[index])
        }
    }

    /// Each group's plain words, which the group pick lists in place of the catalog's token (code maps the answer back). A
    /// token missing here is listed as it is; a test holds every group of every report to a label of its own.
    static let groupLabels: [String: String] = [
        "lock:USER": "user lock", "lock:MDM": "MDM lock", "lock:NONE": "lock type none", "lock:other": "unknown lock type",
        "unlocked": "unlocked", "unclear": "unclear",
        "status:REQUESTED": "requested", "status:STARTED": "started", "status:SUCCESS": "succeeded", "status:FAILED": "failed",
        "status:other": "unknown status", "no-status": "no status", "no-data": "no data", "past-due": "past the deadline",
        "past-due-status-unknown": "past the deadline with unknown status",
        "healthy": "healthy", "quiet": "quiet", "inactive": "inactive", "deleted": "deleted", "other-status": "unknown status",
        "cannot-judge": "cannot judge",
        "active": "active coverage", "no-active-coverage": "no active coverage", "no-record": "no coverage record",
        "status-unknown": "unknown coverage status", "estimated-past-limit": "estimated past the limit",
        "not-read": "not read",
    ]

    static func groupLabel(_ token: String) -> String { groupLabels[token] ?? token }

    /// Words too general to name a group: they sit in several reports' labels and in what a person says about a whole report.
    static let groupStopWords: Set<String> = ["status", "coverage", "data", "type"]

    /// Whether the sentence shares a word with any group's plain label that isn't a word of the report's own label ("lock" names
    /// Activation Lock, not a group of it) and isn't in `groupStopWords`. Words as `WordRule` reads them, the stoplist too (the
    /// coordinating session, 2026-11-27, round 3: a word in two labels counts, as "all" is listed first).
    static func namesAGroup(_ request: String, _ choice: Choices.Choice) -> Bool {
        // The stoplist read as the sentence is, so "status" is the "statu" `WordRule.words` makes of it.
        let stop = Set(groupStopWords.flatMap(WordRule.words))
        let naming = Set(choice.groups.flatMap { WordRule.words(groupLabel($0)) }).subtracting(stop).subtracting(WordRule.words(choice.label))
        let said = Set(WordRule.words(request))
        if !said.isDisjoint(with: naming) { return true }
        // Another way of saying a group the choice has (S9.6b): it only opens the pick; the model still picks from the plain labels.
        if choice.groups.contains(where: { group in groupSynonyms[group].map { !said.isDisjoint(with: $0.flatMap(WordRule.words)) } ?? false }) {
            return true
        }
        return choice.groups.contains { group in deniesAWord(request, group) }
    }

    /// Other words for a group, read through `WordRule.words`, for the gate only (the coordinating session, 2026-11-27). A group the
    /// report doesn't have is never looked at, so "overdue" opens nothing for a report with no past-the-deadline group. No synonym
    /// is invented for a group that doesn't exist: service health has no "unhealthy" group, so it has no such word.
    static let groupSynonyms: [String: [String]] = [
        "past-due": ["overdue"], "past-due-status-unknown": ["overdue"],
        "status:SUCCESS": ["successful", "success"],
        "no-active-coverage": ["expired", "lapsed"],
    ]

    /// The words after "no" or "without" that ask for a group by its absence: no lock is `unlocked`. Read as the sentence's own
    /// words ("no" is no word to `WordRule`), the word within three after the negation.
    static let denied: [String: Set<String>] = ["unlocked": ["lock", "locks", "locked"]]

    /// Whether `request` says "no lock" or "without a lock" for a group in `denied`.
    static func deniesAWord(_ request: String, _ group: String) -> Bool {
        guard let words = denied[group] else { return false }
        let tokens = request.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        for (index, token) in tokens.enumerated() where token == "no" || token == "without" {
            if tokens.dropFirst(index + 1).prefix(3).contains(where: words.contains) { return true }
        }
        return false
    }

    /// The lines after the choices: each report's holds line, from the catalog. The summary's would repeat the rules' labels,
    /// and a rule's label says what it is, so neither has one here.
    static func holds(_ choices: [Choices.Choice]) -> [String] {
        choices.compactMap { choice in
            guard case .report = choice.kind else { return nil }
            return choice.holds
        }
    }

    enum Asked: Equatable {
        case picked(String)
        case refused(Refusal)
    }

    /// One pick of `labels`, and one re-ask naming the fault if code finds one; a thrown error is not understood at once.
    static func ask(_ request: String, labels: [String], step: Step, about subject: String? = nil, holds: [String] = [],
                    using model: some Picker.Asking) async throws -> Asked {
        // A schema the SDK won't build (`SchemaError`, as for an empty list) is not understood: `pick` throws only cancellation.
        let schema: GenerationSchema
        do { schema = try Self.schema(labels) } catch { return .refused(.notUnderstood(.other)) }
        var fault: String?
        for _ in 0..<2 {
            try Task.checkCancellation()
            let content: GeneratedContent
            do {
                content = try await model.answer(instructions: instructions,
                                                 prompt: prompt(request, labels: labels, step: step, about: subject, holds: holds, fault: fault),
                                                 schema: schema)
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                return .refused(.notUnderstood(.from(error)))
            }
            switch check(content, labels: labels, request: request) {
            case .success(let label): return .picked(label)
            case .failure(let found): fault = found.words
            }
        }
        return .refused(.notUnderstood(.faultTwice))
    }

    /// What code finds wrong with an answer.
    enum Fault: Error, Equatable {
        case noPick, offList, noWords, echoed, notFromRequest

        var words: String {
            switch self {
            case .noPick: "it has no \(pickField.name)"
            case .offList: "its \(pickField.name) is not one of the listed choices"
            case .noWords: "its \(wordsField.name) are empty"
            case .echoed: "its \(wordsField.name) repeat the field's description, not the request"
            case .notFromRequest: "its \(wordsField.name) are not from the request"
            }
        }
    }

    /// The pick if it is a listed label and the answer read the request: its words are there, aren't the field's own
    /// description, and share a word with the request. A "none" pick says nothing fits, so its words aren't held to it.
    static func check(_ content: GeneratedContent, labels: [String], request: String) -> Swift.Result<String, Fault> {
        guard let picked = try? content.value(String.self, forProperty: pickField.name) else { return .failure(.noPick) }
        guard labels.contains(picked) else { return .failure(.offList) }
        if picked == none { return .success(picked) }
        let words = ((try? content.value(String.self, forProperty: wordsField.name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return .failure(.noWords) }
        if words.lowercased().trimmingCharacters(in: .punctuationCharacters) == wordsField.description.lowercased() { return .failure(.echoed) }
        if Set(plainWords(words)).isDisjoint(with: plainWords(request)) { return .failure(.notFromRequest) }
        return .success(picked)
    }

    /// Lowercased whole words of three letters or more.
    static func plainWords(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 3 }
    }

    static func schema(_ labels: [String]) throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Pick", properties: [
            .init(name: pickField.name, description: pickField.description, schema: DynamicGenerationSchema(name: "Choice", anyOf: labels)),
            .init(name: wordsField.name, description: wordsField.description, schema: DynamicGenerationSchema(type: String.self)),
        ]), dependencies: [])
    }

    /// The list, the lines after it, the request, then the task: the stable part first, the request last but one.
    static func prompt(_ request: String, labels: [String], step: Step, about subject: String?, holds: [String], fault: String?) -> String {
        var parts: [String] = []
        if let subject { parts.append("\(reportHeading) \(subject)") }
        parts.append(choicesHeading + "\n" + labels.map { "- \($0)" }.joined(separator: "\n"))
        parts += holds
        parts.append("\(requestHeading) \u{201C}\(request)\u{201D}")
        parts.append(step.task)
        if let fault { parts.append("\(faultLead) \(fault). \(faultTail)") }
        return parts.joined(separator: "\n\n")
    }
}
