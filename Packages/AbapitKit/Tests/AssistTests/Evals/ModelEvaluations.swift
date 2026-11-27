import Foundation
import FoundationModels
import Testing
@testable import Assist

/// The model half. It calls the on-device model, so it never runs in the fast run or on CI (the runners have none):
/// `ABAPIT_MODEL_EVALS=1 swift test --filter ModelEvaluations`. Even with the flag, it refuses to run when `CI` or
/// `GITHUB_ACTIONS` is set, and with the flag set on a Mac whose model isn't available it fails, so a flag can't pass by doing
/// nothing. It scores the model picker on the dev samples only, through the same `Judge` and `PickEvaluation` as `WordRule`,
/// with `WordRule`'s score printed beside it; the held-out samples are `theModelOnHeldOut`'s single run, behind a second switch.
@Suite("ModelEvaluations", .serialized) struct ModelEvaluations {
    /// Whether the evaluations may run with this environment: the flag is `1`, and neither `CI` nor `GITHUB_ACTIONS` is set.
    static func mayRun(_ environment: [String: String]) -> Bool {
        func set(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
        return environment["ABAPIT_MODEL_EVALS"] == "1" && !set("CI") && !set("GITHUB_ACTIONS")
    }

    static let flagged = mayRun(ProcessInfo.processInfo.environment)

    /// Whether the held-out run may happen: the flag above, and `ABAPIT_MODEL_EVALS_SET=held-out` besides, so the dev run never
    /// reaches it. Run it once, with `--filter theModelOnHeldOut`.
    static func mayRunHeldOut(_ environment: [String: String]) -> Bool {
        mayRun(environment) && environment["ABAPIT_MODEL_EVALS_SET"] == "held-out"
    }

    static let heldOutFlagged = mayRunHeldOut(ProcessInfo.processInfo.environment)

    /// The client the samples are written for: the largest list.
    static let client = Picker.Client(scope: .business, hasMosyle: true, thresholds: Samples.thresholds)

    /// The picker's outcome as the evaluators judge it: any refusal is a refusal.
    static func judged(_ outcome: Picker.Outcome) -> WordRule.Answer {
        switch outcome {
        case .picked(let pick): .choice(pick.choice.id, group: pick.group)
        case .changeRequest: .changeRequest
        case .refused: .refuse
        }
    }

    @Test(.enabled(if: ModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set, or CI or GITHUB_ACTIONS is: these evaluations call the on-device model"))
    func theModelBeatsTheWordRuleOnDev() async throws {
        let model = ModelPicker.OnDevice()
        try #require(model.availability == .available, "the flag is set and the on-device model isn't available on this Mac")
        #expect(Samples.choices == Self.client.choices)
        let dev = try Samples.dev()
        // Each sample is asked once; the three evaluations read the answers kept here.
        var answers: [String: WordRule.Answer] = [:], refusals: [String: Int] = [:], times: [Duration] = []
        let clock = ContinuousClock()
        for sample in dev {
            let start = clock.now
            let outcome = try await Picker.pick(sample.text, for: Self.client, using: model)
            times.append(start.duration(to: clock.now))
            answers[sample.text] = Self.judged(outcome)
            if case .refused(let refusal) = outcome { refusals[String(describing: refusal), default: 0] += 1 }
        }
        let kept = answers
        let choices = Self.client.choices
        let score = Judge.score(dev, choices: choices) { kept[$0]! }
        let words = Judge.score(dev, choices: choices) { WordRule.answer($0, choices: choices) }
        print("EVAL model dev: \(score.summary)")
        print("EVAL wordrule dev: \(words.summary)")
        let seconds = times.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        print("EVAL model dev time: mean \(String(format: "%.2f", seconds.reduce(0, +) / Double(seconds.count))) s, most \(String(format: "%.2f", seconds.max() ?? 0)) s")
        print("EVAL model dev refusals: \(refusals.sorted { $0.key < $1.key })")
        for sample in dev {
            let answer = kept[sample.text]!
            let right = [Judge.report(sample, answer), Judge.group(sample, answer, choices: choices), Judge.refusal(sample, answer)]
            if right.contains(false) { print("EVAL miss \(sample.id): \(answer)") }
        }
        // The same through Apple's Evaluations, which must agree with the code evaluators.
        for (kind, right, of) in [(PickEvaluation.Kind.report, score.report, score.reports), (.group, score.group, score.groups),
                                  (.refusal, score.refusal, score.refusals)] {
            let evaluation = PickEvaluation(kind: kind, samples: dev, choices: choices) { kept[$0]! }
            let result = try await evaluation.run(info: ["split": "dev", "picker": "model"])
            #expect(abs(result.aggregateValue(.mean(of: evaluation.right)) - Double(right) / Double(of)) < 1e-9, Comment(rawValue: "\(kind)"))
        }
        #expect(score.report > words.report, "the model picks more reports right than the word rule on dev")
    }

    /// The single held-out run: the same picker, `Judge` and `WordRule` beside it, scores and times only. It prints no sentence,
    /// no sample id and no miss, asserts no score (a result is recorded, never tuned against), and is not part of the dev run.
    @Test(.enabled(if: ModelEvaluations.heldOutFlagged, "ABAPIT_MODEL_EVALS=1 and ABAPIT_MODEL_EVALS_SET=held-out are not both set, or CI or GITHUB_ACTIONS is: the held-out run calls the on-device model"))
    func theModelOnHeldOut() async throws {
        let model = ModelPicker.OnDevice()
        try #require(model.availability == .available, "the flag is set and the on-device model isn't available on this Mac")
        let held = try Samples.heldOut()
        var answers: [String: WordRule.Answer] = [:], refusals: [String: Int] = [:], times: [Duration] = []
        let clock = ContinuousClock()
        for sample in held {
            let start = clock.now
            let outcome = try await Picker.pick(sample.text, for: Self.client, using: model)
            times.append(start.duration(to: clock.now))
            answers[sample.text] = Self.judged(outcome)
            if case .refused(let refusal) = outcome { refusals[String(describing: refusal), default: 0] += 1 }
        }
        let kept = answers
        let choices = Self.client.choices
        let score = Judge.score(held, choices: choices) { kept[$0]! }
        let words = Judge.score(held, choices: choices) { WordRule.answer($0, choices: choices) }
        print("EVAL model heldout: \(score.summary)")
        print("EVAL wordrule heldout: \(words.summary)")
        let seconds = times.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        print("EVAL model heldout time: mean \(String(format: "%.2f", seconds.reduce(0, +) / Double(seconds.count))) s, most \(String(format: "%.2f", seconds.max() ?? 0)) s, calls \(seconds.count)")
        print("EVAL model heldout refusals: \(refusals.sorted { $0.key < $1.key })")
    }

    /// The largest call of each pick, measured with the model's own `tokenCount`: the instructions, the prompt and the schema
    /// each counted on its own (so the fixed overhead of each count is in the total more than once), plus the response cap.
    @Test(.enabled(if: ModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set, or CI or GITHUB_ACTIONS is: tokenCount needs the on-device model"))
    func theWholeCallFitsTheBudget() async throws {
        let model = SystemLanguageModel.default
        try #require(model.availability == .available, "the flag is set and the on-device model isn't available on this Mac")
        for (name, instructions, prompt, schema) in try PickerTests.largestCalls() {
            let parts = [try await model.tokenCount(for: Instructions(instructions)), try await model.tokenCount(for: prompt),
                         try await model.tokenCount(for: schema)]
            let whole = parts.reduce(ModelPicker.responseCap, +)
            print("BUDGET tokenCount \(name): instructions \(parts[0]), prompt \(parts[1]), schema \(parts[2]), cap \(ModelPicker.responseCap): \(whole) of \(PickerTests.budget); context \(model.contextSize)")
            #expect(whole <= PickerTests.budget, Comment(rawValue: name))
        }
    }

    @Test func theHeldOutRunNeedsItsOwnSwitch() {
        #expect(!Self.mayRunHeldOut(["ABAPIT_MODEL_EVALS": "1"]))
        #expect(!Self.mayRunHeldOut(["ABAPIT_MODEL_EVALS_SET": "held-out"]))
        #expect(!Self.mayRunHeldOut(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "dev"]))
        #expect(Self.mayRunHeldOut(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "held-out"]))
        #expect(!Self.mayRunHeldOut(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "held-out", "CI": "true"]))
    }

    @Test func theFlagNeverRunsThemOnCI() {
        #expect(Self.mayRun(["ABAPIT_MODEL_EVALS": "1"]))
        #expect(!Self.mayRun([:]))
        #expect(!Self.mayRun(["ABAPIT_MODEL_EVALS": "0"]))
        #expect(!Self.mayRun(["ABAPIT_MODEL_EVALS": "1", "CI": "true"]))
        #expect(!Self.mayRun(["ABAPIT_MODEL_EVALS": "1", "GITHUB_ACTIONS": "true"]))
        #expect(!Self.mayRun(["ABAPIT_MODEL_EVALS": "1", "CI": "1", "GITHUB_ACTIONS": "true"]))
        #expect(Self.mayRun(["ABAPIT_MODEL_EVALS": "1", "CI": "", "GITHUB_ACTIONS": ""]), "an empty value is not set")
    }
}
