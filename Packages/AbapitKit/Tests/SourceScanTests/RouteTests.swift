import Foundation
import Testing
import TestSupport

/// The structural half of invariants 1–4, as source scans (SwiftGamGui's `WriteRouteTests`, adapted). Access
/// levels close most routes at compile time; these close the ones the compiler can't see: another place that
/// opens a connection, builds a request, or touches the Keychain.
@Suite("Routes")
struct RouteTests {
    static let sources = "Packages/AbapitKit/Sources"

    // The needle lists, each held to the spellings it must find by `ScannerTests`. A needle matches inside a longer
    // name and across whitespace, in code and string literals, never in a comment (`SourceScan.mentions`).
    /// What opens a connection. `URLSession` matches `NSURLSession`, `URLSessionConfiguration` and every other
    /// spelling; only the whole name `URLSessionTransport`, the allowed transport, is excused, in the package only.
    static let networking = ["URLSession", "NSURLConnection", "CFStream", "nw_connection", "NWConnection", "Network.", "CFSocket", "socket("]
    static let allowedTransport = ["URLSessionTransport"]
    /// Every spelling of the read initializer, `.init(host:` included (Phase 1a's review evaded `ReadRequest(`).
    static let readMakers = ["ReadRequest(", "ReadRequest.init", ".init(host:"]
    static let authMakers = ["AuthRequest(", "AuthRequest.init"]
    /// The Keychain's item, key and access-control calls, and the legacy `SecKeychain…` family.
    static let keychain = ["SecItem", "SecKeyCreate", "kSecClass", "SecAccessControl", "SecKeychain"]
    static let fetches = ["contentsOf:", "NSData(", "dataTask(", "downloadTask(", "uploadTask(", "WKWebView", "CFReadStream"]
    static let casts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound", "bindMemory"]
    /// Code found by name at run time: a class or selector from a string, a symbol from the loader, a private
    /// property read through reflection or key-value coding (`URLSessionTransport`'s session).
    static let lookups = ["NSClassFromString", "NSSelectorFromString", "Selector(", "objc_", "dlopen", "dlsym", "NSInvocation",
                          "Mirror(reflecting", "value(forKey"]

    /// Only the transport opens connections (invariant 4: one door, one allowlist). Phase 1b review H3:
    /// `URLSession.shared.upload(…)` in AppleBusiness or a screen passed when this matched a Unicode whole word.
    @Test func onlyTheTransportNamesURLSession() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.networking, except: Self.allowedTransport) == ["\(Self.sources)/HTTPCore/Transport.swift"])
        // The app gets its client from `AppleClient`; it names no transport, the allowed one included.
        #expect(try SourceScan.files(in: "App", matching: Self.networking).isEmpty)
    }

    /// Only the read builders make a read (invariant 2); `Wire` defines it and its `setting` copy.
    @Test func onlyTheReadBuildersMakeAReadRequest() throws {
        let makers = try SourceScan.files(in: Self.sources, matching: Self.readMakers)
        #expect(makers == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Wire/Requests.swift"], "\(makers)")
        #expect(try SourceScan.files(in: "App", matching: Self.readMakers + Self.authMakers).isEmpty)
    }

    /// A credential exchange carries a secret: only the token broker builds one (Mosyle's session joins in Phase 7).
    @Test func onlyTheBrokersMakeACredentialExchange() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.authMakers) == ["\(Self.sources)/AppleBusiness/TokenBroker.swift"])
    }

    /// Only the Vault touches the Keychain (invariant 3); the app's spike uses throwaway items only.
    @Test func onlyTheVaultTouchesTheKeychain() throws {
        let found = try SourceScan.files(in: Self.sources, matching: Self.keychain)
        #expect(found == ["\(Self.sources)/Vault/KeychainStore.swift"], "\(found)")
        #expect(try SourceScan.files(in: "App", matching: Self.keychain) == ["App/Debug/Spikes.swift"])
    }

    /// Nothing reads a URL outside the transport: `Data(contentsOf:)` and friends would fetch past the host allowlist
    /// (Phase 1a's review added one to AppleClient and the scans passed). Test fixtures are read in TestSupport only.
    @Test func nothingFetchesOutsideTheTransport() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.fetches) == ["\(Self.sources)/TestSupport/Fixtures.swift"])
        #expect(try SourceScan.files(in: "App", matching: Self.fetches).isEmpty)
    }

    /// A name scan holds only if code can't be found by a name it never spells: `objc_getClass("NSURL" + "Session")`
    /// would reach a session no scan above sees.
    @Test func nothingLooksCodeUpByName() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.lookups).isEmpty)
        #expect(try SourceScan.files(in: "App", matching: Self.lookups).isEmpty)
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
        #expect(try SourceScan.files(in: Self.sources, matching: Self.casts).isEmpty)
        #expect(try SourceScan.files(in: "App", matching: Self.casts).isEmpty)
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesWhatItGuards() throws {
        let transport = try SourceScan.swiftFiles(in: "\(Self.sources)/HTTPCore").first { $0.path.hasSuffix("Transport.swift") }
        #expect(transport?.lines.contains { $0.contains("URLSession(configuration:") } == true)
        let vault = try SourceScan.swiftFiles(in: "\(Self.sources)/Vault").first { $0.path.hasSuffix("KeychainStore.swift") }
        #expect(vault?.lines.contains { $0.contains("SecItemAdd(") } == true)
    }
}
