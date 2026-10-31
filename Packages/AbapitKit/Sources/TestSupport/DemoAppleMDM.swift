#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation

/// The demo org's Apple MDM devices and their posture (plan §4, demo mode), for the Apple MDM screen and its
/// snapshots. Invented serials. A placeholder the Apple MDM unit fills, through the stub's `add(_:)` and
/// `setDetails(_:_:)`.
public enum DemoAppleMDM {
    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {}
}
#endif
