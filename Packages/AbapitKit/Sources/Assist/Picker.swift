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
    /// a rule's window must be it, and a choice that takes no number (the summary, a rule with no window, a report with no
    /// number filter) refuses it, never drops it (the coordinating session, 2026-11-27). A number that can't be taken as said
    /// is a problem, and any problem refuses the pick in its words.
    static func check(_ id: String, group: String?, sentence: String, against choices: [Choices.Choice],
                      thresholds: NeedsAttention.Thresholds) -> Outcome {
        guard let choice = choices.first(where: { $0.id == id }) else { return .refused(.notOnTheList) }
        if let group, !choice.groups.contains(group) { return .refused(.notOnTheList) }
        let said = numbers(in: sentence)
        /// The pick, or a refusal when the sentence gives a number this choice can't take.
        func noNumber(_ pick: Pick) -> Outcome {
            if said.values.isEmpty && said.problems.isEmpty { return .picked(pick) }
            return .refused(.numbers(["\(choice.label) takes no number, so the sentence's number can't be used."] + said.problems))
        }
        switch choice.kind {
        case .attentionSummary:
            return noNumber(Pick(choice: choice, group: nil, tokens: [:]))
        case .rule(let rule):
            guard let window = window(rule, thresholds) else { return noNumber(Pick(choice: choice, group: nil, tokens: [:])) }
            var problems = said.forANumber
            for (unit, values) in said.values.sorted(by: { $0.key < $1.key }) where unit != "days" || values.contains(where: { $0 != String(window) }) {
                problems.append("\(choice.label) has a window of \(window) days; the sentence gives " + values.map { "\($0) \(unit)" }.joined(separator: ", ") + ".")
            }
            return problems.isEmpty ? .picked(Pick(choice: choice, group: nil, tokens: [:])) : .refused(.numbers(problems))
        case .report(let report):
            var tokens: [String: String] = [:]
            if let group { tokens["group"] = group }
            let filters = ReportCatalog.entry(report).filters.filter(\.isNumber).map(\.name)
            guard !filters.isEmpty else { return noNumber(Pick(choice: choice, group: group, tokens: tokens)) }
            var problems = said.forANumber
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

    /// The numbers a sentence gives, as code reads them: plain digits before a unit word, or a number word from one to twelve.
    struct Said: Equatable {
        /// By filter name (`days`, `years`), each value as its digits (any length: the catalog's bounds refuse what's too big).
        var values: [String: [String]] = [:]
        /// What can't be taken as said, in words.
        var problems: [String] = []
        /// Digit runs with no unit after them: a problem for a choice that takes a number (a range's end, "within 60", "30 d",
        /// "before 2021"), nothing for one that takes none ("macOS 15").
        var bare: [String] = []

        /// The problems for a choice that takes a number: each bare number is one.
        var forANumber: [String] {
            problems + bare.map { "\u{201C}\($0)\u{201D} has no unit: give one number of days, weeks or years." }
        }
    }

    /// The unit words after a number: days, weeks and years are read (with `yr`/`yrs`, `wk`/`wks`); months and anything shorter
    /// than a day are units abapit doesn't read, each a problem (the coordinating session, 2026-11-27).
    static let units: [String: String] = [
        "day": "days", "days": "days", "week": "weeks", "weeks": "weeks", "wk": "weeks", "wks": "weeks",
        "year": "years", "years": "years", "yr": "years", "yrs": "years",
        "month": "months", "months": "months", "mo": "months", "mos": "months",
        "hour": "hours", "hours": "hours", "hr": "hours", "hrs": "hours",
        "minute": "minutes", "minutes": "minutes", "min": "minutes", "mins": "minutes",
    ]
    /// The unit words that are a problem with no digits before them ("two weeks", "a year"); an abbreviation alone is no unit.
    static let spelled: Set<String> = ["day", "days", "week", "weeks", "year", "years", "month", "months"]
    /// The abbreviations a number word may stand before ("two wks"); alone they are no unit and no problem.
    static let abbreviated: Set<String> = ["wk", "wks", "yr", "yrs"]
    /// Characters that make a number more than plain digits: a decimal point, a thousands comma, a minus sign or a range dash
    /// (hyphen, en dash, em dash).
    static let joiners: Set<Character> = [".", ",", "-", "\u{2212}", "\u{2013}", "\u{2014}"]

    /// What is said of digits glued to letters that aren't a unit ("90d", "3pm", "14in", a serial-like token): no filter of abapit's
    /// takes it. Worded as that, not as a number of days, which "3pm" was never meant to be (the coordinating session, S9.7).
    static func gluedWords(_ token: String) -> String { "abapit's reports can't filter by \u{201C}\(token)\u{201D}." }

    /// The number words read before a unit word (the coordinating session, 2026-11-27): one to twelve, and "a"/"an" for one before
    /// a singular unit ("a year"). Nothing else: "a few", "several", "a couple of" and "this"/"next"/"last" year are ambiguous.
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12,
    ]
    /// The singular unit words "a" and "an" may stand before, exactly as written: "a days" and "an weeks" are no number.
    static let singular: Set<String> = ["day", "week", "wk", "year", "yr", "month"]
    /// Number words read as a number only in a bigger one ("twenty-one", "one hundred"): never as one to twelve, so a unit after
    /// one is a problem, and with no unit after it the word is kept as a bare number.
    static let bigNumbers: Set<String> = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand"]
    /// Words before a number word or "a" that make it part of something bigger, smaller or hedged ("half a year", "about a year"):
    /// the unit word is then left a problem, never read as 1.
    static let bigger: Set<String> = bigNumbers.union([
        "half", "quarter", "third", "once", "twice", "about", "around", "roughly", "approximately", "approx", "almost", "nearly", "maybe",
    ])
    /// The words before a number in digits that hedge it ("about 30 days"); a tens or fraction word before digits is no hedge.
    static let hedgeBefore: Set<String> = ["about", "around", "roughly", "approximately", "approx", "almost", "nearly", "maybe"]
    /// Words after "or" or "and" (and an optional "a") that make the number a range, a fraction or a hedge ("a year and a half", "a week
    /// or two", "one year or so").
    static let rangeWords: Set<String> = ["half", "quarter", "third", "few", "couple", "so", "thereabouts", "change"]

    /// What stands right after a spelled unit that makes it no window: "ago" (a past time), "or so", or "or"/"and" with another
    /// number or fraction word ("a week or two", "a year and a half"). `text[from...]` is what follows the unit word.
    ///
    /// With `ranges` false (digits: "30 days or 60 days" is two values, not a hedge) only a fraction or hedge word after "or"/"and" counts,
    /// not another number.
    static func hedgedAfter(_ from: Int, in text: [Character], ranges: Bool = true) -> Bool {
        func word(at start: Int) -> (String, Int) {
            var end = start
            while end < text.count, text[end].isLetter || text[end].isNumber { end += 1 }
            return (String(text[start..<end]), end)
        }
        func skipSpace(_ index: Int) -> Int {
            var index = index
            while index < text.count, text[index].isWhitespace { index += 1 }
            return index
        }
        var cursor = skipSpace(from)
        guard cursor < text.count else { return false }
        let (first, firstEnd) = word(at: cursor)
        if first == "ago" { return true }
        guard first == "or" || first == "and" else { return false }
        cursor = skipSpace(firstEnd)
        guard cursor < text.count else { return false }
        if ranges, text[cursor].isNumber { return true }
        var (next, nextEnd) = word(at: cursor)
        if next == "a" || next == "an" { (next, nextEnd) = word(at: skipSpace(nextEnd)) }
        return rangeWords.contains(next) || (ranges && (numberWords[next] != nil || bigger.contains(next)))
    }

    /// The number said in words just before the unit word at `position` ("two weeks", "three-year", "a year"), and where its first
    /// word starts; nil when it isn't a window. A hyphen or a bigger-number word before it ("twenty-one days", "half a year", "about
    /// a year"), a range or hedge after it ("a week or two", "a year ago") and, for "a"/"an", a hyphen or apostrophe right after the
    /// unit ("a year-end report", "a day's notice") are nil: the unit is left a problem.
    static func spelledNumber(before position: Int, in text: [Character], unit: String) -> (value: Int, start: Int)? {
        var cursor = position
        while cursor > 0, text[cursor - 1].isWhitespace { cursor -= 1 }
        if cursor > 0, ["-", "\u{2013}", "\u{2014}", "\u{2212}"].contains(text[cursor - 1]), cursor == position { cursor -= 1 }
        guard cursor > 0, text[cursor - 1].isLetter else { return nil }
        var start = cursor
        while start > 0, text[start - 1].isLetter { start -= 1 }
        let word = String(text[start..<cursor])
        let value: Int
        let end = position + unit.count
        if let number = numberWords[word] {
            value = number
        } else if word == "a" || word == "an", singular.contains(unit) {
            if end < text.count, ["-", "'", "\u{2019}"].contains(text[end]) { return nil }
            value = 1
        } else {
            return nil
        }
        if hedgedAfter(end, in: text) { return nil }
        // What stands before the number word.
        if start > 0, dashes.contains(text[start - 1]) { return nil }
        var before = start
        while before > 0, text[before - 1].isWhitespace { before -= 1 }
        var from = before
        while from > 0, text[from - 1].isLetter { from -= 1 }
        if from < before, bigger.contains(String(text[from..<before])) || numberWords[String(text[from..<before])] != nil { return nil }
        return (value, start)
    }

    /// The word right before `index` (whitespace, and a period after an abbreviation, skipped), lowercased; "" when none.
    static func wordBefore(_ index: Int, in text: [Character]) -> String {
        var cursor = index
        while cursor > 0, text[cursor - 1].isWhitespace { cursor -= 1 }
        if cursor > 0, text[cursor - 1] == "." { cursor -= 1 }
        var start = cursor
        while start > 0, text[start - 1].isLetter { start -= 1 }
        return String(text[start..<cursor])
    }

    /// The characters that join two numbers or a number and its unit, as a hyphen does: hyphen, en dash, em dash, minus sign and "/".
    static let dashes: Set<Character> = ["-", "\u{2013}", "\u{2014}", "\u{2212}", "/"]

    /// The words that join two ends of a range, between them and the second end: one word or a short phrase, as said.
    static let rangeConnectors: Set<String> = [
        "", "or", "to", "and", "through", "thru", "till", "until", "up to", "vs", "versus", "plus", "or else", "or more",
    ]

    /// Whether the number word "one" at token `i` is one end of a range: a number (a digit or a number word) follows it, or a number
    /// or unit word precedes it, with between them only characters that aren't letters (any punctuation or spacing: "one - two",
    /// "one; two", "one... two") or a connector word (`rangeConnectors`: "one up to two", "a week vs one"). A bare "one" anywhere else
    /// ("which one", "for each one", "one of them") is a pronoun and no number. The other number words never ask: from two up, one
    /// with no unit after it is bare always (fix rounds 2 to 4, the coordinating session, 2026-11-27: the default is turned round, a
    /// closed list of separators missed every one it hadn't named).
    static func inARange(_ i: Int, _ tokens: [(word: String, start: Int, end: Int)], in text: [Character]) -> Bool {
        func isNumber(_ word: String) -> Bool { word.first?.isNumber == true || numberWords[word] != nil || bigNumbers.contains(word) }
        /// The words strictly between two tokens, joined by a space: "" when only punctuation and spacing stand between them.
        func between(_ a: Int, _ b: Int) -> String { tokens[(a + 1)..<b].map(\.word).joined(separator: " ") }
        for distance in 1...3 {
            if i + distance < tokens.count, isNumber(tokens[i + distance].word), rangeConnectors.contains(between(i, i + distance)) { return true }
            if i - distance >= 0, isNumber(tokens[i - distance].word) || units[tokens[i - distance].word] != nil,
               rangeConnectors.contains(between(i - distance, i)) { return true }
        }
        return false
    }

    /// The numbers the sentence gives in days, weeks (seven days each) or years, in digits or as a word from one to twelve ("two
    /// weeks" is 14 days; "a year" is 1), through the same checks. A number written with a joiner ("1.5 years",
    /// "-30 days", "30-60 days", "1,000 days"), a number glued to letters that aren't a unit ("90d"), months (their days vary)
    /// and a unit word with no number before it ("this year", "a few weeks") are problems, never a value. A number with no unit
    /// after it is kept apart (`Said.bare`): `check` makes it a problem for a choice that takes a number (the coordinating
    /// session, 2026-11-27, round 3). "90-day" is 90 days: a hyphen between the digits and the unit is not a joiner.
    static func numbers(in sentence: String) -> Said {
        let text = Array(sentence.lowercased()), original = Array(sentence)
        var said = Said(), used: Set<Int> = []
        var tokens: [(word: String, start: Int, end: Int)] = []
        var cursor = 0
        while cursor < text.count {
            guard text[cursor].isLetter || text[cursor].isNumber else { cursor += 1; continue }
            var end = cursor
            while end < text.count, text[end].isLetter || text[end].isNumber { end += 1 }
            tokens.append((String(text[cursor..<end]), cursor, end))
            cursor = end
        }
        func letters(from start: Int) -> (word: String, end: Int) {
            var end = start
            while end < text.count, text[end].isLetter { end += 1 }
            return (String(text[start..<end]), end)
        }
        /// A number and its unit word, once read: a problem, or a value (weeks as seven days each).
        func record(_ cluster: String, _ word: String, _ unit: String, said written: String? = nil) {
            let phrase = written ?? "\(cluster) \(word)"
            if cluster.contains(where: { joiners.contains($0) }) {
                said.problems.append("\u{201C}\(phrase)\u{201D} isn't a whole number in plain digits.")
            } else if unit == "months" {
                said.problems.append("\u{201C}\(phrase)\u{201D}: months aren't read, as their days vary. Give days.")
            } else if unit == "hours" || unit == "minutes" {
                said.problems.append("\u{201C}\(phrase)\u{201D}: \(unit) aren't read. Give days.")
            } else if unit == "weeks" {
                if let weeks = Int(cluster), case let (days, overflow) = weeks.multipliedReportingOverflow(by: 7), !overflow {
                    said.values["days", default: []].append(String(days))
                } else {
                    said.values["days", default: []].append(cluster)
                }
            } else {
                said.values[unit, default: []].append(cluster)
            }
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
                if glued, !word.isEmpty {
                    said.problems.append(gluedWords("\(cluster)\(word)"))
                } else {
                    said.bare.append(cluster)
                }
                continue
            }
            used.insert(next)
            // A hedge or a past time is no window (fix round 2): "about 30 days", "30 days or so", "30 days ago", "2 years and a half".
            let hedged = ["days", "weeks", "years"].contains(unit)
                && (hedgeBefore.contains(wordBefore(start, in: text)) || hedgedAfter(wordEnd, in: text, ranges: false))
            if hedged {
                said.problems.append("\u{201C}\(cluster) \(word)\u{201D} is hedged or in the past, not a window: give one number of days, weeks or years.")
            } else {
                record(cluster, word, unit)
            }
            index = max(index, wordEnd)
        }
        // A unit word no digits came before: a number word (one to twelve, "a"/"an" for one) read the same way, else a problem.
        var position = 0
        while position < text.count {
            guard text[position].isLetter, position == 0 || !text[position - 1].isLetter else { position += 1; continue }
            let (word, end) = letters(from: position)
            if spelled.contains(word) || abbreviated.contains(word), !used.contains(position) {
                if let found = spelledNumber(before: position, in: text, unit: word) {
                    // Quoted as the sentence says it ("a month", not "1 month").
                    let source = original.count == text.count ? original : text
                    record(String(found.value), word, units[word]!, said: String(source[found.start..<end]))
                } else if spelled.contains(word) {
                    said.problems.append("\u{201C}\(word)\u{201D} has no number in digits before it, such as 30 days.")
                }
            } else if numberWords[word] != nil || bigNumbers.contains(word) {
                // A number word with no unit after it, in a range, is kept apart as a digit is (`Said.bare`): "one or two years",
                // "between one and two years". Alone ("which one") it is no number.
                var after = end
                if after < text.count, dashes.contains(text[after]) { after += 1 } else { while after < text.count, text[after].isWhitespace { after += 1 } }
                let unitAfter = units[after < text.count && text[after].isLetter ? letters(from: after).word : ""] != nil
                // From two up a number word with no unit after it is bare always; "one" only in a range, as it is also a pronoun.
                if !unitAfter, word != "one" || tokens.firstIndex(where: { $0.start == position }).map({ inARange($0, tokens, in: text) }) == true {
                    said.bare.append(word)
                }
            }
            position = end
        }
        return said
    }
}
