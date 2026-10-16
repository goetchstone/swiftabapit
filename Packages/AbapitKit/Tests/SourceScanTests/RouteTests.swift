import Foundation
import Testing
import TestSupport

/// The structural half of invariants 1–4, as source scans (SwiftGamGui's `WriteRouteTests`, adapted). Access
/// levels close most routes at compile time; these close the ones the compiler can't see: another place that
/// opens a connection, builds a request, or touches the Keychain.
@Suite("Routes")
struct RouteTests {
    static let sources = "Packages/AbapitKit/Sources"

    /// Only the transport opens connections (invariant 4: one door, one allowlist).
    @Test func onlyTheTransportNamesURLSession() throws {
        // URLSession as a whole word: constructing the allowed `URLSessionTransport` is not opening a connection.
        let networking = ["NSURLConnection", "CFStream", "nw_connection", "NWConnection", "Network.", "CFSocket", "socket("]
        #expect(try SourceScan.files(in: Self.sources, matching: networking, orWord: "URLSession") == ["\(Self.sources)/HTTPCore/Transport.swift"])
        #expect(try SourceScan.files(in: "App", matching: networking, orWord: "URLSession").isEmpty)
    }

    /// Only the read builders make a read (invariant 2); `Wire` defines it and its `setting` copy.
    @Test func onlyTheReadBuildersMakeAReadRequest() throws {
        // Every spelling of the initializer, `.init(host:` included (Phase 1a's review evaded `ReadRequest(`).
        let makers = try SourceScan.files(in: Self.sources, matching: ["ReadRequest(", "ReadRequest.init", ".init(host:"])
        #expect(makers == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Wire/Requests.swift"], "\(makers)")
        #expect(try SourceScan.files(in: "App", matching: ["ReadRequest(", "AuthRequest("]).isEmpty)
    }

    /// A credential exchange carries a secret: only the token broker builds one (Mosyle's session joins in Phase 7).
    @Test func onlyTheBrokersMakeACredentialExchange() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: ["AuthRequest("]) == ["\(Self.sources)/AppleBusiness/TokenBroker.swift"])
    }

    /// Only the Vault touches the Keychain (invariant 3); the app's spike uses throwaway items only.
    @Test func onlyTheVaultTouchesTheKeychain() throws {
        let keychain = ["SecItem", "SecKeyCreate", "kSecClass", "SecAccessControl"]
        let found = try SourceScan.files(in: Self.sources, matching: keychain)
        #expect(found == ["\(Self.sources)/Vault/KeychainStore.swift"], "\(found)")
        #expect(try SourceScan.files(in: "App", matching: keychain) == ["App/Debug/Spikes.swift"])
    }

    /// Nothing reads a URL outside the transport: `Data(contentsOf:)` and friends would fetch past the host allowlist
    /// (Phase 1a's review added one to AppleClient and the scans passed). Test fixtures are read in TestSupport only.
    @Test func nothingFetchesOutsideTheTransport() throws {
        let fetches = ["contentsOf:", "NSData(", "dataTask(", "downloadTask(", "uploadTask(", "WKWebView", "CFReadStream"]
        #expect(try SourceScan.files(in: Self.sources, matching: fetches) == ["\(Self.sources)/TestSupport/Fixtures.swift"])
        #expect(try SourceScan.files(in: "App", matching: fetches).isEmpty)
    }

    /// `package` access is the boundary that keeps the app from secrets and the write ticket. A `-package-name`
    /// flag on the app target would open it (Phase 1a's review typechecked `Secret.bytes` from outside that way), so
    /// no committed build setting may carry one; `scripts/check_graph.py` refuses `unsafeFlags` in the manifest.
    @Test func noBuildSettingOpensThePackageBoundary() throws {
        let root = Fixtures.repoRoot
        var settings = [try String(contentsOf: root.appending(path: "SwiftAbapit.xcodeproj/project.pbxproj"), encoding: .utf8)]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Config").path) where name.hasSuffix(".xcconfig") {
            settings.append(try String(contentsOf: root.appending(path: "Config/\(name)"), encoding: .utf8))
        }
        for text in settings {
            #expect(!text.contains("package-name") && !text.contains("PACKAGE_NAME") && !text.contains("-enable-testing"),
                    "a build setting names the package or enables testing")
        }
    }

    /// Reinterpreting memory could forge a value the type system guards.
    @Test func nothingReinterpretsMemory() throws {
        let casts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound", "bindMemory"]
        #expect(try SourceScan.files(in: Self.sources, matching: casts).isEmpty)
        #expect(try SourceScan.files(in: "App", matching: casts).isEmpty)
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesWhatItGuards() throws {
        let transport = try SourceScan.swiftFiles(in: "\(Self.sources)/HTTPCore").first { $0.path.hasSuffix("Transport.swift") }
        #expect(transport?.lines.contains { $0.contains("URLSession(configuration:") } == true)
        let vault = try SourceScan.swiftFiles(in: "\(Self.sources)/Vault").first { $0.path.hasSuffix("KeychainStore.swift") }
        #expect(vault?.lines.contains { $0.contains("SecItemAdd(") } == true)
    }
}
