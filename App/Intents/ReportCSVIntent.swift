import AppIntents
import AppModels
import Foundation

/// "Get report CSV", for Shortcuts only: no Siri phrase and no App Shortcut (a spoken request has nowhere to put a file). It returns
/// one report's CSV for the active client, byte for byte what the Reports screen's Export CSV writes for the same report, group and
/// number: the same allowlisted columns (`ExportPolicy`) and the same file name (the client's name first only when the app shows
/// clients). The same parameters as `RunReportIntent`, whose `ReportChoice` it uses.
///
/// It reads only, over `Answers` alone, in the background. The file holds the tenant's device rows, so it goes to the person's own
/// Shortcut and nowhere else: it is returned from memory (the screen's export writes no temporary file either), never logged, never
/// written by the app. When nothing was judged, the client changed during the read or the read didn't finish, it returns no file and
/// says why in `Answers`' words; a read in part or from an old snapshot is said beside the file, as `RunReportIntent` says it.
struct GetReportCSVIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Report CSV"
    static let description = IntentDescription(
        "Returns one of abapit's six reports for the active client as a CSV file, the same file the Reports screen exports. It lists the organization's devices, so use it only in your own shortcuts. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Report")
    var report: ReportChoice

    /// One of the report's groups, as for `RunReportIntent`.
    @Parameter(title: "Group")
    var group: String?

    /// The report's number: days for AppleCare coverage and service health, years for fleet age.
    @Parameter(title: "Number")
    var number: Int?

    @Dependency private var answers: Answers

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$report) as CSV") {
            \.$group
            \.$number
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> & ProvidesDialog {
        let report = report.report
        return AnswerSnippet.fileResult(await answers.reportCSV(report: report, tokens: Answers.tokens(report, group: group, number: number)))
    }
}
