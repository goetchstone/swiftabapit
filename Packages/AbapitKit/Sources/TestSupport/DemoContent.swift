#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation

/// The demo org's content (plan §4, demo mode): apps, packages, blueprints with their members, and configurations,
/// for the Content screen and its snapshots. Invented; a custom setting's profile holds no real secret. A placeholder
/// the content unit fills, through the stub's `add(_:)` and `relate(_:_:_:to:)`.
public enum DemoContent {
    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {}
}
#endif
