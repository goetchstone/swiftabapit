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
    /// Named so the picker's held-out scans (`SampleFileTests`) never see this file's name or reader as theirs.
    static func explainHeldOut() throws -> [FactSample] { try load("explain-" + "held" + "out") }
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

/// Numbers a sentence states that no fact holds, found apart from the checker so the evaluation can catch the checker's own misses:
/// every run of digits (a thousands comma joined) and every number word from two to ninety ("twenty five" as 25), its value held
/// to the facts' values whatever the unit. "One" is left out (it is the pronoun as often as the number), and a scale word
/// ("hundred", "thousand") counts as unsupported however it reads, to err toward finding one.
enum Unsupported {
    static let words = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
                        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
                        "nineteen": 19, "zero": 0]
    static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    static func values(_ sentence: String) -> (values: [Int], scales: Int) {
        let text = sentence.lowercased().replacing(/(\d),(\d{3})/) { "\($0.output.1)\($0.output.2)" }
        var values = text.matches(of: /\d+/).compactMap { Int($0.output) }
        let tokens = text.split { !$0.isLetter }.map(String.init)
        var index = 0
        while index < tokens.count {
            if let ten = tens[tokens[index]] {
                if index + 1 < tokens.count, let one = words[tokens[index + 1]], one < 10, one > 0 { values.append(ten + one); index += 2; continue }
                values.append(ten)
            } else if let word = words[tokens[index]] {
                values.append(word)
            }
            index += 1
        }
        let scales = tokens.filter { ["hundred", "thousand", "million", "dozen"].contains($0) }.count
        return (values, scales)
    }

    static func count(_ sentence: String, _ facts: Explain.Facts) -> Int {
        let known = Set(facts.numbers.map(\.value))
        let (values, scales) = values(sentence)
        return values.filter { !known.contains($0) }.count + scales
    }
}

/// The evaluation's own checks, in the fast run with scripted explainers (no model).
@Suite("Explain evaluation")
struct ExplainEvaluationTests {
    @Test func theIndependentScanFindsWhatTheFactsDontHold() {
        let facts = ExplainTests.facts() // 90 days, 5 found, 2 hidden, 3 days old
        #expect(Unsupported.count("This check found 5 devices within 90 days, 3 days old; 2 are hidden.", facts) == 0)
        #expect(Unsupported.count("It found 6 devices.", facts) == 1)
        #expect(Unsupported.count("It found twenty five devices and 1,043 more.", facts) == 2)
        #expect(Unsupported.count("Each one is listed; two are hidden.", facts) == 0)
        #expect(Unsupported.count("About a hundred devices.", facts) == 1)
        #expect(Unsupported.count("It found 1,043 devices.", ExplainTests.facts(found: 1043, hidden: 0)) == 0)
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
