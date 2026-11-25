import AppIntents

/// The phrases Siri listens for (the operator, 2026-11-24: Q1 "Six reports + more"): one per report, the Needs-attention summary,
/// serial lookup, and any report by name. Each names the app, as Siri requires, and each is in App/AppShortcuts.xcstrings too:
/// without that catalog Xcode ships no phrase localization and Siri never matches a phrase by voice (SwiftGamGui failure-log
/// 2026-10-10). Change both together; `scripts/check_app.sh` checks every phrase names the app and is in the built catalog.
struct AbapitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OutOfWarrantyIntent(), phrases: [
            "Which devices are out of warranty in \(.applicationName)",
        ], shortTitle: "Out of Warranty", systemImageName: "shield.slash")
        AppShortcut(intent: CoverageEndingIntent(), phrases: [
            "Which AppleCare coverage is ending in \(.applicationName)",
        ], shortTitle: "AppleCare Ending", systemImageName: "calendar.badge.exclamationmark")
        AppShortcut(intent: FleetAgeIntent(), phrases: [
            "How old is the fleet in \(.applicationName)",
        ], shortTitle: "Fleet Age", systemImageName: "clock")
        AppShortcut(intent: ActivationLockIntent(), phrases: [
            "Which devices are Activation Locked in \(.applicationName)",
        ], shortTitle: "Activation Lock", systemImageName: "lock")
        AppShortcut(intent: MigrationIntent(), phrases: [
            "How is the MDM migration going in \(.applicationName)",
        ], shortTitle: "MDM Migration", systemImageName: "arrow.right.circle")
        AppShortcut(intent: ServiceHealthIntent(), phrases: [
            "How are the device management services in \(.applicationName)",
        ], shortTitle: "Service Health", systemImageName: "server.rack")
        AppShortcut(intent: NeedsAttentionIntent(), phrases: [
            "What needs attention in \(.applicationName)",
        ], shortTitle: "Needs Attention", systemImageName: "exclamationmark.triangle")
        AppShortcut(intent: LookUpSerialIntent(), phrases: [
            "Look up a serial number in \(.applicationName)",
        ], shortTitle: "Look Up a Serial Number", systemImageName: "magnifyingglass")
        AppShortcut(intent: RunReportIntent(), phrases: [
            "Run the \(\.$report) report in \(.applicationName)",
        ], shortTitle: "Run a Report", systemImageName: "chart.bar.doc.horizontal")
    }
}
