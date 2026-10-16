import Foundation
import HTTPCore
import JSONAPI
@testable import Mosyle
import MosyleModels
import Testing
import TestSupport
import Vault
import Wire

/// Every failure the Mosyle client handles, each driven through a `MosyleStub` switch (invariant 5; Phase 7a's review
/// found most of them unreached, failure-log 2026-10-16 "the stub could not fail").
@Suite("Mosyle failures")
struct MosyleFailureTests {
    typealias Harness = MosyleClientTests.Harness

    static func devices(_ count: Int, os: String) -> [JSONObject] { MosyleClientTests.devices(count, os: os) }
    static func users(_ count: Int) -> [JSONObject] { MosyleClientTests.users(count) }
    static func groups(_ count: Int, _ prefix: String) -> [JSONObject] {
        (0..<count).map { ["idusergroup": .string("\(prefix)\($0)"), "iddevicegroup": .string("\(prefix)\($0)"), "name": .string("G\($0)")] }
    }

    // MARK: H2, a malformed 200

    /// Phase 7a review H2: each of these read as an empty list with no error, and the ping as "ok".
    static let malformed: [(String, String)] = [
        (#"{"status":"ERROR","message":"Invalid token"}"#, "it has no response (status ERROR)"),
        (#"{"status":"OK","response":"Access denied"}"#, "its response is neither a list nor an object"),
        ("{}", "it has no response"),
        (#"{"response":[{"status":42}]}"#, "its status isn't a string"),
        (#"{"response":[{"status":null}]}"#, "its status isn't a string"),
        (#"{"status":"OK","response":[]}"#, "its response list is empty"),
        (#"{"status":"OK","response":["devices"]}"#, "its first entry isn't an object"),
        (#"{"status":"OK","response":[{"rows":3}]}"#, "it has no status and no devices list"),
        (#"{"status":"OK","response":[{"devices":"none"}]}"#, "it has no status and no devices list"),
        (#"{"status":"OK","response":[{"devices":[1,2]}]}"#, "a row under devices isn't an object"),
    ]

    @Test(arguments: malformed)
    func aMalformed200IsNeverAnEmptyList(body: String, reason: String) async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.queue(200, for: "/v1/devices", body: body)
        await #expect(throws: MosyleAPIError.malformed(reason)) { try await harness.client.ping() }
        harness.stub.queue(200, for: "/v1/devices", body: body)
        await #expect(throws: MosyleAPIError.malformed(reason)) { _ = try await harness.devices() }
        harness.stub.queue(200, for: "/v1/users", body: body.replacingOccurrences(of: "devices", with: "users"))
        await #expect(throws: MosyleAPIError.self) { _ = try await harness.client.users() }
    }

    /// A ping is "ok" for what Mosyle sends: no Macs (`DEVICES_NOTFOUND`), a `devices` list, or the entry's `OK`.
    @Test func aPingAcceptsWhatMosyleSends() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        try await harness.client.ping()
        harness.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"status":"OK"}]}"#)
        try await harness.client.ping()
    }

    /// Past page 1 an entry with no status and no list is the end of the list, not an error: the rows are kept.
    @Test func pastPageOneAnEntryWithNoListIsTheEnd() async throws {
        let harness = try await Harness()
        harness.stub.add(users: Self.users(50))
        harness.stub.queue(200, for: "/v1/users", page: 2, body: #"{"status":"OK","response":[{"rows":50}]}"#)
        #expect(try await harness.client.users().items.count == 50)
    }

    /// The plan reads `response[0]` (abapit too, where both entries hold a list): never a later entry.
    @Test func theFirstEntryIsTheAnswer() async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/devices",
                           body: #"{"status":"OK","response":[{"devices":[{"serial_number":"FIRST"}]},{"devices":[{"serial_number":"SECOND"}]}]}"#)
        #expect(try await harness.devices().flatMap(\.items).map(\.id) == ["FIRST"])
    }

    @Test func anAnswerThatIsntJSONSaysSo() async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/devices", body: "<html>maintenance</html>")
        await #expect(throws: MosyleAPIError.notJSON(bytes: 24)) { try await harness.client.ping() }
    }

    // MARK: M1, each list's own end

    /// Phase 7a review M1: each list ends on its own status and keeps what it read (50 users and then a status lost
    /// all 50). The statuses but `DEVICES_NOTFOUND` and `USERGROUP_NOTFOUND` are guesses, listed to check live.
    static let ends: [(String, String)] = [
        ("/v1/users", "USERS_NOTFOUND"), ("/v1/users", "USER_NOTFOUND"), ("/v1/usergroups", "USERGROUP_NOTFOUND"),
        ("/v1/usergroups", "USERGROUPS_NOTFOUND"), ("/v1/devicegroups", "DEVICEGROUPS_NOTFOUND"), ("/v1/devicegroups", "DEVICEGROUP_NOTFOUND"),
    ]

    @Test(arguments: ends)
    func aListEndsOnItsOwnStatusAndKeepsItsRows(path: String, status: String) async throws {
        for count in [0, 50, 60] {
            let harness = try await Harness()
            harness.stub.endLists(with: status, for: path)
            let read: MosylePage
            switch path {
            case "/v1/users":
                harness.stub.add(users: Self.users(count))
                read = try await harness.client.users()
            case "/v1/usergroups":
                harness.stub.add(userGroups: Self.groups(count, "UG"))
                read = try await harness.client.userGroups()
            default:
                harness.stub.add(deviceGroups: Self.groups(count, "DG"), os: "mac")
                read = try await harness.client.deviceGroups()
            }
            #expect(read.items.count == count && !read.truncated, "\(path) \(status) \(count)")
            #expect(harness.stub.requests.contains { $0.contains(path) })
        }
    }

    /// One list's end is another's error: a status still fails closed unless it is the list's own.
    @Test func anotherListsEndIsAnError() async throws {
        let harness = try await Harness()
        harness.stub.add(users: Self.users(50))
        harness.stub.queue(200, for: "/v1/users", page: 2, body: #"{"status":"OK","response":[{"status":"USERGROUP_NOTFOUND","info":"x"}]}"#)
        await #expect(throws: MosyleAPIError.status(.known(.userGroupNotFound), info: "x")) { _ = try await harness.client.users() }
        harness.stub.failEnvelope("DEVICES_NOTFOUND", for: "/v1/usergroups")
        await #expect(throws: MosyleAPIError.status(.known(.devicesNotFound), info: "stubbed")) { _ = try await harness.client.userGroups() }
        harness.stub.failEnvelope("USERS_NOTFOUND", for: "/v1/devices")
        await #expect(throws: MosyleAPIError.status(.unknown("USERS_NOTFOUND"), info: "stubbed")) { _ = try await harness.devices() }
    }

    // MARK: M3, HTTP failures

    /// A 403 isn't logged in again (plan §3.5 re-logs on 401 only; abapit did on both, review L5), and doesn't claim
    /// a fresh login was tried.
    @Test func a403IsForbiddenWithoutAnotherLogin() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.queue(403, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.forbidden) { try await harness.client.ping() }
        #expect(harness.stub.logins == 1)
        #expect(!MosyleAPIError.forbidden.message.contains("fresh login") && MosyleAPIError.forbidden.message.contains("403"))
    }

    @Test func a405IsInvalidMethod() async throws {
        let harness = try await Harness()
        harness.stub.queue(405, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.invalidMethod) { try await harness.client.ping() }
    }

    /// A 429 is retried up to `HTTPClient.attempts` times; past that the client says it is rate-limited.
    @Test func a429PastTheRetriesIsRateLimited() async throws {
        let harness = try await Harness()
        for _ in 1..<HTTPClient.attempts { harness.stub.queue(429, for: "/v1/devices", headers: ["Retry-After": "1"]) }
        try await harness.client.ping()
        for _ in 0..<HTTPClient.attempts { harness.stub.queue(429, for: "/v1/devices", headers: ["Retry-After": "1"]) }
        await #expect(throws: MosyleAPIError.rateLimited) { try await harness.client.ping() }
    }

    @Test func anyOtherStatusIsUnexpected() async throws {
        let harness = try await Harness()
        harness.stub.queue(418, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.unexpected(status: 418)) { try await harness.client.ping() }
    }

    /// The body cap holds for Mosyle's answers too (`HTTPClient.bodyLimit`; the stub sizes its body as the transport does).
    @Test func anOversizedAnswerIsDropped() async throws {
        let harness = try await Harness(bodyLimit: 4096)
        harness.stub.add(devices: Self.devices(50, os: "mac"), os: "mac")
        await #expect(throws: MosyleAPIError.http(.tooLarge(limit: 4096))) { _ = try await harness.devices() }
    }

    /// A screen that stops reading the device stream stops the walk: with page 2 still out, no page 3 is asked for.
    @Test func stoppingTheStreamStopsTheWalk() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(2000, os: "ios"), os: "ios")
        harness.stub.holdRequests(to: "/v1/devices", fromPage: 2)
        for try await page in harness.client.devices() {
            #expect(!page.items.isEmpty)
            break
        }
        harness.stub.release()
        let pages = { harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count }
        // Uncancelled, the walk runs on through 40 pages and three platforms; nothing signals its end, so wait a little.
        for _ in 0..<30 where pages() <= 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pages() <= 2, "\(pages()) pages asked for; the stream stopped after the first")
    }

    // MARK: M4, the allowlist as sent

    /// A read made anywhere else in the package is checked as it will be sent, and a write never leaves.
    @Test func aForgedReadIsNeverSent() async throws {
        let harness = try await Harness()
        let forged = ReadRequest(host: .mosyle, method: .post, path: "/v1/devices", body: Data(#"{"operation": "wipe_devices"}"#.utf8))
        await #expect(throws: MosyleAPIError.notARead("/v1/devices")) { _ = try await harness.client.envelope(forged) }
        #expect(harness.stub.requests.isEmpty)
    }

    // MARK: H3, the columns

    /// Phase 7a review H3: the stub's columns are its own, so a column Mosyle lacks is refused, not agreed with; and
    /// every column the client asks for is one this Mosyle has (each is still a live check).
    @Test func everyRequestedColumnIsOneMosyleHas() async throws {
        let unknown = Set(MosyleAdapter.deviceColumns).subtracting(MosyleStub.deviceColumns)
        #expect(unknown.isEmpty, "asked for but not a Mosyle column: \(unknown.sorted())")
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(harness.stub.columnRefusals == 0)
        #expect(await harness.client.columnFallback == nil)
    }

    /// A column Mosyle names as unknown is dropped once, loudly, and the list still reads.
    @Test func aColumnMosyleNamesIsDropped() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["currentconsolemanageduser"])
        harness.stub.add(devices: Self.devices(120, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 120)
        #expect(harness.stub.columnRefusals == 1, "refused once, then remembered")
        #expect(await harness.client.columnFallback == .without(["currentconsolemanageduser"]))
        let columns = try #require(harness.stub.bodies.last?["options"]?["specific_columns"]?.array).compactMap(\.string)
        #expect(columns == MosyleAdapter.deviceColumns.filter { $0 != "currentconsolemanageduser" })
    }

    /// Unnamed, the list is asked for whole, and only the adapter's allowlist keeps the bypass codes out (invariant 11).
    @Test func aColumnMosyleDoesntNameDropsTheColumnsAndTheCodesStillStayOut() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["device_type"], named: false)
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        let items = try await harness.devices().flatMap(\.items)
        #expect(items.count == 3)
        #expect(await harness.client.columnFallback == .everyColumn)
        #expect(harness.stub.bodies.last?["options"]?["specific_columns"] == nil)
        for item in items {
            #expect(!JSONValue.dumps(.object(item.attributes)).contains("SECRET"))
            #expect(Set(item.attributes.keys).isSubset(of: MosyleAdapter.deviceAttributes))
        }
    }

    /// The fallback is bounded: a refusal with nothing left to drop is the error, after two requests, not a loop.
    @Test func aRefusalWithNothingLeftToDropIsTheError() async throws {
        let harness = try await Harness()
        for _ in 0..<3 { harness.stub.failEnvelope("UNKNOWN_COLUMNS", for: "/v1/devices") }
        await #expect(throws: MosyleAPIError.status(.known(.unknownColumns), info: "stubbed")) { _ = try await harness.devices() }
        #expect(harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count == 2)
    }

    // MARK: L2, dedupe

    /// Phase 7a review L2: a tenant that serves its pages again past its end gave 6000 users from 60 real ones.
    @Test func aTenantThatWrapsPastItsEndStopsAtTheRepeat() async throws {
        let harness = try await Harness()
        harness.stub.wrapPages()
        harness.stub.add(users: Self.users(60))
        harness.stub.add(userGroups: Self.groups(60, "UG"))
        harness.stub.add(deviceGroups: Self.groups(60, "DG"), os: "ios")
        harness.stub.add(users: [["name": .string("No id")], ["name": .string("No id either")]])
        let users = try await harness.client.users()
        #expect(users.items.count == 62 && !users.truncated, "two rows without an id are two users")
        #expect(try await harness.client.userGroups().items.count == 60)
        #expect(try await harness.client.deviceGroups().items.count == 60)
        #expect(harness.stub.bodies.filter { $0["operation"] == .string("list_users") }.count == 3, "page 3 repeated page 1")
    }

    /// abapit's key, `serial or udid` by truthiness: an empty serial is no key, a number is one, and `12345` isn't
    /// `"12345"` (checked against abapit at the parity pin; review L4).
    @Test func devicesAreDeduplicatedAsAbapitKeyedThem() async throws {
        let harness = try await Harness()
        let rows: [JSONObject] = [
            ["serial_number": .string(""), "deviceudid": .string("U1"), "device_name": .string("A")],
            ["serial_number": .string(""), "deviceudid": .string("U2"), "device_name": .string("B")],
            ["serial_number": .string(""), "deviceudid": .string(""), "device_name": .string("C")],
            ["serial_number": .string(""), "deviceudid": .string(""), "device_name": .string("D")],
            ["serial_number": .number("12345"), "device_name": .string("N1")],
            ["serial_number": .number("12345"), "device_name": .string("N2")],
            ["serial_number": .string("12345"), "device_name": .string("S")],
        ]
        harness.stub.add(devices: rows, os: "mac")
        let names = try await harness.devices().flatMap(\.items).compactMap { $0.attributes["deviceName"]?.string }
        #expect(names == ["A", "B", "C", "D", "N1", "S"])
    }

    /// Device groups are asked for on each platform abapit read: iOS, macOS and tvOS.
    @Test func deviceGroupsAreReadOnEachPlatform() async throws {
        let harness = try await Harness()
        harness.stub.add(deviceGroups: Self.groups(1, "TV"), os: "tvos")
        #expect(try await harness.client.deviceGroups().items.map(\.id) == ["TV0"])
        #expect(harness.stub.bodies.compactMap { $0["options"]?["os"]?.string } == ["ios", "mac", "tvos", "tvos"])
    }
}
