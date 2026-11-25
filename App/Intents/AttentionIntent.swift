import AppIntents
import AppModels

/// The Needs-attention summary over the active client (the operator, 2026-11-24: Q1 "Six reports + more"): the screen's rules,
/// judged and said through `Answers` and nothing else, and never recorded (the operator, 2026-11-25: "Don't record (Recommended)").
/// Declared background only, with the Mac's own authentication; what both do on a Mac is unverified (a live check).
struct NeedsAttentionIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs Attention"
    static let description = IntentDescription(
        "Says how many findings each Needs-attention rule has open for the active client, how old the data is and how much was read. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var answers: Answers

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await answers.attention())
    }
}
