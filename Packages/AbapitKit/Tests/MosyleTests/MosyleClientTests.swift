import Foundation
import HTTPCore
import JSONAPI
@testable import Mosyle
import MosyleModels
import Synchronization
import Testing
import TestSupport
import Vault
import Wire

/// Mosyle Business through the strict `MosyleStub` (plan §3.5): the login, the envelope inside HTTP 200, paging at
/// Mosyle's 50 whatever is asked (defect 2), the allowlisted columns (defect 1), and every failure the client handles.
@Suite("Mosyle client")
struct MosyleClientTests {
    static let org = "acme-mosyle"
    static let account = MosyleStub.Account(accessToken: "access-token", email: "admin@example.com", password: "pw")

    /// A limiter whose sleeps move its own clock: a no-op sleep on the real clock spins until real time refills it.
    static func limiter() -> RateLimiter {
        let clock = MosyleSessionTests.Clock()
        return RateLimiter(now: { clock.now }, sleep: { clock.advance($0) })
    }

    struct Harness {
        let stub = MosyleStub()
        let vault = Vault(store: MemoryStore())
        let client: MosyleClient

        init(pageCap: Int = MosyleClient.defaultPageCap, account: MosyleStub.Account = MosyleClientTests.account,
             bodyLimit: Int = HTTPClient.bodyLimit) async throws {
            stub.register(account)
            try await vault.replaceSet([.mosyleAccessToken: Secret("access-token"), .mosyleEmail: Secret("admin@example.com"),
                                        .mosylePassword: Secret("pw")], for: MosyleClientTests.org)
            client = MosyleClient(org: MosyleClientTests.org, vault: vault, transport: stub, limiter: MosyleClientTests.limiter(),
                                  pageCap: pageCap, bodyLimit: bodyLimit, sleep: { _ in })
        }

        func devices() async throws -> [MosylePage] {
            var pages: [MosylePage] = []
            for try await page in client.devices() { pages.append(page) }
            return pages
        }
    }

    static func device(_ serial: String, os: String) -> JSONObject {
        ["serial_number": .string(serial), "deviceudid": .string("UDID-\(serial)"), "device_name": .string("Device \(serial)"),
         "os": .string(os), "osversion": .string("27.0"), "date_last_beat": .string("1700000000"),
         "activation_bypass": .string("BYPASS-SECRET"), "activation_bypass_mdm": .string("MDM-SECRET"),
         "activation_bypass_code": .string("CODE-SECRET")]
    }

    static func devices(_ count: Int, os: String) -> [JSONObject] { (0..<count).map { device("\(os.uppercased())\($0)", os: os) } }
    static func users(_ count: Int) -> [JSONObject] { (0..<count).map { ["iduser": .string("U\($0)"), "name": .string("User \($0)")] } }

    @Test func aLoginIsSharedAcrossReads() async throws {
        let harness = try await Harness()
        for _ in 0..<3 { try await harness.client.ping() }
        #expect(harness.stub.logins == 1, "the 1981 Expires header is ignored; the JWT's exp sets its life")
        #expect(harness.stub.requests.first == "POST businessapi.mosyle.com/v1/login")
    }

    @Test func devicesPageAtFiftyOnEveryPlatform() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(120, os: "mac"), os: "mac")
        harness.stub.add(devices: Self.devices(7, os: "ios"), os: "ios")
        harness.stub.add(devices: Self.devices(2, os: "visionos"), os: "visionos")
        let pages = try await harness.devices()
        #expect(pages.flatMap(\.items).count == 129)
        #expect(pages.allSatisfy { !$0.truncated })
        let asked = harness.stub.bodies.compactMap { body -> String? in
            guard let options = body["options"]?.object else { return nil }
            return "\(options["os"]?.string ?? "")#\(options["page"]?.int ?? 0)"
        }
        #expect(asked == ["ios#1", "ios#2", "mac#1", "mac#2", "mac#3", "mac#4", "tvos#1", "visionos#1", "visionos#2"])
    }

    /// Defect 1: the Activation Lock bypass codes are never asked for, and never kept when a tenant sends them anyway.
    @Test func theBypassCodesAreNeitherAskedForNorKept() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.ignoreColumns()
        let items = try await harness.devices().flatMap(\.items)
        #expect(items.count == 3)
        for body in harness.stub.bodies {
            let columns = body["options"]?["specific_columns"]?.array?.compactMap(\.string) ?? []
            #expect(!columns.isEmpty && !columns.contains { $0.hasPrefix("activation_bypass") })
        }
        for item in items {
            #expect(!item.attributes.keys.contains { $0.lowercased().contains("bypass") })
            #expect(Set(item.attributes.keys).isSubset(of: MosyleAdapter.deviceAttributes))
            #expect(!JSONValue.dumps(.object(item.attributes)).contains("SECRET"))
        }
    }

    @Test func aDeviceOnTwoPlatformsIsCountedOnce() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: [Self.device("SAME", os: "ios")], os: "ios")
        harness.stub.add(devices: [Self.device("SAME", os: "mac"), Self.device("OTHER", os: "mac")], os: "mac")
        #expect(try await harness.devices().flatMap(\.items).map(\.id) == ["SAME", "OTHER"])
    }

    /// Defect 3: a status inside an HTTP 200 is an error, not an empty list; an unknown one fails closed. The device
    /// list's `UNKNOWN_COLUMNS` asks again without its columns first (`MosyleFailureTests`); a user list's is the error.
    @Test(arguments: ["MISSING_DATA", "UNKNOWN_COLUMNS", "SOMETHING_NEW"])
    func aStatusInsideA200IsAnError(status: String) async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.add(users: Self.users(3))
        harness.stub.failEnvelope(status, for: "/v1/users")
        await #expect(throws: MosyleAPIError.status(OpenEnum(status), info: "stubbed")) { _ = try await harness.client.users() }
        guard status != "UNKNOWN_COLUMNS" else { return }
        harness.stub.failEnvelope(status, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.status(OpenEnum(status), info: "stubbed")) { _ = try await harness.devices() }
    }

    @Test func aTenantThatIgnoresPagingStopsAtTheRepeat() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(120, os: "mac"), os: "mac")
        harness.stub.add(users: Self.users(70))
        harness.stub.ignorePaging()
        #expect(try await harness.devices().flatMap(\.items).count == 50)
        #expect(harness.stub.bodies.filter { $0["options"]?["os"]?.string == "mac" }.count == 2)
        let users = try await harness.client.users()
        #expect(users.items.count == 50 && !users.truncated)
    }

    /// Invariant 8: a list cut off at the cap says so, and the device stream's last page says so even when a later
    /// platform wasn't cut (Phase 7a review L3: the visionOS page after a cut macOS read as complete).
    @Test func theCapIsShown() async throws {
        let harness = try await Harness(pageCap: 2)
        harness.stub.add(devices: Self.devices(120, os: "mac"), os: "mac")
        harness.stub.add(devices: Self.devices(2, os: "visionos"), os: "visionos")
        harness.stub.add(users: Self.users(120))
        let pages = try await harness.devices()
        #expect(pages.flatMap(\.items).count == 102)
        #expect(pages.last?.items.first?.attributes["productFamily"] == .string("Vision"))
        #expect(pages.last?.truncated == true)
        #expect(pages.first?.truncated == false, "nothing before the cut is marked")
        let users = try await harness.client.users()
        #expect(users.items.count == 100 && users.truncated)
        let whole = try await Harness()
        whole.stub.add(users: Self.users(120))
        let all = try await whole.client.users()
        #expect(all.items.count == 120 && !all.truncated)
    }

    /// Device groups are read per platform: a cut-off iOS list stays marked even when the last platform isn't cut.
    @Test func aCutOffPlatformMarksTheGroups() async throws {
        let harness = try await Harness(pageCap: 1)
        harness.stub.add(deviceGroups: (0..<60).map { ["iddevicegroup": .string("D\($0)"), "name": .string("G\($0)")] }, os: "ios")
        // tvos, read last, has none: its walk isn't cut, and must not clear iOS's mark.
        let groups = try await harness.client.deviceGroups()
        #expect(groups.items.count == 50 && groups.truncated)
    }

    @Test func groupsReadAsAbapitReadThem() async throws {
        let harness = try await Harness()
        harness.stub.add(userGroups: [["idusergroup": .string("G1"), "name": .string("Staff"), "idusers_primary": .array([.string("U1"), .string("U2")])]])
        harness.stub.add(deviceGroups: [["iddevicegroup": .string("D1"), "name": .string("Carts"), "device_numbers": .number("12")]], os: "ios")
        let users = try await harness.client.userGroups()
        #expect(users.items.map(\.id) == ["G1"])
        #expect(users.items.first?.attributes["memberCount"] == .number("2"))
        let devices = try await harness.client.deviceGroups()
        #expect(devices.items.map(\.id) == ["D1"], "device groups answer with an object, not a list")
        #expect(devices.items.first?.attributes["memberCount"] == .number("12"))
    }

    @Test func aLoginThatExpiredEarlyIsRenewedOnce() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.expireLoginsOnce()
        try await harness.client.ping()
        #expect(harness.stub.logins == 2)
    }

    /// An IP-restricted token: a fresh login doesn't help, so the client stops after one and says why.
    @Test func aRevokedTokenIsUnauthorizedAfterOneRelogin() async throws {
        let harness = try await Harness()
        harness.stub.revoke()
        await #expect(throws: MosyleAPIError.unauthorized) { try await harness.client.ping() }
        #expect(harness.stub.logins == 2)
        #expect(MosyleAPIError.unauthorized.message.contains("IP addresses"))
    }

    @Test func wrongCredentialsAreALoginFailure() async throws {
        let harness = try await Harness(account: .init(accessToken: "access-token", email: "admin@example.com", password: "other"))
        await #expect(throws: MosyleAPIError.login(status: 401)) { try await harness.client.ping() }
    }

    @Test func aMissingSecretSaysWhatToDo() async throws {
        let stub = MosyleStub()
        stub.register(Self.account)
        let client = MosyleClient(org: Self.org, vault: Vault(store: MemoryStore()), transport: stub, limiter: MosyleClientTests.limiter())
        await #expect(throws: MosyleAPIError.vault(VaultError.missing(VaultItem(org: Self.org, kind: .mosyleAccessToken)!).guidance)) {
            try await client.ping()
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func transportFailuresRetryThenGiveUp() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.failTransport(2)
        try await harness.client.ping()
        harness.stub.failTransport(HTTPClient.attempts)
        await #expect(throws: MosyleAPIError.self) { try await harness.client.ping() }
    }

    @Test func aRateLimitIsRetriedAndAServerFailureSaysSo() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.queue(429, for: "/v1/devices", headers: ["Retry-After": "1"])
        try await harness.client.ping()
        harness.stub.queue(500, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.server(status: 500)) { try await harness.client.ping() }
    }

    @Test func everyReadIsAPOSTAndAGETIsRefused() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        #expect(harness.stub.requests.allSatisfy { $0.hasPrefix("POST ") })
        var request = URLRequest(url: URL(string: "https://businessapi.mosyle.com/v1/devices")!)
        request.httpMethod = "GET"
        #expect(try await harness.stub.send(request, limit: 1 << 20).1.statusCode == 405)
    }
}

/// The session itself: one login per JWT life, a late 401 never drops a newer login, and its own host only.
@Suite("Mosyle session")
struct MosyleSessionTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ by: Duration) { lock.withLock { instant = instant.advanced(by: by) } }
    }

    static func session(_ stub: MosyleStub, clock: Clock = Clock()) async throws -> MosyleSession {
        stub.register(MosyleClientTests.account)
        let vault = Vault(store: MemoryStore())
        try await vault.replaceSet([.mosyleAccessToken: Secret("access-token"), .mosyleEmail: Secret("admin@example.com"),
                                    .mosylePassword: Secret("pw")], for: MosyleClientTests.org)
        return MosyleSession(org: MosyleClientTests.org, service: .business, vault: vault,
                             http: HTTPClient(transport: stub, limiter: MosyleClientTests.limiter()), clock: { clock.now })
    }

    @Test func theJWTsExpSetsItsLife() async throws {
        let stub = MosyleStub(), clock = Clock()
        stub.jwtLifetime(150)
        let session = try await Self.session(stub, clock: clock)
        _ = try await session.headers(for: .mosyle)
        clock.advance(.seconds(89))
        _ = try await session.headers(for: .mosyle)
        #expect(await session.logins == 1)
        clock.advance(.seconds(2))
        _ = try await session.headers(for: .mosyle)
        #expect(await session.logins == 2, "inside the last 60 s: logged in again")
    }

    /// Review H1's shape, on Mosyle's side: an `exp` far past `Duration`'s range is the fallback, not a trap. One at or
    /// before now is the fallback too, not a zero life (Phase 7a review M2: a login per read).
    static let exps: [(String, Int)] = [("1e300", 82_800), ("1e999", 82_800), ("-1e300", 82_800), ("1", 82_800), ("-1e999", 82_800),
                                        ("NaN", 82_800), ("\"soon\"", 82_800), ("null", 82_800)]

    @Test(arguments: exps)
    func everyExpIsBounded(exp: String, seconds: Int) {
        let payload = Base64URL.encode(Data("{\"exp\": \(exp)}".utf8))
        let life = MosyleSession.lifetime(of: "h.\(payload).s", now: Date())
        #expect(life == .seconds(seconds), "\(exp)")
        #expect(MosyleSession.lifetime(of: "not a jwt", now: Date()) == MosyleSession.fallbackLifetime)
    }

    @Test func aLate401KeepsTheNewLogin() async throws {
        let session = try await Self.session(MosyleStub())
        let old = try await session.headers(for: .mosyle)
        await session.invalidate(rejected: old)
        let new = try await session.headers(for: .mosyle)
        #expect(new != old)
        await session.invalidate(rejected: old)
        #expect(try await session.headers(for: .mosyle) == new)
        #expect(await session.logins == 2)
    }

    @Test func theSessionAuthenticatesOnlyItsHost() async throws {
        let session = try await Self.session(MosyleStub())
        for host in [APIHost.appleBusiness, .appleSchool, .appleAccount, .mosyleLogs] {
            await #expect(throws: MosyleAPIError.wrongHost(host.rawValue)) { _ = try await session.headers(for: host) }
        }
        let headers = try await session.headers(for: .mosyle)
        #expect(headers["accessToken"] == "access-token" && headers["Authorization"]?.hasPrefix("Bearer ") == true)
    }

    /// The JWT from the response's `Authorization` header, bare or `Bearer`, else the body as abapit tolerated.
    @Test func theBearerIsFoundWhereMosyleSendsIt() {
        func response(_ headers: [String: String], _ body: String = "{}") -> HTTPResponse {
            HTTPResponse(status: 200, headers: headers, body: Data(body.utf8))
        }
        #expect(MosyleSession.bearer(response(["authorization": "Bearer abc"])) == "abc")
        #expect(MosyleSession.bearer(response(["authorization": "  bearer   abc "])) == "abc")
        #expect(MosyleSession.bearer(response(["authorization": "abc"])) == "abc")
        #expect(MosyleSession.bearer(response([:], #"{"token": "Bearer xyz"}"#)) == "xyz")
        #expect(MosyleSession.bearer(response(["authorization": "Bearer "])) == nil)
        #expect(MosyleSession.bearer(response(["authorization": "Bearer abc def"])) == nil, "a JWT has no space in it")
        #expect(MosyleSession.bearer(response([:])) == nil)
    }
}
