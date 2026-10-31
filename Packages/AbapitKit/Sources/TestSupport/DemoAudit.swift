#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation

/// The demo org's audit events (plan §4, demo mode), for the Activity screen, the Dashboard's recent events and their
/// snapshots. Invented. The stub filters by range against its own clock, so the events' dates decide what a range
/// shows. A placeholder the activity unit fills, through the stub's `add(_:)`.
public enum DemoAudit {
    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {}
}
#endif
