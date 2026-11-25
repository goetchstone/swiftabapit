import AppIntents
import AppModels

/// A serial number (or IMEI, MEID, EID, order number, MAC address) looked up in Apple's device list for the active client, as
/// the Devices screen's Find does, through `Answers` and nothing else. The identifier is never said back; the devices found are
/// shown, at most 10. In the background; the Mac's own authentication first (pending its live check).
struct LookUpSerialIntent: AppIntent {
    static let title: LocalizedStringResource = "Look Up a Serial Number"
    static let description = IntentDescription(
        "Finds the devices in Apple's device list for the active client whose serial number or other identifier matches, exactly or in part. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Serial Number", requestValueDialog: "Which serial number?")
    var serial: String

    @Dependency private var screens: ScreenModels

    static var parameterSummary: some ParameterSummary {
        Summary("Look up \(\.$serial)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.lookUp(serial: serial))
    }
}
