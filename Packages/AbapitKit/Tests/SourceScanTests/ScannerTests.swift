import Testing
import TestSupport

/// The scanner held to what it must see (Phase 1b review H3: the transport scan missed `URLSession.shared`, and
/// no test said which spellings it had to find). Each needle list `RouteTests` uses gets the ways code can spell
/// a use of it. The decision under test: a comment is never a use; a string literal always is, since it is how a
/// run-time lookup names a class (`NSClassFromString("NSURLSession")`).
@Suite("Source scanner")
struct ScannerTests {
    static func found(_ code: String, _ needles: [String], except: [String] = []) -> Bool {
        SourceScan.mentions(SourceScan.File(path: "x.swift", text: code), needles, except: except)
    }

    @Test(arguments: [
        "let s = URLSession.shared",
        "URLSession.shared.upload(for: request, from: body)",
        "let s = Foundation.URLSession(configuration: .ephemeral)",
        "let type = URLSession.self",
        "use(URLSession.shared)",
        "let all: [URLSession] = []",
        "let boxed: Box<URLSession> = box",
        "let wrapped = URLSession<Never>.self",
        "let session: URLSession",
        "let c = URLSessionConfiguration.default",
        #"let type: AnyClass? = NSClassFromString("NSURLSession")"#,
        "let t = makeURLSessionTransport()",
        "let t = URLSessionTransportShim()",
        #"print("\(URLSession.shared)")"#,
        #"let u = "https://example.com"; let s = URLSession.shared"#,
        #"let o = "/*"; let s = URLSession.shared"#,
        ##"let r = #"\"#; let s = URLSession.shared"##,
        "let m = \"\"\"\n    URLSession\n    \"\"\"",
        "let c = NWConnection(host: host, port: 443, using: .tls)",
        "let c = Network.NWConnection(to: endpoint, using: .tls)",
        "let c = nw_connection_create(endpoint, parameters)",
        "CFStreamCreatePairWithSocketToHost(nil, host, 443, &input, &output)",
        "let s = CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)",
        "let fd = socket(AF_INET, SOCK_STREAM, 0)",
        "let fd = socket (AF_INET, SOCK_STREAM, 0)",
        "let c = NSURLConnection(request: request, delegate: nil)",
        // One case per lexer branch that, misread, hides what follows (Phase 1b gates verifier round 1): an escaped
        // quote, an interpolation's own parentheses and string, an escape in a regex literal, a raw string's quote.
        #"let s = "a\"b // c"; let t = URLSession.shared"#,
        #"let s = "\(f(a) + "x // y")"; let t = URLSession.shared"#,
        #"let r = #/a\/#//x/#; let s = URLSession.shared"#,
        ##"let r = #"a"//"#; let s = URLSession.shared"##,
        // A line ends at CR as well as LF, for swiftc and so for the scan.
        "_ = 1 // note\rlet s = URLSession.shared",
        "_ = 1 // note\r\nlet s = URLSession.shared",
        "/* a */ _ = 1 // note\r    let s = URLSession.shared",
        // A raw identifier is one name: its `//`, `"` or `/*` opens nothing. A plain one is the name itself.
        "let `a // b` = 1; let s = URLSession.shared",
        "let `a \"b` = 1; let s = URLSession.shared",
        "let `a /* b` = 1; let s = URLSession.shared",
        "let s = `URLSession`.shared",
    ])
    func theNetworkingNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.networking, except: RouteTests.allowedTransport))
    }

    /// The one excused name, and comments: none of these opens a connection.
    @Test(arguments: [
        "let t = URLSessionTransport()",
        "let t: any Transport = URLSessionTransport()",
        "// let s = URLSession.shared",
        "/// Apple over `URLSession`",
        "run() // URLSession.shared",
        "/* URLSession.shared */ run()",
        "/* outer /* nested */ URLSession.shared */ run()",
        "run() /* a\n URLSession.shared\n */",
        "run() // a\r\n// URLSession.shared",
        "let `a // URLSession` = 1",
    ])
    func theNetworkingNeedlesExcuse(_ code: String) {
        #expect(!Self.found(code, RouteTests.networking, except: RouteTests.allowedTransport))
    }

    /// Swift accepts a space before a call's `(` and a `.init` on the next line, so the read scan does too.
    @Test(arguments: [
        #"let r = ReadRequest(host: .business, path: "/v1/orgDevices")"#,
        "let r = ReadRequest (host: .business, path: p)",
        "let r = ReadRequest.init(host: .business, path: p)",
        "let r = ReadRequest .init(host: .business, path: p)",
        "let r: ReadRequest = .init(host: .business, path: p)",
        "let r: ReadRequest = .init(\n    host: .business, path: p)",
        "let r = ReadRequest\n    .init(host: .business, path: p)",
        "let make = ReadRequest.init",
        "let r = type(of: template).init(host: .business, path: p)",
        "static func sneak() -> Self { Self(host: .business, path: p) }",
        "extension Maker where Made == ReadRequest { func make() -> Made { Made(host: .business, path: p) } }",
        "extension Maker where Made == Wire.ReadRequest { func make() -> Made { Made(host: .business, path: p) } }",
        // A raw identifier is the name it holds, and a member of a type holding the request is the request's.
        "let r = `ReadRequest`(host: .business, path: p)",
        "let r = ReadRequest.`init`(host: .business, path: p)",
        "let r: ReadRequest = .`init`(host: .business, path: p)",
        "let make = [ReadRequest].Element.init",
        "let make = (ReadRequest).init",
        "let make = Dictionary<String, ReadRequest>.Value.init",
    ])
    func theReadMakerNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.readMakers))
    }

    /// `let a: AuthRequest = .init(host:…)` is found too, by the read makers' `.init(host:` (both take `host:`).
    @Test(arguments: [
        "let a = AuthRequest(host: .appleAccount, path: p, contentType: t, body: b)",
        "let a = AuthRequest (host: .appleAccount, path: p, contentType: t, body: b)",
        "let a = AuthRequest.init(host: .appleAccount, path: p, contentType: t, body: b)",
        "let make = AuthRequest.init",
        "extension Maker where Made == AuthRequest { func make() -> Made { Made(host: h, path: p, contentType: t, body: b) } }",
        "let a = `AuthRequest`(host: h, path: p, contentType: t, body: b)",
        "let make = [AuthRequest].Element.init",
    ])
    func theAuthMakerNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.authMakers))
    }

    @Test(arguments: [
        "SecItemAdd(query as CFDictionary, nil)",
        "SecItemAdd (query as CFDictionary, nil)",
        "let status = Security.SecItemCopyMatching(query, &result)",
        "let key = SecKeyCreateRandomKey(attributes, &error)",
        "let query = [kSecClass: kSecClassGenericPassword]",
        "let access = SecAccessControlCreateWithFlags(nil, accessible, .userPresence, nil)",
        "SecKeychainFindGenericPassword(nil, 0, nil, 0, nil, nil, nil, nil)",
    ])
    func theKeychainNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.keychain))
    }

    @Test(arguments: [
        "let data = try Data(contentsOf: url)",
        "let data = try Data(contentsOf : url)",
        "let text = try String(contentsOf: url, encoding: .utf8)",
        "let data = NSData(contentsOf: url)",
        "let task = session.dataTask(with: request)",
        "let task = session.downloadTask(with: url)",
        "let task = session.uploadTask(with: request, from: body)",
        "let view = WKWebView()",
        "let stream = CFReadStreamCreateWithFile(nil, url as CFURL)",
        // Phase 1b gates verifier round 2: swiftc only warns that these backticks aren't needed.
        "let data = try Data(`contentsOf`: url)",
        "let data = try `Data`(`contentsOf` : url)",
        "let task = session.`dataTask`(with: request)",
    ])
    func theFetchNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.fetches))
    }

    @Test(arguments: [
        "let n = unsafeBitCast(x, to: Int.self)",
        "let c = unsafeDowncast(x, to: C.self)",
        "p.withMemoryRebound(to: UInt8.self, capacity: 1) { _ in }",
        "let q = raw.assumingMemoryBound(to: Int.self)",
        "let q = raw.bindMemory(to: Int.self, capacity: 1)",
    ])
    func theCastNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.casts))
    }

    @Test(arguments: [
        #"let type: AnyClass? = NSClassFromString("NSURL" + "Session")"#,
        #"let s = NSSelectorFromString("dataTaskWithRequest:")"#,
        #"let s = Selector(("dataTaskWithRequest:"))"#,
        #"let type = objc_getClass("NSURL" + "Session")"#,
        "let handle = dlopen(nil, RTLD_NOW)",
        #"let symbol = dlsym(handle, "connect")"#,
        "let session = Mirror(reflecting: transport).children.first?.value",
        #"let session = transport.value(forKey: "session")"#,
        "let invocation: NSInvocation? = nil",
        #"let type: AnyClass? = Bundle.main.classNamed("NSURL" + "Session")"#,
        "let type: AnyClass? = bundle.principalClass",
        #"let p = NSProtocolFromString("NSURLSessionDelegate")"#,
        #"let f = CFBundleGetFunctionPointerForName(bundle, "connect" as CFString)"#,
        #"let d = CFBundleGetDataPointerForName(bundle, "environ" as CFString)"#,
        #"let type = _typeByName("So12NSURLSessionC")"#,
        #"@_silgen_name("connect") func link(_ fd: Int32, _ address: UnsafeRawPointer, _ length: UInt32) -> Int32"#,
        #"@_extern(c, "connect") func link(_ fd: Int32, _ address: UnsafeRawPointer, _ length: UInt32) -> Int32"#,
        "let session = `Mirror`(reflecting: transport).children.first?.value",
        #"let s = `Selector`(("dataTaskWithRequest:"))"#,
        #"let session = transport.`value`(forKey: "session")"#,
    ])
    func theLookupNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.lookups))
    }

    @Test(arguments: [
        "let (body, http) = try await transport.send(request, limit: bodyLimit)",
        "_ = try await URLSessionTransport().send(request, limit: 1)",
        "_ = try await t\n    .send (request, limit: 1)",
        "let send = transport.send",
        "extension Transport { func go(_ r: URLRequest) async throws { _ = try await send(r, limit: 1) } }",
        "extension HTTPCore.Transport {}",
        "_ = try await URLSessionTransport().`send`(request, limit: 1)",
        "extension `Transport` {}",
    ])
    func theSendNeedleFinds(_ code: String) {
        #expect(Self.found(code, RouteTests.sends))
    }

    static func named(_ code: String, _ names: [String]) -> Bool { SourceScan.names(SourceScan.File(path: "x.swift", text: code), names) }

    /// `send` as a name, however it is reached: bare in an extension of `URLSessionTransport` or of a protocol refining
    /// `Transport` (Phase 1b gates verifier round 2), taken as a function, or escaped.
    @Test(arguments: [
        "extension URLSessionTransport { func go(_ r: URLRequest) async throws { _ = try await send(r, limit: 1) } }",
        "protocol Relay: Transport {}\nextension Relay { func go(_ r: URLRequest) async throws { _ = try await send (r, limit: 1) } }",
        "let f = send",
        "_ = try await `send`(r, limit: 1)",
        "_ = try await self.send(r, limit: 1)",
        "let s = t.send",
        "#selector(send(_:limit:))",
    ])
    func theSendNameFinds(_ code: String) {
        #expect(Self.named(code, RouteTests.sendName))
    }

    /// A name is whole: not inside a longer one, a comment or a string.
    @Test(arguments: [
        "func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }",
        "let resend = 1", "let sends = 2", "let send2 = 3", "// send(r, limit: 1)", "/* send */ run()", #"let s = "send it""#,
        "let `send it` = 1",
    ])
    func theSendNameIsWhole(_ code: String) {
        #expect(!Self.named(code, RouteTests.sendName))
    }

    @Test(arguments: [
        "let p = Process()",
        "let p: Foundation.Process = .init()",
        "try Process.run(url, arguments: []) { _ in }",
        "let p = `Process`()",
        "posix_spawn(&pid, path, nil, nil, argv, environ)",
        "posix_spawnp(&pid, \"curl\", nil, nil, argv, nil)",
        "execv(path, argv)",
        "execve(path, argv, envp)",
        "let s = NSAppleScript(source: text)",
        "let s = OSAScript(source: text)",
        "let t = try NSUserUnixTask(url: url)",
    ])
    func theChildNeedlesFind(_ code: String) {
        #expect(Self.named(code, RouteTests.children))
    }

    @Test func aProcessIsNotItsInfo() {
        #expect(!Self.named("let info = ProcessInfo.processInfo.processIdentifier", RouteTests.children))
        #expect(!Self.named("let processes = 1; let execution = 2", RouteTests.children))
    }

    static func hostCallees(_ code: String) -> [String] { RouteTests.hostCalls(SourceScan.File(path: "x.swift", text: code)) }

    /// What a `host:` call is made on, and which of those make a request where no maker needle looks.
    @Test func aHostCallSaysWhatItIsMadeOn() {
        #expect(Self.hostCallees("let r = [ReadRequest].Element(host: .business, path: p)") == ["Element"])
        #expect(Self.hostCallees("let r = (ReadRequest)(host: .business, path: p)") == [")"])
        #expect(Self.hostCallees("let r = Box<ReadRequest>.Inner (\n    host: .business, path: p)") == ["Inner"])
        #expect(Self.hostCallees("let r = `Sneak`(`host`: .business, path: p)") == ["Sneak"])
        #expect(Self.hostCallees("static func sneak() -> Self { Self(host: .business, path: p) }") == ["Self"])
        #expect(Self.hostCallees("ReadRequest(host: h, path: p); URL.make(host: h, path: p); AuthRequest(host: h, path: p, contentType: t, body: b)")
                == ["ReadRequest", "make", "AuthRequest"])
        #expect(Self.hostCallees("package init(host: APIHost, path: String) {}; let r: ReadRequest = .init(host: h, path: p)") == ["init", "init"])
        for code in ["page(items, url: url, host: host)", "func headers(for host: APIHost)", "// Sneak(host: h)", #"let s = "Sneak(host: h)""#] {
            #expect(Self.hostCallees(code).isEmpty, "\(code)")
        }
        func others(_ code: String) -> [String] { RouteTests.otherHostCalls(SourceScan.File(path: "x.swift", text: code)) }
        #expect(others("let r = [ReadRequest].Element(host: .business, path: p); let s = ReadRequest(host: h, path: p)") == ["Element"])
        #expect(others("let r = (ReadRequest)(host: h, path: p); let u = URL.make(host: h, path: p)") == [")"])
        #expect(others("let a = AuthRequest(host: h, path: p, contentType: t, body: b); let r: ReadRequest = .init(host: h, path: p)").isEmpty)
    }

    /// What the send-name scan excuses as a stub: TestSupport's files, never a client, a session or a screen.
    @Test func onlyTestSupportIsAStub() {
        let sources = RouteTests.sources
        for path in ["\(sources)/TestSupport/AppleStub.swift", "\(sources)/TestSupport/MosyleStub.swift"] {
            #expect(RouteTests.isStub(path), "\(path)")
        }
        for path in ["\(sources)/AppleBusiness/AppleClient.swift", "\(sources)/AppleBusiness/TokenBroker.swift", "\(sources)/HTTPCore/HTTPClient.swift",
                     "\(sources)/Mosyle/MosyleSession.swift", "App/Screens/ServicesView.swift", "\(sources)/TestSupportShim/X.swift"] {
            #expect(!RouteTests.isStub(path), "\(path)")
        }
    }

    @Test(arguments: [
        "extension ReadRequest { static func sneak() -> Self { Self(host: .business, path: p) } }",
        "extension ReadRequest: Maker {}",
        "public extension Wire.ReadRequest {}",
        "extension AuthRequest: Maker {}",
        "extension\n    Wire.AuthRequest {}",
        "extension `ReadRequest`: Maker {}",
    ])
    func theExtensionNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.requestExtensions))
    }

    static func aliases(_ code: String) -> [String] { RouteTests.aliases(SourceScan.File(path: "x.swift", text: code)) }

    /// `typealias Sneak = ReadRequest`, however spelled, and the near misses that alias something else.
    @Test func theAliasScanFindsARequestTypeUnderAnotherName() {
        let aliased = ["typealias Sneak = ReadRequest", "typealias Sneak = Wire.ReadRequest", "public typealias S<T> = ReadRequest",
                       "typealias Sneak =\n    ReadRequest", "typealias Sneak = Optional<AuthRequest>", "associatedtype R = ReadRequest",
                       "let a = 1; typealias Sneak = ReadRequest", "typealias Sneak = Dictionary<Int,\n    ReadRequest>",
                       "typealias Make = (Int) -> ReadRequest", "typealias Sneak = ReadRequest; let a = 1"]
        for code in aliased { #expect(!Self.aliases(code).isEmpty, "\(code)") }
        let other = ["typealias Handler = (Int) -> Void\nfunc read() -> ReadRequest { make() }", "let r = ReadRequest(host: h, path: p)",
                     "// typealias Sneak = ReadRequest", "let s = \"typealias Sneak = ReadRequest\"", "typealias Pair = (Int, Int)\nlet r: ReadRequest",
                     "let mytypealias = ReadRequest.self", "typealias Pair = (Int, Int); let r = ReadRequest(host: h, path: p)"]
        for code in other { #expect(Self.aliases(code).isEmpty, "\(code)") }
    }

    /// The reads `DebugOnlyTests` keeps out of Release code, each spelled as a debug switch could be.
    @Test(arguments: [
        #"if ProcessInfo.processInfo.environment["ABAPIT" + "_DEMO"] == "1" { demo() }"#,
        #"let info = NSProcessInfo.processInfo"#,
        "let all = CommandLine.arguments",
        #"let value = getenv("X")"#,
        "let env = _NSGetEnviron()",
        #"if UserDefaults.standard.bool(forKey: "ABAPIT" + "_DEMO") { demo() }"#,
        #"let suite = UserDefaults(suiteName: "x")"#,
        #"@AppStorage("demo") var demo = false"#,
        #"let v = CFPreferencesCopyAppValue("demo" as CFString, kCFPreferencesCurrentApplication)"#,
        // Phase 1b gates verifier round 2: the process's own arguments and environment, through sysctl.
        "var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, getpid()]",
        "_ = sysctl(&mib, 3, &buffer, &size, nil, 0)",
        #"_ = sysctlbyname("kern.procargs2", &buffer, &size, nil, 0)"#,
        "let count = _NSGetArgc().pointee",
        "_ = proc_pidpath(getpid(), &path, 4096)",
    ])
    func theProcessReadNeedlesFind(_ code: String) {
        #expect(Self.found(code, DebugOnlyTests.processReads))
    }

    /// Darwin's `environ`, a whole name in Release code, and `environment`, which isn't it.
    @Test func theEnvironNameIsWhole() {
        func spots(_ code: String) -> [SourceScan.Spot] {
            SourceScan.outsideDebug(SourceScan.File(path: "x.swift", text: code), [], names: DebugOnlyTests.processReadNames, strings: false)
        }
        #expect(spots(#"if let first = environ.pointee, String(cString: first).hasPrefix("DEMO=") { demo() }"#).map(\.what) == ["environ outside #if DEBUG"])
        #expect(!spots("let all = Darwin.environ").isEmpty)
        #expect(!spots("let all = `environ`").isEmpty)
        for code in ["#if DEBUG\nlet all = environ\n#endif", "content.environment(model)", "@Environment(\\.openURL) var openURL",
                     "let environment = 1", "// environ", #"let s = "environ""#] {
            #expect(spots(code).isEmpty, "\(code)")
        }
    }

    @Test func theTestableNeedleFinds() {
        #expect(Self.found("@testable import AppleBusiness", ["@testable"]))
    }

    /// Every needle of every list: named in a string literal it counts; named in a comment it doesn't.
    @Test(arguments: [RouteTests.networking, RouteTests.readMakers, RouteTests.authMakers, RouteTests.requestExtensions, RouteTests.keychain,
                      RouteTests.fetches, RouteTests.casts, RouteTests.lookups, RouteTests.sends, DebugOnlyTests.processReads, ["@testable"]])
    func aStringIsAUseAndACommentIsNot(_ needles: [String]) {
        for needle in needles {
            #expect(Self.found("let name = \"\(needle)\"", needles), "\(needle) in a string")
            #expect(Self.found("let name = \"\"\"\n    \(needle)\n    \"\"\"", needles), "\(needle) in a multi-line string")
            #expect(!Self.found("run() // \(needle)", needles), "\(needle) in a line comment")
            #expect(!Self.found("/* \(needle) */ run()", needles), "\(needle) in a block comment")
        }
    }

    /// The lexer under the scans, case by case: what a comment or a literal blanks, and where it ends.
    @Test func theLexerReadsLiteralsAsSwiftDoes() {
        func code(_ text: String, strings: Bool) -> [UInt8] { Array(SourceScan.code(text, strings: strings).utf8) }
        #expect(code("a // b\nc", strings: true) == Array("a     \nc".utf8))
        #expect(code(#"let s = "a // b"; t"#, strings: true) == Array(#"let s = "a // b"; t"#.utf8))
        #expect(code(#"let s = "a // b"; t"#, strings: false) == Array(#"let s = "      "; t"#.utf8))
        // A raw string's `\` is a backslash, not an escape of the quote after it.
        #expect(code(##"let r = #"\"#; t"##, strings: false) == Array(##"let r = #" "#; t"##.utf8))
        #expect(code("let m = \"\"\"\n  // x\n  \"\"\"; t", strings: false) == Array("let m = \"\"\"\n      \n  \"\"\"; t".utf8))
        // An interpolation is code: its comment is blanked even with the string kept, and its `)` ends it.
        #expect(code(#""\(a /* " */) b""#, strings: false) == Array(#""  a        )  ""#.utf8))
        #expect(code(#""\(a /* " */) b""#, strings: true) == Array(#""\(a        ) b""#.utf8))
        // A regex literal's slashes are blanked with its contents: no `/` outside code is left for `unreadable`.
        #expect(code("let r = #/a//b/#; t", strings: false) == Array("let r = #      #; t".utf8))
        #expect(code("a /* x /* y */ z */ b", strings: true) == Array(("a " + String(repeating: " ", count: 17) + " b").utf8))
        // Phase 1b gates verifier round 1: each of these branches had no case, and a misreading hid what follows.
        // A line ends at CR too; an unterminated string ends with its line (swiftc reports it; the scan reads on).
        #expect(code("a // b\rc", strings: true) == Array("a     \rc".utf8))
        #expect(code("/* a\rb */c", strings: true) == Array("    \r    c".utf8))
        // A raw identifier ends with its line, as swiftc's does: a backtick left open is a backtick.
        #expect(code("let a = `b\nlet s = `c`", strings: true) == Array("let a = `b\nlet s = `c`".utf8))
        #expect(code("let s = \"a\nb", strings: false) == Array("let s = \" \nb".utf8))
        #expect(code("let s = \"a\rb", strings: false) == Array("let s = \" \rb".utf8))
        // A plain escape takes the scalar after it, so `\"` doesn't close the string.
        #expect(code(#"let s = "a\"b // c"; t"#, strings: false) == Array(#"let s = "         "; t"#.utf8))
        // A raw string closes only at a quote followed by its hashes.
        #expect(code(##"let r = #"a"//"#; t"##, strings: false) == Array(##"let r = #"    "#; t"##.utf8))
        // An escape in a regex literal takes the scalar after it, so `\/#` doesn't close it.
        #expect(code(#"let r = #/a\/#//x/#; t"#, strings: false) == Array("let r = #         #; t".utf8))
        // An interpolation counts its own parentheses, and a string inside it is a string.
        #expect(code(#""\(f(a) + "x // y") z""#, strings: false) == Array(#""  f(a) + "      ")  ""#.utf8))
        // A raw identifier is one name: what it holds is no comment, string or directive. A plain one is kept.
        #expect(code("let `a // b` = 1; t", strings: true) == Array("let `      ` = 1; t".utf8))
        #expect(code("let `a\"b` = 1; let c = \"d\"", strings: false) == Array("let `   ` = 1; let c = \" \"".utf8))
        #expect(code("let s = `URLSession`.shared", strings: false) == Array("let s = `URLSession`.shared".utf8))
    }

    static func unreadable(_ code: String) -> [SourceScan.Spot] { SourceScan.unreadable(SourceScan.File(path: "x.swift", text: code)) }

    /// A bare regex literal: Swift 6 lexes one wherever an expression can start, and this lexer doesn't. `/\/*/` opened a
    /// block comment and `/"/` a string here, hiding the code after them (Phase 1b gates verifier round 1). Each shape
    /// below is one swiftc accepts; a division without spaces is refused with them. So is `a/ b`, which swiftc
    /// rejects: a `/` needs a space on both sides, not on either.
    @Test(arguments: [
        #"_ = /\/*/"#, #"let r = /\/\//; _ = r"#, #"_ = /"/; _ = "/*""#, "return/x/", "let r = /=a/", "_ = [/a/, /b/]", "_ = (/c/)",
        "_ = !/x/", "/x/.firstMatch(in: s)", "let c = a/b", "x /= 2", "let c = a /b", "let c = a/ b", "let c = a/\n    b",
    ])
    func aBareSlashIsUnreadable(_ code: String) {
        #expect(!Self.unreadable(code).isEmpty)
    }

    @Test(arguments: [
        "let c = a / b", "let c = (a / 2) / b", "let c = a\n    / b", "let c = a /\n    b", #"let u = "https://example.com/v1/x""#,
        "// a/b", "/* a/b */", "/// `/x/`", "let r = #/a/b/#", "let r = ##/a/#b/##", #""\(a / b)""#, "let m = \"\"\"\n  /x/\n  \"\"\"",
        ##"let s = #"a/b"#"##,
    ])
    func spacedDivisionAndLiteralsAreReadable(_ code: String) {
        #expect(Self.unreadable(code).isEmpty, "\(Self.unreadable(code))")
    }

    static func spots(_ code: String, _ needles: [String] = ["ABAPIT_"], strings: Bool = true) -> [SourceScan.Spot] {
        SourceScan.outsideDebug(SourceScan.File(path: "x.swift", text: code), needles, strings: strings)
    }

    /// Debug code, however the `#if` is spelled or nested; a comment naming a switch isn't a use.
    @Test(arguments: [
        "#if DEBUG\nlet a = environment[\"ABAPIT_DEMO\"]\n#endif",
        "#if DEBUG\n#if os(macOS)\nlet a = \"ABAPIT_X\"\n#else\nlet a = \"ABAPIT_Y\"\n#endif\n#endif",
        "#if canImport(AppKit)\nlet a = 1\n#elseif DEBUG\nlet a = \"ABAPIT_X\"\n#endif",
        "let a = 1; #if DEBUG\nlet b = \"ABAPIT_X\"; #endif",
        "#if DEBUG // the snapshot harness\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUG /* the snapshot harness */\nlet a = \"ABAPIT_X\"\n#endif",
        "// ABAPIT_DEMO=1 fills the window from the demo org",
        "/* ABAPIT_SPIKE */ let a = 1",
        // DEBUG inside another condition is debug code at any depth.
        "#if os(macOS)\n#if DEBUG\nlet a = \"ABAPIT_X\"\n#endif\n#endif",
        // A directive's line ends at CR as well as LF; a raw identifier that holds `#endif` is a name.
        "#if DEBUG\rlet a = \"ABAPIT_X\"\r#endif",
        "#if DEBUG // the harness\rlet a = \"ABAPIT_X\"\r\n#endif",
        "#if DEBUG\nlet `#endif` = 1\nlet a = \"ABAPIT_X\"\n#endif",
    ])
    func debugCodeIsDebug(_ code: String) {
        #expect(Self.spots(code).isEmpty, "\(Self.spots(code))")
    }

    /// Release code: an `#else` of `#if DEBUG`, another condition, code after the `#endif`, and directives that
    /// are only text (in a comment or a string).
    @Test(arguments: [
        "let a = environment[\"ABAPIT_DEMO\"]",
        "let a = environment[\"ABAPIT_\" + \"DEMO\"]",
        "#if DEBUG\n#else\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUG\n#elseif os(macOS)\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUG\n#elseif true\nlet a = \"ABAPIT_X\"\n#endif",
        "#if !DEBUG\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUG || RELEASE\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUGGING\nlet a = \"ABAPIT_X\"\n#endif",
        "#if os(macOS)\n#if DEBUG\n#endif\nlet a = \"ABAPIT_X\"\n#endif",
        "#if DEBUG\n#endif\nlet a = \"ABAPIT_X\"",
        "let a = \"ABAPIT_X\"; #if DEBUG\n#endif",
        "// #if DEBUG\nlet a = \"ABAPIT_X\"\n// #endif",
        "/*\n#if DEBUG\n*/\nlet a = \"ABAPIT_X\"\n/*\n#endif\n*/",
        "let s = \"\"\"\n#if DEBUG\n\"\"\"\nlet a = \"ABAPIT_X\"\nlet t = \"\"\"\n#endif\n\"\"\"",
        "let s = \"#if DEBUG\"\nlet a = \"ABAPIT_X\"\nlet t = \"#endif\"",
        "#if DEBUG\nlet a = 1\n#endif\n#endif\nlet b = \"ABAPIT_X\"",
        "#if DEBUG\nlet a = \"ABAPIT_X\"",
        // A comment after `#endif` ends at CR, and the code after it is Release code (Phase 1b gates verifier round 1).
        "#if DEBUG\nlet a = 1\n#endif // demo\rlet b = \"ABAPIT_X\"",
        "let `#if DEBUG` = 1\nlet a = \"ABAPIT_X\"\nlet `#endif` = 2",
    ])
    func releaseCodeIsRelease(_ code: String) {
        #expect(!Self.spots(code).isEmpty)
    }

    @Test func aSpotSaysWhereItIs() {
        #expect(Self.spots("let a = 1\nlet b = \"ABAPIT_X\"").map(\.description) == ["x.swift:2: ABAPIT_ outside #if DEBUG"])
        #expect(Self.spots("#if DEBUG\n#endif\n#endif").map(\.what) == ["#endif without an #if"])
        #expect(Self.spots("#if DEBUG\n").map(\.what) == ["an #if is never closed"])
        // Lines are Swift's: a lone CR ends one, a CRLF ends one.
        #expect(Self.spots("let a = 1\rlet b = \"ABAPIT_X\"").map(\.line) == [2])
        #expect(Self.spots("let a = 1\r\nlet b = 2\r\nlet c = \"ABAPIT_X\"").map(\.line) == [3])
        #expect(Self.unreadable("let a = 1\n_ = /\\/*/\nlet b = 2").map(\.line) == [2])
    }

    /// The app's `TestSupport` import (PackageGraphTests): code only, so a trailing comment can't pass it off
    /// as the line after `#if DEBUG` (Phase 1b review: `import TestSupport // demo` did), and a string isn't one.
    @Test func theTestSupportImportIsReadAsCode() {
        let guarded = ["#if DEBUG\nimport TestSupport\n#endif", "#if DEBUG\n@preconcurrency import TestSupport\n#endif",
                       "let name = \"TestSupport\""]
        for code in guarded { #expect(Self.spots(code, ["TestSupport"], strings: false).isEmpty, "\(code)") }
        let released = ["import TestSupport // demo", "import TestSupport /* demo */", "@testable import TestSupport",
                        "/* #if DEBUG */ import TestSupport", "#if DEBUG\n#else\nimport TestSupport\n#endif",
                        "import struct TestSupport.AppleStub", "let stub = TestSupport.AppleStub.self"]
        for code in released { #expect(!Self.spots(code, ["TestSupport"], strings: false).isEmpty, "\(code)") }
    }
}
