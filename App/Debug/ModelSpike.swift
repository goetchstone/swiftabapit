#if DEBUG
import FoundationModels

/// S4 (plan §8 Phase 0, step 9): is the on-device model there? `ABAPIT_SPIKE=model`, headless. Its own
/// file: code that talks to a model stays apart from anything that can reach a write (invariant 9).
enum ModelSpike {
    static func run() -> Int32 {
        let model = SystemLanguageModel.default
        print("SystemLanguageModel.default.availability: \(model.availability)")
        print("supported languages: \(model.supportedLanguages.count)")
        return 0
    }
}
#endif
