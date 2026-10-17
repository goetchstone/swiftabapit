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
    /// A transport's `send`: called (`transport.send(request, limit:)`), taken as a function (`let s = t.send`), or
    /// called as `send(…)` in an extension of the protocol.
    static let sends = [".send", "extensionTransport", "extensionHTTPCore.Transport"]
    /// Every spelling of the read initializer: `.init(host:` (Phase 1a's review evaded `ReadRequest(`), `Self(host:`,
    /// and an associated type made the same type (`extension P where Made == ReadRequest`, then `Made(host:…)`).
    static let readMakers = ["ReadRequest(", "ReadRequest.init", ".init(host:", "Self(host:", "==ReadRequest", "==Wire.ReadRequest"]
    static let authMakers = ["AuthRequest(", "AuthRequest.init", "==AuthRequest", "==Wire.AuthRequest"]
    /// An extension of a request type, which can add a maker or a conformance a generic `T(host:…)` makes one through.
    static let requestExtensions = ["extensionReadRequest", "extensionWire.ReadRequest", "extensionAuthRequest", "extensionWire.AuthRequest"]
    /// The Keychain's item, key and access-control calls, and the legacy `SecKeychain…` family.
    static let keychain = ["SecItem", "SecKeyCreate", "kSecClass", "SecAccessControl", "SecKeychain"]
    static let fetches = ["contentsOf:", "NSData(", "dataTask(", "downloadTask(", "uploadTask(", "WKWebView", "CFReadStream"]
    static let casts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound", "bindMemory"]
    /// Code found by name at run time: a class or selector from a string, a symbol from the loader, a private
    /// property read through reflection or key-value coding (`URLSessionTransport`'s session).
    /// A symbol bound by name at link time (`@_silgen_name("connect")`) is one too.
    static let lookups = ["NSClassFromString", "NSSelectorFromString", "NSProtocolFromString", "Selector(", "objc_", "dlopen", "dlsym",
                          "NSInvocation", "Mirror(reflecting", "value(forKey", "classNamed", "principalClass", "CFBundleGetFunctionPointer",
                          "CFBundleGetDataPointer", "_typeByName", "_silgen_name", "_extern("]

    /// Only the transport opens connections (invariant 4: one door, one allowlist). Phase 1b review H3:
    /// `URLSession.shared.upload(…)` in AppleBusiness or a screen passed when this matched a Unicode whole word.
    @Test func onlyTheTransportNamesURLSession() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.networking, except: Self.allowedTransport) == ["\(Self.sources)/HTTPCore/Transport.swift"])
        // The app gets its client from `AppleClient`; it names no transport, the allowed one included.
        #expect(try SourceScan.files(in: "App", matching: Self.networking).isEmpty)
    }

    /// Only the client builds the transport (and hands it to `HTTPClient`), and only `HTTPClient` sends through one.
    /// `send(_:limit:)` takes any `URLRequest`, so a send from anywhere else goes past HTTPCore's host allowlist and the
    /// Executor. The name was excused package-wide, and `URLSessionTransport().send(…)` in AppleClient passed every scan
    /// (Phase 1b gates verifier round 1). Mosyle's client joins in Phase 7, as a reviewed change here.
    @Test func onlyTheClientBuildsTheTransportAndOnlyHTTPClientSends() throws {
        let found = try SourceScan.files(in: Self.sources, matching: Self.allowedTransport)
        #expect(found == ["\(Self.sources)/AppleBusiness/AppleClient.swift", "\(Self.sources)/HTTPCore/Transport.swift"], "\(found)")
        #expect(try SourceScan.files(in: Self.sources, matching: Self.sends) == ["\(Self.sources)/HTTPCore/HTTPClient.swift"])
        #expect(try SourceScan.files(in: "App", matching: Self.sends).isEmpty)
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

    /// A request type under another name, or extended, is made where no maker needle looks: `typealias Sneak =
    /// ReadRequest` then `Sneak(host:…)`, and `Self(host:…)` in an `extension ReadRequest`, both in AppleClient, passed
    /// the scan above (Phase 1b gates verifier round 1). No file does either, the makers' own included: the types'
    /// conformances are declared with them, in `Wire`.
    @Test func noRequestTypeIsAliasedOrExtended() throws {
        for root in [Self.sources, "App"] {
            #expect(try SourceScan.files(in: root, matching: Self.requestExtensions).isEmpty)
            for file in try SourceScan.swiftFiles(in: root) {
                #expect(Self.aliases(file).isEmpty, "\(file.path) names a request type in a typealias: \(Self.aliases(file))")
            }
        }
    }

    /// The right sides of the `typealias` and `associatedtype` declarations in `file` (read from its code,
    /// `SourceScan.code`) that name a request type. A right side starts after the `=` and any line breaks, and runs to
    /// a brace, `;`, another `=`, or a line break outside its brackets (`Optional<\n  ReadRequest>` is one).
    static func aliases(_ file: SourceScan.File) -> [String] {
        let code = Array(SourceScan.code(file.text, strings: false).unicodeScalars)
        func isName(_ offset: Int) -> Bool {
            code.indices.contains(offset) && code[offset].isASCII && (code[offset].properties.isAlphabetic || ("0"..."9").contains(code[offset]) || code[offset] == "_")
        }
        func isBreak(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }
        var found: [String] = []
        for keyword in ["typealias", "associatedtype"].map({ Array($0.unicodeScalars) }) {
            for start in code.indices where code[start...].starts(with: keyword) && !isName(start - 1) && !isName(start + keyword.count) {
                guard let equals = code[(start + keyword.count)...].firstIndex(where: { "={};".unicodeScalars.contains($0) }),
                      code[equals] == "=" else { continue }
                var end = equals + 1, depth = 0
                while end < code.count, code[end].properties.isWhitespace { end += 1 }
                while end < code.count, !"={};".unicodeScalars.contains(code[end]), !(isBreak(code[end]) && depth <= 0) {
                    if "<([".unicodeScalars.contains(code[end]) { depth += 1 }
                    if ")]".unicodeScalars.contains(code[end]) || (code[end] == ">" && code[end - 1] != "-") { depth -= 1 }
                    end += 1
                }
                let right = String(String.UnicodeScalarView(code[equals + 1..<end]))
                if right.contains("ReadRequest") || right.contains("AuthRequest") { found.append(right) }
            }
        }
        return found
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
