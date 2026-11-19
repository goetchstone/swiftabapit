import Foundation
import HTTPCore
import JSONAPI
@testable import Mosyle
import MosyleModels
import OSLog
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

    /// Phase 7a review H2, and its verification: each of these read as an empty list with no error, and the ping as
    /// "ok": on page 1, and (from `{"rows":3}` on) beside an `OK` or on any later page, where 50 of 120 users read as
    /// all of them. A list key holding no list (`null`, a string, PHP's object-keyed array) and an end status beside
    /// rows are errors too. Only a code is shown from a top-level `status`, never Mosyle's text.
    static let malformed: [(String, String)] = [
        (#"{"status":"ERROR","message":"Invalid token"}"#, "it has no response (status ERROR)"),
        (#"{"status":"Invalid token for this org","message":"x"}"#, "it has no response"),
        (#"{"status":"OK","response":"Access denied"}"#, "its response is neither a list nor an object"),
        (#"{"status":"OK","response":null}"#, "its response is neither a list nor an object"),
        ("{}", "it has no response"),
        (#"{"response":[{"status":42}]}"#, "its status isn't a string"),
        (#"{"response":[{"status":null}]}"#, "its status isn't a string"),
        (#"{"status":"OK","response":[]}"#, "its response list is empty"),
        (#"{"status":"OK","response":["devices"]}"#, "its first entry isn't an object"),
        (#"{"status":"OK","response":[{"rows":3}]}"#, "it has no devices list and no end-of-list status"),
        (#"{"status":"OK","response":[{"status":"OK"}]}"#, "it has no devices list and no end-of-list status"),
        (#"{"status":"OK","response":{}}"#, "it has no devices list and no end-of-list status"),
        (#"{"status":"OK","response":[{"status":"OK","device_list":[{"serial_number":"X"}]}]}"#, "it has no devices list and no end-of-list status"),
        (#"{"status":"OK","response":[{"devices":"none"}]}"#, "its devices isn't a list"),
        (#"{"status":"OK","response":[{"status":"OK","devices":null}]}"#, "its devices isn't a list"),
        (#"{"status":"OK","response":[{"status":"OK","devices":{"0":{"serial_number":"A"},"1":{"serial_number":"B"}}}]}"#, "its devices isn't a list"),
        (#"{"status":"OK","response":[{"devices":[1,2]}]}"#, "a row under devices isn't an object"),
        (#"{"status":"OK","response":[{"status":"DEVICES_NOTFOUND","devices":[{"serial_number":"X"}]}]}"#,
         "its status DEVICES_NOTFOUND ends the list, yet it holds rows"),
    ]

    @Test(arguments: malformed)
    func aMalformed200IsNeverAnEmptyList(body: String, reason: String) async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.queue(200, for: "/v1/devices", body: body)
        await #expect(throws: MosyleAPIError.malformed(reason)) { try await harness.client.ping() }
        harness.stub.queue(200, for: "/v1/devices", body: body)
        await #expect(throws: MosyleAPIError.malformed(reason)) { _ = try await harness.devices() }
        // The users list's own spelling of each, on page 1 and past 50 good users on page 2.
        func users(_ text: String) -> String { text.replacingOccurrences(of: "devices", with: "users").replacingOccurrences(of: "DEVICES", with: "USERS") }
        harness.stub.add(users: Self.users(120))
        for page in [1, 2] {
            harness.stub.queue(200, for: "/v1/users", page: page, body: users(body))
            await #expect(throws: MosyleAPIError.malformed(users(reason)), "page \(page)") { _ = try await harness.client.users() }
        }
    }

    /// A ping is "ok" for what Mosyle sends: no Macs (`DEVICES_NOTFOUND`, abapit's recorded envelope) or a `devices`
    /// list. An entry's bare `OK` with no list is not one (no source; it is in the malformed list above). The list's
    /// own end status beside an empty list is the end too, on any page: no row is lost by reading it so, and one
    /// beside rows is the error (Phase 7a's verification, round 3: this reading was unpinned).
    @Test func aPingAcceptsWhatMosyleSends() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        try await harness.client.ping()
        let end = #"{"status":"OK","response":[{"status":"DEVICES_NOTFOUND","devices":[]}]}"#
        harness.stub.queue(200, for: "/v1/devices", body: end)
        try await harness.client.ping()
        harness.stub.queue(200, for: "/v1/devices", page: 1, body: end)
        #expect(try await harness.devices().flatMap(\.items).count == 3, "iOS, asked first, ends at once; macOS reads its 3")
        harness.stub.add(users: Self.users(50))
        harness.stub.queue(200, for: "/v1/users", page: 2, body: #"{"status":"OK","response":[{"status":"USERS_NOTFOUND","users":[]}]}"#)
        #expect(try await harness.client.users().items.count == 50)
    }

    /// `OK` is no status only as Mosyle spells it: an `ok` beside a list is a status this app doesn't know, and fails
    /// closed rather than reading the rows, as an end status is compared byte for byte (Phase 7a's verification,
    /// round 3: a case-insensitive `OK` survived).
    @Test(arguments: ["ok", "Ok", "oK"])
    func onlyOKAsMosyleSpellsItIsNoStatus(spelling: String) async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"status":"\#(spelling)","devices":[{"serial_number":"X"}]}]}"#)
        await #expect(throws: MosyleAPIError.status(OpenEnum(spelling), info: nil)) { _ = try await harness.devices() }
    }

    /// A status's `info` is shown only when it is text: anything else could be any size and shape.
    @Test func aStatusesInfoIsTextOrNothing() async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/users", body: #"{"status":"OK","response":[{"status":"MISSING_DATA","info":{"detail":"x"}}]}"#)
        await #expect(throws: MosyleAPIError.status(.known(.missingData), info: nil)) { _ = try await harness.client.users() }
    }

    /// The device stream sends only pages with devices on them: a page that adds nothing new, or an empty list,
    /// ends a platform without a page for it.
    @Test func theStreamSendsNoEmptyPage() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(50, os: "mac"), os: "mac")
        harness.stub.add(devices: Self.devices(60, os: "ios"), os: "ios")
        harness.stub.queue(200, for: "/v1/devices", page: 2, body: #"{"status":"OK","response":[{"devices":[]}]}"#)
        harness.stub.wrapPages()
        let pages = try await harness.devices()
        #expect(pages.map(\.items.count) == [50, 50], "iOS page 1, then an empty list; macOS page 1, then a repeat")
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

    /// Each list's own end-of-list statuses, written out here and not read from `MosyleRead` (a test that took them
    /// from the code would agree with any change to it).
    static let ownEnds: [String: Set<String>] = [
        "/v1/devices": ["DEVICES_NOTFOUND"], "/v1/users": ["USERS_NOTFOUND", "USER_NOTFOUND"],
        "/v1/usergroups": ["USERGROUP_NOTFOUND", "USERGROUPS_NOTFOUND"], "/v1/devicegroups": ["DEVICEGROUPS_NOTFOUND", "DEVICEGROUP_NOTFOUND"],
    ]

    static func read(_ harness: Harness, _ path: String) async throws {
        switch path {
        case "/v1/users": _ = try await harness.client.users()
        case "/v1/usergroups": _ = try await harness.client.userGroups()
        case "/v1/devicegroups": _ = try await harness.client.deviceGroups()
        default: _ = try await harness.devices()
        }
    }

    @Test func eachListsEndsAreTheseExactly() {
        #expect(MosyleRead.endOfList == [
            "/v1/devices#list": Self.ownEnds["/v1/devices"]!, "/v1/users#list_users": Self.ownEnds["/v1/users"]!,
            "/v1/usergroups#list_usergroup": Self.ownEnds["/v1/usergroups"]!, "/v1/devicegroups#list_devicegroup": Self.ownEnds["/v1/devicegroups"]!,
        ])
    }

    /// One list's end is another's error: a status fails closed unless it is the list's own, byte for byte. Every
    /// other list's end, the list's own in lower case, and a write's success status (`COMMAND_SENT`…) are each an
    /// error on every list (Phase 7a's verification: one pair per list, no case and no success status were tried).
    @Test func anotherListsEndIsAnError() async throws {
        let harness = try await Harness()
        harness.stub.add(users: Self.users(50))
        harness.stub.queue(200, for: "/v1/users", page: 2, body: #"{"status":"OK","response":[{"status":"USERGROUP_NOTFOUND","info":"x"}]}"#)
        await #expect(throws: MosyleAPIError.status(.known(.userGroupNotFound), info: "x")) { _ = try await harness.client.users() }
        let every = Set(Self.ownEnds.values.joined())
        let writes = ["COMMAND_SENT", "COMMAND_SENDED", "DEVICE_UPDATED", "DEVICE_ASSIGNED", "NO_DEVICE_UPDATED", "LOSTMODE_NOTENABLED"]
        for (path, own) in Self.ownEnds {
            let others = every.subtracting(own).sorted() + own.map { $0.lowercased() }.sorted() + writes
            for status in others {
                let harness = try await Harness()
                harness.stub.failEnvelope(status, for: path)
                await #expect(throws: MosyleAPIError.status(OpenEnum(status), info: "stubbed"), "\(path) \(status)") { try await Self.read(harness, path) }
            }
        }
    }

    // MARK: M3, HTTP failures

    /// A 403 logs in again once, as abapit did on 401 and 403 (its 7f118fc, from Mosyle's docs): a login Mosyle
    /// expired early reads again, and one refused twice is `.forbidden`, which says a fresh login was tried (review L5
    /// and its verification: not re-logging rested on an argument, against abapit's evidence).
    @Test func a403LogsInAgainOnceThenIsForbidden() async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        harness.stub.queue(403, for: "/v1/devices")
        try await harness.client.ping()
        #expect(harness.stub.logins == 2, "the refused login was dropped, and a fresh one read")
        harness.stub.queue(403, for: "/v1/devices")
        harness.stub.queue(403, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.forbidden) { try await harness.client.ping() }
        #expect(harness.stub.logins == 3, "one fresh login per read, not a loop")
        #expect(MosyleAPIError.forbidden.message.contains("fresh login") && MosyleAPIError.forbidden.message.contains("403"))
    }

    /// One fresh login per read, whichever refusal comes first, as abapit's single `relogged` allowed: a 401 then a
    /// 403, or a 403 then a 401, is the error after one more login, not two or three (Phase 7a's verification, round
    /// 3: HTTPClient's 401 refresh and the client's 403 retry each logged in, up to three times for one read).
    static let refusals: [([Int], MosyleAPIError?)] = [
        ([401], nil), ([403], nil), ([401, 401], .unauthorized), ([403, 403], .forbidden), ([401, 403], .forbidden),
        ([403, 401], .unauthorized), ([401, 403, 403], .forbidden), ([403, 401, 401], .unauthorized),
    ]

    @Test(arguments: refusals)
    func aReadLogsInAgainOnceWhicheverRefusalAsks(statuses: [Int], error: MosyleAPIError?) async throws {
        let harness = try await Harness()
        try await harness.client.ping()
        for status in statuses { harness.stub.queue(status, for: "/v1/devices") }
        if let error {
            await #expect(throws: error, "\(statuses)") { try await harness.client.ping() }
        } else {
            try await harness.client.ping()
        }
        #expect(harness.stub.logins == 2, "\(statuses): one fresh login")
        let asked = harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count
        #expect(asked == 3, "\(statuses): the first ping's page, then this one's twice, never a third time")
    }

    /// A 403 drops the login its read's last attempt carried, not its first: here a 429's wait outlived the first
    /// login, the retry renewed it, and the 403 refused the renewed one, which must be the one dropped (Phase 7a's
    /// verification, round 3: keeping the first attempt's headers survived, and the refused login was used again).
    @Test func a403DropsTheLoginItWasRefusedWith() async throws {
        let stub = MosyleStub(), clock = MosyleSessionTests.Clock()
        let session = try await MosyleSessionTests.session(stub, clock: clock, sleep: { _ in clock.advance(.seconds(24 * 3600)) })
        _ = try await session.read(MosyleSessionTests.read)
        stub.queue(429, for: "/v1/users", headers: ["Retry-After": "1"])
        stub.queue(403, for: "/v1/users")
        #expect(try await session.read(MosyleSessionTests.read).status == 200)
        #expect(stub.logins == 3, "the first; the one renewed after the wait; the fresh one after its 403")
    }

    /// A late 403 for an older JWT keeps the newer login, as a late 401 does: the read held while another logged in
    /// again drops only the login it was refused with.
    @Test func aLate403KeepsTheNewerLogin() async throws {
        let harness = try await Harness()
        harness.stub.add(users: Self.users(3))
        try await harness.client.ping()
        harness.stub.holdRequests(to: "/v1/devices", fromPage: 1)
        let client = harness.client
        let held = Task { try await client.ping() }
        let asked = { harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count }
        for _ in 0..<300 where asked() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        harness.stub.expireLoginsOnce()
        #expect(try await client.users().items.count == 3)
        #expect(harness.stub.logins == 2, "the users read logged in again after its 401")
        harness.stub.queue(403, for: "/v1/devices")
        harness.stub.release()
        try await held.value
        #expect(harness.stub.logins == 2, "the held read's 403 was for the first login: the second is kept")
    }

    /// A 405 is `INVALID_METHOD`, with what Mosyle's answer said (the stub's body: plan §3.5 names the status).
    @Test func a405IsInvalidMethod() async throws {
        let harness = try await Harness()
        harness.stub.queue(405, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.answered(.invalidMethod, said: "INVALID_METHOD: Method not allowed")) { try await harness.client.ping() }
    }

    /// A 429 is retried up to `HTTPClient.attempts` times; past that the client says it is rate-limited.
    @Test func a429PastTheRetriesIsRateLimited() async throws {
        let harness = try await Harness()
        for _ in 1..<HTTPClient.attempts { harness.stub.queue(429, for: "/v1/devices", headers: ["Retry-After": "1"]) }
        try await harness.client.ping()
        for _ in 0..<HTTPClient.attempts { harness.stub.queue(429, for: "/v1/devices", headers: ["Retry-After": "1"]) }
        await #expect(throws: MosyleAPIError.rateLimited) { try await harness.client.ping() }
    }

    /// Any other status is unexpected, a redirect with a well-formed envelope included (the transport refuses to
    /// follow one off the host; the client reads nothing from one).
    @Test func anyOtherStatusIsUnexpected() async throws {
        let harness = try await Harness()
        harness.stub.queue(418, for: "/v1/devices")
        await #expect(throws: MosyleAPIError.unexpected(status: 418)) { try await harness.client.ping() }
        harness.stub.queue(302, for: "/v1/devices", headers: ["Location": "https://businessapi.mosyle.com/v1/devices"],
                           body: #"{"status":"OK","response":[{"status":"DEVICES_NOTFOUND"}]}"#)
        await #expect(throws: MosyleAPIError.unexpected(status: 302)) { try await harness.client.ping() }
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

    /// A read made anywhere else in the package is checked as it will be sent, and a write never leaves. The Logs
    /// Stream's read is for its own session (Phase 7b), never the business one.
    @Test func aForgedReadIsNeverSent() async throws {
        let harness = try await Harness()
        let forged = ReadRequest(host: .mosyle, method: .post, path: "/v1/devices", body: Data(#"{"operation": "wipe_devices"}"#.utf8))
        await #expect(throws: MosyleAPIError.notARead("/v1/devices")) { _ = try await harness.client.envelope(forged) }
        let logs = MosyleRead.logsStream(types: ["dns"], page: 1)
        await #expect(throws: MosyleAPIError.wrongHost(APIHost.mosyleLogs.rawValue)) { _ = try await harness.client.envelope(logs) }
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

    /// The columns Mosyle names as unknown are dropped, loudly, and the list still reads. A name with an underscore is
    /// one name (most columns have one).
    @Test func aColumnMosyleNamesIsDropped() async throws {
        let harness = try await Harness()
        let lacking: Set = ["currentconsolemanageduser", "wifi_mac_address"]
        harness.stub.lackColumns(lacking)
        harness.stub.add(devices: Self.devices(120, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 120)
        #expect(harness.stub.columnRefusals == 1, "refused once, then remembered")
        #expect(await harness.client.columnFallback == .without(MosyleAdapter.deviceColumns.filter(lacking.contains)))
        let columns = try #require(harness.stub.bodies.last?["options"]?["specific_columns"]?.array).compactMap(\.string)
        #expect(columns == MosyleAdapter.deviceColumns.filter { !lacking.contains($0) })
    }

    // MARK: the columns, as seen live (2026-11-19: the list asking 33 columns was answered HTTP 400, its body unseen)

    static let adapter = MosyleAdapter.deviceColumns
    static let six = MosyleClient.undocumentedColumns
    static let documented = adapter.filter { !six.contains($0) }
    /// The adapter's columns that are in `base` or `extra`, in the adapter's order: what the client asks for.
    static func with(_ base: [String], _ extra: String...) -> [String] { adapter.filter { base.contains($0) || extra.contains($0) } }
    /// Each device list request the stub answered itself, by the columns it asked for (nil: every column).
    static func asked(_ stub: MosyleStub) -> [[String]?] {
        stub.bodies.filter { $0["operation"] == .string("list") }.map { $0["options"]?["specific_columns"]?.array?.compactMap(\.string) }
    }
    /// No request names a bypass code; only an every-column walk sends one without `specific_columns` (invariant 11).
    static func noCodeAsked(_ stub: MosyleStub, everyColumn: Bool = false, _ location: SourceLocation = #_sourceLocation) {
        let asked = Self.asked(stub)
        #expect(!asked.isEmpty, sourceLocation: location)
        #expect(!asked.contains { ($0 ?? []).contains { $0.hasPrefix("activation_bypass") } }, "a bypass code was asked for", sourceLocation: location)
        if !everyColumn { #expect(!asked.contains(nil), "every column was asked for", sourceLocation: location) }
    }

    /// The two lists the client keeps apart: the six Mosyle's doc doesn't list are the adapter's, in its order, and the
    /// stub's own list of them (written out there) with the bypass code the doc doesn't list either.
    @Test func theUndocumentedColumnsAreTheAdaptersAndTheStubs() {
        #expect(Self.six == Self.adapter.filter(Self.six.contains) && Self.six.count == 6 && Self.documented.count == 27)
        #expect(MosyleStub.undocumentedColumns == Set(Self.six).union(["activation_bypass_mdm"]))
        #expect(MosyleStub.undocumentedColumns.isSubset(of: MosyleStub.deviceColumns))
        #expect(MosyleClient.columnTries == 7)
    }

    /// Mosyle's refusal reaches the fallback however it comes: inside a 200 or with HTTP 400 (seen live), in the envelope
    /// or bare (the three keys of the example in Mosyle's doc), its names under `unknown_columns` (the 2026-11-19 live
    /// check: the 400 was `.unexpected` and its body thrown away, so the fallback never ran).
    @Test(arguments: [
        (200, #"{"status":"OK","response":[{"unknown_columns":["meid"],"status":"UNKNOWN_COLUMNS","info":"Unknown columns"}]}"#),
        (400, #"{"status":"OK","response":[{"unknown_columns":["meid"],"status":"UNKNOWN_COLUMNS","info":"Unknown columns"}]}"#),
        (400, #"{"unknown_columns":["meid"],"status":"UNKNOWN_COLUMNS","info":"Unknown columns"}"#),
    ])
    func aRefusalReachesTheFallbackAt200Or400(status: Int, body: String) async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.queue(status, for: "/v1/devices", body: body)
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .without(["meid"]))
        #expect(Self.asked(harness.stub).allSatisfy { $0 == Self.adapter.filter { $0 != "meid" } })
        Self.noCodeAsked(harness.stub)
    }

    /// Named, exactly those are dropped, in one more request: the six Mosyle's doc doesn't list, named as its doc shows the
    /// answer (before 2026-11-19 the names were read from `info` only, and this refusal asked for every column).
    @Test func theColumnsMosyleNamesAreDroppedExactly() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(Set(Self.six))
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .without(Self.six))
        #expect(harness.stub.columnRefusals == 1)
        #expect(Array(Self.asked(harness.stub).prefix(2)) == [Self.adapter, Self.documented])
        #expect(Self.asked(harness.stub).dropFirst().allSatisfy { $0 == Self.documented })
        Self.noCodeAsked(harness.stub)
    }

    /// A name inside `info` (no source shows Mosyle writes one there) is dropped as well.
    @Test func aColumnNamedInsideInfoIsDroppedToo() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        harness.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"status":"UNKNOWN_COLUMNS","info":"Unknown columns: imei, meid"}]}"#)
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .without(["imei", "meid"]))
    }

    /// A later refusal naming columns drops those too (the operator, 2026-11-19: only the documented columns refused
    /// unnamed lead to every column).
    @Test func aSecondNamedRefusalDropsThoseToo() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["currentconsolemanageduser"])
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .without(["currentconsolemanageduser"]))
        harness.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"status":"UNKNOWN_COLUMNS","info":"Unknown columns: device_name"}]}"#)
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .without(["device_name", "currentconsolemanageduser"]))
        #expect(Self.asked(harness.stub).last == Self.adapter.filter { $0 != "device_name" && $0 != "currentconsolemanageduser" })
        Self.noCodeAsked(harness.stub)
    }

    /// Unnamed, the list is asked for the 27 columns Mosyle's doc lists; once Mosyle takes them, each of the six is tried
    /// alone beside the ones it took, on that page, and the ones it takes are kept: one request more than the bound's 1 + 6
    /// is the first. Every later page asks for those. The page read is the last answer Mosyle took.
    @Test func anUnnamedRefusalTriesEachUndocumentedColumnAlone() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["imei", "meid"], named: false)
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        let items = try await harness.devices().flatMap(\.items)
        #expect(items.count == 3)
        let (d, kept) = (Self.documented, Self.adapter.filter { $0 != "imei" && $0 != "meid" })
        let tries = [Self.adapter, d, Self.with(d, "enrollment_type"), Self.with(d, "enrollment_type", "currentconsolemanageduser"),
                     Self.with(d, "enrollment_type", "currentconsolemanageduser", "imei"), Self.with(d, "enrollment_type", "currentconsolemanageduser", "meid"),
                     Self.with(d, "enrollment_type", "currentconsolemanageduser", "date_enroll"), kept]
        let asked = Self.asked(harness.stub)
        #expect(Array(asked.prefix(8)) == tries, "\(asked)")
        #expect(asked.count == 12 && asked.dropFirst(8).allSatisfy { $0 == kept }, "mac 1 and 2, tvOS, visionOS: \(asked)")
        #expect(harness.stub.columnRefusals == 3)
        let columns = try #require(await harness.client.columns)
        #expect(columns == MosyleColumns(refused: ["imei", "meid"], taken: kept, untried: []))
        #expect(await harness.client.columnFallback == .without(["imei", "meid"]))
        #expect(items.allSatisfy { $0.attributes["lastCheckIn"] != nil }, "the rows carry the columns kept")
        Self.noCodeAsked(harness.stub)
    }

    /// A list Mosyle refused is never sent again: with the others taken, the last of the six would make the very list it
    /// refused, so that one is refused without a request.
    @Test func theListMosyleRefusedIsntAskedAgain() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["date_checkin"], named: false)
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        let asked = Self.asked(harness.stub), kept = Self.adapter.filter { $0 != "date_checkin" }
        #expect(asked.filter { $0 == Self.adapter }.count == 1)
        #expect(asked.count == 7 + 4 && asked[6] == kept && asked.dropFirst(6).allSatisfy { $0 == kept }, "\(asked)")
        #expect(harness.stub.columnRefusals == 1)
        #expect(await harness.client.columns == MosyleColumns(refused: ["date_checkin"], taken: kept, untried: []))
    }

    /// Mosyle naming every column asked for leaves nothing to ask: every column, never an empty `specific_columns`.
    @Test func aRefusalOfEveryColumnAsksForEveryColumn() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(Set(MosyleAdapter.deviceColumns))
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await harness.devices().flatMap(\.items).count == 3)
        #expect(await harness.client.columnFallback == .everyColumn && harness.stub.columnRefusals == 1)
        #expect(!harness.stub.bodies.contains { $0["options"]?["specific_columns"] == .array([]) })
        Self.noCodeAsked(harness.stub, everyColumn: true)
    }

    /// Two walks refused at once settle on one fallback: the second asks again with what the first chose, rather than
    /// taking its own refusal as a second one.
    @Test func walksRefusedTogetherShareOneFallback() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["currentconsolemanageduser"])
        harness.stub.add(devices: Self.devices(60, os: "ios"), os: "ios")
        harness.stub.holdRequests(to: "/v1/devices", fromPage: 1)
        let client = harness.client
        func count() async throws -> Int {
            var count = 0
            for try await page in client.devices() { count += page.items.count }
            return count
        }
        async let first = count()
        async let second = count()
        let asked = { harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count }
        for _ in 0..<300 where asked() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(asked() == 2, "both walks have their first page out")
        harness.stub.release()
        #expect(try await [first, second] == [60, 60])
        #expect(harness.stub.columnRefusals == 2)
        #expect(await client.columnFallback == .without(["currentconsolemanageduser"]))
    }

    /// Two walks refused unnamed at once try the columns once: the second waits for the first's tries, then reads with
    /// the columns they kept.
    @Test func walksRefusedTogetherTryTheColumnsOnce() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["imei", "meid"], named: false)
        harness.stub.add(devices: Self.devices(60, os: "ios"), os: "ios")
        harness.stub.holdRequests(to: "/v1/devices", fromPage: 1)
        let client = harness.client
        func count() async throws -> Int {
            var count = 0
            for try await page in client.devices() { count += page.items.count }
            return count
        }
        async let first = count()
        async let second = count()
        let out = { harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count }
        for _ in 0..<300 where out() < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(out() == 2, "both walks have their first page out")
        harness.stub.release()
        #expect(try await [first, second] == [60, 60])
        #expect(harness.stub.columnRefusals == 4, "each walk's 33, then imei and meid once")
        let d = Self.documented, asked = Self.asked(harness.stub)
        let tries = [Self.with(d, "enrollment_type"), Self.with(d, "enrollment_type", "currentconsolemanageduser"),
                     Self.with(d, "enrollment_type", "currentconsolemanageduser", "imei"), Self.with(d, "enrollment_type", "currentconsolemanageduser", "meid"),
                     Self.with(d, "enrollment_type", "currentconsolemanageduser", "date_enroll")]
        for tried in tries { #expect(asked.filter { $0 == tried }.count == 1, "tried once: \(asked)") }
        #expect(await client.columnFallback == .without(["imei", "meid"]))
    }

    /// The ping asks as the device list does and falls back as it does: a ping of `serial_number` alone said
    /// `UNKNOWN_COLUMNS` where the list degraded and read.
    @Test func aPingFallsBackAsTheListDoes() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["serial_number"])
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        try await harness.client.ping()
        #expect(await harness.client.columnFallback == .without(["serial_number"]))
    }

    /// Each step is an error-level line naming the columns: the live check reads it, and a debug line is never kept
    /// (Phase 7a's verification: lowering both lines survived). Read back from this process's own log, so each line is
    /// this test's own, whole: columns no other test refuses (round 3: the lines of the tests running beside it passed for
    /// its own, and logging only two or more columns, or only a first refusal, survived).
    @Test func theFallbackIsLoggedAsAnError() async throws {
        let since = Date().addingTimeInterval(-1)
        let harness = try await Harness()
        harness.stub.lackColumns(["bluetooth_mac_address"])
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        _ = try await harness.devices()
        harness.stub.queue(200, for: "/v1/devices",
                           body: #"{"status":"OK","response":[{"status":"UNKNOWN_COLUMNS","info":"Unknown columns: ethernet_mac_address"}]}"#)
        _ = try await harness.devices()
        #expect(await harness.client.columnFallback == .without(["bluetooth_mac_address", "ethernet_mac_address"]))
        let tried = try await Harness()
        tried.stub.lackColumns(["meid", "date_enroll"], named: false)
        _ = try await tried.devices()
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: since),
                                           matching: NSPredicate(format: "subsystem == %@ AND category == %@", "io.github.goetchstone.swiftabapit", "mosyle"))
        let errors = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level == .error }.map(\.composedMessage)
        #expect(errors.contains("Mosyle refused the device columns bluetooth_mac_address (UNKNOWN_COLUMNS): asking without them"), "\(errors)")
        #expect(errors.contains("Mosyle refused the device columns ethernet_mac_address (UNKNOWN_COLUMNS): asking without them"), "\(errors)")
        #expect(errors.contains("Mosyle's device columns tried alone: took enrollment_type, currentconsolemanageduser, imei, date_checkin; "
                                + "refused meid, date_enroll; left untried none"), "\(errors)")
    }

    /// Unnamed when only the documented columns were asked for, the list is asked for whole, and only the adapter's
    /// allowlist keeps the bypass codes out (invariant 11): the 33, the 27, then every column.
    @Test func theDocumentedColumnsRefusedUnnamedAskForEveryColumn() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(["device_type"], named: false)
        harness.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        let items = try await harness.devices().flatMap(\.items)
        #expect(items.count == 3)
        #expect(await harness.client.columnFallback == .everyColumn)
        #expect(await harness.client.columns == MosyleColumns(refused: [], taken: nil, untried: []))
        let asked = Self.asked(harness.stub)
        #expect(Array(asked.prefix(3)) == [Self.adapter, Self.documented, nil] && asked.dropFirst(2).allSatisfy { $0 == nil }, "\(asked)")
        Self.noCodeAsked(harness.stub, everyColumn: true)
        for item in items {
            #expect(!JSONValue.dumps(.object(item.attributes)).contains("SECRET"))
            #expect(Set(item.attributes.keys).isSubset(of: MosyleAdapter.deviceAttributes))
        }
    }

    /// The fallback is bounded: a refusal with nothing left to drop is the error, after three requests (the 33, the 27 and
    /// every column), not a loop. A refusal inside a 200 is read as one at 400.
    @Test func aRefusalWithNothingLeftToDropIsTheError() async throws {
        let harness = try await Harness()
        for _ in 0..<3 { harness.stub.failEnvelope("UNKNOWN_COLUMNS", for: "/v1/devices") }
        await #expect(throws: MosyleAPIError.status(.known(.unknownColumns), info: "stubbed")) { _ = try await harness.devices() }
        #expect(harness.stub.requests.filter { $0.hasSuffix("/v1/devices list") }.count == 3)
        #expect(await harness.client.columnFallback == .everyColumn)
    }

    /// The requests a refusal brings are bounded per client (the operator: 1 + 6): with all six refused unnamed the tries
    /// are spent, and a later refusal is the error with no request more; a session whose tries ran out mid-way leaves the
    /// rest out untried and says so.
    @Test func theTriesAreBoundedPerClient() async throws {
        let harness = try await Harness()
        harness.stub.lackColumns(Set(Self.six), named: false)
        #expect(try await harness.devices().isEmpty)
        let asked = Self.asked(harness.stub)
        let sent: [[String]] = [Self.adapter, Self.documented] + Self.six.map { Self.with(Self.documented, $0) }
        #expect(asked == (sent + Array(repeating: Self.documented, count: 3)).map { Optional($0) },
                "the 33, the 27, each of the six; then macOS, tvOS, visionOS: \(asked)")
        #expect(await harness.client.columns == MosyleColumns(refused: Self.six, taken: Self.documented, untried: []))
        harness.stub.failEnvelope("UNKNOWN_COLUMNS", for: "/v1/devices")
        let before = harness.stub.requests.count
        await #expect(throws: MosyleAPIError.status(.known(.unknownColumns), info: "stubbed")) { _ = try await harness.devices() }
        #expect(harness.stub.requests.count == before + 1, "no request more once the tries are spent")

        // Two named refusals (one inside a 200, one bare at 400) spend two tries; the documented ask a third; four are left.
        let cut = try await Harness()
        cut.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"unknown_columns":["device_name"],"status":"UNKNOWN_COLUMNS","info":"Unknown columns"}]}"#)
        cut.stub.queue(400, for: "/v1/devices", body: #"{"unknown_columns":["model_name"],"status":"UNKNOWN_COLUMNS","info":"Unknown columns"}"#)
        cut.stub.lackColumns(["imei"], named: false)
        cut.stub.add(devices: Self.devices(3, os: "mac"), os: "mac")
        #expect(try await cut.devices().flatMap(\.items).count == 3)
        let d = Self.documented.filter { $0 != "device_name" && $0 != "model_name" }
        let kept = Self.with(d, "enrollment_type", "currentconsolemanageduser", "meid")
        let columns = try #require(await cut.client.columns)
        #expect(columns == MosyleColumns(refused: ["device_name", "model_name", "imei"], taken: kept, untried: ["date_enroll", "date_checkin"]))
        #expect(columns.words == "Mosyle refused the device columns device_name, model_name and imei, so they were left out of the request. "
                + "It took 28, among them enrollment_type, currentconsolemanageduser and meid, which Mosyle's doc doesn't list. "
                + "Left out untried, as this session's tries were spent: date_enroll and date_checkin.")
        #expect(await cut.client.columnFallback == .without(["device_name", "model_name", "imei", "date_enroll", "date_checkin"]))
        Self.noCodeAsked(cut.stub)
    }

    /// What a screen says of the columns (Settings' Test, the devices' note, beside a failed read): which Mosyle refused,
    /// which it took (the six in doubt by name), which were left out untried, or that every column was asked for.
    @Test func theColumnsAreSaidInWords() {
        let kept = Self.adapter.filter { $0 != "imei" }
        #expect(MosyleColumns(refused: ["imei"], taken: kept, untried: []).words
                == "Mosyle refused the device column imei, so it was left out of the request. It took the other 32, among them "
                + "enrollment_type, currentconsolemanageduser, meid, date_enroll and date_checkin, which Mosyle's doc doesn't list.")
        #expect(MosyleColumns(refused: Self.six, taken: Self.documented, untried: []).words
                == "Mosyle refused the device columns enrollment_type, currentconsolemanageduser, imei, meid, date_enroll and date_checkin, "
                + "so they were left out of the request. It took the other 27.")
        #expect(MosyleColumns(refused: [], taken: nil, untried: []).words
                == "Mosyle refused the requested device columns, so every column was asked for; only the fields this app keeps are shown.")
        #expect(MosyleColumns(refused: ["imei"], taken: nil, untried: []).words
                == "Mosyle refused the requested device columns (by name: imei), so every column was asked for; only the fields this app keeps are shown.")
        #expect(MosyleColumns.allTaken == "Mosyle took all 33 device columns asked for.")
    }

    // MARK: Mosyle's own words in an answer that isn't a 2xx

    /// A read's 4xx or 5xx says Mosyle's own `status` and `info` (the 2026-11-19 live check showed only "400"): the entry's,
    /// else the top level's, never another field; control and format characters out, trimmed, cut at 64 and 200.
    @Test func aRefusedReadSaysMosylesOwnWords() async throws {
        let harness = try await Harness()
        let junk = [0x0A, 0x202E, 0x200B, 0x07].map { String(Character(UnicodeScalar($0)!)) }.joined()
        func entry(_ fields: JSONObject) -> String { JSONValue.dumps(.object(["status": .string("OK"), "response": .array([.object(fields)])])) }
        harness.stub.queue(400, for: "/v1/devices", body: entry(["status": .string(" BAD\(junk)_PAGE "),
                                                                 "info": .string("Page \(junk)size " + String(repeating: "x", count: 300))]))
        let said = "BAD_PAGE: Page size " + String(repeating: "x", count: 190) + "\u{2026}"
        await #expect(throws: MosyleAPIError.answered(.unexpected(status: 400), said: said)) { try await harness.client.ping() }
        #expect(MosyleAPIError.answered(.unexpected(status: 400), said: said).message
                == "Mosyle answered HTTP 400, which this app doesn't expect. Mosyle said: " + said)
        // At the top level, and after the session's one fresh login for a 403; Mosyle's `message` is never said.
        let top = #"{"status":"ERROR","message":"MESSAGE-CANARY","info":"Not allowed"}"#
        for _ in 0..<2 { harness.stub.queue(403, for: "/v1/devices", body: top) }
        await #expect(throws: MosyleAPIError.answered(.forbidden, said: "ERROR: Not allowed")) { try await harness.client.ping() }
        harness.stub.queue(500, for: "/v1/devices", body: entry(["status": .string("SERVER_DOWN")]))
        await #expect(throws: MosyleAPIError.answered(.server(status: 500), said: "SERVER_DOWN")) { try await harness.client.ping() }
        // Nothing of Mosyle's own: the error as it was.
        harness.stub.queue(400, for: "/v1/devices", body: #"{"error":"x","status":"OK"}"#)
        await #expect(throws: MosyleAPIError.unexpected(status: 400)) { try await harness.client.ping() }
        // Inside a 200, a status of the list's own is said cleaned too.
        harness.stub.queue(200, for: "/v1/devices", body: entry(["status": .string("NEW\(junk)_CODE"), "info": .string("x\(junk)y")]))
        do {
            try await harness.client.ping()
            Issue.record("a new status read as a list")
        } catch let error as MosyleAPIError {
            #expect(error.message == "Mosyle answered NEW_CODE: xy")
        }
    }

    /// A 400's body is never logged as public past Mosyle's status code: its `info` is Mosyle's own text.
    @Test func aRefusedReadsInfoIsNeverLogged() async throws {
        let since = Date().addingTimeInterval(-1)
        let harness = try await Harness()
        harness.stub.queue(400, for: "/v1/devices", body: #"{"status":"OK","response":[{"status":"LOGCHECK_7Q","info":"INFO-CANARY-7Q"}]}"#)
        await #expect(throws: MosyleAPIError.answered(.unexpected(status: 400), said: "LOGCHECK_7Q: INFO-CANARY-7Q")) { try await harness.client.ping() }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let logged = try store.getEntries(at: store.position(date: since)).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
        #expect(logged.contains("Mosyle answered HTTP 400 to /v1/devices list, its status LOGCHECK_7Q"), "\(logged.filter { $0.contains("Mosyle") })")
        #expect(!logged.contains { $0.contains("INFO-CANARY-7Q") })
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

    /// abapit's key, `serial or udid` by truthiness and compared as Python's set compares: an empty serial or a zero
    /// is no key, a number is one, `12345` isn't `"12345"`, and `1000`, `1e3` and `1000.0` are one key, as are `true`
    /// and `1` (checked against abapit at the parity pin with its own `devices()`; review L4 and its verification).
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
            ["serial_number": .number("0"), "deviceudid": .string("U3"), "device_name": .string("Z1")],
            ["serial_number": .number("0.0"), "deviceudid": .string("U4"), "device_name": .string("Z2")],
            ["serial_number": .bool(false), "deviceudid": .string("U4"), "device_name": .string("Z3")],
            ["serial_number": .number("0"), "deviceudid": .string("U6"), "device_name": .string("Z4")],
            ["serial_number": .number("1000"), "device_name": .string("T1")],
            ["serial_number": .number("1e3"), "device_name": .string("T2")],
            ["serial_number": .number("1000.0"), "device_name": .string("T3")],
            ["serial_number": .bool(true), "deviceudid": .string("U5"), "device_name": .string("B1")],
            ["serial_number": .number("1"), "device_name": .string("B2")],
            ["serial_number": .number("1.5"), "device_name": .string("F1")],
            ["serial_number": .number("15e-1"), "device_name": .string("F2")],
            ["serial_number": .number("2.5"), "device_name": .string("F3")],
            // Past `Int`'s range and the same `Double`: two integers Python keeps apart, and one repeated (round 3:
            // keyed through `Double`, the two merged and a device went, silently).
            ["serial_number": .number("100000000000000000000"), "device_name": .string("L1")],
            ["serial_number": .number("100000000000000000001"), "device_name": .string("L2")],
            ["serial_number": .number("100000000000000000000"), "device_name": .string("L3")],
        ]
        harness.stub.add(devices: rows, os: "mac")
        let names = try await harness.devices().flatMap(\.items).compactMap { $0.attributes["deviceName"]?.string }
        #expect(names == ["A", "B", "C", "D", "N1", "S", "Z1", "Z2", "Z4", "T1", "B1", "F1", "F3", "L1", "L2"])
    }

    /// A cap page that adds nothing new is the end, not a cut: a list that wraps on the cap's page isn't marked.
    @Test func aCapPageWithNothingNewIsNotACut() async throws {
        let harness = try await Harness(pageCap: 2)
        harness.stub.wrapPages()
        harness.stub.add(users: Self.users(50))
        harness.stub.add(devices: Self.devices(50, os: "mac"), os: "mac")
        let users = try await harness.client.users()
        #expect(users.items.count == 50 && !users.truncated)
        let pages = try await harness.devices()
        #expect(pages.flatMap(\.items).count == 50 && pages.allSatisfy { !$0.truncated })
    }

    /// Device groups are read from the first key that holds a list, in abapit's order (`_extract`): `devicegroups`,
    /// `groups`, `device_groups`; a key holding something else is passed over when a later one holds the list.
    @Test func deviceGroupsAreReadFromAbapitsFirstKey() async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/devicegroups", page: 1, body: #"{"status":"OK","response":{"groups":[{"iddevicegroup":"SECOND"}],"devicegroups":[{"iddevicegroup":"FIRST"}],"device_groups":[{"iddevicegroup":"THIRD"}]}}"#)
        #expect(try await harness.client.deviceGroups().items.map(\.id) == ["FIRST"])
        harness.stub.queue(200, for: "/v1/devicegroups", page: 1, body: #"{"status":"OK","response":{"devicegroups":null,"groups":[{"iddevicegroup":"G"}]}}"#)
        #expect(try await harness.client.deviceGroups().items.map(\.id) == ["G"])
    }

    /// Device groups are asked for on each platform abapit read: iOS, macOS and tvOS.
    @Test func deviceGroupsAreReadOnEachPlatform() async throws {
        let harness = try await Harness()
        harness.stub.add(deviceGroups: Self.groups(1, "TV"), os: "tvos")
        #expect(try await harness.client.deviceGroups().items.map(\.id) == ["TV0"])
        #expect(harness.stub.bodies.compactMap { $0["options"]?["os"]?.string } == ["ios", "mac", "tvos", "tvos"])
    }
}
