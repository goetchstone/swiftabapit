import Foundation
@testable import HTTPCore
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
        let limiter = RateLimiter(readsPerMinute: 60, sleep: { _ in })
        await limiter.throttled(.read)
        #expect(await limiter.readsPerMinute == 30)
        for _ in 0..<20 { await limiter.succeeded(.read) }
        #expect(abs(await limiter.readsPerMinute - 33) < 0.01)
        for _ in 0..<20 { await limiter.throttled(.read) }
        #expect(await limiter.readsPerMinute == RateLimiter.floor)
    }
}
