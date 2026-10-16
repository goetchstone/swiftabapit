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

    /// Vault's `MemoryStore` keeps an org's key in memory: for tests and the demo org only. It is public and in
    /// every build, so `scripts/check_app.sh` can't tell a use of it from its presence; the source holds that
    /// only debug code uses it, outside its own definition and the Vault initializer that takes it.
    @Test func onlyDebugCodeUsesTheMemoryStore() throws {
        let definitions: Set = ["Packages/AbapitKit/Sources/Vault/SecretStore.swift", "Packages/AbapitKit/Sources/Vault/Vault.swift"]
        var seen = 0
        for root in Self.roots {
            for file in try SourceScan.swiftFiles(in: root) where !definitions.contains(file.path) {
                seen += SourceScan.mentions(file, ["MemoryStore"]) ? 1 : 0
                let spots = SourceScan.outsideDebug(file, ["MemoryStore"], strings: false)
                #expect(spots.isEmpty, "\(spots)")
            }
        }
        #expect(seen > 0, "the demo's use of the MemoryStore isn't where the scan looks")
    }

    /// The scan must see the switches it guards, or it passes vacuously.
    @Test func theScanSeesEverySwitch() throws {
        let code = try Self.roots.flatMap { try SourceScan.swiftFiles(in: $0) }.map { SourceScan.code($0.text, strings: true) }.joined()
        for name in ["SPIKE", "SNAPSHOT", "DEMO", "SCREEN", "SELECT", "WINDOW"] {
            #expect(code.contains("\"ABAPIT_\(name)\""), "ABAPIT_\(name) isn't read where the scan looks")
        }
    }
}
