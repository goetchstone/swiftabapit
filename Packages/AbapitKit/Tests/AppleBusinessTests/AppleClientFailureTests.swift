import AppleBusiness
import AppleModels
import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Testing
import TestSupport
import Vault
import Wire

/// The failure paths Phase 1a's review found untested (13 of its 14 mutants survived): each test here kills one.
@Suite("Apple client failure paths", .serialized)
struct AppleClientFailureTests {
    /// Review H1: a 22-digit Retry-After trapped in `Duration.seconds` before the 60 s cap.
    @Test func aHugeRetryAfterIsCappedNotACrash() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.queue(429, for: "/v1/orgDevices/TESTD0000000", headers: ["Retry-After": "1000000000000000000000"])
        _ = try await harness.client.device("TESTD0000000")
        #expect(harness.sleeps.all == [.seconds(60)])
    }

    /// Review M1 (mutant M1): the broker refuses to authenticate a request for another host.
    @Test func theBrokerAuthenticatesOnlyItsScopesHost() async throws {
        let harness = try await Harness(devices: 1)
        let broker = TokenBroker(account: .init(org: "acme", scope: .business, clientID: Harness.clientID, keyID: Harness.keyID, teamID: ""),
                                 vault: harness.vault, http: HTTPClient(transport: harness.stub, limiter: RateLimiter(sleep: { _ in })))
        await #expect(throws: AppleAPIError.wrongHost("api-school.apple.com")) { _ = try await broker.headers(for: .appleSchool) }
        await #expect(throws: AppleAPIError.wrongHost("businessapi.mosyle.com")) { _ = try await broker.headers(for: .mosyle) }
        #expect(try await broker.headers(for: .appleBusiness)["Authorization"]?.hasPrefix("Bearer ") == true)
    }

    /// Mutant M2: a token within its last minute is refreshed before use.
    @Test func aTokenIsRefreshedBeforeItEnds() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.tokenLifetime(150)
        _ = try await harness.client.device("TESTD0000000")
        _ = try await harness.client.device("TESTD0000000")
        #expect(harness.stub.mints == 1, "150 s left: no refresh yet")
        let clock = ManualClock()
        let broker = TokenBroker(account: .init(org: "acme", scope: .business, clientID: Harness.clientID, keyID: Harness.keyID, teamID: ""),
                                 vault: harness.vault, http: HTTPClient(transport: harness.stub, limiter: RateLimiter(sleep: { _ in })),
                                 clock: { clock.now })
        _ = try await broker.headers(for: .appleBusiness)
        clock.advance(.seconds(89))
        _ = try await broker.headers(for: .appleBusiness)
        #expect(await broker.mints == 1)
        clock.advance(.seconds(2))
        _ = try await broker.headers(for: .appleBusiness)
        #expect(await broker.mints == 2, "inside the last 60 s of a 150 s token: refreshed")
    }

    /// Mutant M9: a token Apple says lasts seconds is held at least two minutes, not minted per request.
    @Test func aShortExpiresInIsClamped() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.tokenLifetime(5)
        for _ in 0..<3 { _ = try await harness.client.device("TESTD0000000") }
        #expect(harness.stub.mints == 1)
    }

    /// Mutant M3: a revoked account is refused after one fresh token, never in a loop.
    @Test func aRevokedAccountIsUnauthorizedAfterOneRefresh() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.revokeAccount()
        await #expect(throws: AppleAPIError.unauthorized) { _ = try await harness.client.device("TESTD0000000") }
        #expect(harness.stub.mints == 2)
    }

    /// Review M3: a late 401 for the old token must not throw away the new one.
    @Test func aLate401KeepsTheNewToken() async throws {
        let harness = try await Harness(devices: 1)
        let broker = TokenBroker(account: .init(org: "acme", scope: .business, clientID: Harness.clientID, keyID: Harness.keyID, teamID: ""),
                                 vault: harness.vault, http: HTTPClient(transport: harness.stub, limiter: RateLimiter(sleep: { _ in })))
        let old = try await broker.headers(for: .appleBusiness)
        await broker.invalidate(rejected: old)
        let new = try await broker.headers(for: .appleBusiness)
        #expect(new != old)
        await broker.invalidate(rejected: old)
        #expect(try await broker.headers(for: .appleBusiness) == new)
        #expect(await broker.mints == 2)
    }

    /// Mutant M4: a dropped connection is retried, and a dead network gives up after the bound.
    @Test func transportFailuresRetryThenGiveUp() async throws {
        let harness = try await Harness(devices: 1)
        _ = try await harness.client.device("TESTD0000000")
        harness.stub.failTransport(2)
        _ = try await harness.client.device("TESTD0000000")
        harness.stub.failTransport(HTTPClient.attempts)
        await #expect(throws: (any Error).self) { _ = try await harness.client.device("TESTD0000000") }
    }

    /// Mutant M7: a body past the cap is dropped, not read.
    @Test func aBodyPastTheCapIsRefused() async throws {
        let harness = try await Harness(devices: 50, bodyLimit: 2_000)
        await #expect(throws: HTTPFailure.tooLarge(limit: 2_000)) { _ = try await harness.allDevices() }
    }

    /// Mutant M6 and review M5: only a 404 or an explicit null is "unassigned"; other failures and malformed
    /// answers throw (the Guard will re-validate assignments with these reads).
    @Test func onlyA404OrNullIsUnassigned() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.queue(403, for: "/v1/orgDevices/TESTD0000000/relationships/assignedServer")
        await #expect(throws: AppleAPIError.forbidden(code: "QUEUED")) { _ = try await harness.client.assignedServiceID("TESTD0000000") }
        harness.stub.queue(500, for: "/v1/orgDevices/TESTD0000000/assignedServer")
        await #expect(throws: AppleAPIError.server(status: 500)) { _ = try await harness.client.assignedService("TESTD0000000") }
        #expect(try await harness.client.assignedServiceID("TESTD0000000") == nil)
    }

    /// Mutant M13: a probe that fails with anything but 403 says so; it never reads as "ok".
    @Test func aFailingProbeIsNeverOk() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.queue(500, for: "/v1/users")
        harness.stub.queue(404, for: "/v1/apps")
        let results = await harness.client.probeReads()
        #expect(results.first { $0.section == .users }?.status == "error 500")
        #expect(results.first { $0.section == .apps }?.status == "error 404")
    }

    /// Review M6: pages past the first follow Apple's cursor-only next link at the size the first page asked for.
    @Test func laterPagesKeepTheirSize() async throws {
        let harness = try await Harness(devices: 2_100)
        var sizes: [Int] = []
        for try await page in harness.client.devices() { sizes.append(page.items.count) }
        #expect(sizes == [1000, 1000, 100])
        #expect(harness.stub.requests.filter { $0.contains("cursor=") }.allSatisfy { $0.contains("limit=1000") })
        harness.stub.add(services: (0..<1_001).map { Harness.service("SVC\($0)", name: "S\($0)") })
        var services = 0
        for try await page in harness.client.services() { services += page.items.count }
        #expect(services == 1_001)
    }
}

/// The token endpoint's negative paths (mutant M10): the stub refuses every malformed assertion Apple would.
@Suite("AppleStub token endpoint")
struct AppleStubTokenTests {
    static let key = P256.Signing.PrivateKey()

    static func stub() -> AppleStub {
        let stub = AppleStub()
        stub.register(.init(clientID: "BUSINESSAPI.1", keyID: "K1", publicKey: key.publicKey))
        return stub
    }

    static func assertion(header: JSONObject = ["alg": .string("ES256"), "kid": .string("K1"), "typ": .string("JWT")],
                          claims: [String: JSONValue] = [:], der: Bool = false) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        var payload: JSONObject = ["iss": .string("BUSINESSAPI.1"), "sub": .string("BUSINESSAPI.1"),
                                   "aud": .string("https://account.apple.com/auth/oauth2/v2/token"), "iat": .number(String(now)),
                                   "exp": .number(String(now + 600)), "jti": .string(UUID().uuidString)]
        for (key, value) in claims { payload[key] = value }
        let input = Base64URL.encode(Data(JSONValue.dumps(.object(header)).utf8)) + "." + Base64URL.encode(Data(JSONValue.dumps(.object(payload)).utf8))
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + Base64URL.encode(der ? signature.derRepresentation : signature.rawRepresentation)
    }

    static func mint(_ stub: AppleStub, _ assertion: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://account.apple.com/auth/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=client_credentials&client_id=BUSINESSAPI.1&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)&scope=business.api"
        request.httpBody = Data(form.utf8)
        return try await stub.send(request, limit: 1 << 20).1.statusCode
    }

    @Test func aGoodAssertionMints() async throws {
        #expect(try await Self.mint(Self.stub(), Self.assertion()) == 200)
    }

    @Test(arguments: ["der", "v1aud", "kid", "alg", "iss", "exp180", "expired", "future", "nojti"])
    func aMalformedAssertionIsInvalidClient(flaw: String) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let assertion: String = switch flaw {
        case "der": try Self.assertion(der: true)
        case "v1aud": try Self.assertion(claims: ["aud": .string("https://account.apple.com/auth/oauth2/token")])
        case "kid": try Self.assertion(header: ["alg": .string("ES256"), "kid": .string("K2"), "typ": .string("JWT")])
        case "alg": try Self.assertion(header: ["alg": .string("HS256"), "kid": .string("K1"), "typ": .string("JWT")])
        case "iss": try Self.assertion(claims: ["iss": .string("SOMEONE.ELSE")])
        case "exp180": try Self.assertion(claims: ["exp": .number(String(now + 180 * 86_400))])
        case "expired": try Self.assertion(claims: ["exp": .number(String(now - 1))])
        case "future": try Self.assertion(claims: ["iat": .number(String(now + 3600))])
        default: try Self.assertion(claims: ["jti": .string("")])
        }
        #expect(try await Self.mint(Self.stub(), assertion) == 400, "\(flaw)")
    }
}

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ by: Duration) { lock.withLock { instant = instant.advanced(by: by) } }
}
