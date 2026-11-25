import Evaluations
import Foundation
import Testing
@testable import Assist

/// `WordRule` scored on the dev samples in the fast run: through Apple's `Evaluations` (it runs under plain `swift test`; no
/// model is called), and again by `Judge.score` so the two agree. The numbers are printed on a line starting `EVAL wordrule dev`
/// and pinned below: a change to the rule, the choices or the dev samples moves them, and the pin says so. Held out is not
/// scored here (a later run scores it beside the model's).
@Suite(.serialized) struct WordRuleEvaluations {
    static let choices = Samples.choices

    static func evaluation(_ kind: PickEvaluation.Kind) throws -> PickEvaluation {
        let choices = Self.choices
        return PickEvaluation(kind: kind, samples: try Samples.dev(), choices: choices) { text in WordRule.answer(text, choices: choices) }
    }

    static let report = try! evaluation(.report)
    static let group = try! evaluation(.group)
    static let refusal = try! evaluation(.refusal)

    /// What the evaluation measured, as a fraction of the samples it applies to.
    static func mean(_ result: EvaluationResult, _ e: PickEvaluation) -> Double { result.aggregateValue(.mean(of: e.right)) }

    @Test(.evaluates(WordRuleEvaluations.report, info: ["split": "dev", "picker": "WordRule"]))
    func reportOnDev() throws {
        let measured = Self.mean(EvaluationContext.current.result, Self.report)
        let score = Judge.score(try Samples.dev(), choices: Self.choices) { WordRule.answer($0, choices: Self.choices) }
        #expect(abs(measured - Double(score.report) / Double(score.reports)) < 1e-9)
        print("EVAL wordrule dev: \(score.summary)")
        #expect(score.summary == WordRuleScore.dev)
    }

    @Test(.evaluates(WordRuleEvaluations.group, info: ["split": "dev", "picker": "WordRule"]))
    func groupOnDev() throws {
        let measured = Self.mean(EvaluationContext.current.result, Self.group)
        let score = Judge.score(try Samples.dev(), choices: Self.choices) { WordRule.answer($0, choices: Self.choices) }
        #expect(abs(measured - Double(score.group) / Double(score.groups)) < 1e-9)
    }

    @Test(.evaluates(WordRuleEvaluations.refusal, info: ["split": "dev", "picker": "WordRule"]))
    func refusalOnDev() throws {
        let measured = Self.mean(EvaluationContext.current.result, Self.refusal)
        let score = Judge.score(try Samples.dev(), choices: Self.choices) { WordRule.answer($0, choices: Self.choices) }
        #expect(abs(measured - Double(score.refusal) / Double(score.refusals)) < 1e-9)
    }
}

/// The recorded dev score of `WordRule` (docs/domains/assist-intents.md, "Choices and the word rule").
enum WordRuleScore {
    static let dev = "report 108/188, group 30/81, refusal 24/24"
}
