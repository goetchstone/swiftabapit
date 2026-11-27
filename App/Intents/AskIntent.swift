import AppIntents
import AppModels

/// A question in words, read by Apple's on-device model and answered from one of abapit's reports, Needs attention or a serial
/// lookup (S9.7; the operator, 2026-11-24: Q3 "Picks + explanations"; D7 and D10: on-device only, only drafts). The answer says
/// first what it understood ("I read that as: …"); a request to change something drafts nothing. With the model off it says why
/// and names the fixed phrases that work without it. It reads only: `Answers` and nothing else, through `AskModel`. Declared
/// background only, with the Mac's own authentication; what both do on a Mac is unverified (a live check).
struct AskIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Question"
    static let description = IntentDescription(
        "Reads a question about the active client's devices with Apple's on-device model and answers it from abapit's reports, Needs attention or a serial lookup, saying first what it understood. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    @Dependency private var answers: Answers

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await AskModel(answers: answers).ask(question))
    }
}
