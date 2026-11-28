import Foundation
import Testing
import TestSupport

/// The transport's protections, held as the text that asks for them (invariants 4 and 7): the host check before a
/// connection, the delegate that refuses every redirect and its wiring to the session's one send, the body cap as the
/// bytes stream in, and the session's settings (ephemeral, no cookies, cache or credential storage, TLS 1.2). Every
/// other test sends through a stub `Transport`, and `HTTPCoreTests` call the delegate method on a task that was never
/// resumed, not the wiring: with the delegate unhooked, both caps removed and the session made `.default` with
/// cookies and TLS 1.0, every test passed (failure-log 2026-11-18, "the transport's protections were held by no
/// test"). The oversized-body tests run the stubs' own cap, which imitates this one. This holds the text, not the
/// behaviour: nothing here opens a connection. The pins hold against an accidental edit and the weakenings listed below,
/// not against a determined author who edits the test too: the review is the second line.
@Suite("Transport shape")
struct TransportShapeTests {
    static let path = "Packages/AbapitKit/Sources/HTTPCore/Transport.swift"

    /// The file's code: comments and string contents blanked, whitespace and backticks removed.
    static func code() throws -> String {
        let file = try #require(SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/HTTPCore").first { $0.path == path }, "\(path) isn't where the scan looks")
        return String(SourceScan.code(file.text, strings: false).filter { !$0.isWhitespace && $0 != "`" })
    }

    /// What `code` no longer does, or does besides: each needle with the count it must have.
    static func problems(_ code: String) -> [String] {
        func count(_ needle: String) -> Int { code.components(separatedBy: needle).count - 1 }
        let held: [(String, Int)] = [
            // One call on the session sends, with this object as the task's delegate; the other ends the session.
            ("tryawaitsession.bytes(for:request,delegate:self)", 1),
            ("session.invalidateAndCancel()", 1),
            ("session.", 2),
            // The host is checked here too, before a connection, and before the one send.
            ("guardleturl=request.url,APIHost(of:url)!=nilelse{throwHTTPFailure.refusedHost(request.url?.host()", 1),
            ("APIHost(", 1),
            // The one delegate method, by the selector URLSession calls (a renamed method is never called), follows no
            // redirect; nothing answers an authentication challenge (server trust).
            ("publicfuncurlSession(_session:URLSession,task:URLSessionTask,willPerformHTTPRedirectionresponse:HTTPURLResponse,newRequestrequest:URLRequest,completionHandler:@escaping@Sendable(URLRequest?)->Void){", 1),
            ("urlSession(", 1),
            ("completionHandler(nil)", 1),
            ("completionHandler(", 1),
            ("URLCredential", 0),
            ("URLAuthenticationChallenge", 0),
            ("serverTrust", 0),
            // The body cap (invariant 7): the declared length first, then every byte as it arrives.
            ("ifhttp.expectedContentLength>Int64(limit){throwHTTPFailure.tooLarge(limit:limit)}", 1),
            ("fortryawaitbyteinbytes{guardbody.count<limitelse{throwHTTPFailure.tooLarge(limit:limit)}body.append(byte)}", 1),
            // One session: ephemeral, no cookies, no cache, no credential storage, TLS 1.2 at least.
            ("letconfiguration=URLSessionConfiguration.ephemeral", 1),
            ("URLSessionConfiguration", 1),
            ("configuration.httpCookieAcceptPolicy=.never", 1),
            ("configuration.httpShouldSetCookies=false", 1),
            ("configuration.httpCookieStorage=nil", 1),
            ("configuration.urlCache=nil", 1),
            ("configuration.urlCredentialStorage=nil", 1),
            ("configuration.tlsMinimumSupportedProtocolVersion=.TLSv12", 1),
            ("session=URLSession(configuration:configuration)", 1),
            ("URLSession(", 1),
        ]
        var found = held.filter { count($0.0) != $0.1 }.map { "\($0.0): \(count($0.0)), not \($0.1)" }
        // Each setting is named once: a second assignment would overwrite the first, and a bare name would find it.
        for name in ["tlsMinimumSupportedProtocolVersion", "httpCookieAcceptPolicy", "httpShouldSetCookies", "httpCookieStorage",
                     "urlCache", "urlCredentialStorage"] where count(name) != 1 {
            found.append("\(name): \(count(name)), not 1")
        }
        // Nothing is compiled only in some builds, no value is shadowed or rebound, and no request, limit or delegate
        // answer is replaced on the way: each of these would defeat a pin above with the text still in place.
        for needle in ["#if", "letlimit", "varlimit", "varrequest", "request.url=", "=session", "=completionHandler"]
        where count(needle) != 0 {
            found.append("\(needle): \(count(needle)), not 0")
        }
        // The host is checked before the one send.
        let guardAt = code.range(of: "APIHost(of:url)")?.lowerBound, sendAt = code.range(of: "session.bytes(")?.lowerBound
        if let guardAt, let sendAt { if guardAt > sendAt { found.append("the host check comes after the send") } } else { found.append("the host check or the send is missing") }
        return found
    }

    @Test func theTransportKeepsItsProtections() throws {
        let problems = try Self.problems(Self.code())
        #expect(problems.isEmpty, "\(Self.path): \(problems)")
    }

    /// The check is seen to fail: each weakening of the file's own text is found (the thirteen a review tried, and their kin).
    @Test func eachWeakeningIsFound() throws {
        let code = try Self.code()
        let weakenings: [(String, String, String)] = [
            ("no delegate, so every redirect is followed", "delegate:self)", "delegate:nil)"),
            ("every redirect followed", "completionHandler(nil)", "completionHandler(request)"),
            ("no host check before a connection", "guardleturl=request.url,APIHost(of:url)!=nilelse{throwHTTPFailure.refusedHost(request.url?.host()", ""),
            ("a host check that lets every host through", "APIHost(of:url)!=nil", "true"),
            ("a renamed delegate method, never called", "willPerformHTTPRedirectionresponse:", "willRedirectresponse:"),
            ("no check of the declared length", "ifhttp.expectedContentLength>Int64(limit){throwHTTPFailure.tooLarge(limit:limit)}", ""),
            ("no cap as the bytes arrive", "guardbody.count<limitelse{throwHTTPFailure.tooLarge(limit:limit)}", ""),
            ("a session that keeps state on disk", "URLSessionConfiguration.ephemeral", "URLSessionConfiguration.default"),
            ("cookies accepted", "httpCookieAcceptPolicy=.never", "httpCookieAcceptPolicy=.always"),
            ("cookies sent", "httpShouldSetCookies=false", "httpShouldSetCookies=true"),
            ("a cookie store", "configuration.httpCookieStorage=nil", ""),
            ("a cache", "configuration.urlCache=nil", ""),
            ("a credential store", "configuration.urlCredentialStorage=nil", ""),
            ("TLS 1.0", "tlsMinimumSupportedProtocolVersion=.TLSv12", "tlsMinimumSupportedProtocolVersion=.TLSv10"),
            ("the shared session", "session=URLSession(configuration:configuration)", "session=URLSession.shared"),
        ]
        for (why, old, new) in weakenings {
            #expect(code.contains(old), "\(why): the text to weaken isn't there")
            #expect(!Self.problems(code.replacingOccurrences(of: old, with: new)).isEmpty, "\(why)")
        }
        for (why, old, new) in [
            ("a second TLS floor", "configuration.tlsMinimumSupportedProtocolVersion=.TLSv12", "configuration.tlsMinimumSupportedProtocolVersion=.TLSv12configuration.tlsMinimumSupportedProtocolVersion=.TLSv10"),
            ("a second cookie policy", "configuration.httpCookieAcceptPolicy=.never", "configuration.httpCookieAcceptPolicy=.neverconfiguration.httpCookieAcceptPolicy=.always"),
            ("a second cookie send", "configuration.httpShouldSetCookies=false", "configuration.httpShouldSetCookies=falseconfiguration.httpShouldSetCookies=true"),
            ("a second cookie store", "configuration.httpCookieStorage=nil", "configuration.httpCookieStorage=nilconfiguration.httpCookieStorage=HTTPCookieStorage.shared"),
            ("a second cache", "configuration.urlCache=nil", "configuration.urlCache=nilconfiguration.urlCache=URLCache.shared"),
            ("a second credential store", "configuration.urlCredentialStorage=nil", "configuration.urlCredentialStorage=nilconfiguration.urlCredentialStorage=URLCredentialStorage.shared"),
            ("TLS only in debug builds", "configuration.tlsMinimumSupportedProtocolVersion=.TLSv12", "#ifDEBUGconfiguration.tlsMinimumSupportedProtocolVersion=.TLSv12#endif"),
            ("a limit raised", "letconfiguration=", "letlimit=limit*100letconfiguration="),
            ("a limit shadowed", "letconfiguration=", "varlimit=Int.maxletconfiguration="),
            ("a request rebuilt", "guardleturl=request.url", "varrequest=URLRequest(url:URL(string:\"x\")!)guardleturl=request.url"),
            ("a request's url replaced", "let(bytes,response)=", "request.url=nillet(bytes,response)="),
            ("another session", "let(bytes,response)=", "letother=sessionlet(bytes,response)="),
            ("the redirect answer replaced", "completionHandler(nil)", "completionHandler(nil)let_=completionHandler"),
        ] {
            #expect(code.contains(old), "\(why): the text to change isn't there")
            #expect(!Self.problems(code.replacingOccurrences(of: old, with: new)).isEmpty, "\(why)")
        }
        // The host check after the send is found.
        let sendLine = "let(bytes,response)=tryawaitsession.bytes(for:request,delegate:self)"
        let guardLine = "guardleturl=request.url,APIHost(of:url)!=nilelse{throwHTTPFailure.refusedHost(request.url?.host()"
        if let sendRange = code.range(of: sendLine), let guardRange = code.range(of: guardLine), let close = code.range(of: "}", range: guardRange.upperBound..<code.endIndex) {
            let guardText = String(code[guardRange.lowerBound..<close.upperBound])
            var moved = code
            moved.removeSubrange(guardRange.lowerBound..<close.upperBound)
            moved.insert(contentsOf: guardText, at: moved.range(of: sendLine)!.upperBound)
            #expect(sendRange.lowerBound > guardRange.lowerBound)
            #expect(!Self.problems(moved).isEmpty, "a host check after the send")
        } else {
            Issue.record("the host check or the send isn't where the test looks")
        }
        for added in ["_=tryawaitsession.data(for:request)",
                      "funcurlSession(_session:URLSession,didReceivechallenge:URLAuthenticationChallenge)async->(URLSession.AuthChallengeDisposition,URLCredential?){(.useCredential,nil)}"] {
            #expect(!Self.problems(code + added).isEmpty, "\(added)")
        }
    }
}
