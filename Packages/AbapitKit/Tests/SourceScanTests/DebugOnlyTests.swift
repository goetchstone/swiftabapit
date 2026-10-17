import Testing
import TestSupport

/// Debug switches stay out of a Release build (Phase 1b review M1). Swift keeps a string literal of 15 bytes or
/// fewer inside the instructions, so `strings` never shows `ABAPIT_DEMO` and `scripts/check_app.sh` can't see a
/// switch by its name (it refuses any read of the environment instead). The source holds the names: every
/// `ABAPIT_` in the app's or the package's code or string literals sits in the true branch of an `#if DEBUG`.
@Suite("Debug-only code")
struct DebugOnlyTests {
    static let roots = ["App", "Packages/AbapitKit/Sources"]

    @Test func everyDebugSwitchIsInDebugCode() throws {
        for root in Self.roots {
            for file in try SourceScan.swiftFiles(in: root) {
                let spots = SourceScan.outsideDebug(file, ["ABAPIT_"], strings: true)
                #expect(spots.isEmpty, "\(spots)")
            }
        }
    }

    /// What Release code may not touch: each reads the environment, the launch arguments or the user defaults, and
    /// `UserDefaults` (so `@AppStorage`) reads a `-key value` launch argument itself. The name scan above held only the
    /// names: `environment["ABAPIT" + "_DEMO"]` passed it, and `UserDefaults.standard.bool(forKey: "ABAPIT" + "_DEMO")`
    /// passed it and the gate (Phase 1b gates verifier round 1). Darwin's `environ` and `sysctl` with `KERN_PROCARGS2`
    /// (the process's own arguments and environment) passed both too (round 2); `proc_pid…` reads a process's path and
    /// state. A Release use of `ProcessInfo` for anything else is a reviewed change to this list.
    static let processReads = ["ProcessInfo", "CommandLine", "getenv", "_NSGetEnviron", "_NSGetArgv", "_NSGetArgc", "UserDefaults", "AppStorage",
                               "CFPreferences", "sysctl", "KERN_PROC", "proc_pid"]
    /// Whole names only: `environ` sits inside `environment`, which a SwiftUI view calls.
    static let processReadNames = ["environ"]

    @Test func releaseCodeReadsNoEnvironmentArgumentOrDefault() throws {
        for root in Self.roots {
            for file in try SourceScan.swiftFiles(in: root) {
                let spots = SourceScan.outsideDebug(file, Self.processReads, names: Self.processReadNames, strings: false)
                #expect(spots.isEmpty, "\(spots)")
            }
        }
    }

    /// Vault's `MemoryStore` keeps an org's key in memory: for tests and the demo org only. It and the Vault
    /// initializer that takes it are debug code, so a Release build can't pick it even unnamed: `Vault(store: .init(),
    /// now: …)` resolved to it, past the old name scan and the gate (Phase 1b gates verifier round 1). This holds the
    /// definitions and every use to debug code.
    @Test func theMemoryStoreIsDebugCode() throws {
        var seen: Set<String> = []
        for root in Self.roots {
            for file in try SourceScan.swiftFiles(in: root) {
                if SourceScan.mentions(file, ["MemoryStore"]) { seen.insert(file.path) }
                let spots = SourceScan.outsideDebug(file, ["MemoryStore"], strings: false)
                #expect(spots.isEmpty, "\(spots)")
            }
        }
        // Its definition, its Vault initializer and the demo's use, each where the scan looks; a new use is a reviewed
        // change here. A count (`seen >= 3`) could be relaxed with every test green (Phase 1b gates verifier round 2).
        let sources = "Packages/AbapitKit/Sources"
        #expect(seen == ["\(sources)/Vault/SecretStore.swift", "\(sources)/Vault/Vault.swift", "\(sources)/TestSupport/DemoOrg.swift"], "\(seen)")
    }

    /// The scan must see the switches it guards, or it passes vacuously.
    @Test func theScanSeesEverySwitch() throws {
        let code = try Self.roots.flatMap { try SourceScan.swiftFiles(in: $0) }.map { SourceScan.code($0.text, strings: true) }.joined()
        for name in ["SPIKE", "SNAPSHOT", "DEMO", "SCREEN", "SELECT", "WINDOW"] {
            #expect(code.contains("\"ABAPIT_\(name)\""), "ABAPIT_\(name) isn't read where the scan looks")
        }
    }
}
