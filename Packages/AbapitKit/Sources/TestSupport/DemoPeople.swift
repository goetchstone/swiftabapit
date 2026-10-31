#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation

/// The demo org's people (plan §4, demo mode): users, user groups and org units, with their members, for the
/// People screen and its snapshots. Invented: `example.com` addresses, no real person's or organization's name.
/// A placeholder the people unit fills, through the stub's `add(_:)` and `relate(_:_:_:to:)`.
public enum DemoPeople {
    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {}
}
#endif
