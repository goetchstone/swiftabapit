import Foundation
import Testing
@testable import Assist

/// The model half. It calls the on-device model, so it never runs in the fast run or on CI (the runners have none):
/// `ABAPIT_MODEL_EVALS=1 swift test --filter ModelEvaluations`. Until S9.6 brings the model picker there is nothing to call:
/// the test is skipped with that reason, and when the flag is set it fails, so a flag set early can't pass by doing nothing.
/// S9.6 fills it in with a `PickEvaluation` whose `pick` is the model's, for dev and then (S9.8) held out, judged by the same
/// `Judge` and set against `WordRule`'s score.
@Suite("ModelEvaluations") struct ModelEvaluations {
    static let flagged = ProcessInfo.processInfo.environment["ABAPIT_MODEL_EVALS"] == "1"

    @Test(.enabled(if: ModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set: these evaluations call the on-device model, which waits for the model picker (S9.6)"))
    func theModelBeatsTheWordRule() throws {
        Issue.record("the model picker doesn't exist yet (S9.6): nothing to evaluate")
    }
}
