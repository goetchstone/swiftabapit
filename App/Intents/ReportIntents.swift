import AppIntents
import AppModels

/// The six reports, as Siri and Shortcuts name them: the catalog's titles (`ReportCatalog.entries`; SourceScanTests'
/// `noIntentReachesAWrite` suite holds them equal). The raw values are the catalog's ids.
enum ReportChoice: String, AppEnum {
    case coverage
    case fleetAge = "fleet-age"
    case activationLock = "activation-lock"
    case migration
    case serviceHealth = "service-health"
    case outOfWarranty = "out-of-warranty"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Report"
    static let caseDisplayRepresentations: [ReportChoice: DisplayRepresentation] = [
        .coverage: "AppleCare coverage ending",
        .fleetAge: "Fleet age",
        .activationLock: "Activation Lock",
        .migration: "MDM migration",
        .serviceHealth: "Device management service health",
        .outOfWarranty: "Out of warranty",
    ]

    var report: ReportsModel.Report {
        switch self {
        case .coverage: .coverage
        case .fleetAge: .fleetAge
        case .activationLock: .activationLock
        case .migration: .migration
        case .serviceHealth: .serviceHealth
        case .outOfWarranty: .outOfWarranty
        }
    }
}

/// One of the six reports over the active client, as the Reports screen builds it (the operator, 2026-11-24: Q1 "Six reports +
/// more", Q4 "Yes, bounded", Q5 "Counts aloud, 10 rows", Q6 "Active client, named"). It reads only: `Answers` and nothing else,
/// whose words are spoken and whose rows are shown. In the background, never opening a window; the Mac's own authentication
/// before it answers (pending the operator's live check of what that does on a Mac).
struct RunReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Run a Report"
    static let description = IntentDescription(
        "Answers one of abapit's six reports for the active client from what abapit reads: counts, how old the data is and how much was read, and at most 10 devices. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Report")
    var report: ReportChoice

    /// One of the report's groups (the catalog's values, such as `lock:USER` or `no-active-coverage`); a group the report doesn't
    /// have is refused in words.
    @Parameter(title: "Group")
    var group: String?

    /// The report's number: days for AppleCare coverage and service health, years for fleet age.
    @Parameter(title: "Number")
    var number: Int?

    @Dependency private var screens: ScreenModels

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$report)") {
            \.$group
            \.$number
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let report = report.report
        return AnswerSnippet.result(await screens.answers.answer(report: report, tokens: Answers.tokens(report, group: group, number: number)))
    }
}

// MARK: one intent per report, for Siri

// An App Shortcut can't preset a parameter (the built metadata keeps only the intent's name), so "Which devices are out of
// warranty in abapit" on `RunReportIntent` would be asked which report. Each report has its own intent instead, with no
// parameter, answering as `RunReportIntent` does with the report's own settings.

/// "Which devices are out of warranty in abapit".
struct OutOfWarrantyIntent: AppIntent {
    static let title: LocalizedStringResource = "Out of Warranty"
    static let description = IntentDescription("Answers the Out of warranty report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .outOfWarranty, tokens: [:]))
    }
}

/// "Which AppleCare coverage is ending in abapit".
struct CoverageEndingIntent: AppIntent {
    static let title: LocalizedStringResource = "AppleCare Coverage Ending"
    static let description = IntentDescription("Answers the AppleCare coverage ending report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .coverage, tokens: [:]))
    }
}

/// "How old is the fleet in abapit".
struct FleetAgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Fleet Age"
    static let description = IntentDescription("Answers the Fleet age report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .fleetAge, tokens: [:]))
    }
}

/// "Which devices are Activation Locked in abapit".
struct ActivationLockIntent: AppIntent {
    static let title: LocalizedStringResource = "Activation Lock"
    static let description = IntentDescription("Answers the Activation Lock report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .activationLock, tokens: [:]))
    }
}

/// "How is the MDM migration going in abapit".
struct MigrationIntent: AppIntent {
    static let title: LocalizedStringResource = "MDM Migration"
    static let description = IntentDescription("Answers the MDM migration report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .migration, tokens: [:]))
    }
}

/// "How are the device management services in abapit".
struct ServiceHealthIntent: AppIntent {
    static let title: LocalizedStringResource = "Device Management Service Health"
    static let description = IntentDescription("Answers the Device management service health report for the active client. It changes nothing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Dependency private var screens: ScreenModels

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        AnswerSnippet.result(await screens.answers.answer(report: .serviceHealth, tokens: [:]))
    }
}
