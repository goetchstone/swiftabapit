#if DEBUG
import Assist
import Foundation
import FoundationModels

/// Debug builds only: the model the Ask and the Needs-attention explanations use for the screenshots, so a picture never depends on
/// the Mac's own model. `ABAPIT_MODEL=unavailable` stands in for Apple Intelligence turned off; `available`, and the demo with no
/// `ABAPIT_MODEL`, for a model that answers. The Ask asks it nothing in a screenshot (no question is typed), and a question asked of it
/// is not understood. An explanation's prompt (it starts "Check:") gets two fixed sentences with the prompt's own count, which go
/// through the explainer's checks like any answer.
struct DemoModel: Picker.Asking {
    let availability: SystemLanguageModel.Availability
    var supportsLocale: Bool { true }

    enum Unanswered: Error { case demo }

    func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        guard prompt.hasPrefix("Check: "),
              let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("Findings: ") }),
              let count = line.dropFirst("Findings: ".count).split(separator: ";").first.flatMap({ Int($0) }) else { throw Unanswered.demo }
        let sentences = ["The check found \(count) finding\(count == 1 ? "" : "s") for this client.",
                         "Each one is listed below with the reason it was raised."]
        let json = try JSONSerialization.data(withJSONObject: ["sentences": sentences])
        return try GeneratedContent(json: String(decoding: json, as: UTF8.self))
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
