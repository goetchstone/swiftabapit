import Foundation
import FoundationModels
import Reports

/// A Needs-attention rule's findings in a few plain sentences (S9.12; the operator, 2026-11-24, Q3 "Picks + explanations"; D7 and
/// D10: on-device only, never Private Cloud Compute). The shape is the coordinating session's proposal: the model reads only code's
/// fixed facts about one rule, writes one to three short sentences, and code checks every sentence against those facts and drops
/// what doesn't hold. Nothing here is stored: the caller shows it and keeps it in memory only.
///
/// - **What the model reads** (`Facts`): the rule's fixed title and description (`NeedsAttention.Rule.title`, `about`), its threshold,
///   and code's counts: findings in all, open, dismissed or snoozed, whether the read was whole or in part, and the data's age in
///   days. The inputs are a rule, the thresholds, whole numbers and two small enums: no serial, name, service, group or any text
///   Apple, Mosyle or an attacker wrote can reach the prompt (a scan test holds the signature and the imports).
/// - **The model**: one guided answer in a fresh session, greedy, capped (`responseCap`), a `DynamicGenerationSchema` of one to three
///   strings, no tools. One call per rule, no re-ask: a sentence that fails is dropped, never repaired.
/// - **Code checks every sentence** (`check`), and drops one that fails any `Check`. Every drop is counted. All dropped: nothing is
///   shown, never a made-up sentence.
public enum Explain {
    /// Whether explanations are shown at all: on only when the held-out evaluation passes (`docs/domains/assist-intents.md`,
    /// "Explaining what needs attention"). Off, the Needs-attention screen shows no explanation and never asks the model.
    public static let isOn = true

    // MARK: the facts

    /// How much of what the rule reads was read.
    public enum Read: String, Sendable, Equatable, Codable {
        /// Every list and device the rule needs: judged whole.
        case whole
        /// Some of it: judged in part, so it may have missed some.
        case partial
    }

    /// Everything the model is told about one rule's findings: code's facts, no list data.
    public struct Facts: Sendable, Equatable {
        public let rule: NeedsAttention.Rule
        public let thresholds: NeedsAttention.Thresholds
        /// Findings in all, dismissed and snoozed ones included.
        public let found: Int
        /// Findings dismissed, or snoozed to a date not reached.
        public let hidden: Int
        public let read: Read
        /// The age in whole days of the oldest snapshot the rule read; nil when it read only live lists.
        public let ageDays: Int?

        public init(rule: NeedsAttention.Rule, thresholds: NeedsAttention.Thresholds, found: Int, hidden: Int, read: Read, ageDays: Int?) {
            self.rule = rule
            self.thresholds = thresholds
            self.found = max(found, 0)
            self.hidden = min(max(hidden, 0), max(found, 0))
            self.read = read
            self.ageDays = ageDays.map { max($0, 0) }
        }

        var title: String { rule.title(thresholds) }
        var about: String { rule.about }
        var threshold: Int? { rule.thresholdDays(thresholds) }

        /// The words a count of this rule's findings may name: findings, and what the rule finds. A quiet service is a service, so
        /// "2 devices" is never its count; FileVault and the firewall find Macs.
        var nouns: Set<String> {
            let things: Set<String> = switch rule {
            case .quietService: ["service", "services"]
            case .fileVaultOff, .firewallOff: ["mac", "macs", "device", "devices", "computer", "computers"]
            default: ["device", "devices", "mac", "macs", "iphone", "iphones", "ipad", "ipads", "computer", "computers"]
            }
            // Findings by other names ("7 alerts", "2 of them"), all counts of the same findings.
            return things.union(["finding", "findings", "item", "items", "result", "results", "alert", "alerts", "instance", "instances",
                                 "case", "cases", "issue", "issues", "entry", "entries", "them"])
        }

        /// Each number the facts hold, with its unit: what a sentence's number must be one of.
        var numbers: Set<Stated> {
            var all: Set<Stated> = [Stated(value: found, unit: .items), Stated(value: hidden, unit: .items)]
            if let threshold { all.insert(Stated(value: threshold, unit: .days)) }
            if let ageDays { all.insert(Stated(value: ageDays, unit: .days)) }
            return all
        }
    }

    /// A number as a sentence states it: its value and its unit.
    struct Stated: Hashable, Sendable {
        let value: Int
        let unit: Unit
    }

    enum Unit: Hashable, Sendable {
        /// Findings, and what the rule finds: devices (Macs for FileVault and the firewall), or services (`Facts.nouns`).
        case items
        case days
    }

    // MARK: what the model reads

    /// The standing instructions: no example sentence (the model copies one), no domain knowledge beyond the facts.
    static let instructions = """
        You explain the result of one check that an IT administrator's device inventory app ran over the Apple devices of one \
        organization. Write plain words for that administrator. Use only the facts given, each number as given with its unit. Say \
        what the check looks for and what its result means.
        """

    /// The answer's one field.
    static let sentencesField = (name: "sentences", description: "One to three short sentences")
    /// At most this many sentences are read, however many come back.
    public static let mostSentences = 3
    /// Three short sentences fit well inside this; it bounds what one call can write, and so its time.
    public static let responseCap = 160
    public static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: responseCap)
    /// A sentence longer than this is dropped as `Check.long`: the field asks for short ones.
    static let longest = 240

    static let headings = (check: "Check:", finds: "What it finds:", threshold: "Threshold:", findings: "Findings:", read: "Read:",
                           data: "Data:")
    static let task = "Explain what this check found, in one to three short sentences."

    /// The prompt: each line a heading and code's words or numbers, the task last.
    static func prompt(_ facts: Facts) -> String {
        var lines = ["\(headings.check) \(facts.title)", "\(headings.finds) \(facts.about)"]
        if let threshold = facts.threshold { lines.append("\(headings.threshold) \(days(threshold))") }
        lines.append("\(headings.findings) \(facts.found); the administrator dismissed or snoozed " + (facts.hidden == 0 ? "none of them" : "\(facts.hidden) of them"))
        lines.append("\(headings.read) " + readWords(facts.read))
        lines.append("\(headings.data) " + dataWords(facts.ageDays))
        lines.append(task)
        return lines.joined(separator: "\n")
    }

    static func readWords(_ read: Read) -> String {
        switch read {
        case .whole: "in full: every list the check needs was read whole"
        case .partial: "in part: some of what the check needs wasn't read, so it may have missed some"
        }
    }

    static func dataWords(_ ageDays: Int?) -> String {
        guard let ageDays else { return "read live" }
        return ageDays == 0 ? "from a snapshot less than a day old" : "from a snapshot \(days(ageDays)) old"
    }

    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }

    static func schema() throws -> GenerationSchema {
        try GenerationSchema(root: DynamicGenerationSchema(name: "Explanation", properties: [
            .init(name: sentencesField.name, description: sentencesField.description,
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: mostSentences)),
        ]), dependencies: [])
    }

    // MARK: asking

    /// The system's on-device model, one fresh session per rule, greedy and capped. Never Private Cloud Compute.
    public struct OnDevice: Picker.Asking {
        public init() {}

        public var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }
        public var supportsLocale: Bool { SystemLanguageModel.default.supportsLocale() }

        public func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            return try await session.respond(to: prompt, schema: schema, options: Explain.options).content
        }
    }

    /// What one rule's explanation came to.
    public enum Outcome: Sendable, Equatable {
        /// At least one sentence held: the kept ones, in order, and what each dropped one failed.
        case explained(sentences: [String], dropped: [Check])
        /// Every sentence failed a check: nothing is shown.
        case nothingKept(dropped: [Check])
        /// The model's answer couldn't be used (a thrown error, an answer with no sentences): nothing is shown.
        case failed(Refusal.NotUnderstood)
        /// The model can't answer on this Mac now: nothing was asked.
        case off(Refusal)

        /// The kept sentences; empty unless explained.
        public var sentences: [String] { if case .explained(let kept, _) = self { kept } else { [] } }

        /// What was dropped, in all.
        public var dropped: [Check] {
            switch self {
            case .explained(_, let dropped), .nothingKept(let dropped): dropped
            case .failed, .off: []
            }
        }

        /// Why nothing is shown, in words; nil when something is.
        public var note: String? {
            switch self {
            case .explained: nil
            case .nothingKept: "The on-device model's explanation didn't match this rule's facts, so none is shown."
            case .failed(let why): "The on-device model couldn't explain this rule: \(why.words)."
            case .off(let refusal): Explain.offWords(refusal)
            }
        }
    }

    /// One rule's facts explained by `model`. Throws only `CancellationError`; every other failure is an outcome in words.
    public static func explain(_ facts: Facts, using model: some Picker.Asking) async throws -> Outcome {
        if let refusal = Refusals.availability(of: model) { return .off(refusal) }
        let schema: GenerationSchema
        do { schema = try Self.schema() } catch { return .failed(.other) }
        try Task.checkCancellation()
        let content: GeneratedContent
        do {
            content = try await model.answer(instructions: instructions, prompt: prompt(facts), schema: schema)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            return .failed(.from(error))
        }
        guard let written = try? content.value([String].self, forProperty: sentencesField.name), !written.isEmpty else {
            return .failed(.unreadable)
        }
        return judge(written, facts)
    }

    /// The sentences held to the facts: at most `mostSentences` read, each kept or dropped with the check it failed.
    static func judge(_ written: [String], _ facts: Facts) -> Outcome {
        var kept: [String] = [], dropped: [Check] = []
        for sentence in written.prefix(mostSentences) {
            let tidy = sentence.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if let failed = check(tidy, facts, earlier: kept) { dropped.append(failed) } else { kept.append(tidy) }
        }
        dropped += Array(repeating: Check.extra, count: max(written.count - mostSentences, 0))
        return kept.isEmpty ? .nothingKept(dropped: dropped) : .explained(sentences: kept, dropped: dropped)
    }

    // MARK: the checks

    /// Why a sentence was dropped. Each is a code check; none reads meaning, so a true sentence can be dropped (counted, as the
    /// shared lessons ask) and a false sentence with no number, name or claim in it can pass.
    public enum Check: String, Sendable, Equatable, CaseIterable, Codable {
        /// Empty once trimmed.
        case empty
        /// Longer than `longest`.
        case long
        /// The field's own description echoed back.
        case echoed
        /// The same as a kept sentence.
        case repeated
        /// "I", "we", "our": the app speaking of itself, as if it acted.
        case person
        /// Advice or a command: an imperative first word, "should", "must", "need to", "recommend", "please".
        case advice
        /// A claim that something was done or will be: "has been fixed", "were removed", "abapit will notify".
        case done
        /// Words against the read's facts: whole when it was in part ("nothing was missed", "it covered each Mac"), in part when
        /// whole; a snapshot when live, live when a snapshot.
        case read
        /// Says nothing needs attention while the rule found something: "no issues", "are fine", "need no attention".
        case allClear
        /// A number (digits, a number word, "no"/"none"/"nothing"/"zero" as zero) that isn't one of the facts' with its unit and in
        /// its place, a number with no unit, a decimal, a percentage, a digit glued to letters, an ordinal, a vague count.
        case number
        /// A capitalized word that isn't in the rule's title or description or the fixed vocabulary.
        case name
        /// Past `mostSentences`: not read.
        case extra
    }

    /// The check `sentence` fails, or nil when it holds. In the order of `Check`.
    static func check(_ sentence: String, _ facts: Facts, earlier: [String] = []) -> Check? {
        if sentence.isEmpty { return .empty }
        if sentence.count > longest { return .long }
        let plain = sentence.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if plain == sentencesField.description.lowercased() { return .echoed }
        if earlier.contains(where: { $0.lowercased() == sentence.lowercased() }) { return .repeated }
        let tokens = lowerTokens(sentence)
        if tokens.contains(where: firstPerson.contains) { return .person }
        if givesAdvice(tokens) { return .advice }
        if claimsDone(tokens) { return .done }
        if contradictsTheRead(tokens, facts) { return .read }
        if facts.found > 0, saysAllClear(tokens) { return .allClear }
        if !numbersHold(sentence, facts) { return .number }
        if !namesHold(sentence, facts) { return .name }
        return nil
    }

    /// Lowercased words: letters, digits, apostrophes inside a word ("didn't"), split at everything else (a hyphen too).
    static func lowerTokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    // MARK: numbers

    static let ones = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
                       "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
                       "eighteen": 18, "nineteen": 19]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    static let scales = ["hundred": 100, "thousand": 1000, "million": 1_000_000]
    /// Words that are a count but no exact number: a sentence with one states a number the facts don't hold.
    static let vague: Set<String> = ["dozen", "dozens", "hundreds", "thousands", "half", "twice", "double", "triple", "percent", "percentage",
                                     "majority", "most", "couple", "several", "both", "all", "single", "few", "handful", "numerous", "many"]

    /// Every noun a count may name; one that isn't the rule's (`Facts.nouns`) is a unit no fact has.
    static let itemNouns: Set<String> = ["finding", "findings", "device", "devices", "mac", "macs", "service", "services", "migration",
                                         "migrations", "item", "items", "result", "results", "iphone", "iphones", "ipad", "ipads", "computer",
                                         "computers", "record", "records", "ones", "alert", "alerts", "instance", "instances", "case", "cases", "issue", "issues", "entry",
                                         "entries", "them"]
    static let dayNouns: Set<String> = ["day", "days"]
    /// Other units: a number before one of these is never a fact's.
    static let otherUnits: Set<String> = ["hour", "hours", "minute", "minutes", "second", "seconds", "week", "weeks", "month", "months", "year",
                                          "years", "time", "times"]
    /// Words that may stand between a number and its unit ("3 open findings", "2 of the 5 devices").
    static let between: Set<String> = ["open", "hidden", "dismissed", "snoozed", "more", "other", "such", "additional", "separate", "total",
                                       "active", "affected", "of", "the", "these", "those", "its", "their", "apple", "mdm", "mosyle", "managed",
                                       "flagged", "listed", "remaining", "or", "and", "full", "whole", "consecutive", "straight"]

    /// Words that put a count in the hidden fact's place: "2 were dismissed or snoozed".
    static let hideWords: Set<String> = ["dismissed", "snoozed", "hidden", "dismiss", "snooze", "dismissing", "snoozing", "hide"]
    /// Words that put a number of days in the threshold's place: "within 90 days", "for 30 days or more", "more than 30 days".
    static let windowWords: Set<String> = ["within", "than", "least", "over", "beyond", "threshold", "window", "longer", "more", "for", "past",
                                           "after", "limit"]
    /// Words that put a number of days in the age's place: "a snapshot 3 days old".
    static let ageWords: Set<String> = ["old", "snapshot", "snapshots", "ago", "age", "aged", "taken"]
    /// How far either side of a number its place words are looked for, in words.
    static let reach = 6
    /// Ordinals: a position is no fact's number.
    static let ordinals: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                                        "eleventh", "twelfth", "twentieth", "hundredth", "thousandth"]
    /// Time words that state a span no fact holds ("last week", "tomorrow").
    static let spans: Set<String> = ["fortnight", "quarter", "tomorrow", "yesterday", "tonight"]
    static let spanLeads: Set<String> = ["last", "next", "this", "past", "coming"]
    static let spanUnits: Set<String> = ["week", "weeks", "month", "months", "year", "years", "quarter"]

    /// Whether every number `sentence` states is one of the facts', with its unit, in its place: a count is the findings, or the
    /// dismissed or snoozed ones beside a word saying so; days are the threshold beside window words, or the age beside age words.
    /// A zero ("no devices", "none", "nothing", "zero") is the dismissed or snoozed count only, beside its words, when none were.
    static func numbersHold(_ sentence: String, _ facts: Facts) -> Bool {
        // A thousands comma joins its digits; any other digit beside a point or comma is a decimal or a list ("1.5", "3,4").
        let joined = sentence.replacingOccurrences(of: #"(\d),(\d{3})(?!\d)"#, with: "$1$2", options: .regularExpression)
        if joined.range(of: #"\d[.,]\d"#, options: .regularExpression) != nil || joined.contains("%") { return false }
        let tokens = lowerTokens(joined)
        // A digit that isn't a plain number ("5th", "7devices", "30d", a digit of another script) states something no fact holds.
        for token in tokens where token.contains(where: \.isNumber) {
            if !token.allSatisfy({ $0.isASCII && $0.isNumber }) || Int(token) == nil { return false }
        }
        if tokens.contains(where: { vague.contains($0) || ordinals.contains($0) || spans.contains($0) }) { return false }
        if zip(tokens, tokens.dropFirst()).contains(where: { spanLeads.contains($0) && spanUnits.contains($1) }) { return false }
        if zip(tokens, tokens.dropFirst()).contains(where: { $0 == "a" && ["couple", "few", "single", "third", "dozen"].contains($1) }) { return false }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // A run of number words or one of digits, read as one number.
            var value: Int?, next = index + 1
            if let digits = Int(token) {
                value = digits
            } else if ones[token] != nil || tens[token] != nil {
                let read = numberWords(tokens, from: index)
                (value, next) = (read.value, read.next)
            } else if token == "no" || token == "none" || token == "nothing" {
                // "No devices", "none of the findings", "nothing was found": a zero. "No" before anything else ("no check-in") states
                // no number.
                let unit = unitAfter(tokens, from: index + 1, nouns: facts.nouns)
                if token == "no" && unit == nil { index += 1; continue }
                if let unit, unit != .items { return false }
                if !holds(0, .items, at: index..<next, tokens, facts) { return false }
                index = next
                continue
            } else if scales[token] != nil {
                return false
            }
            guard let value else { index += 1; continue }
            switch unitAfter(tokens, from: next, nouns: facts.nouns) {
            case .some(.some(let unit)):
                if !holds(value, unit, at: index..<next, tokens, facts) { return false }
            case .some(.none):
                return false
            case .none:
                // A zero with no unit ("zero were dismissed") counts findings; "one" with no unit is the pronoun ("each one"); any
                // other number needs its unit.
                if value == 0 {
                    if !holds(0, .items, at: index..<next, tokens, facts) { return false }
                } else if !(token == "one" && next == index + 1) {
                    return false
                }
            }
            index = next
        }
        return true
    }

    /// Whether `value` in `unit`, stated at `span`, is a fact's number in that fact's place.
    static func holds(_ value: Int, _ unit: Unit, at span: Range<Int>, _ tokens: [String], _ facts: Facts) -> Bool {
        func near(_ words: Set<String>) -> Bool {
            tokens[max(0, span.lowerBound - reach)..<min(tokens.count, span.upperBound + reach)].contains(where: words.contains)
        }
        switch unit {
        case .items:
            // With findings, a zero is only the dismissed or snoozed count: "no devices" or "nothing was found" isn't.
            if value == facts.found, value > 0 || facts.found == 0 { return true }
            return value == facts.hidden && near(hideWords)
        case .days:
            if let threshold = facts.threshold, value == threshold, near(windowWords) { return true }
            if let age = facts.ageDays, value == age, near(ageWords) { return true }
            return false
        }
    }

    /// The number words from `start`: "twenty five", "one hundred twenty", "three thousand". Returns the value and the index after.
    static func numberWords(_ tokens: [String], from start: Int) -> (value: Int, next: Int) {
        var total = 0, current = 0, index = start
        while index < tokens.count {
            let token = tokens[index]
            if let one = ones[token] { current += one } else if let ten = tens[token] { current += ten } else if let scale = scales[token] {
                current = max(current, 1) * scale
                if scale >= 1000 { total += current; current = 0 }
            } else if token == "and", index + 1 < tokens.count, ones[tokens[index + 1]] != nil || tens[tokens[index + 1]] != nil, total + current >= 100 {
                // "one hundred and five"
            } else { break }
            index += 1
        }
        return (total + current, index)
    }

    /// The unit after a number, skipping up to four `between` words and any further number ("2 of the 5 devices"): `.some(unit)`
    /// for a fact's unit (`nouns`, the rule's), `.some(nil)` for another unit (hours, weeks, another rule's noun), nil for none.
    static func unitAfter(_ tokens: [String], from start: Int, nouns: Set<String>) -> Unit?? {
        var index = start, skipped = 0
        while index < tokens.count, skipped <= 4 {
            let token = tokens[index]
            if nouns.contains(token) { return .some(.items) }
            if itemNouns.contains(token) { return .some(nil) }
            if dayNouns.contains(token) { return .some(.days) }
            if otherUnits.contains(token) { return .some(nil) }
            guard between.contains(token) || Int(token) != nil || ones[token] != nil || tens[token] != nil || scales[token] != nil else { return nil }
            index += 1
            skipped += 1
        }
        return nil
    }

    // MARK: names

    /// Capitalized words any rule may use: the products and platforms abapit reads.
    static let vocabulary: Set<String> = ["Apple", "AppleCare", "Mosyle", "Mac", "Macs", "iPhone", "iPhones", "iPad", "iPads", "MDM", "FileVault",
                                          "Activation", "Lock", "Account", "Business", "School", "IT"]
    /// Ordinary words that start a sentence with a capital.
    static let starters: Set<String> = ["this", "these", "that", "those", "the", "a", "an", "it", "its", "they", "their", "there", "each", "every",
                                        "all", "any", "some", "no", "none", "of", "in", "on", "for", "when", "while", "if", "because", "since",
                                        "so", "but", "and", "only", "what", "which", "here", "such", "until", "after", "before", "once",
                                        "with", "without", "from", "devices", "findings", "nothing", "zero", "one", "two", "three", "four", "five",
                                        "six", "seven", "eight", "nine", "ten", "as", "at", "by", "not", "more", "most", "both", "either",
                                        "neither", "however", "also", "still", "even", "although", "though", "where", "how", "within"]

    /// Whether every capitalized word of `sentence` is in the rule's title or description, the vocabulary, or an ordinary word
    /// starting the sentence.
    static func namesHold(_ sentence: String, _ facts: Facts) -> Bool {
        func words(_ text: String) -> [String] {
            text.replacingOccurrences(of: "\u{2019}", with: "'").split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }
                .map { word -> String in
                    var word = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
                    if word.hasSuffix("'s") { word.removeLast(2) }
                    return word
                }
                .filter { !$0.isEmpty }
        }
        let allowed = Set(words(facts.title) + words(facts.about)).union(vocabulary)
        let lowerAllowed = Set(allowed.map { $0.lowercased() })
        for (position, word) in words(sentence).enumerated() where word.contains(where: \.isUppercase) {
            if allowed.contains(word) { continue }
            // A sentence's first word may be capitalized for that alone.
            if position == 0, word.dropFirst().allSatisfy({ !$0.isUppercase }),
               starters.contains(word.lowercased()) || lowerAllowed.contains(word.lowercased()) || itemNouns.contains(word.lowercased()) {
                continue
            }
            return false
        }
        return true
    }

    // MARK: person, advice, done, read

    static let firstPerson: Set<String> = ["i", "we", "us", "our", "ours", "me", "my", "i'm", "i've", "i'll", "i'd", "we're", "we've", "we'll", "we'd"]

    /// Verbs that open a command ("Turn on FileVault", "Contact the user", "Review these devices").
    static let commands: Set<String> = ["turn", "enable", "disable", "enroll", "unenroll", "release", "remove", "delete", "wipe", "lock",
                                        "unlock", "renew", "extend", "buy", "purchase", "assign", "reassign", "migrate", "contact", "check",
                                        "update", "upgrade", "fix", "change", "set", "run", "review", "investigate", "ensure", "make",
                                        "consider", "open", "go", "click", "dismiss", "snooze", "replace", "restart", "reboot", "install",
                                        "reinstall", "add", "look", "verify", "confirm", "ask", "call", "email", "schedule", "plan", "act",
                                        "resolve", "address", "try", "use", "keep", "follow", "reconnect", "connect", "sync", "refresh",
                                        "retire", "move", "send", "notify", "reach", "find", "start", "stop", "re", "take", "do", "don't",
                                        "be", "please", "remember", "note", "monitor", "track", "audit", "inspect", "handle", "tell", "get"]
    /// Words that advise anywhere in a sentence.
    static let advising: Set<String> = ["should", "must", "ought", "recommend", "recommended", "recommends", "suggest", "suggests",
                                        "suggested", "please", "consider", "ensure", "advisable", "advised", "shouldn't", "mustn't", "could", "wise",
                                        "ought"]
    /// Two-word advice ("need to", "make sure").
    static let advisingPairs: Set<[String]> = [["need", "to"], ["needs", "to"], ["have", "to"], ["has", "to"], ["make", "sure"],
                                               ["you", "can"], ["you", "may"], ["you", "might"], ["want", "to"], ["best", "to"], ["it's", "best"],
                                               ["good", "idea"]]

    static func givesAdvice(_ tokens: [String]) -> Bool {
        if let first = tokens.first, commands.contains(first) { return true }
        if tokens.contains(where: advising.contains) { return true }
        return zip(tokens, tokens.dropFirst()).contains { advisingPairs.contains([$0, $1]) }
    }

    /// Acts only someone does: "was fixed", "has been removed", "will be wiped".
    static let actWords: Set<String> = ["fixed", "resolved", "removed", "deleted", "unenrolled", "released", "wiped", "renewed", "reassigned",
                                        "repaired", "cleared", "corrected", "notified", "contacted", "scheduled", "addressed", "handled",
                                        "reconnected", "synced", "refreshed", "retired", "replaced", "reinstalled", "restarted", "sent",
                                        "fixing", "removing", "deleting", "releasing", "wiping", "renewing", "notifying", "contacting"]
    /// Words that also describe a state ("devices that are enrolled", "a Mac that is locked"): a claim only after "been", "now",
    /// "will", "got" or "being".
    static let stateWords: Set<String> = ["enrolled", "assigned", "locked", "unlocked", "enabled", "disabled", "turned", "migrated",
                                          "updated", "upgraded", "extended", "moved", "installed", "changed", "taken"]
    /// Before an act word, any of these makes it a claim; before a state word, only the strong ones.
    static let claiming: Set<String> = ["been", "was", "were", "now", "be", "being", "got", "gets", "has", "have", "had", "will", "is", "are"]
    static let strongClaiming: Set<String> = ["been", "now", "will", "got", "gets", "being"]
    /// The app's own verbs of change: "abapit will notify", "abapit removed".
    static let changeStems = ["fix", "resolv", "remov", "delet", "enrol", "unenrol", "releas", "wip", "lock", "unlock", "renew", "extend",
                              "assign", "reassign", "migrat", "updat", "upgrad", "turn", "enabl", "disabl", "chang", "repair", "clear",
                              "correct", "notif", "contact", "schedul", "dismiss", "snooz", "install", "restart", "replac", "retir", "send",
                              "sent", "email", "alert", "mov"]

    static func claimsDone(_ tokens: [String]) -> Bool {
        for (index, token) in tokens.enumerated() {
            let before = tokens[max(0, index - 2)..<index]
            if actWords.contains(token), before.contains(where: claiming.contains) { return true }
            if stateWords.contains(token), before.contains(where: strongClaiming.contains) { return true }
            if token == "abapit" || token == "app" {
                for after in tokens.dropFirst(index + 1).prefix(3) where changeStems.contains(where: after.hasPrefix) { return true }
            }
        }
        return false
    }

    /// Words that say nothing needs attention, while the rule found something.
    static let allClearWords: Set<String> = ["fine", "healthy", "ok", "okay", "safe", "harmless"]
    static let allClearPairs: Set<[String]> = [["no", "attention"], ["nothing", "needs"], ["nothing", "to"], ["no", "issues"], ["no", "issue"],
                                               ["no", "problem"], ["no", "problems"], ["no", "action"], ["no", "concern"], ["no", "concerns"],
                                               ["all", "clear"], ["all", "good"], ["need", "no"], ["needs", "no"]]

    static func saysAllClear(_ tokens: [String]) -> Bool {
        if tokens.contains(where: allClearWords.contains) { return true }
        return zip(tokens, tokens.dropFirst()).contains { allClearPairs.contains([$0, $1]) }
    }

    static func contradictsTheRead(_ tokens: [String], _ facts: Facts) -> Bool {
        switch facts.read {
        case .partial:
            // "Every device was read", "the read was complete", "it covered each Mac", "nothing was missed": a part read said as whole.
            let readWords: Set<String> = ["read", "checked", "scanned", "covered", "looked", "included", "reviewed", "examined", "counted",
                                          "inspected", "searched"]
            if tokens.contains(where: readWords.contains), tokens.contains(where: ["each", "every", "all"].contains) { return true }
            if tokens.contains(where: ["complete", "completely", "full", "fully", "entire", "entirely", "whole"].contains) { return true }
            let negations: Set<String> = ["no", "nothing", "none", "not", "never", "without", "didn't", "wasn't", "weren't", "nor", "neither"]
            for (index, token) in tokens.enumerated() where token.hasPrefix("miss") || token.hasPrefix("skip") || token == "overlooked" {
                // "Nothing was missed", "no Mac was skipped"; not "some of it wasn't read, possibly missing some".
                let before = tokens[max(0, index - 4)..<index]
                if before.contains(where: negations.contains), !before.contains("read") { return true }
            }
        case .whole:
            if tokens.contains(where: ["partial", "partially", "partly", "incomplete", "missed"].contains) { return true }
            if zip(tokens, tokens.dropFirst()).contains(where: { $0 == "in" && $1 == "part" }) { return true }
            if zip(tokens, tokens.dropFirst()).contains(where: { ($0 == "not" || $0 == "weren't" || $0 == "wasn't") && $1 == "read" }) { return true }
        }
        if facts.ageDays == nil, tokens.contains(where: { $0.hasPrefix("snapshot") }) { return true }
        if facts.ageDays != nil, tokens.contains("live") { return true }
        return false
    }

    // MARK: the words when off

    /// Why rules aren't explained, for the Needs-attention screen: one per reason `Refusals.availability` gives.
    public static func offWords(_ refusal: Refusal) -> String {
        let rest = "Everything else on this screen works as before."
        return switch refusal {
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model, so rules aren't explained in words. " + rest
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off, so rules aren't explained in words: turn it on in System Settings. " + rest
        case .unavailable(.modelNotReady): "The on-device model is still being set up (downloading), so rules aren't explained in words yet. " + rest
        case .unsupportedLocale: "The on-device model doesn't support this Mac's language, so rules aren't explained in words. " + rest
        case .unavailable(.other): "The on-device model isn't available, so rules aren't explained in words. " + rest
        default: "The on-device model isn't available, so rules aren't explained in words. " + rest
        }
    }
}
