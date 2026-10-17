import Foundation
import HTTPCore
import JSONAPI
@testable import Mosyle
import MosyleModels
import Testing
import TestSupport
import Vault
import Wire

/// The login's failures and its single flight, each through a `MosyleStub` switch (Phase 7a review M2 and M3).
@Suite("Mosyle login")
struct MosyleLoginTests {
    typealias Harness = MosyleClientTests.Harness
    typealias Clock = MosyleSessionTests.Clock

    /// Phase 7a review M2: a JWT good for a day whose `exp` reads as past (a stale claim, or this Mac's clock ahead)
    /// logged in once per read.
    @Test func anExpInThePastIsNotALoginPerRead() async throws {
        let harness = try await Harness()
        harness.stub.jwtLifetime(24 * 3600, exp: .number("1"))
        harness.stub.add(devices: MosyleClientTests.devices(120, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 120)
        for _ in 0..<3 { try await harness.client.ping() }
        #expect(harness.stub.logins == 1)
    }

    /// A 45 s JWT is renewed halfway through its life, not on every read inside a flat 60 s margin.
    @Test func aShortJWTIsRenewedHalfwayNotOnEveryRead() async throws {
        let stub = MosyleStub(), clock = Clock()
        stub.jwtLifetime(45)
        let session = try await MosyleSessionTests.session(stub, clock: clock)
        for _ in 0..<5 { _ = try await session.headers(for: .mosyle) }
        #expect(await session.logins == 1)
        clock.advance(.seconds(21))
        _ = try await session.headers(for: .mosyle)
        #expect(await session.logins == 1)
        clock.advance(.seconds(2))
        _ = try await session.headers(for: .mosyle)
        #expect(await session.logins == 2, "past the halfway mark: renewed")
    }

    /// An `exp` exactly at now is the fallback too, and one a moment later is its own life: the boundary is held.
    @Test func anExpAtNowIsTheFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func jwt(_ exp: Int) -> String { "h.\(Base64URL.encode(Data("{\"exp\": \(exp)}".utf8))).s" }
        #expect(MosyleSession.lifetime(of: jwt(1_800_000_000), now: now) == MosyleSession.fallbackLifetime)
        #expect(MosyleSession.lifetime(of: jwt(1_800_000_100), now: now) == .seconds(100))
    }

    @Test func theMarginIsSixtySecondsOrHalfTheLife() {
        #expect(MosyleSession.margin(for: .seconds(23 * 3600)) == .seconds(60))
        #expect(MosyleSession.margin(for: .seconds(120)) == .seconds(60))
        #expect(MosyleSession.margin(for: .seconds(45)) == .milliseconds(22_500))
        #expect(MosyleSession.margin(for: .zero) == .zero)
    }

    /// A login refused for the credentials says so; a 429, a 5xx or an answer without a token doesn't send the
    /// operator to re-enter them (Phase 7a review M2: a 429 read as "refused the email, password or access token").
    static let failures: [(Int, String?, MosyleAPIError)] = [
        (429, nil, .rateLimited), (500, nil, .server(status: 500)), (503, nil, .server(status: 503)),
        (401, nil, .login(status: 401)), (403, nil, .login(status: 403)), (302, nil, .login(status: 302)),
        (200, "<html>sign in</html>", .noToken), (200, #"{"status":"OK"}"#, .noToken),
    ]

    @Test(arguments: failures)
    func aLoginFailureSaysWhatFailed(status: Int, body: String?, error: MosyleAPIError) async throws {
        let harness = try await Harness()
        harness.stub.queue(status, for: "/v1/login", body: body)
        await #expect(throws: error) { try await harness.client.ping() }
        #expect(await harness.client.logins == 1, "a login is never retried")
        if case .login = error {} else { #expect(!error.message.contains("password")) }
        try await harness.client.ping()
        #expect(harness.stub.logins == 1, "the next read logs in afresh")
    }

    /// Ten reads at once share one login (single flight); ten after an early expiry share one more.
    @Test func concurrentReadsShareOneLogin() async throws {
        let stub = MosyleStub()
        let session = try await MosyleSessionTests.session(stub)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { _ = try await session.headers(for: .mosyle) } }
            try await group.waitForAll()
        }
        #expect(await session.logins == 1 && stub.logins == 1)
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.expireLoginsOnce()
        let client = harness.client
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try await client.ping() } }
            try await group.waitForAll()
        }
        #expect(harness.stub.logins == 2)
    }

    /// The Logs Stream is its own service: its own token, logged in on its own host, used only there.
    @Test func theLogsStreamLogsInOnItsOwnHostWithItsOwnToken() async throws {
        let stub = MosyleStub()
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw", logsToken: "logs-token"))
        let vault = Vault(store: MemoryStore())
        try await vault.replaceSet([.mosyleAccessToken: Secret("access-token"), .mosyleLogsToken: Secret("logs-token"),
                                    .mosyleEmail: Secret("admin@example.com"), .mosylePassword: Secret("pw")], for: MosyleClientTests.org)
        let session = MosyleSession(org: MosyleClientTests.org, service: .logs, vault: vault,
                                    http: HTTPClient(transport: stub, limiter: MosyleClientTests.limiter()))
        let headers = try await session.headers(for: .mosyleLogs)
        #expect(headers["accessToken"] == "logs-token" && headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(stub.requests == ["POST businessapilogs.mosyle.com/v1/login"])
        #expect(stub.logins == 1)
        await #expect(throws: MosyleAPIError.wrongHost(APIHost.mosyle.rawValue)) { _ = try await session.headers(for: .mosyle) }
    }
}
