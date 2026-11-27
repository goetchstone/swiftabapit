import Evaluations
import Foundation
import FoundationModels
import Reports
import TestSupport
import Testing
@testable import Assist

/// One invented fact set: what the explainer is given about one rule. Invented, no tenant data.
struct FactSample: Codable, Sendable, Equatable {
    struct Thresholds: Codable, Sendable, Equatable {
        var checkInDays: Int
        var appleCareExpiringDays: Int
        var migrationDeadlineDays: Int
        var quietServiceDays: Int
    }

    var id: String
    var rule: String
    var thresholds: Thresholds
    var found: Int
    var hidden: Int
    var read: Explain.Read
    var ageDays: Int?

    var facts: Explain.Facts {
        let t = thresholds
        return Explain.Facts(rule: NeedsAttention.Rule(rawValue: rule)!,
                             thresholds: .init(checkInDays: t.checkInDays, appleCareExpiringDays: t.appleCareExpiringDays,
                                               migrationDeadlineDays: t.migrationDeadlineDays, quietServiceDays: t.quietServiceDays),
                             found: found, hidden: hidden, read: read, ageDays: ageDays)
    }
}

struct FactFile: Codable { var about: String; var facts: [FactSample] }

/// The explainer's two fact files. The dev file is what the instructions and checks are tuned on. The set held back is read by the
/// shape test and by one flagged run, and by nothing else (`ExplainSampleFileTests` holds that).
enum ExplainSamples {
    static func load(_ name: String) throws -> [FactSample] {
        try JSONDecoder().decode(FactFile.self, from: Data(contentsOf: Samples.folder.appending(path: name + ".json"))).facts
    }

    static func dev() throws -> [FactSample] { try load("explain-dev") }
    /// The set held back now (the fix round of PR 58, written before the fixes). Named so the picker's held-out scans
    /// (`SampleFileTests`) never see this file's name or reader as theirs.
    static func explainHeldOut() throws -> [FactSample] { try load("explain-" + "held" + "out-2") }
    /// The first set held back, superseded (its run's scan shared the checker's blind spots): read by the shape test only.
    static func explainHeldOutFirst() throws -> [FactSample] { try load("explain-" + "held" + "out") }
}

/// What one fact set's explanation came to, as the evaluation carries it.
struct ExplainCase: Codable, Sendable {
    var sample: FactSample
    var kept: [String] = []
    /// Sentences written and dropped; written is zero when the call failed or the model was off.
    var written = 0
    var dropped = 0
}

/// Apple's `Evaluations` over an explainer: any `(Facts) -> (Outcome, written)`, so a scripted explainer runs it in the fast run and
/// the on-device model behind `ABAPIT_MODEL_EVALS=1`. Three code evaluators: an explanation with at least one kept sentence; the
/// share of written sentences dropped; and numbers in kept sentences that aren't the facts' (`Unsupported`, a scan of its own, not
/// the checker's), which must be 0.
struct ExplainEvaluation: Evaluation {
    let samples: [FactSample]
    let explain: @Sendable (Explain.Facts) async throws -> (outcome: Explain.Outcome, written: Int)
    let kept = Metric("Kept")
    let dropRate = Metric("Dropped share")
    let unsupported = Metric("Unsupported numbers")
    static let unsupportedSum = "Unsupported numbers, in all"

    var dataset: ArrayLoader<ModelSample<ExplainCase>> {
        ArrayLoader(samples: samples.map { ModelSample(prompt: $0.id, expected: ExplainCase(sample: $0)) })
    }

    func subject(from sample: ModelSample<ExplainCase>) async throws -> ModelSubject<ExplainCase> {
        guard var made = sample.expected else { throw PickEvaluationError.noCase }
        let (outcome, written) = try await explain(made.sample.facts)
        made.kept = outcome.sentences
        made.written = written
        made.dropped = outcome.dropped.count
        return ModelSubject(value: made)
    }

    var evaluators: Evaluators {
        Evaluator { _, subject in
            subject.value.kept.isEmpty ? kept.failing(rationale: subject.value.sample.id) : kept.passing()
        }
        Evaluator { _, subject in
            let made = subject.value
            return made.written == 0 ? dropRate.ignore() : dropRate.scoring(Double(made.dropped) / Double(made.written))
        }
        Evaluator { _, subject in
            let made = subject.value
            return unsupported.scoring(Double(made.kept.map { Unsupported.count($0, made.sample.facts) }.reduce(0, +)))
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: kept)
        aggregator.computeMean(of: dropRate)
        aggregator.custom(of: unsupported, label: Self.unsupportedSum) { $0.reduce(0, +) }
    }
}

/// What a kept sentence states that the facts don't hold, found apart from the checker: written separately here (regular
/// expressions and word lists of its own, none of `Explain`'s code or lists; the coordinating session, 2026-11-27, fix round: the
/// first scan shared the checker's blind spots). It is not independent in design, though: it shares the checker's place-window idea
/// (a number held to its fact by the words near it) and word lists much like the checker's, so it can't catch what both miss: a
/// number placed by proximity ("within 3 days, per the snapshot"), advice with no listed word ("The next step is renewal."), a claim
/// against the rule, a lowercase name, meaning in general. Its "0 unsupported" measures only the classes below. Each counts one:
/// - a number that isn't a fact's with its unit and in its place: a count of findings (or of what the rule finds: services for the
///   quiet service rule, devices or Macs for the others) that is neither the found count nor, beside dismissed/snoozed/hidden words,
///   the hidden one; days that are neither the threshold beside window words nor the age beside age words; another unit; no unit;
/// - a zero ("no devices", "none", "nothing", "zero", "0") while the rule found something, other than "none dismissed or snoozed";
/// - a digit glued to letters or of another script, a decimal, a percentage, an ordinal, a vague count or span, a scale word;
/// - a part read said whole ("nothing was missed", "it covered each Mac", "complete");
/// - "nothing needs attention" while the rule found something ("no issues", "are fine").
enum Unsupported {
    static let small: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                       "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                       "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    static let decades: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                                         "ninety": 90]

    /// Patterns that state something no fact holds wherever they stand.
    static let alwaysWrong = [
        #"\d+(st|nd|rd|th)\b"#, #"\d[a-z]"#, #"[a-z]\d"#, #"\d[.,]\d"#, #"%"#, #"[\p{Nd}&&[^\x00-\x7F]]"#,
        #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|hundredth|thousandth)\b"#,
        #"\b(couple|several|both|most|many|few|handful|numerous|single|dozens?|hundreds|thousands|half|twice|double|triple|majority|percent)\b"#,
        // "All" only as the findings' own: "all 12 Macs", "all of these", "all of them" (and "all clear", which `allClear` counts).
        #"\ball\b(?!\s+(\d+|[a-z]+teen|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|of\s+(these|those|them)|clear|good)\b)"#,
        #"\b(fortnight|quarter|tomorrow|yesterday|tonight)\b"#, #"\b(last|next|this|past|coming) (week|month|year)s?\b"#,
        #"\b(hundred|thousand|million)\b"#,
    ]
    /// A part read said whole.
    static let wholeOverPart = [
        #"\b(complete|completely|entire|entirely|entirety|whole|full|fully|thorough|thoroughly|exhaustive|exhaustively)\b"#,
        #"\b(each|every|all)\b.*\b(read|checked|scanned|covered|looked|included|reviewed|examined|counted|found|listed)\b"#,
        #"\b(read|checked|scanned|covered|looked|included|reviewed|examined|counted|found|listed)\b.*\b(each|every|all)\b"#,
        // Nothing or none missed, or never missing: "nothing was missed", "no Mac was skipped", "it didn't miss any". Not "some wasn't
        // read, possibly missing some", which says the part read.
        #"\b(nothing|none|no \w+) (was|were|is|are|got|has been|have been) (missed|skipped|overlooked)\b"#,
        #"\b(didn't|did not|never|without) (miss|skip|overlook)\w*"#,
    ]
    /// Nothing needs attention, said of a rule that found something.
    static let allClear = [#"\b(fine|healthy|okay|ok|secure|protected|everything|harmless)\b"#,
                           #"\bno (attention|issues?|problems?|action|concerns?|risks?)\b"#, #"\bnothing (needs|to)\b"#,
                           #"\bneeds? no\b"#, #"\ball (clear|good)\b"#, #"\blooks? good\b"#, #"\bpass(es)?\b"#,
                           // "safe" said of the findings ("these Macs are safe"), not of what FileVault keeps.
                           #"\b(they|these|those|it|them|devices?|macs?|services?|computers?|iphones?|ipads?)\b(\W+\w+){0,3}?\W+(is|are) safe\b"#]
    /// Rule by rule: an encrypted Mac is no FileVault finding.
    static func ruleAllClear(_ rule: NeedsAttention.Rule) -> [String] { rule == .fileVaultOff ? [#"\bencrypted\b"#] : [] }

    static func matches(_ text: String, _ patterns: [String]) -> Int {
        patterns.filter { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }.count
    }

    static func nouns(of rule: NeedsAttention.Rule) -> (own: Set<String>, foreign: Set<String>) {
        let findings: Set<String> = ["finding", "findings", "alert", "alerts", "case", "cases", "issue", "issues", "result", "results",
                                     "item", "items", "entry", "entries", "instance", "instances", "them"]
        let services: Set<String> = ["service", "services"]
        let devices: Set<String> = ["device", "devices", "mac", "macs", "iphone", "iphones", "ipad", "ipads", "computer", "computers"]
        return rule == .quietService ? (findings.union(services), devices) : (findings.union(devices), services)
    }

    static func count(_ sentence: String, _ facts: Explain.Facts) -> Int {
        let text = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"(\d),(\d{3})\b"#, with: "$1$2", options: .regularExpression)
        var wrong = matches(text, alwaysWrong)
        if facts.read == .partial { wrong += min(matches(text, wholeOverPart), 1) }
        if facts.found > 0 { wrong += min(matches(text, allClear + ruleAllClear(facts.rule)), 1) }

        let words = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted).filter { !$0.isEmpty }
        let (own, foreign) = nouns(of: facts.rule)
        let threshold = facts.rule.thresholdDays(facts.thresholds)
        func context(_ at: Int) -> String { words[max(0, at - 6)..<min(words.count, at + 7)].joined(separator: " ") }
        func beside(_ at: Int, _ pattern: String) -> Bool { context(at).range(of: pattern, options: .regularExpression) != nil }
        let hiding = #"\b(dismiss|snooz|hid)\w*"#
        let window = #"\b(within|than|least|over|beyond|threshold|window|longer|more|for|past|after|limit)\b"#
        let aged = #"\b(old|snapshots?|ago|age|aged|taken)\b"#
        /// A zero is the hidden count only, beside its words, when none were hidden; or the found count when nothing was found.
        func zeroHolds(_ at: Int) -> Bool { facts.found == 0 || (facts.hidden == 0 && beside(at, hiding)) }

        var at = 0
        while at < words.count {
            let word = words[at]
            var value: Int?
            var after = at + 1
            if let digits = Int(word), word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                value = digits
            } else if let tens = decades[word] {
                value = tens
                if after < words.count, let unit = small[words[after]], (1...9).contains(unit) { value = tens + unit; after += 1 }
            } else if let number = small[word] {
                value = number
            } else if word == "none" || word == "nothing" {
                if !zeroHolds(at) { wrong += 1 }
                at += 1
                continue
            } else if word == "no", at + 1 < words.count, own.contains(words[at + 1]) || foreign.contains(words[at + 1]) {
                if foreign.contains(words[at + 1]) || !zeroHolds(at) { wrong += 1 }
                at += 2
                continue
            }
            guard let number = value else { at += 1; continue }
            // The unit: the first noun in the next five words ("2 of the 5 devices"); for "one", the next two, as it is the pronoun as
            // often as the number ("each one is listed; two findings are hidden").
            let ahead = words[after..<min(words.count, after + (word == "one" ? 2 : 5))]
            if let noun = ahead.first(where: { own.contains($0) || foreign.contains($0) || ["day", "days", "week", "weeks", "month", "months",
                                                                                            "year", "years", "hour", "hours", "minute", "minutes"].contains($0) }) {
                if own.contains(noun) {
                    let ok = number == 0 ? zeroHolds(at) : (number == facts.found || (number == facts.hidden && beside(at, hiding)))
                    if !ok { wrong += 1 }
                } else if noun == "day" || noun == "days" {
                    let asThreshold = threshold == number && beside(at, window)
                    let asAge = facts.ageDays == number && beside(at, aged)
                    if !asThreshold && !asAge { wrong += 1 }
                } else {
                    wrong += 1
                }
            } else if number == 0 {
                if !zeroHolds(at) { wrong += 1 }
            } else if word != "one" {
                wrong += 1
            }
            at = after
        }
        return wrong
    }
}

/// The evaluation's own checks, in the fast run with scripted explainers (no model).
@Suite("Explain evaluation")
struct ExplainEvaluationTests {
    @Test func theIndependentScanFindsWhatTheFactsDontHold() {
        let facts = ExplainTests.facts() // 90 days, 5 found, 2 hidden, 3 days old
        #expect(Unsupported.count("This check found 5 devices within 90 days; the snapshot is 3 days old; 2 findings are hidden.", facts) == 0)
        #expect(Unsupported.count("It found 6 devices.", facts) == 1)
        #expect(Unsupported.count("It found twenty five devices and 1,043 more devices.", facts) == 2)
        #expect(Unsupported.count("Each one is listed; two findings are hidden.", facts) == 0)
        #expect(Unsupported.count("The administrator dismissed or snoozed 2 of those 5 devices.", facts) == 0)
        #expect(Unsupported.count("About a hundred devices.", facts) == 1)
        #expect(Unsupported.count("It found 1,043 devices.", ExplainTests.facts(found: 1043, hidden: 0)) == 0)
        // The fix round's cases (the coordinating session, 2026-11-27): each counted, none through the checker's code.
        let noneHidden = ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0)
        for (sentence, made) in [("No Macs have FileVault off.", noneHidden), ("Nothing was found.", noneHidden),
                                 ("These devices are fine.", facts), ("2 devices have coverage ending within 90 days.", facts),
                                 ("Coverage ends within 3 days.", facts), ("The snapshot is 90 days old.", facts), ("The 5th device.", facts),
                                 ("It found 7devices.", facts), ("A couple of devices.", facts), ("It found 4 devices.", ExplainTests.facts(.quietService, found: 4, hidden: 0, ageDays: nil)),
                                 ("Nothing was missed.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("It covered each Mac.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("No Mac was skipped.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("It didn't miss a Mac.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 // Fix round 2 (the coordinating session, 2026-11-27).
                                 ("Every Mac is encrypted.", noneHidden), ("These Macs are secure.", noneHidden), ("They are protected.", noneHidden),
                                 ("The Macs pass the check.", noneHidden), ("There is no risk.", noneHidden),
                                 ("For now, everything looks good.", noneHidden), ("These Macs are safe.", noneHidden),
                                 ("All Macs have FileVault off.", noneHidden),
                                 ("The read was thorough.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("It read the lists in their entirety.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("It found every Mac.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial))] {
            #expect(Unsupported.count(sentence, made) >= 1, Comment(rawValue: sentence))
        }
        for (sentence, made) in [("None were dismissed or snoozed.", noneHidden), ("It found 4 Macs with FileVault off.", noneHidden),
                                 ("It found 4 services.", ExplainTests.facts(.quietService, found: 4, hidden: 0, ageDays: nil)),
                                 ("It may have missed some Macs.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("Some data wasn't read, possibly missing some Macs.", ExplainTests.facts(.fileVaultOff, found: 4, hidden: 0, read: .partial)),
                                 ("FileVault keeps the data on a Mac safe.", noneHidden), ("Twelve Macs have FileVault off.", ExplainTests.facts(.fileVaultOff, found: 12, hidden: 0)),
                                 ("All 4 Macs have FileVault off.", noneHidden), ("All of these Macs have FileVault off.", noneHidden),
                                 ("A device that is not enrolled is missing from Apple MDM.", ExplainTests.facts(.missingFromAppleMDM, found: 4, hidden: 0, read: .partial))] {
            #expect(Unsupported.count(sentence, made) == 0, Comment(rawValue: sentence))
        }
    }

    /// A scripted explainer whose first sentence holds and whose second states a number the facts don't: one kept per sample, half
    /// dropped, no unsupported number kept. Then one that keeps an unsupported number past a (planted) broken checker: the evaluator
    /// counts it, so a checker bug can't hide behind the checker.
    @Test func theEvaluatorsScoreAScriptedExplainer() async throws {
        let dev = try ExplainSamples.dev()
        let good = ExplainEvaluation(samples: dev) { facts in
            let outcome = Explain.judge(["This check found \(facts.found) findings.", "It found \(facts.found + 1000) devices."], facts)
            return (outcome, 2)
        }
        let result = try await good.run(info: ["split": "dev", "explainer": "scripted"])
        #expect(result.aggregateValue(.mean(of: good.kept)) == 1)
        #expect(abs(result.aggregateValue(.mean(of: good.dropRate)) - 0.5) < 1e-9)
        #expect(result.aggregateValue(.custom(label: ExplainEvaluation.unsupportedSum)) == 0)

        let leaky = ExplainEvaluation(samples: dev) { facts in
            (.explained(sentences: ["It found \(facts.found + 1000) devices."], dropped: []), 1)
        }
        let leaked = try await leaky.run(info: ["split": "dev", "explainer": "leaky"])
        #expect(leaked.aggregateValue(.custom(label: ExplainEvaluation.unsupportedSum)) == Double(dev.count))
    }
}
