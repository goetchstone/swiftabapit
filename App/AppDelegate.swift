import AppKit

/// The app's lifetime hooks. Phase 4 adds the quit guard: `applicationShouldTerminate` answers
/// `.terminateLater` while the Executor is sending a write, and an unmatched audit begin record shows
/// "outcome unknown — verify" at launch (plan §3.8).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
