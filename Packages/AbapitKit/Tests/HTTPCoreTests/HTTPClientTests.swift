import Foundation
@testable import HTTPCore
import Testing
import TestSupport
import Wire

@Suite("HTTP core")
struct HTTPCoreTests {
    struct NoAuth: Authorizer {
        func headers(for host: APIHost) async throws -> [String: String] { [:] }
        func invalidate() async {}
    }

    @Test func aNextLinkOffTheHostIsRefused() async throws {
        let client = HTTPClient(transport: AppleStub(), limiter: RateLimiter(sleep: { _ in }))
        for link in ["https://evil.example.com/v1/orgDevices", "http://api-business.apple.com/v1/orgDevices",
                     "https://api-business.apple.com:8443/v1/orgDevices", "https://user@api-business.apple.com/v1/orgDevices",
                     "https://api-school.apple.com/v1/orgDevices", "https://api-business.apple.com/v2/other"] {
            await #expect(throws: HTTPFailure.self, "\(link)") {
                _ = try await client.read(next: URL(string: link)!, on: .appleBusiness, template: "/v1/orgDevices", authorizer: NoAuth())
            }
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
