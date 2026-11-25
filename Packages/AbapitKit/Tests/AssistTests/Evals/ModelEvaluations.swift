import Foundation
import Testing
@testable import Assist

/// The model half. It calls the on-device model, so it never runs in the fast run or on CI (the runners have none):
/// `ABAPIT_MODEL_EVALS=1 swift test --filter ModelEvaluations`. Even with the flag, it refuses to run when `CI` or
/// `GITHUB_ACTIONS` is set. Until the model picker exists there is nothing to call: the test is skipped with that reason, and when
/// the flag is set on a developer's Mac it fails, so a flag set early can't pass by doing nothing. The picker's step fills it in
/// with a `PickEvaluation` whose `pick` is the model's, for dev and then held out, judged by the same `Judge` and set against
/// `WordRule`'s score.
@Suite("ModelEvaluations") struct ModelEvaluations {
    /// Whether the evaluations may run with this environment: the flag is `1`, and neither `CI` nor `GITHUB_ACTIONS` is set.
    static func mayRun(_ environment: [String: String]) -> Bool {
        func set(_ key: String) -> Bool { !(environment[key] ?? "").isEmpty }
        return environment["ABAPIT_MODEL_EVALS"] == "1" && !set("CI") && !set("GITHUB_ACTIONS")
    }

    static let flagged = mayRun(ProcessInfo.processInfo.environment)

    @Test(.enabled(if: ModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set, or CI or GITHUB_ACTIONS is: these evaluations call the on-device model, which isn't built yet"))
    func theModelBeatsTheWordRule() throws {
        Issue.record("the model picker doesn't exist yet: nothing to evaluate")
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
