import Foundation
@testable import HTTPCore
import Synchronization
import Testing
import TestSupport
import Wire

@Suite("HTTP core")
struct HTTPCoreTests {
    struct NoAuth: Authorizer {
        func headers(for host: APIHost) async throws -> [String: String] { [:] }
        func invalidate(rejected: [String: String]) async {}
    }

    /// Review H1: every Retry-After a server could send is a wait between zero and the cap, never a trap.
    @Test(arguments: ["1000000000000000000000", "1e400", "-5", "nan", "inf", "-inf", "0x10", "",
                      "Fri, 31 Dec 9999 23:59:59 GMT", "Thu, 01 Jan 1970 00:00:00 GMT", "9223372036854775807"])
    func everyRetryAfterIsBounded(value: String) {
        let wait = HTTPClient.wait(after: HTTPResponse(status: 429, headers: ["retry-after": value], body: Data()), attempt: 1, now: Date())
        #expect(wait >= .zero && wait <= HTTPClient.longestWait, "\(value)")
    }

    /// Records what reaches it and answers 204: nothing may reach it from a refused request.
    final class Recorder: Transport, Sendable {
        let seen = Mutex<[String]>([])
        func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
            let url = try #require(request.url)
            seen.withLock { $0.append("\(request.httpMethod ?? "?") \(url.absoluteString)") }
            return (Data("{}".utf8), try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/2", headerFields: [:])))
        }
    }

    static let notReads: [ReadRequest] = [
        ReadRequest(host: .appleBusiness, method: .post, path: "/v1/orgDeviceActivities", body: Data("{}".utf8)),
        ReadRequest(host: .appleBusiness, method: .post, path: "/v1/orgDeviceActivities"),
        ReadRequest(host: .appleBusiness, method: .patch, path: "/v1/mdmServers/S1", body: Data("{}".utf8)),
        ReadRequest(host: .appleBusiness, method: .delete, path: "/v1/mdmServers/S1"),
        ReadRequest(host: .appleSchool, method: .post, path: "/v1/orgDeviceActivities", body: Data("{}".utf8)),
        ReadRequest(host: .appleSchool, method: .patch, path: "/v1/mdmServers/S1"),
        ReadRequest(host: .appleSchool, method: .delete, path: "/v1/mdmServers/S1"),
        ReadRequest(host: .appleBusiness, method: .get, path: "/v1/orgDevices", body: Data("{}".utf8)),
        ReadRequest(host: .appleAccount, method: .get, path: "/auth/oauth2/token"),
        ReadRequest(host: .appleAccount, method: .post, path: "/auth/oauth2/token", body: Data("{}".utf8)),
        ReadRequest(host: .mosyle, method: .get, path: "/v1/devices"),
        ReadRequest(host: .mosyle, method: .post, path: "/v1/devices"),
        ReadRequest(host: .mosyle, method: .delete, path: "/v1/devices", body: Data("{}".utf8)),
        ReadRequest(host: .mosyle, method: .post, path: "/v1/devices", query: [QueryItem("a", "b")], body: Data("{}".utf8)),
        ReadRequest(host: .mosyleLogs, method: .get, path: "/v1/logsstream"),
    ]

    /// Invariants 1 and 2 as each request leaves: an Apple read is a GET with no body, a Mosyle read a POST with a body
    /// and no query, and the token host takes no read. Anything else built as a read is refused and nothing is sent
    /// (failure-log 2026-11-18: a DELETE built in AppleRead.swift went out with the bearer token, every gate green).
    @Test(arguments: notReads.indices)
    func aRequestThatIsNotAReadIsNeverSent(index: Int) async throws {
        let request = Self.notReads[index], recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        await #expect(throws: HTTPFailure.notARead("\(request.method.rawValue) \(request.host.rawValue) a path with no template")) {
            _ = try await client.read(request, authorizer: NoAuth())
        }
        #expect(recorder.seen.withLock { $0 }.isEmpty)
    }

    /// A refusal names the template, never an identifier in a raw path.
    @Test func aRefusalNamesNoIdentifier() async throws {
        let recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        let bare = ReadRequest(host: .appleBusiness, method: .delete, path: "/v1/orgDevices/C02SERIAL1")
        let templated = ReadRequest(host: .appleBusiness, method: .delete, path: "/v1/orgDevices/C02SERIAL1", template: "/v1/orgDevices/{id}")
        for (request, said) in [(bare, "DELETE api-business.apple.com a path with no template"),
                                (templated, "DELETE api-business.apple.com /v1/orgDevices/{id}")] {
            do { _ = try await client.read(request, authorizer: NoAuth()); Issue.record("sent") } catch {
                let message = (error as? HTTPFailure)?.message ?? ""
                #expect(error as? HTTPFailure == .notARead(said))
                #expect(!message.contains("C02SERIAL1"), "\(message)")
            }
        }
        #expect(recorder.seen.withLock { $0 }.isEmpty)
    }

    /// The control: a read of each shape is sent.
    @Test func aReadOfEachShapeIsSent() async throws {
        let recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        _ = try await client.read(ReadRequest(host: .appleBusiness, path: "/v1/orgDevices"), authorizer: NoAuth())
        _ = try await client.read(ReadRequest(host: .appleSchool, path: "/v1/orgDevices"), authorizer: NoAuth())
        _ = try await client.read(ReadRequest(host: .mosyle, method: .post, path: "/v1/devices", body: Data("{}".utf8)), authorizer: NoAuth())
        _ = try await client.read(ReadRequest(host: .mosyleLogs, method: .post, path: "/v1/logsstream", body: Data("{}".utf8)), authorizer: NoAuth())
        #expect(recorder.seen.withLock { $0 } == ["GET https://api-business.apple.com/v1/orgDevices", "GET https://api-school.apple.com/v1/orgDevices",
                                                  "POST https://businessapi.mosyle.com/v1/devices", "POST https://businessapilogs.mosyle.com/v1/logsstream"])
    }

    /// A next link is an Apple read: on any other host nothing is sent.
    @Test(arguments: [APIHost.appleAccount, .mosyle, .mosyleLogs])
    func aNextLinkIsFollowedOnlyOnAnAppleAPIHost(host: APIHost) async throws {
        let recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        await #expect(throws: HTTPFailure.notARead("GET \(host.rawValue) /v1/x")) {
            _ = try await client.read(next: try #require(URL(string: "https://\(host.rawValue)/v1/x")), on: host, template: "/v1/x", authorizer: NoAuth())
        }
        #expect(recorder.seen.withLock { $0 }.isEmpty)
    }

    static let notLogins: [(APIHost, String, [String: String])] = [
        (.appleBusiness, "/v1/orgDeviceActivities", [:]), (.appleSchool, "/v1/orgDeviceActivities", [:]),
        (.appleSchool, "/auth/oauth2/token", [:]), (.appleAccount, "/auth/oauth2/v2/token", [:]), (.appleAccount, "/auth/oauth2/token/", [:]),
        (.mosyle, "/v1/devices", [:]), (.mosyle, "/v1/login/../devices", [:]), (.mosyleLogs, "/v1/logsstream", [:]),
        (.appleAccount, "/auth/oauth2/token", ["Authorization": "Bearer x"]), (.mosyle, "/v1/login", ["Authorization": "Bearer x"]),
        (.mosyle, "/v1/login", ["accessToken": "t", "Authorization": "Bearer x"]),
        (.appleAccount, "/auth/oauth2/token", ["accessToken": "MOSYLE-SECRET"]),
    ]

    /// A credential exchange goes to a login endpoint only, with no header but Mosyle's access token: any other would
    /// be a POST of any body, with any credential, past the read check and the Executor (Phase 7a verifier S9).
    @Test(arguments: notLogins.indices)
    func aCredentialExchangeGoesOnlyToALogin(index: Int) async throws {
        let (host, path, headers) = Self.notLogins[index], recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        await #expect(throws: HTTPFailure.notARead("POST \(host.rawValue) \(path)")) {
            _ = try await client.authenticate(AuthRequest(host: host, path: path, contentType: "application/json", headers: headers, body: Data("{}".utf8)))
        }
        #expect(recorder.seen.withLock { $0 }.isEmpty)
    }

    /// The control: the three logins are sent, and the list is exactly those three.
    @Test func theThreeLoginsAreSent() async throws {
        let recorder = Recorder()
        let client = HTTPClient(transport: recorder, limiter: RateLimiter(sleep: { _ in }))
        _ = try await client.authenticate(AuthRequest(host: .appleAccount, path: "/auth/oauth2/token", contentType: "application/x-www-form-urlencoded", body: Data()))
        _ = try await client.authenticate(AuthRequest(host: .mosyle, path: "/v1/login", contentType: "application/json", headers: ["accessToken": "t"], body: Data()))
        _ = try await client.authenticate(AuthRequest(host: .mosyleLogs, path: "/v1/login", contentType: "application/json", headers: ["accessToken": "t"], body: Data()))
        #expect(recorder.seen.withLock { $0 } == ["POST https://account.apple.com/auth/oauth2/token", "POST https://businessapi.mosyle.com/v1/login",
                                                  "POST https://businessapilogs.mosyle.com/v1/login"])
        #expect(HTTPClient.logins.map { "\($0.0.rawValue)\($0.1)" } == ["account.apple.com/auth/oauth2/token", "businessapi.mosyle.com/v1/login",
                                                                         "businessapilogs.mosyle.com/v1/login"])
    }

    @Test func aNextLinkOffTheHostIsRefused() async throws {
        let client = HTTPClient(transport: AppleStub(), limiter: RateLimiter(sleep: { _ in }))
        for link in ["https://evil.example.com/v1/orgDevices", "http://api-business.apple.com/v1/orgDevices",
                     "https://api-business.apple.com:8443/v1/orgDevices", "https://user@api-business.apple.com/v1/orgDevices",
                     "https://api-school.apple.com/v1/orgDevices", "https://api-business.apple.com/v2/other",
                     "https://api-business.apple.com/v1/../v2/x", "https://api-business.apple.com/v1/%2e%2E/v2/x",
                     "https://api-business.apple.com/v1/.%2e/v2/x", "https://api-business.apple.com/v1/%2E./v2/x",
                     "https://api-business.apple.com/v1/./orgDevices", "https://api-business.apple.com/v1/a%2Fb"] {
            await #expect(throws: HTTPFailure.self, "\(link)") {
                _ = try await client.read(next: URL(string: link)!, on: .appleBusiness, template: "/v1/orgDevices", authorizer: NoAuth())
            }
        }
    }

    /// A rate that isn't a number never reaches the limiter: NaN would never wait.
    @Test func aNonFiniteRateIsTheDefault() async {
        for rate in [Double.nan, .infinity, -.infinity] {
            #expect(await RateLimiter(readsPerMinute: rate, sleep: { _ in }).readsPerMinute == RateLimiter.defaultReadsPerMinute)
        }
    }

    @Test func redirectsStayOnTheSameAllowlistedHost() {
        let business = URL(string: "https://api-business.apple.com/v1/orgDevices")
        #expect(URLSessionTransport.followable(from: business, to: URL(string: "https://api-business.apple.com/v1/x")))
        #expect(!URLSessionTransport.followable(from: business, to: URL(string: "https://api-school.apple.com/v1/x")))
        #expect(!URLSessionTransport.followable(from: business, to: URL(string: "https://evil.example.com/v1/x")))
        #expect(!URLSessionTransport.followable(from: business, to: URL(string: "http://api-business.apple.com/v1/x")))
    }

    @Test func retryAfterIsSecondsOrADateAndNeverOverAMinute() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func wait(_ value: String?, attempt: Int = 1) -> Duration {
            HTTPClient.wait(after: HTTPResponse(status: 429, headers: value.map { ["retry-after": $0] } ?? [:], body: Data()), attempt: attempt, now: now)
        }
        #expect(wait("3") == .seconds(3))
        #expect(wait("3600") == .seconds(60))
        #expect(wait(nil, attempt: 3) == .seconds(8))
        #expect(wait("garbage", attempt: 1) == .seconds(2))
        let date = HTTPClient.httpDate("Fri, 17 Sep 2026 20:00:30 GMT")
        #expect(date != nil)
    }

    @Test func theLimiterHalvesOnA429AndRecoversSlowly() async {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 60, now: { clock.now }, sleep: { clock.advance($0) })
        await limiter.throttled(.read)
        #expect(await limiter.readsPerMinute == 30)
        for _ in 0..<20 { await limiter.succeeded(.read) }
        #expect(abs(await limiter.readsPerMinute - 33) < 0.01)
        // Each 429 its own throttle event: after the last one's hold (one token's time, at most 30 s at the floor).
        for _ in 0..<20 {
            clock.advance(.seconds(31))
            await limiter.throttled(.read)
        }
        #expect(await limiter.readsPerMinute == RateLimiter.floor)
    }

    /// A sweep has several reads in flight (plan §3.6): Apple's `Retry-After` holds the lane, so no token goes to any of
    /// them before it has passed; then the lane runs at the halved rate, the wait not repeated. Without one, the next
    /// token comes one token's time later, as before.
    @Test func aRetryAfterHoldsTheLaneForEveryRead() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let start = clock.now
        await limiter.throttled(.read, retryAfter: .seconds(30))
        try await limiter.acquire(.read)
        #expect(clock.now - start >= .seconds(29.999) && clock.now - start < .seconds(30.001), "\(clock.now - start)")
        try await limiter.acquire(.read)
        #expect(clock.now - start < .seconds(30.3), "the next waits a token at 300 a minute, not the Retry-After again")
        await limiter.throttled(.read)
        let unsaid = clock.now
        try await limiter.acquire(.read)
        #expect(clock.now - unsaid < .seconds(1), "no Retry-After: one token's time")
        // A Retry-After shorter than a token's time at the new rate waits the token's time.
        await limiter.throttled(.read, retryAfter: .zero)
        let short = clock.now
        try await limiter.acquire(.read)
        #expect(clock.now - short > .zero)
    }

    /// The client passes a 429's `Retry-After` to the limiter: here its own wait returns at once, so the limiter's clock
    /// shows the hold (another read waiting on the lane would wait as long).
    @Test func the429sRetryAfterReachesTheLimiter() async throws {
        for (headers, held) in [(["Retry-After": "30"], true), ([:], false)] {
            let clock = Clock()
            let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
            let client = HTTPClient(transport: Scripted([(429, headers)]), limiter: limiter, sleep: { _ in })
            let start = clock.now
            let response = try await client.read(next: URL(string: "https://api-business.apple.com/v1/orgDevices")!, on: .appleBusiness,
                                                 template: "/v1/orgDevices", authorizer: NoAuth())
            #expect(response.status == 200)
            #expect((clock.now - start >= .seconds(29.999)) == held, "\(headers): \(clock.now - start)")
        }
    }

    /// One throttle event halves the rate once (review of PR #37, M1): four reads in flight refused at once halved it four
    /// times, 600 to 37.5, and the run saved that. A 429 after the hold has passed is a new event.
    @Test func fourReadsRefusedAtOnceHalveTheRateOnce() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let start = clock.now
        for _ in 0..<4 { await limiter.throttled(.read, retryAfter: .seconds(30)) }
        #expect(await limiter.readsPerMinute == 300)
        try await limiter.acquire(.read)
        #expect(clock.now - start >= .seconds(29.999) && clock.now - start < .seconds(30.001), "\(clock.now - start)")
        await limiter.throttled(.read)
        #expect(await limiter.readsPerMinute == 150, "after the hold, a new event")
    }

    /// A later 429 inside the hold, with a later `Retry-After`, extends it; one with none (another read's, or a token
    /// exchange's) never shortens it (review L1).
    @Test func aLater429ExtendsTheHoldAndNeverShortensIt() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let start = clock.now
        await limiter.throttled(.read, retryAfter: .seconds(60))
        await limiter.throttled(.read)
        await limiter.throttled(.read, retryAfter: .seconds(5))
        try await limiter.acquire(.read)
        #expect(clock.now - start >= .seconds(59.999), "the 60 s hold was cut to \(clock.now - start)")
        #expect(await limiter.readsPerMinute == 300)
        let later = Clock()
        let extended = RateLimiter(readsPerMinute: 600, now: { later.now }, sleep: { later.advance($0) })
        let from = later.now
        await extended.throttled(.read, retryAfter: .seconds(10))
        later.advance(.seconds(5))
        await extended.throttled(.read, retryAfter: .seconds(20))
        try await extended.acquire(.read)
        #expect(later.now - from >= .seconds(24.999) && later.now - from < .seconds(25.001), "\(later.now - from)")
    }

    /// The token exchange's 429 (`authenticate`, no `Retry-After` read) keeps a pending hold (review L1).
    @Test func aTokenExchange429KeepsTheHold() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let client = HTTPClient(transport: Scripted([(429, [:])]), limiter: limiter, sleep: { _ in })
        let start = clock.now
        await limiter.throttled(.read, retryAfter: .seconds(60))
        let token = AuthRequest(host: .appleAccount, path: "/auth/oauth2/token", contentType: "application/x-www-form-urlencoded", body: Data())
        #expect(try await client.authenticate(token).status == 429)
        try await limiter.acquire(.read)
        #expect(clock.now - start >= .seconds(59.999), "the 60 s hold was cut to \(clock.now - start)")
    }

    /// The limiter caps a hold itself, whoever asks (review L2): a year's `Retry-After` holds a minute.
    @Test func aHoldIsAtMostAMinute() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let start = clock.now
        await limiter.throttled(.read, retryAfter: .seconds(86_400 * 365))
        try await limiter.acquire(.read)
        #expect(clock.now - start <= RateLimiter.longestHold + .milliseconds(1), "held \(clock.now - start)")
        await limiter.throttled(.read, retryAfter: .seconds(-30))
        #expect(await limiter.readsPerMinute == 150, "a negative wait is no wait")
    }

    /// Every `Retry-After` a server could send holds the lane between nothing and a minute (the review's probe).
    @Test func everyRetryAfterHoldIsBounded() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        // `1e400` and `inf` read as infinity, which isn't a delay this reads (as `garbage` isn't): no hold past a token's time.
        let cases: [(String, ClosedRange<Double>)] = [
            ("1e400", 0...1), ("1000000000000000000000", 59.9...60.1), ("-5", 0...1), ("nan", 0...1), ("inf", 0...1),
            ("Fri, 31 Dec 9999 23:59:59 GMT", 59.9...60.1), ("Thu, 01 Jan 1970 00:00:00 GMT", 0...1),
            ("Wed, 15 Sep 2026 20:00:30 GMT", 0...60.1), ("garbage", 0...1), ("0", 0...1),
        ]
        for (value, range) in cases {
            let clock = Clock()
            let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
            let client = HTTPClient(transport: Scripted([(429, ["Retry-After": value])]), limiter: limiter, sleep: { _ in }, clock: { now })
            let start = clock.now
            _ = try await client.read(next: URL(string: "https://api-business.apple.com/v1/orgDevices")!, on: .appleBusiness,
                                      template: "/v1/orgDevices", authorizer: NoAuth())
            let held = clock.now - start
            let seconds = Double(held.components.seconds) + Double(held.components.attoseconds) / 1e18
            #expect(range.contains(seconds), "\(value): \(seconds)")
        }
    }

    /// A read 429's hold is the read lane's: a write waits for nothing it holds.
    @Test func theWriteLaneIsNotHeld() async throws {
        let clock = Clock()
        let limiter = RateLimiter(readsPerMinute: 600, now: { clock.now }, sleep: { clock.advance($0) })
        let start = clock.now
        await limiter.throttled(.read, retryAfter: .seconds(60))
        try await limiter.acquire(.write)
        #expect(clock.now - start == .zero)
    }

    /// A read waiting out a hold leaves at once when cancelled, without a token (a sweep stopped during a 429's wait).
    @Test func aCancelledWaiterLeavesAtOnce() async throws {
        let limiter = RateLimiter(readsPerMinute: 600)
        await limiter.throttled(.read, retryAfter: .seconds(60))
        let waiter = Task { try await limiter.acquire(.read) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        waiter.cancel()
        let result = await waiter.result
        #expect(ContinuousClock.now - start < .seconds(1))
        if case .success = result { Issue.record("a cancelled waiter got a token") }
    }

    /// Answers each request with the next scripted status and headers, then 200 `{}`.
    final class Scripted: Transport, Sendable {
        private let answers: Mutex<[(Int, [String: String])]>
        init(_ answers: [(Int, [String: String])]) { self.answers = Mutex(answers) }

        func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
            let (status, headers) = answers.withLock { $0.isEmpty ? (200, [:]) : $0.removeFirst() }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: headers)!)
        }
    }

    /// A clock only the limiter's sleeps move.
    final class Clock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ by: Duration) { instant.withLock { $0 = $0.advanced(by: by) } }
    }
}
