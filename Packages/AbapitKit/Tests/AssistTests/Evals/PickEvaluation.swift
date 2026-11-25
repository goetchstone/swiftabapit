import Evaluations
import Foundation
import Testing
@testable import Assist

/// One sample as the evaluation carries it: the sample, and what the thing under test answered.
struct PickCase: Codable, Sendable {
    var sample: Sample
    var answered = ""
}

/// Apple's `Evaluations` over a picker: any `(sentence) -> Answer`, so `WordRule` runs it in the fast run and S9.6's model picker
/// runs the same evaluation behind `ABAPIT_MODEL_EVALS=1`. Three code evaluators, one metric each (`Evaluators`); a sample a
/// metric doesn't apply to isn't in that metric's dataset.
struct PickEvaluation: Evaluation {
    enum Kind: String, Sendable { case report, group, refusal }

    let kind: Kind
    let samples: [Sample]
    let choices: [Choices.Choice]
    let pick: @Sendable (String) async throws -> WordRule.Answer
    let right = Metric("Right")

    func applies(_ sample: Sample) -> Bool {
        switch kind {
        case .report: Judge.report(sample, .refuse) != nil
        case .group: Judge.group(sample, .refuse, choices: choices) != nil
        case .refusal: Judge.refusal(sample, .changeRequest) != nil
        }
    }

    var dataset: ArrayLoader<ModelSample<PickCase>> {
        ArrayLoader(samples: samples.filter(applies).map { ModelSample(prompt: $0.text, expected: PickCase(sample: $0)) })
    }

    func subject(from sample: ModelSample<PickCase>) async throws -> ModelSubject<PickCase> {
        guard var made = sample.expected else { throw PickEvaluationError.noCase }
        let answer = try await pick(made.sample.text)
        made.answered = answer.printed
        return ModelSubject(value: made)
    }

    var evaluators: Evaluators {
        Evaluator { _, subject in
            // The answer is kept as the text it printed; judge it again from the typed one.
            let made = subject.value
            return judged(made) ? right.passing() : right.failing(rationale: "\(made.sample.id): \(made.answered)")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) { aggregator.computeMean(of: right) }

    private func judged(_ made: PickCase) -> Bool { PickEvaluation.verdict(made, kind: kind, choices: choices) }

    static func verdict(_ made: PickCase, kind: Kind, choices: [Choices.Choice]) -> Bool {
        let answer = WordRule.Answer(printed: made.answered)
        return switch kind {
        case .report: Judge.report(made.sample, answer) ?? false
        case .group: Judge.group(made.sample, answer, choices: choices) ?? false
        case .refusal: Judge.refusal(made.sample, answer) ?? false
        }
    }
}

enum PickEvaluationError: Error { case noCase }

extension WordRule.Answer {
    /// The answer back from its printed form, so an evaluation's subject can be a plain `Codable` string.
    init(printed: String) {
        if printed == "changeRequest" { self = .changeRequest; return }
        if printed == "refuse" { self = .refuse; return }
        let parts = printed.components(separatedBy: "\u{1F}")
        self = parts.count == 3 && parts[0] == "choice" ? .choice(parts[1], group: parts[2].isEmpty ? nil : parts[2]) : .refuse
    }

    var printed: String {
        switch self {
        case .changeRequest: "changeRequest"
        case .refuse: "refuse"
        case .choice(let id, let group): ["choice", id, group ?? ""].joined(separator: "\u{1F}")
        }
    }
}
