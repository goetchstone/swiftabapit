import Foundation
import Testing
import TestSupport

/// The structural half of invariants 1–4, as source scans (SwiftGamGui's `WriteRouteTests`, adapted). Access
/// levels close most routes at compile time; these close the ones the compiler can't see: another place that
/// opens a connection, builds a request, or touches the Keychain.
@Suite("Routes")
struct RouteTests {
    static let sources = "Packages/AbapitKit/Sources"
    /// The app's side of the package boundary: the app target and the screen models' own package (Phase 1b review), which
    /// see AbapitKit's public API only, and so are held to what the app is held to.
    static let appModels = "Packages/AbapitApp/Sources"
    static let appSide = ["App", appModels]

    // The needle lists, each held to the spellings it must find by `ScannerTests`. A needle matches inside a longer
    // name and across whitespace, in code and string literals, never in a comment (`SourceScan.mentions`).
    /// What opens a connection. `URLSession` matches `NSURLSession`, `URLSessionConfiguration` and every other
    /// spelling; only the whole name `URLSessionTransport`, the allowed transport, is excused, in the package only.
    static let networking = ["URLSession", "NSURLConnection", "CFStream", "nw_connection", "NWConnection", "Network.", "CFSocket", "socket("]
    static let allowedTransport = ["URLSessionTransport"]
    /// A transport's `send`: called (`transport.send(request, limit:)`), taken as a function (`let s = t.send`), or
    /// called as `send(…)` in an extension of the protocol.
    /// `.send(`, not `.send`: the substring caught `Self.sendable(…)` in AcceptancePass when the branches met. Every
    /// other spelling of the call (`` `send` ``, `send (`, a bare `send(` in an extension) is `sendName`'s, below.
    static let sends = [".send(", "extensionTransport", "extensionHTTPCore.Transport"]
    /// The name itself, which an extension of a conforming type or of a protocol refining `Transport` calls bare:
    /// `extension URLSessionTransport { … send(request, limit: 1) }` in AppleClient, and `protocol Sneaky: Transport`
    /// with a default method doing the same, passed `sends` (Phase 1b gates verifier round 2).
    static let sendName = ["send"]
    /// What starts another program, which inherits the app's network entitlement and fetches past the transport:
    /// `Process` running `/usr/bin/curl` from AppleBusiness passed every scan (Phase 1b gates verifier round 2).
    /// (`system`, `popen`, `fork`, `vfork`, the variadic `execl…` and the name `NSTask` don't compile in Swift.)
    static let children = ["Process", "posix_spawn", "posix_spawnp", "execv", "execve", "execvp", "NSAppleScript", "OSAScript", "NSUserScriptTask",
                           "NSUserUnixTask", "NSUserAppleScriptTask", "NSUserAutomatorTask"]
    /// What may be called with `host:` first: the two request types' initializers (`init` declares them), and
    /// `URL.make(host:…)`. `[ReadRequest].Element(host:…)` made a read where no maker needle looks (Phase 1b gates
    /// verifier round 2), and so would any other type expression that names a request type.
    static let hostCallees: Set = ["ReadRequest", "AuthRequest", "init", "make"]
    /// Every spelling of the read initializer: `.init(host:` (Phase 1a's review evaded `ReadRequest(`), `Self(host:`,
    /// an associated type made the same type (`extension P where Made == ReadRequest`, then `Made(host:…)`), and a
    /// member of a type that holds it (`[ReadRequest].Element.init`, which a call needs no `host:` label through).
    static let readMakers = ["ReadRequest(", "ReadRequest.init", ".init(host:", "Self(host:", "==ReadRequest", "==Wire.ReadRequest",
                             "ReadRequest].", "ReadRequest>.", "ReadRequest)."]
    static let authMakers = ["AuthRequest(", "AuthRequest.init", "==AuthRequest", "==Wire.AuthRequest", "AuthRequest].", "AuthRequest>.",
                             "AuthRequest)."]
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
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.networking).isEmpty, "\(root)") }
    }

    /// Only the client builds the transport (and hands it to `HTTPClient`), and only `HTTPClient` sends through one.
    /// `send(_:limit:)` takes any `URLRequest`, so a send from anywhere else goes past HTTPCore's host allowlist and the
    /// Executor. The name was excused package-wide, and `URLSessionTransport().send(…)` in AppleClient passed every scan
    /// (Phase 1b gates verifier round 1). Mosyle's client joins in Phase 7, as a reviewed change here.
    @Test func onlyTheClientBuildsTheTransportAndOnlyHTTPClientSends() throws {
        let found = try SourceScan.files(in: Self.sources, matching: Self.allowedTransport)
        #expect(found == ["\(Self.sources)/AppleBusiness/AppleClient.swift", "\(Self.sources)/HTTPCore/Transport.swift"], "\(found)")
        #expect(try SourceScan.files(in: Self.sources, matching: Self.sends) == ["\(Self.sources)/HTTPCore/HTTPClient.swift"])
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.sends).isEmpty, "\(root)") }
        // The name: `Transport` declares it, `URLSessionTransport` implements it, `HTTPClient` calls it, and the stubs.
        let named = try SourceScan.files(in: Self.sources, naming: Self.sendName).filter { !Self.isStub($0) }
        #expect(named == ["\(Self.sources)/HTTPCore/HTTPClient.swift", "\(Self.sources)/HTTPCore/Transport.swift"], "\(named)")
        for root in Self.appSide { #expect(try SourceScan.files(in: root, naming: Self.sendName).isEmpty, "\(root)") }
    }

    /// A stub, which implements `send`: TestSupport, which a Release build compiles out.
    static func isStub(_ path: String) -> Bool { path.hasPrefix("\(sources)/TestSupport/") }

    /// Nothing starts another program: a child inherits the sandbox's network entitlement and goes past the one door.
    @Test func nothingStartsAProgram() throws {
        #expect(try SourceScan.files(in: Self.sources, naming: Self.children).isEmpty)
        for root in Self.appSide { #expect(try SourceScan.files(in: root, naming: Self.children).isEmpty, "\(root)") }
    }

    /// What each `host:` call in `file`'s code is made on (`SourceScan.code`, a raw identifier's backticks dropped): the
    /// name before its `(`, or the bracket that ends a type expression there (`(ReadRequest)(host:…)`'s `)`).
    static func hostCalls(_ file: SourceScan.File) -> [String] {
        let code = SourceScan.code(file.text, strings: false).replacing("`", with: "")
        return code.matches(of: #/([A-Za-z0-9_]+|[^\sA-Za-z0-9_])\s*\(\s*host\s*:/#).map { String($0.output.1) }
    }

    /// The `host:` calls in `file` made on something other than a request type's initializer or `URL.make`.
    static func otherHostCalls(_ file: SourceScan.File) -> [String] { hostCalls(file).filter { !hostCallees.contains($0) } }

    @Test func onlyARequestIsMadeWithAHost() throws {
        for root in [Self.sources] + Self.appSide {
            for file in try SourceScan.swiftFiles(in: root) {
                let others = Self.otherHostCalls(file)
                #expect(others.isEmpty, "\(file.path) calls \(others) with host: first, as a request initializer is called")
            }
        }
    }

    /// Only the read builders make a read (invariant 2); `Wire` defines it and its `setting` copy.
    @Test func onlyTheReadBuildersMakeAReadRequest() throws {
        let makers = try SourceScan.files(in: Self.sources, matching: Self.readMakers)
        #expect(makers == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Wire/Requests.swift"], "\(makers)")
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.readMakers + Self.authMakers).isEmpty, "\(root)") }
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
        for root in [Self.sources] + Self.appSide {
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
        #expect(try SourceScan.files(in: Self.appModels, matching: Self.keychain).isEmpty)
    }

    /// Nothing reads a URL outside the transport: `Data(contentsOf:)` and friends would fetch past the host allowlist
    /// (Phase 1a's review added one to AppleClient and the scans passed). Test fixtures are read in TestSupport only.
    @Test func nothingFetchesOutsideTheTransport() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.fetches) == ["\(Self.sources)/TestSupport/Fixtures.swift"])
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.fetches).isEmpty, "\(root)") }
    }

    /// A name scan holds only if code can't be found by a name it never spells: `objc_getClass("NSURL" + "Session")`
    /// would reach a session no scan above sees.
    @Test func nothingLooksCodeUpByName() throws {
        #expect(try SourceScan.files(in: Self.sources, matching: Self.lookups).isEmpty)
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.lookups).isEmpty, "\(root)") }
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
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.casts).isEmpty, "\(root)") }
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesWhatItGuards() throws {
        let transport = try SourceScan.swiftFiles(in: "\(Self.sources)/HTTPCore").first { $0.path.hasSuffix("Transport.swift") }
        #expect(transport?.lines.contains { $0.contains("URLSession(configuration:") } == true)
        let vault = try SourceScan.swiftFiles(in: "\(Self.sources)/Vault").first { $0.path.hasSuffix("KeychainStore.swift") }
        #expect(vault?.lines.contains { $0.contains("SecItemAdd(") } == true)
    }
}
