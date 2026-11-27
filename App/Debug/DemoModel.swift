#if DEBUG
import Assist
import Foundation
import FoundationModels

/// Debug builds only: the model the Ask uses for the screenshots, so a picture never depends on the Mac's own model.
/// `ABAPIT_MODEL=unavailable` stands in for Apple Intelligence turned off; `available`, and the demo with no `ABAPIT_MODEL`, for a
/// model that answers. It is asked nothing in a screenshot (no question is typed), and a question asked of it is not understood.
struct DemoModel: Picker.Asking {
    let availability: SystemLanguageModel.Availability
    var supportsLocale: Bool { true }

    enum Unanswered: Error { case demo }

    func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        throw Unanswered.demo
    }

    /// The model `ABAPIT_MODEL` asks for, the demo's when it asks none, or nil for the Mac's own.
    static func requested(demo: Bool) -> DemoModel? {
        switch ProcessInfo.processInfo.environment["ABAPIT_MODEL"] {
        case "unavailable": DemoModel(availability: .unavailable(.appleIntelligenceNotEnabled))
        case "available": DemoModel(availability: .available)
        default: demo ? DemoModel(availability: .available) : nil
        }
    }
}
#endif
