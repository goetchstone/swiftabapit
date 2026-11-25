import AppIntents
import AppModels

/// The Needs-attention summary over the active client (the operator, 2026-11-24: Q1 "Six reports + more"): the screen's own
/// evaluation, through `Answers` and nothing else. In the background; the Mac's own authentication first (pending its live check).
struct NeedsAttentionIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs Attention"
    static let description = IntentDescription(
        "Says how many findings each Needs-attention rule has open for the active client, how old the data is and how much was read. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.attention())
    }
}
