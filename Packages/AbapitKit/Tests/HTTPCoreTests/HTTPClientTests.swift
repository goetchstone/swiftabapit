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
