import Foundation
import Testing
import TestSupport

/// The package's shape is a decision (plan §3.2), held here so a convenient import can't quietly erode
/// it: the dependency edges, the pure modules' imports, zero third-party code (L5), and what the app
/// may import.
@Suite("Package graph")
struct PackageGraphTests {
    /// A fast local check of the edges. The authoritative one is `scripts/check_graph.py`, which reads the
    /// manifest SwiftPM evaluates (`swift package dump-package`): this regex can be fooled by a variable or a
    /// later `.append` (Phase 0's review), and `scripts/test.sh` and CI run both.
    /// Every allowed edge. Wire is the pure home of `WireOperation`, shared by Planners, HTTPCore and
    /// ChangeCore (RULE-FEEDBACK 2026-10-16); Orgs holds the non-secret org profiles (`orgs.json`, Phase 1).
    /// A new edge is a reviewed change to this list and the plan.
    static let allowed: [String: Set<String>] = [
        "JSONAPI": [],
        "AppleModels": ["JSONAPI"],
        "MosyleModels": [],
        "Wire": [],
        "Planners": ["AppleModels", "MosyleModels", "JSONAPI", "Wire"],
        "Reports": ["AppleModels", "MosyleModels", "JSONAPI"],
        "ProfileSchema": [],
        "Orgs": ["JSONAPI"],
        "Vault": [],
        "HTTPCore": ["Wire"],
        "AppleBusiness": ["HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "JSONAPI"],
        "Mosyle": ["HTTPCore", "Wire", "Vault", "Orgs", "MosyleModels"],
        "History": ["Orgs", "AppleModels", "MosyleModels", "Reports"],
        "ChangeCore": ["HTTPCore", "Wire", "Planners", "Vault", "Orgs"],
        "Assist": ["Planners", "Reports"],
        "AppModels": ["AppleBusiness", "AppleModels", "Orgs", "Vault", "Reports"],
        "TestSupport": ["HTTPCore", "Wire", "Vault", "Orgs", "AppleModels", "MosyleModels", "JSONAPI"],
    ]

    /// Modules that build on Linux (the fuzz job) and so import only Foundation.
    static let pure: Set = ["JSONAPI", "AppleModels", "MosyleModels", "Wire", "Planners", "Reports", "ProfileSchema"]

    /// `.target(name: "X", dependencies: [...])` edges as Package.swift declares them.
    static func declaredTargets() throws -> [String: Set<String>] {
        let text = try String(contentsOf: Fixtures.packageManifest, encoding: .utf8)
        let target = try Regex(#"\.target\(name:\s*"([A-Za-z]+)"(?:,\s*dependencies:\s*\[([^\]]*)\])?"#)
        var found: [String: Set<String>] = [:]
        for match in text.matches(of: target) {
            let name = String(match.output[1].substring ?? "")
            let list = match.output[2].substring.map(String.init) ?? ""
            found[name] = Set(list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }.filter { !$0.isEmpty })
        }
        return found
    }

    @Test func theDependencyEdgesAreExactlyThePlannedOnes() throws {
        let declared = try Self.declaredTargets()
        #expect(declared == Self.allowed)
    }

    @Test func thereAreNoPackageDependencies() throws {
        let manifest = try String(contentsOf: Fixtures.packageManifest, encoding: .utf8)
        #expect(!manifest.contains(".package("), "zero third-party dependencies (L5)")
        let project = try String(contentsOf: Fixtures.repoRoot.appending(path: "SwiftAbapit.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(!project.contains("XCRemoteSwiftPackageReference"), "no remote packages in the Xcode project either")
    }

    /// Every module's own imports stay within its edges, plus the system frameworks it may use.
    @Test func eachModuleImportsOnlyItsDependencies() throws {
        let system: [String: Set<String>] = [
            "Vault": ["CryptoKit", "Security", "LocalAuthentication", "Synchronization", "Dispatch", "Darwin", "os"],
            "HTTPCore": ["os", "Synchronization"],
            "AppleBusiness": ["CryptoKit", "os", "Synchronization"],
            "Mosyle": ["os", "Synchronization"],
            "History": ["SQLite3", "os", "Synchronization", "Darwin"],
            "ChangeCore": ["CryptoKit", "os", "Synchronization", "Darwin"],
            "Assist": ["FoundationModels"],
            "AppModels": ["Observation"],
            "TestSupport": ["Testing", "CryptoKit", "Security", "Synchronization"],
        ]
        for (module, edges) in Self.allowed {
            let permitted = edges.union(["Foundation"]).union(system[module] ?? [])
            for file in try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/\(module)") {
                let extra = Set(SourceScan.imports(of: file)).subtracting(permitted)
                #expect(extra.isEmpty, "\(file.path) imports \(extra.sorted())")
            }
        }
    }

    @Test func thePureModulesImportOnlyFoundationAndEachOther() throws {
        for module in Self.pure {
            for file in try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/\(module)") {
                let extra = Set(SourceScan.imports(of: file)).subtracting(Self.pure.union(["Foundation"]))
                #expect(extra.isEmpty, "\(file.path) imports \(extra.sorted()); pure modules build on Linux")
            }
        }
    }

    /// Every way of spelling an import Phase 0's review found the first scan missed, and the ways a comment or
    /// a string could fake one.
    @Test func theImportScanSeesEveryWayOfSpellingAnImport() {
        let text = """
        fileprivate import ChangeCore
        /* drafts only */ import HTTPCore
        let _x = 0; import Security
        import
          Vault
        @preconcurrency import Network
        @_spi(X) @testable public import struct Wire.ReadRequest
        // import CommentOnly
        /* import BlockOnly /* nested import Nested */ still comment */
        let text = "import StringOnly"
        """
        let found = SourceScan.imports(of: SourceScan.File(path: "x.swift", text: text))
        #expect(found == ["ChangeCore", "HTTPCore", "Security", "Vault", "Network", "Wire"])
    }

    /// The app imports the planned modules (plan §3.2, plus Orgs, AppleModels and JSONAPI for Phase 1's screens)
    /// and the system frameworks it uses; `TestSupport` (the stubs and the demo) only under `#if DEBUG`.
    @Test func theAppImportsOnlyThePlannedModules() throws {
        let package: Set = ["ChangeCore", "AppleBusiness", "AppleModels", "Mosyle", "History", "Reports", "Planners", "Assist", "Vault",
                            "Orgs", "JSONAPI", "AppModels", "TestSupport"]
        let system: Set = ["SwiftUI", "AppKit", "Foundation", "Charts", "Observation", "UniformTypeIdentifiers", "CryptoKit",
                           "LocalAuthentication", "Security", "Synchronization", "FoundationModels", "Dispatch", "AppIntents", "os"]
        for file in try SourceScan.swiftFiles(in: "App") {
            let extra = Set(SourceScan.imports(of: file)).subtracting(package).subtracting(system)
            #expect(extra.isEmpty, "\(file.path) imports \(extra.sorted())")
            let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            for (index, line) in lines.enumerated() where line == "import TestSupport" {
                #expect(index > 0 && lines[index - 1] == "#if DEBUG", "\(file.path): TestSupport is imported outside #if DEBUG")
            }
        }
    }

    /// The app reaches the package through its public API only: `@testable` would reopen every route.
    @Test func theAppNeverImportsThePackageTestably() throws {
        #expect(try SourceScan.files(in: "App", matching: ["@testable"]).isEmpty)
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesThePackageAndTheApp() throws {
        #expect(try Self.declaredTargets().count == Self.allowed.count)
        for module in Self.allowed.keys {
            #expect(try !SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/\(module)").isEmpty, "no sources seen for \(module)")
        }
        #expect(try SourceScan.swiftFiles(in: "App").contains { $0.path == "App/AbapitApp.swift" })
        let vault = try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/Vault")
        #expect(vault.contains { SourceScan.imports(of: $0).contains("Foundation") })
    }
}
