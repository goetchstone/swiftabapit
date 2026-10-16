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
    ])
    func theLookupNeedlesFind(_ code: String) {
        #expect(Self.found(code, RouteTests.lookups))
    }

    @Test func theTestableNeedleFinds() {
        #expect(Self.found("@testable import AppleBusiness", ["@testable"]))
    }

    /// Every needle of every list: named in a string literal it counts; named in a comment it doesn't.
    @Test(arguments: [RouteTests.networking, RouteTests.readMakers, RouteTests.authMakers, RouteTests.keychain,
                      RouteTests.fetches, RouteTests.casts, RouteTests.lookups, ["@testable"]])
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
        #expect(code("let r = #/a//b/#; t", strings: false) == Array("let r = #/    /#; t".utf8))
        #expect(code("a /* x /* y */ z */ b", strings: true) == Array(("a " + String(repeating: " ", count: 17) + " b").utf8))
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
    ])
    func releaseCodeIsRelease(_ code: String) {
        #expect(!Self.spots(code).isEmpty)
    }

    @Test func aSpotSaysWhereItIs() {
        #expect(Self.spots("let a = 1\nlet b = \"ABAPIT_X\"").map(\.description) == ["x.swift:2: ABAPIT_ outside #if DEBUG"])
        #expect(Self.spots("#if DEBUG\n#endif\n#endif").map(\.what) == ["#endif without an #if"])
        #expect(Self.spots("#if DEBUG\n").map(\.what) == ["an #if is never closed"])
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
