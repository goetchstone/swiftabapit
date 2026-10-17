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
        #expect(makers == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Mosyle/MosyleRead.swift",
                           "\(Self.sources)/Wire/Requests.swift"], "\(makers)")
        for root in Self.appSide { #expect(try SourceScan.files(in: root, matching: Self.readMakers + Self.authMakers).isEmpty, "\(root)") }
    }

    /// A credential exchange carries a secret: only Apple's token broker and Mosyle's session build one.
    @Test func onlyTheBrokersMakeACredentialExchange() throws {
        let makers = try SourceScan.files(in: Self.sources, matching: Self.authMakers)
        #expect(makers == ["\(Self.sources)/AppleBusiness/TokenBroker.swift", "\(Self.sources)/Mosyle/MosyleSession.swift"], "\(makers)")
    }

    /// Mosyle's reads are POSTs, so the method can't tell a read from a write (invariant 2): every Mosyle read is on
    /// `MosyleRead.allowed`, and that list holds no operation that changes anything. Phase 7a's review passed
    /// `insert_users`, `variables#save` and an operation-less `/v1/lostmode#`: an operation is now a read verb with no
    /// write word in it, and only the two endpoints that have no operation may go without one. `MosyleReadTests`
    /// holds the list's value, which a computed addition after the literal could change.
    @Test func everyMosyleReadIsOnTheAllowlist() throws {
        let writes = ["update", "assign", "change", "create", "delete", "remove", "wipe", "lock", "restart", "shutdown", "clear",
                      "enable", "disable", "play", "request", "bulk", "set", "add", "insert", "save", "send", "push", "move", "erase",
                      "reset", "revoke", "release", "limbo", "install", "rename", "edit", "modify", "apply", "attach", "detach",
                      "import", "upload", "sync", "activation", "lost", "command", "restore", "enroll", "retire", "write", "post"]
        let file = try #require(SourceScan.swiftFiles(in: "\(Self.sources)/Mosyle").first { $0.path.hasSuffix("MosyleRead.swift") })
        let text = file.lines.joined(separator: "\n")
        let start = try #require(text.range(of: "allowed: Set<String> = ["))
        let end = try #require(text[start.upperBound...].range(of: "]"))
        let entries = text[start.upperBound..<end.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        #expect(entries.count == 8, "\(entries)")
        var allowed: Set<String> = []
        for entry in entries {
            #expect(entry.hasPrefix("\"") && entry.hasSuffix("\"") && entry.filter { $0 == "\"" }.count == 2, "a plain literal: \(entry)")
            let key = String(entry.dropFirst().dropLast())
            allowed.insert(key)
            let parts = key.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
            #expect(parts.count == 2 && parts[0].hasPrefix("/v1/"), "\(entry)")
            let (path, operation) = (parts.first ?? "", (parts.last ?? "").lowercased())
            if operation.isEmpty {
                #expect(["/v1/adminlogs", "/v1/logsstream"].contains(path), "only these two have no operation: \(entry)")
            } else {
                #expect(operation.hasPrefix("list") || operation == "get_info", "a read verb: \(entry)")
                #expect(!writes.contains { operation.contains($0) }, "\(entry)")
            }
        }
        // The only builders in the file go through `read(_:_:_:)` or the Logs Stream's own; both check the list.
        #expect(text.components(separatedBy: "ReadRequest(").count - 1 == 2)
        #expect(text.components(separatedBy: "precondition(allowed.contains").count - 1 == 2)
        // Every `read(path, operation…)` the file makes is on the list, called or not: the trap fires only when called.
        let calls = try Regex(#"read\("(/v1/[A-Za-z_/]+)",\s*(?:"([A-Za-z_]*)"|nil)"#)
        let made = text.matches(of: calls).map { match in
            "\(match.output[1].substring ?? "")#\(match.output[2].substring ?? "")"
        }
        #expect(made.count >= 4 && Set(made).isSubset(of: allowed), "\(made)")
        // Nor anywhere else: a write built in another file through `MosyleRead.read`, never called, passed the scan of
        // this file alone (Phase 7a's verification), and so did `MosyleRead.`read`(` (round 3). Only this file calls
        // the raw builder; each file is read as text and as code.
        var others = 0, problems: [String] = []
        for directory in [Self.sources, "App"] {
            for other in try SourceScan.swiftFiles(in: directory) {
                problems += try Self.mosyleReadProblems(other.path, other.text, allowed: allowed)
                if other.path != file.path { others += 1 }
            }
        }
        #expect(others > 50)
        #expect(problems.isEmpty, "\(problems)")
        // The Logs Stream's body is top-level with no `operation`: one there would make it another request.
        let logs = try #require(text.range(of: "func logsStream("))
        let logsEnd = try #require(text[logs.upperBound...].range(of: "\n    }\n"))
        #expect(!text[logs.lowerBound..<logsEnd.lowerBound].contains("operation"))
    }

    /// Nothing outside `Wire` extends `ReadRequest` or names it otherwise: an extension's `Self(host: …)` was a second
    /// Mosyle builder that every scan above passed (Phase 7a review M4).
    @Test func nothingElseExtendsOrRenamesReadRequest() throws {
        let patterns = [try Regex(#"extension\s+(Wire\s*\.\s*)?ReadRequest\b"#),
                        try Regex(#"typealias\s+\w+\s*(<[^>]*>)?\s*=\s*(Wire\s*\.\s*)?ReadRequest\b"#),
                        try Regex(#"\btypealias\b[^=\n]*=[^\n]*\bReadRequest\b"#),
                        try Regex(#"\bSelf\s*(\.\s*init\s*)?\(\s*host\s*:"#)]
        var scanned = 0
        for directory in [Self.sources, "App"] {
            for file in try SourceScan.swiftFiles(in: directory) where file.path != "\(Self.sources)/Wire/Requests.swift" {
                scanned += 1
                // As text, and as code: `` extension `ReadRequest` `` and `.init(/**/host:` passed the text (round 3).
                for code in [file.lines.joined(separator: "\n"), SwiftCode.read(file.text).code] {
                    for pattern in patterns {
                        #expect(!code.contains(pattern) && !code.contains(pattern.wordBoundaryKind(.simple)), "\(file.path)")
                    }
                }
            }
        }
        #expect(scanned > 50)
        let wire = try #require(SourceScan.swiftFiles(in: "\(Self.sources)/Wire").first { $0.path.hasSuffix("Requests.swift") })
        #expect(wire.lines.contains { $0.contains("public struct ReadRequest") })
    }

    /// Only the builders make a `ReadRequest` or an `AuthRequest`, in every spelling this scan knows. A space before
    /// the parenthesis (`ReadRequest (host:`), a line break (`ReadRequest` then `.init(` on the next line), the
    /// metatype (`ReadRequest.self`, then `.init (`) and an implicit `.init (host:` passed the line scans above (Phase
    /// 7a's verification), and a backticked name, a comment between the tokens and `Array<ReadRequest>.Element(`
    /// passed this one while it read text (round 3). Each file is read whole, as text and as code (`requestProblems`).
    /// No scan of the source sees every spelling Swift accepts (an unapplied `init` on any capitalised name passes
    /// this one), so for Mosyle what holds is the session's check of each request as it is sent (`MosyleSession.read`);
    /// the scan keeps the builders where a reviewer looks.
    @Test func noRequestIsMadeOutsideTheBuilders() throws {
        let read = try Regex(#"\bReadRequest\s*(\.\s*(init|self)\b|\()"#)
        let auth = try Regex(#"\bAuthRequest\s*(\.\s*(init|self)\b|\()"#)
        let implicit = try Regex(#"\.\s*init\s*\(\s*host\s*:"#)
        var reads: Set<String> = [], auths: Set<String> = [], implicits: Set<String> = [], scanned = 0
        for directory in [Self.sources, "App"] {
            for file in try SourceScan.swiftFiles(in: directory) {
                scanned += 1
                let code = file.lines.joined(separator: "\n")
                if code.contains(read) { reads.insert(file.path) }
                if code.contains(auth) { auths.insert(file.path) }
                if code.contains(implicit) { implicits.insert(file.path) }
            }
        }
        #expect(scanned > 50)
        #expect(reads == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Mosyle/MosyleRead.swift",
                          "\(Self.sources)/Wire/Requests.swift"], "\(reads)")
        #expect(auths == ["\(Self.sources)/AppleBusiness/TokenBroker.swift", "\(Self.sources)/Mosyle/MosyleSession.swift"], "\(auths)")
        #expect(implicits.isEmpty, "\(implicits)")
        var problems: [String] = []
        for directory in [Self.sources, "App"] {
            for file in try SourceScan.swiftFiles(in: directory) { problems += try Self.requestProblems(file.path, file.text) }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    /// The scans read code as the compiler does: each of these makes a request outside the builders, or hides one from
    /// a reader of the text, and is found; the controls aren't. The first five are Phase 7a's verification, round 3:
    /// each passed every scan, and `HTTPClient` sent each as a read with the session's login.
    @Test func theRequestScansFindEverySpellingTheyKnow() throws {
        let new = "\(Self.sources)/Mosyle/ZZNew.swift", tick = "`"
        let args = #"host: .mosyle, method: .post, path: "/v1/devices", body: wipe"#
        let auth = #"host: .mosyle, path: "/v1/devices", contentType: "application/json", body: wipe"#
        let forged: [(String, String)] = [
            ("a backticked name", "func a() -> ReadRequest { \(tick)ReadRequest\(tick)(\(args)) }"),
            ("a block comment before the call", "func a() -> ReadRequest { ReadRequest/**/(\(args)) }"),
            ("the type through a generic", "func a() -> ReadRequest { Array<ReadRequest>.Element(\(args)) }"),
            ("a backticked AuthRequest", "func a() -> AuthRequest { \(tick)AuthRequest\(tick)(\(auth)) }"),
            ("a backticked extension", "extension \(tick)ReadRequest\(tick) { static func zz() -> Self { .init(/**/\(args)) } }"),
            ("an implicit init with a comment", "func a() -> ReadRequest { .init(/**/\(args)) }"),
            ("a space", "func a() -> ReadRequest { ReadRequest (\(args)) }"),
            ("a line break", "func a() -> ReadRequest {\n    ReadRequest\n        .init(\n            \(args))\n}"),
            ("the metatype", "func a() -> ReadRequest { let type = ReadRequest.self\n    return type.init (\(args)) }"),
            ("another generic", "func a() -> ReadRequest { Result<ReadRequest, any Error>.Success(\(args)) }"),
            ("a generic typealias", "typealias Request = Array<ReadRequest>.Element"),
            ("an unapplied implicit init", "let make: (APIHost, HTTPMethod, String, String?, [QueryItem], Data?) -> ReadRequest = .init"),
            ("a metatype value's init", "func a(_ read: ReadRequest) { let made = type(of: read).init }"),
            ("a value's metatype's init", "func a(_ read: ReadRequest) { let meta = type(of: read); let make = meta.init }"),
            ("an exchange through its parameter's type", "func a(_ http: HTTPClient) async throws { _ = try await http.authenticate(.init(\(auth))) }"),
            ("an exchange through a generic maker", "func a(_ http: HTTPClient) async throws { _ = try await http.authenticate(make(.init)) }"),
            ("the type qualified by its module", "let make = Wire.ReadRequest.init"),
            ("the exchange qualified by its module", "func a() -> Wire.AuthRequest { Wire.AuthRequest.init(\(auth)) }"),
            // Each of these hides the builder after it from a reader that ends a string or a regex too early, or
            // misses one: the rest of the line would read as a comment (round 3, the attack's regex and string).
            ("a comment marker in an interpolation's string", "let shown = \"\\(String(\"//\"))\"; let made = ReadRequest(\(args))"),
            ("an escaped quote", "let shown = \"a \\\" /* \"; let made = ReadRequest(\(args)) // */"),
            ("a quote in a raw string", "let shown = #\"a \" /* \"#; let made = ReadRequest(\(args)) // */"),
            ("a quote in a multi-line string",
             "let shown = \"\"\"\n    a \" /* b\n    \"\"\"; let made = ReadRequest(\(args)) // */"),
            ("a comment marker on a multi-line string's own line",
             "let shown = \"\"\"\n    /* b\n    \"\"\"; let made = ReadRequest(\(args)) // */"),
            ("a division by a string holding a comment marker", "let shown = 1/\"/ //\"; let made = ReadRequest(\(args))"),
            ("a regex literal holding a quote", "let pattern = /\"/; let shown = \"/*\"; let made = ReadRequest/**/(\(args)) // */"),
            ("a regex literal holding a backtick", "let pattern = /a`b/; let made = ReadRequest(\(args))"),
            ("an extended regex literal", "let pattern = #/a\"/#\nfunc a() -> Int { 1 }"),
            ("an unterminated comment", "/* /* */\nfunc a() -> Int { 1 }"),
            ("a builder after a regex literal", #"let pattern = /^(\d{2})\/(\d{4})$/; let made = ReadRequest(\#(args))"#),
        ]
        for (why, code) in forged {
            #expect(try !Self.requestProblems(new, "import Foundation\nimport Wire\n\n\(code)\n").isEmpty, "\(why)")
        }
        // A third builder in a builder's own file (round 3: the file was on the list, and the count was of the text).
        let builders: [(String, String, String)] = [
            ("Mosyle/MosyleRead.swift", "    public static func users(page: Int)",
             "    package static func zz() -> ReadRequest { ReadRequest (\(args)) }\n\n    public static func users(page: Int)"),
            ("Mosyle/MosyleSession.swift", "    public let org: String", "    static func zz() -> ReadRequest { .init(\(args)) }\n    public let org: String"),
            ("HTTPCore/HTTPClient.swift", "    public static let attempts = 5",
             "    static func zz() -> ReadRequest { ReadRequest(\(args)) }\n    public static let attempts = 5"),
            ("Wire/Requests.swift", "    /// The same read with one query parameter replaced",
             "    static func zz() -> ReadRequest { ReadRequest(\(args)) }\n    /// The same read with one query parameter replaced"),
        ]
        for (file, anchor, added) in builders {
            let path = "\(Self.sources)/\(file)"
            let text = try #require(SourceScan.swiftFiles(in: (path as NSString).deletingLastPathComponent).first { $0.path == path }).text
            #expect(try Self.requestProblems(path, text).isEmpty, "\(file) as it is")
            #expect(text.contains(anchor), "\(file)")
            #expect(try !Self.requestProblems(path, text.replacingOccurrences(of: anchor, with: added)).isEmpty, "\(file) with another builder")
        }
        let controls = ["func a(_ request: ReadRequest) async throws -> HTTPResponse { try await send(request) }",
                        "func a(_ make: (Int) -> ReadRequest, keys: [String]) {}", "let names = [1, 2].map(String.init)",
                        "let half = total / 2", "let shown = \"a // b /* c\"", "let pattern = #\"\\d+/\"#",
                        #"let pattern = /^(\d{1,2}):(\d{2}) (AM|PM) - (\d{2})\/(\d{2})\/(\d{4})$/"#]
        for code in controls { #expect(try Self.requestProblems(new, code).isEmpty, "\(code)") }
        // And the allowlist's scan of every file: the raw builder by a backticked name, or a write in a literal read.
        let allowed: Set = ["/v1/devices#list"]
        for code in ["_ = MosyleRead.\(tick)read\(tick)(\"/v1/devices\", \"list\")", "let read = MosyleRead.read",
                     "let reads = MosyleRead.self", "typealias Reads = MosyleRead", "extension Mosyle.MosyleRead {}",
                     "_ = reader.\(tick)read\(tick)(\"/v1/devices\", \"wipe_devices\")", "_ = read(/**/\"/v1/devices\", \"wipe_devices\")",
                     "_ = reader.read(\"/v1/devices\", \"wipe_devices\")", "_ = Mosyle.MosyleRead.read(\"/v1/devices\", \"list\")"] {
            #expect(try !Self.mosyleReadProblems(new, code, allowed: allowed).isEmpty, "\(code)")
        }
        #expect(try Self.mosyleReadProblems(new, "_ = MosyleRead.users(page: 1)", allowed: allowed).isEmpty)
    }

    /// A pattern with ASCII word boundaries, `^` and `$` at each line: Swift's default `\b` is Unicode's, under which
    /// `reader.read` and `Wire.ReadRequest` are one word each, so `\bread` and `\bReadRequest` match neither (round 3).
    static func regex(_ pattern: String) throws -> Regex<AnyRegexOutput> {
        try Regex(pattern).wordBoundaryKind(.simple).anchorsMatchLineEndings()
    }

    static let wire = "\(sources)/Wire/Requests.swift"
    /// The files allowed to make each request type (the needles above are `readMakers` and `authMakers`).
    static let readMakerFiles: Set = ["\(sources)/AppleBusiness/AppleRead.swift", "\(sources)/Mosyle/MosyleRead.swift", wire]
    static let authMakerFiles: Set = ["\(sources)/AppleBusiness/TokenBroker.swift", "\(sources)/Mosyle/MosyleSession.swift", wire]
    /// How many argument lists open with `host:` in each file that makes a request, counted exactly in this unit's
    /// files and Wire's (nil: Apple's, held by its own scans). Every applied `ReadRequest` or `AuthRequest` init opens
    /// so, however its type is spelt; HTTPClient's two are `URL.make(host:`.
    static let labelled: [String: Int?] = [
        "\(sources)/AppleBusiness/AppleRead.swift": nil, "\(sources)/AppleBusiness/TokenBroker.swift": nil,
        "\(sources)/Mosyle/MosyleRead.swift": 2, "\(sources)/Mosyle/MosyleSession.swift": 1, wire: 4, "\(sources)/HTTPCore/HTTPClient.swift": 2,
    ]

    /// What the request scans find in one file, read as code (`SwiftCode.read`): an argument list opening with
    /// `host:` outside the makers, or more of them in one than it has; `ReadRequest` or `AuthRequest` named other than
    /// as a parameter or result type outside its makers (a generic's argument, a metatype, an extension, a call);
    /// an extension or a typealias of either outside Wire; an unapplied `.init` on anything but a named type; and
    /// anything this reading can't follow (a regex literal), which is refused rather than guessed at.
    static func requestProblems(_ path: String, _ text: String) throws -> [String] {
        let (code, unreadable) = SwiftCode.read(text)
        var problems = unreadable.map { "\(path): can't read \($0)" }
        func count(_ pattern: String) throws -> Int { code.matches(of: try Self.regex(pattern)).count }
        let hostFirst = try count(#"\(\s*host\s*:"#)
        switch labelled[path] {
        case let exact??: if hostFirst != exact { problems.append("\(path): \(hostFirst) argument lists open with host:, not \(exact)") }
        case .some(nil): break
        case nil: if hostFirst != 0 { problems.append("\(path): an argument list opens with host:") }
        }
        if path == "\(sources)/HTTPCore/HTTPClient.swift", try count(#"\bURL\s*\.\s*make\s*\(\s*host\s*:"#) != 2 {
            problems.append("\(path): its host: lists are no longer URL.make's")
        }
        for (name, makers) in [("ReadRequest", readMakerFiles), ("AuthRequest", authMakerFiles)] where !makers.contains(path) {
            let named = try count(#"\b\#(name)\b"#), annotated = try count(#"(:|->)\s*(Wire\s*\.\s*)?\#(name)\s*(\)|,|\{|async\b|throws\b|$)"#)
            if named != annotated { problems.append("\(path): \(name) named other than as a parameter or result type") }
        }
        guard path != wire else { return problems }
        for pattern in [#"\bextension\s+(Wire\s*\.\s*)?(ReadRequest|AuthRequest)\b"#, #"\btypealias\b[^=\n]*=[^\n]*\b(ReadRequest|AuthRequest)\b"#]
            where try count(pattern) != 0 {
            problems.append("\(path): \(pattern)")
        }
        // `= .init`, `make(.init)`, `type(of: read).init`, `meta.init`: an initializer taken unapplied from a value or
        // a context. A named type's (`String.init`) is the only kind the sources use.
        for match in code.matches(of: try Self.regex(#"\.init\b(?!\s*\()"#)) {
            let before = String(code[..<match.range.lowerBound].reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
            if before.first?.isUppercase != true { problems.append("\(path): an unapplied .init after \"\(before)\"") }
        }
        return problems
    }

    /// What the allowlist scan finds in one file, as text and as code: a literal `read(path, operation)` not on
    /// `allowed`, and outside MosyleRead.swift the raw builder reached by name (`MosyleRead.read`, its metatype, an
    /// extension, a typealias), however the name is quoted.
    static func mosyleReadProblems(_ path: String, _ text: String, allowed: Set<String>) throws -> [String] {
        var problems: [String] = []
        let own = path == "\(sources)/Mosyle/MosyleRead.swift"
        let literal = try Self.regex(#"\bread\s*\(\s*"([^"]*)"\s*,\s*(?:"([^"]*)"|nil)"#)
        for code in [SourceScan.File(path: path, text: text).lines.joined(separator: "\n"), SwiftCode.read(text).code] {
            let reads = code.matches(of: literal).map { "\($0.output[1].substring ?? "")#\($0.output[2].substring ?? "")" }
            if !Set(reads).isSubset(of: allowed) { problems.append("\(path): \(reads)") }
            guard !own else { continue }
            for pattern in [#"\bMosyleRead\s*\.\s*(read|self|Type)\b"#, #"\bextension\s+(Mosyle\s*\.\s*)?MosyleRead\b"#,
                            #"\btypealias\b[^=\n]*=[^\n]*\bMosyleRead\b"#] where code.contains(try Self.regex(pattern)) {
                problems.append("\(path): \(pattern)")
            }
        }
        return problems
    }

    /// Only the session carries a Mosyle login onto the wire (Phase 7a's verification, round 3): no other Mosyle file
    /// names `Authorizer` (one there could hand `HTTPClient` the login unchecked), the session's file names it once
    /// (its per-read `Login`), and none builds a `URLRequest`, sets one's method, body or headers, or calls a
    /// transport's `send` (one could go around `HTTPClient` altogether).
    @Test func onlyTheSessionCarriesAMosyleLogin() throws {
        let files = try SourceScan.swiftFiles(in: "\(Self.sources)/Mosyle")
        #expect(files.count >= 3)
        var problems: [String] = []
        for file in files { problems += try Self.mosyleLoginProblems(file.path, file.text) }
        #expect(problems.isEmpty, "\(problems)")
        let session = try #require(files.first { $0.path.hasSuffix("/Mosyle/MosyleSession.swift") })
        let new = "\(Self.sources)/Mosyle/ZZNew.swift"
        let forged: [(String, String)] = [
            (new, "actor Relay: Authorizer {}"), (new, "extension MosyleClient: HTTPCore.Authorizer {}"),
            (session.path, session.text + "\nactor Relay: Authorizer {}\n"),
            (new, "var request = URLRequest(url: url)"), (new, "let request = NSMutableURLRequest(url: url)"),
            (new, "request.httpBody = body"), (new, "request.setValue(jwt, forHTTPHeaderField: \"Authorization\")"),
            (new, "_ = try await transport.send(request, limit: 1)"), (new, "let session = URLSession.shared"),
        ]
        for (path, text) in forged { #expect(try !Self.mosyleLoginProblems(path, text).isEmpty, "\(text)") }
    }

    /// What `onlyTheSessionCarriesAMosyleLogin` finds in one Mosyle file, read as code.
    static func mosyleLoginProblems(_ path: String, _ text: String) throws -> [String] {
        let code = SwiftCode.read(text).code
        var problems: [String] = []
        let authorizers = code.matches(of: try Self.regex(#"\bAuthorizer\b"#)).count
        if authorizers != (path.hasSuffix("/Mosyle/MosyleSession.swift") ? 1 : 0) { problems.append("\(path): \(authorizers) Authorizers") }
        for pattern in [#"\b(NS)?(Mutable)?URLRequest\b"#, #"\bURLSession\b"#, #"\b(httpMethod|httpBody|allHTTPHeaderFields|setValue|addValue)\b"#,
                        #"\.\s*send\s*\("#] where code.contains(try Self.regex(pattern)) {
            problems.append("\(path): \(pattern)")
        }
        return problems
    }

    /// The reader itself, on what each part of it is for (round 3's attack used a regex and a string to hide a builder
    /// from a reader that didn't know them): comments, nested ones too, are gone; backticks go; a string's and a
    /// multi-line string's text stays, comment markers and all, and an interpolation inside one is code; a regex
    /// that reads the same either way is taken as written, and one that doesn't, or a string or comment left open,
    /// is reported.
    @Test func theReaderReadsCodeAsTheCompilerDoes() {
        func code(_ text: String) -> String { SwiftCode.read(text).code }
        func refused(_ text: String) -> Bool { !SwiftCode.read(text).unreadable.isEmpty }
        let comments = code("a /* b /* c */ d */ e // f\ng")
        #expect(comments.contains("a") && comments.contains("e") && comments.contains("\ng"))
        #expect(!comments.contains("b") && !comments.contains("c") && !comments.contains("d") && !comments.contains("f"), "\(comments)")
        #expect(code("`ReadRequest`(`host`: x)") == "ReadRequest(host: x)")
        #expect(code(#"let s = "a // b /* c"; d"#) == #"let s = "a // b /* c"; d"#)
        #expect(code(#"let s = "\(f("//")) x"; d // e"#).hasPrefix(#"let s = "\(f("//")) x"; d "#))
        #expect(code("let s = \"\"\"\n  /* a \" b\n  \"\"\"; d // e").hasPrefix("let s = \"\"\"\n  /* a \" b\n  \"\"\"; d "))
        #expect(code(##"let s = #"a " /* "#; d // e"##).hasPrefix(##"let s = #"a " /* "#; d "##))
        #expect(code(#"let s = "a \" /* "; d // e"#).hasPrefix(#"let s = "a \" /* "; d "#))
        #expect(code(#"let p = /^(\d{2})\/(\d{4})$/; d // e"#).hasPrefix(#"let p = /^(\d{2})\/(\d{4})$/; d "#))
        #expect(!refused(#"let p = /^(\d{2})\/(\d{4})$/; let half = a / 2; a /= 2"#))
        for text in [#"let p = /"/"#, #"let p = /a`b/"#, #"let p = /[a]/"#, #"let p = #/a/#"#, "let half = a/b", "let s = \"abc",
                     "let s = \"\"\"\nabc", #"let s = "\(f(1)"#, "/* a", "/* a /* b */"] {
            #expect(refused(text), "\(text)")
        }
    }

    /// The stub's device columns are its own (Phase 7a review H3): taken from the adapter or the client again, a
    /// column the client asks for and Mosyle lacks would be agreed with, and `everyRequestedColumnIsOneMosyleHas`
    /// would pass vacuously (Phase 7a's verification).
    @Test func theMosyleStubDoesNotAskTheClient() throws {
        let stub = try #require(SourceScan.swiftFiles(in: "\(Self.sources)/TestSupport").first { $0.path.hasSuffix("/MosyleStub.swift") })
        let code = stub.lines.joined(separator: "\n")
        #expect(code.contains("static let deviceColumns: Set<String> = ["))
        for name in ["MosyleAdapter", "MosyleRead", "MosyleClient", "MosyleSession", "deviceAttributes"] {
            #expect(!code.contains(name), "MosyleStub.swift names \(name)")
        }
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

/// Swift source as the compiler reads it, for the request scans (Phase 7a's verification, round 3: a backticked name,
/// a block comment between the tokens and a generic alias each got a forged builder past scans of the text).
/// Comments become a space (nested block comments too), backticks go (`` `ReadRequest` `` is `ReadRequest`), and
/// string literals stay as written, so a literal read's path is still seen; an interpolation is read as code, so a
/// `"//"` inside one hides nothing after it. A `/` that could open a regex literal (one the sources divide by has a
/// space on each side) is taken as written up to the next `/` on its line when what it holds reads the same as code
/// or as a regex (no quote, backtick, bracket or hash: MosyleModels' compliance pattern); otherwise a `"` or `/*`
/// inside one could hide what comes after from this reading, so it is reported, and the scans refuse the file.
enum SwiftCode {
    private enum Context {
        case code(parens: Int)
        case string(hashes: Int, multiline: Bool)
    }

    static func read(_ text: String) -> (code: String, unreadable: [String]) {
        let source = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView(), unreadable: [String] = []
        var stack: [Context] = [.code(parens: 0)]
        var index = 0
        func at(_ offset: Int) -> Unicode.Scalar? { offset < source.count ? source[offset] : nil }
        func all(_ scalar: Unicode.Scalar, from start: Int, count: Int) -> Bool { (0..<count).allSatisfy { at(start + $0) == scalar } }
        func line(_ offset: Int) -> Int { source[..<min(offset, source.count)].count { $0 == "\n" } + 1 }
        while index < source.count {
            let scalar = source[index]
            switch stack[stack.count - 1] {
            case .code(let parens):
                if scalar == "/", at(index + 1) == "/" {
                    while index < source.count, source[index] != "\n" { index += 1 }
                    out.append(" ")
                    continue
                }
                if scalar == "/", at(index + 1) == "*" {
                    let start = index
                    var depth = 0
                    repeat {
                        if at(index) == "/", at(index + 1) == "*" {
                            depth += 1
                            index += 2
                        } else if at(index) == "*", at(index + 1) == "/" {
                            depth -= 1
                            index += 2
                        } else {
                            index += 1
                        }
                    } while depth > 0 && index < source.count
                    if depth > 0 { unreadable.append("an unterminated comment at line \(line(start))") }
                    out.append(" ")
                    continue
                }
                if scalar == "`" {
                    index += 1
                    continue
                }
                if scalar == "#" || scalar == "\"" {
                    var hashes = 0
                    while at(index + hashes) == "#" { hashes += 1 }
                    if at(index + hashes) == "\"" {
                        let multiline = all("\"", from: index + hashes, count: 3)
                        let opener = hashes + (multiline ? 3 : 1)
                        out.append(contentsOf: source[index..<(index + opener)])
                        index += opener
                        stack.append(.string(hashes: hashes, multiline: multiline))
                        continue
                    }
                    if at(index + hashes) == "/" { unreadable.append("a regex literal at line \(line(index))") }
                    out.append(contentsOf: source[index..<(index + hashes)])
                    index += hashes
                    continue
                }
                if scalar == "/" {
                    let before = index > 0 ? source[index - 1] : " ", after = at(index + 1) ?? " "
                    if after != "=", !(before.properties.isWhitespace && after.properties.isWhitespace) {
                        // A bare regex literal, or a division the compiler may read as one: to the next unescaped `/`
                        // on the line. Holding no quote, backtick, bracket or hash, it reads the same as code or as a
                        // regex, so it is taken as written; anything else could hide what follows, and is refused.
                        var end = index + 1
                        while let next = at(end), next != "/", next != "\n" { end += next == "\\" ? 2 : 1 }
                        let inside = end < source.count && source[end] == "/" ? source[(index + 1)..<end] : []
                        if inside.isEmpty || inside.contains(where: { "\"`[#".unicodeScalars.contains($0) }) {
                            unreadable.append("a / that may open a regex literal at line \(line(index))")
                        } else {
                            out.append(contentsOf: source[index...end])
                            index = end + 1
                            continue
                        }
                    }
                }
                if stack.count > 1, scalar == "(" { stack[stack.count - 1] = .code(parens: parens + 1) }
                if stack.count > 1, scalar == ")" {
                    if parens == 0 { stack.removeLast() } else { stack[stack.count - 1] = .code(parens: parens - 1) }
                }
                out.append(scalar)
                index += 1
            case .string(let hashes, let multiline):
                // `\` and the string's own hashes: an escape, or `\(` (`\#(` in a raw string), an interpolation.
                if scalar == "\\", all("#", from: index + 1, count: hashes), let next = at(index + 1 + hashes) {
                    out.append(contentsOf: source[index...(index + 1 + hashes)])
                    index += hashes + 2
                    if next == "(" { stack.append(.code(parens: 0)) }
                    continue
                }
                let quotes = multiline ? 3 : 1
                if scalar == "\"", all("\"", from: index, count: quotes), all("#", from: index + quotes, count: hashes) {
                    out.append(contentsOf: source[index..<(index + quotes + hashes)])
                    index += quotes + hashes
                    stack.removeLast()
                    continue
                }
                // A line break ends a single-line string (the compiler refuses one that runs on).
                if scalar == "\n", !multiline { stack.removeLast() }
                out.append(scalar)
                index += 1
            }
        }
        if stack.count > 1 { unreadable.append("a string or an interpolation left open") }
        return (String(out), unreadable)
    }
}
