#if DEBUG
import Foundation
import HTTPCore
import JSONAPI
import MosyleModels
import Synchronization
import Vault
import Wire

/// A strict stand-in for Mosyle Business and its login (plan §3.5, invariant 5). An unhandled request throws
/// `StubFailure.unhandled`. Each behaviour is written from plan §3.5 or from what abapit's `mosyle.py` (at the
/// parity pin) saw live; where neither says, the choice is listed in docs/domains/mosyle.md as an assumption to
/// check live.
///
/// - Every request is a POST (anything else is 405 `INVALID_METHOD`) with a JSON body.
/// - `/v1/login` takes the `accessToken` header and `{email, password}`; the JWT comes back in the response's
///   `Authorization` header, with PHP's fixed `Expires: Thu, 19 Nov 1981 08:52:00 GMT` beside it. The Logs Stream
///   host logs in the same way with its own token, and each host takes only its own JWTs.
/// - Every other request needs both `accessToken` and `Authorization: Bearer <jwt>` of a live login on its host, else
///   401 `{"error": …}`. A Logs Stream read that has both is unhandled: the read itself arrives with LogsDrain (7b).
/// - Lists page at **50 rows whatever `page_size` asks** (abapit recorded `"page_size":50`; it asked for 500 and
///   stopped after the first short page: defect 2). Devices need `os` (else `MISSING_DATA`), refuse a column not in
///   `deviceColumns` (`UNKNOWN_COLUMNS`), answer `DEVICES_NOTFOUND` past the end, and return only `specific_columns`
///   when given. Device groups answer with an object, not a list.
/// - The top-level `"status": "OK"` is sent on errors too, as Mosyle does.
public final class MosyleStub: Transport, Sendable {
    public struct Account: Sendable {
        public let accessToken: String
        public let email: String
        public let password: String
        /// The Logs Stream's own access token (a second service, its own login: abapit's `_logs_login`).
        public let logsToken: String?

        public init(accessToken: String, email: String, password: String, logsToken: String? = nil) {
            self.accessToken = accessToken
            self.email = email
            self.password = password
            self.logsToken = logsToken
        }
    }

    public enum StubFailure: Error, Equatable, Sendable {
        case unhandled(String)
    }

    /// Mosyle's page size, whatever the request asks.
    public static let serverPageSize = 50
    /// The device columns this Mosyle has, written out here and not taken from the adapter, so that a column the
    /// client asks for and Mosyle lacks is refused rather than agreed with (Phase 7a review H3: the stub's columns
    /// were the adapter's, so `UNKNOWN_COLUMNS` could never fire). The names: the device-list fields abapit's
    /// `mosyle.py` read at the parity pin (`_FIELD_MAP`, `_DATE_MAP`, `os` and `device_type` for the family), the
    /// Activation Lock bypass codes (plan §2.3 defect 1), and the lost-mode location (plan §2.2). abapit read these
    /// from responses and never sent `specific_columns`, so none is confirmed as a request column: that is a named
    /// Phase 7 live check (docs/domains/mosyle.md).
    public static let deviceColumns: Set<String> = [
        "serial_number", "deviceudid", "device_name", "device_model", "device_model_name", "model_name", "osversion", "status",
        "enrollment_type", "ManagementStatus", "userid", "useremail", "username", "CurrentConsoleManagedUser",
        "currentconsolemanageduser", "battery", "total_disk", "available_disk", "is_supervised", "lostmode_status", "asset_tag",
        "imei", "meid", "wifi_mac_address", "bluetooth_mac_address", "ethernet_mac_address",
        "date_last_beat", "date_last_push", "date_enroll", "date_checkin", "date_app_info",
        "os", "device_type",
        "activation_bypass", "activation_bypass_mdm",
        "latitude", "longitude",
    ]

    private struct Queued {
        let path: String
        let host: APIHost?
        let page: Int?
        let status: Int
        let headers: [String: String]
        let body: String?
    }

    private struct State {
        var account: Account?
        var jwts: [String: (expires: Date, host: APIHost)] = [:]
        var devices: [String: [JSONObject]] = [:]
        var users: [JSONObject] = []
        var userGroups: [JSONObject] = []
        var deviceGroups: [String: [JSONObject]] = [:]
        var queued: [Queued] = []
        var envelopeFailures: [(path: String, status: String)] = []
        var endOfList: [String: String] = [:]
        var lacking: Set<String> = []
        var namesLacking = true
        var columnRefusals = 0
        var requests: [String] = []
        var bodies: [JSONObject] = []
        var logins = 0
        var jwtLifetime: TimeInterval = 24 * 3600
        var jwtExpClaim: JSONValue?
        var revoked = false
        var expireOnce = false
        var transportFailures = 0
        var ignoresPage = false
        var wrapsPages = false
        var ignoresColumns = false
        var hold: (path: String, fromPage: Int)?
        var released = false
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var waiters = 0
        var woken: Set<Int> = []
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: arranging

    public func register(_ account: Account) { state.withLock { $0.account = account } }
    /// Raw device records for one platform, as Mosyle keeps them (every column).
    public func add(devices: [JSONObject], os: String) { state.withLock { $0.devices[os, default: []] += devices } }
    public func add(users: [JSONObject]) { state.withLock { $0.users += users } }
    public func add(userGroups: [JSONObject]) { state.withLock { $0.userGroups += userGroups } }
    public func add(deviceGroups: [JSONObject], os: String) { state.withLock { $0.deviceGroups[os, default: []] += deviceGroups } }
    /// The next request to `path` (on `host`, for page `page`, when given) answers `status`, with `body` (by default
    /// what Mosyle sends for that status: `INVALID_METHOD` for 405, `{"error": …}` otherwise) and `headers`. It
    /// answers before any credential check, the login included: a 429 with `Retry-After`, a 500, a 403, a login
    /// without a token, or a malformed 200 (`{}`, a string `response`, HTML).
    public func queue(_ status: Int, for path: String, host: APIHost? = nil, page: Int? = nil, headers: [String: String] = [:],
                      body: String? = nil) {
        state.withLock { $0.queued.append(Queued(path: path, host: host, page: page, status: status, headers: headers, body: body)) }
    }
    /// The next request to `path` answers HTTP 200 with this status in its entry (`UNKNOWN_COLUMNS`, a new code).
    public func failEnvelope(_ status: String, for path: String) { state.withLock { $0.envelopeFailures.append((path, status)) } }
    /// Past its last row, the list at `path` answers this status instead of an empty list (`USERGROUP_NOTFOUND`, …).
    /// Which one each list sends is unconfirmed (docs/domains/mosyle.md); the device list always answers
    /// `DEVICES_NOTFOUND` (abapit's recorded envelope).
    public func endLists(with status: String, for path: String) { state.withLock { $0.endOfList[path] = status } }
    /// This Mosyle lacks these device columns: asking for one is `UNKNOWN_COLUMNS`, its `info` naming them or not.
    public func lackColumns(_ names: Set<String>, named: Bool = true) {
        state.withLock {
            $0.lacking = names
            $0.namesLacking = named
        }
    }
    /// Every request but the login answers 401, as a token restricted to other IP addresses: logging in again doesn't help.
    public func revoke() { state.withLock { $0.revoked = true } }
    /// Every JWT issued so far is refused once: a login that expired early.
    public func expireLoginsOnce() { state.withLock { $0.expireOnce = true } }
    /// The next `count` requests fail before reaching "Mosyle".
    public func failTransport(_ count: Int) { state.withLock { $0.transportFailures = count } }
    /// JWTs from now on live this long, and carry this `exp` claim (nil: none; the default is the real expiry).
    public func jwtLifetime(_ seconds: TimeInterval, exp: JSONValue? = nil) {
        state.withLock {
            $0.jwtLifetime = seconds
            $0.jwtExpClaim = exp
        }
    }
    /// A tenant that answers every page with the first page's rows.
    public func ignorePaging() { state.withLock { $0.ignoresPage = true } }
    /// A tenant that serves its pages again past its end: with 60 rows, page 3 is page 1 (Phase 7a review L2).
    public func wrapPages() { state.withLock { $0.wrapsPages = true } }
    /// A tenant that sends every column, `specific_columns` or not.
    public func ignoreColumns() { state.withLock { $0.ignoresColumns = true } }
    /// A slow tenant: requests to `path` for page `fromPage` on wait until `release()` (or 5 s, so a walk that never
    /// lets the test release fails the test instead of hanging the suite). A test can stop a walk with a page still
    /// out and see that no other page is asked for.
    public func holdRequests(to path: String, fromPage: Int) { state.withLock { $0.hold = (path, fromPage) } }
    public func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [:] }
            return state.waiting
        }
        for continuation in waiting.values { continuation.resume() }
    }

    private func wake(_ waiter: Int) {
        let continuation = state.withLock { state in
            state.woken.insert(waiter)
            return state.waiting.removeValue(forKey: waiter)
        }
        continuation?.resume()
    }

    /// Every request, as `METHOD host/path operation`.
    public var requests: [String] { state.withLock { $0.requests } }
    /// Every list request's body, for asserting on `specific_columns` and paging.
    public var bodies: [JSONObject] { state.withLock { $0.bodies } }
    public var logins: Int { state.withLock { $0.logins } }
    /// How many device lists were refused `UNKNOWN_COLUMNS`.
    public var columnRefusals: Int { state.withLock { $0.columnRefusals } }

    // MARK: Transport

    public func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = APIHost(of: url), host == .mosyle || host == .mosyleLogs else {
            throw StubFailure.unhandled(request.url?.absoluteString ?? "?")
        }
        let offline = state.withLock { state -> Bool in
            guard state.transportFailures > 0 else { return false }
            state.transportFailures -= 1
            return true
        }
        if offline { throw URLError(.networkConnectionLost) }
        let method = request.httpMethod ?? "GET"
        let path = url.path(percentEncoded: false)
        let object = request.httpBody.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self))?.object }
        let operation = object?["operation"]?.string ?? ""
        let waiter = state.withLock { state -> Int? in
            state.requests.append("\(method) \(host.rawValue)\(path) \(operation)".trimmingCharacters(in: .whitespaces))
            guard let hold = state.hold, hold.path == path, !state.released, (object?["options"]?["page"]?.int ?? 1) >= hold.fromPage else {
                return nil
            }
            defer { state.waiters += 1 }
            return state.waiters
        }
        if let waiter {
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.wake(waiter)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = state.withLock { state -> Bool in
                    if state.released || state.woken.contains(waiter) { return true }
                    state.waiting[waiter] = continuation
                    return false
                }
                if go { continuation.resume() }
            }
            deadline.cancel()
        }
        guard url.query == nil else { throw StubFailure.unhandled("a query string on \(path): Mosyle reads take a body") }

        let (status, headers, body): (Int, [String: String], Data)
        if let queued = dequeue(path: path, host: host, page: object?["options"]?["page"]?.int ?? 1) {
            (status, headers, body) = queued
        } else if method != "POST" {
            (status, headers, body) = (405, [:], Self.invalidMethod)
        } else if let object {
            if path == "/v1/login" {
                (status, headers, body) = login(request, object, host: host)
            } else if host == .mosyle {
                (status, headers, body) = try business(request, path: path, object)
            } else if state.withLock({ refuses(request, on: host, $0) }) {
                (status, headers, body) = (401, [:], Self.json(["error": .string("Unauthorized")]))
            } else {
                throw StubFailure.unhandled("\(host.rawValue)\(path): the Logs Stream arrives with LogsDrain")
            }
        } else {
            throw StubFailure.unhandled("\(path): a body that isn't a JSON object")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
        if body.count > limit { throw HTTPFailure.tooLarge(limit: limit) }
        return (body, response)
    }

    private func dequeue(path: String, host: APIHost, page: Int) -> (Int, [String: String], Data)? {
        state.withLock { state in
            guard let index = state.queued.firstIndex(where: { $0.path == path && ($0.host ?? host) == host && ($0.page ?? page) == page }) else {
                return nil
            }
            let queued = state.queued.remove(at: index)
            let body = queued.body.map { Data($0.utf8) }
                ?? (queued.status == 405 ? Self.invalidMethod : Self.json(["error": .string("queued \(queued.status)")]))
            return (queued.status, queued.headers, body)
        }
    }

    static let invalidMethod = json(["status": .string("INVALID_METHOD"), "info": .string("Method not allowed")])

    // MARK: login

    private func login(_ request: URLRequest, _ object: JSONObject, host: APIHost) -> (Int, [String: String], Data) {
        state.withLock { state in
            let token = host == .mosyle ? state.account?.accessToken : state.account?.logsToken
            guard let account = state.account, let token, request.value(forHTTPHeaderField: "accessToken") == token,
                  object["email"]?.string == account.email, object["password"]?.string == account.password else {
                return (401, [:], Self.json(["error": .string("Invalid credentials")]))
            }
            state.logins += 1
            let expires = now().addingTimeInterval(state.jwtLifetime)
            let exp = state.jwtExpClaim ?? .number(String(Int(expires.timeIntervalSince1970)))
            let payload = Self.json(["exp": exp, "jti": .string(UUID().uuidString)])
            let jwt = "eyJhbGciOiJIUzI1NiJ9." + Base64URL.encode(payload) + ".c2ln"
            state.jwts[jwt] = (expires, host)
            return (200, ["Authorization": "Bearer \(jwt)", "Expires": "Thu, 19 Nov 1981 08:52:00 GMT",
                          "Set-Cookie": "PHPSESSID=stub; path=/"],
                    Self.json(["status": .string("OK")]))
        }
    }

    // MARK: Mosyle Business

    /// Whether `request` lacks `host`'s access token or a live JWT this stub issued for `host` (or the token is revoked).
    private func refuses(_ request: URLRequest, on host: APIHost, _ state: State) -> Bool {
        let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let jwt = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : ""
        let token = host == .mosyle ? state.account?.accessToken : state.account?.logsToken
        guard !state.revoked, let token, request.value(forHTTPHeaderField: "accessToken") == token,
              let issued = state.jwts[jwt], issued.host == host, issued.expires > now() else { return true }
        return false
    }

    private func business(_ request: URLRequest, path: String, _ object: JSONObject) throws -> (Int, [String: String], Data) {
        let refusal: (Int, [String: String], Data)? = state.withLock { state in
            if refuses(request, on: .mosyle, state) { return (401, [:], Self.json(["error": .string("Unauthorized")])) }
            if state.expireOnce {
                state.expireOnce = false
                state.jwts = [:]
                return (401, [:], Self.json(["error": .string("Unauthorized")]))
            }
            if let index = state.envelopeFailures.firstIndex(where: { $0.path == path }) {
                let failure = state.envelopeFailures.remove(at: index)
                return (200, [:], Self.entry(["status": .string(failure.status), "info": .string("stubbed")]))
            }
            state.bodies.append(object)
            return nil
        }
        if let refusal { return refusal }
        let options = object["options"]?.object ?? [:]
        switch (path, object["operation"]?.string) {
        case ("/v1/devices", "list"): return devices(options)
        case ("/v1/users", "list_users"): return list(state.withLock { $0.users }, key: "users", path: path, options)
        case ("/v1/usergroups", "list_usergroup"): return list(state.withLock { $0.userGroups }, key: "usergroups", path: path, options)
        case ("/v1/devicegroups", "list_devicegroup"):
            guard let os = options["os"]?.string, !os.isEmpty else { return (200, [:], Self.entry(Self.missing("os"))) }
            let (groups, end) = state.withLock { ($0.deviceGroups[os] ?? [], $0.endOfList[path]) }
            let (rows, _) = page(groups, options)
            // Device groups answer with an object, not a one-entry list (plan §3.5).
            let entry: JSONObject = rows.isEmpty && end != nil ? ["status": .string(end!), "info": .string("No device groups found")]
                : ["devicegroups": .array(rows.map(JSONValue.object))]
            return (200, [:], Self.json(["status": .string("OK"), "response": .object(entry)]))
        default:
            throw StubFailure.unhandled("\(path) \(object["operation"]?.string ?? "")")
        }
    }

    private func devices(_ options: JSONObject) -> (Int, [String: String], Data) {
        guard let os = options["os"]?.string, !os.isEmpty else { return (200, [:], Self.entry(Self.missing("os"))) }
        var columns: [String]?
        if case .array(let names)? = options["specific_columns"] {
            let asked = names.compactMap(\.string)
            let (lacking, named) = state.withLock { ($0.lacking, $0.namesLacking) }
            let unknown = asked.filter { !Self.deviceColumns.contains($0) || lacking.contains($0) }
            guard unknown.isEmpty, asked.count == names.count else {
                state.withLock { $0.columnRefusals += 1 }
                let info = named ? "Unknown columns: \(unknown.joined(separator: ", "))" : "Unknown columns"
                return (200, [:], Self.entry(["status": .string("UNKNOWN_COLUMNS"), "info": .string(info)]))
            }
            columns = asked
        }
        let (all, ignoresColumns) = state.withLock { ($0.devices[os] ?? [], $0.ignoresColumns) }
        let (rows, total) = page(all, options)
        guard !rows.isEmpty else {
            return (200, [:], Self.entry(["status": .string("DEVICES_NOTFOUND"), "info": .string("No devices found")]))
        }
        let shown = rows.map { row in
            guard let columns, !ignoresColumns else { return row }
            var kept = JSONObject()
            for (key, value) in row where columns.contains(key) { kept[key] = value }
            return kept
        }
        return (200, [:], Self.entry(["devices": .array(shown.map(JSONValue.object)), "rows": .number(String(total)),
                                      "page": options["page"] ?? .number("1"), "page_size": .number(String(Self.serverPageSize))]))
    }

    private func list(_ all: [JSONObject], key: String, path: String, _ options: JSONObject) -> (Int, [String: String], Data) {
        let (rows, total) = page(all, options)
        if rows.isEmpty, let end = state.withLock({ $0.endOfList[path] }) {
            return (200, [:], Self.entry(["status": .string(end), "info": .string("Nothing found")]))
        }
        return (200, [:], Self.entry([key: .array(rows.map(JSONValue.object)), "rows": .number(String(total))]))
    }

    /// The page `options` asks for, at Mosyle's page size; the first page again for a tenant that ignores paging.
    private func page(_ all: [JSONObject], _ options: JSONObject) -> ([JSONObject], Int) {
        let asked = max(options["page"]?.int ?? 1, 1)
        let (ignores, wraps) = state.withLock { ($0.ignoresPage, $0.wrapsPages) }
        var number = ignores ? 1 : asked
        if wraps, !all.isEmpty { number = (number - 1) % ((all.count + Self.serverPageSize - 1) / Self.serverPageSize) + 1 }
        let start = (number - 1) * Self.serverPageSize
        guard start < all.count else { return ([], all.count) }
        return (Array(all[start..<min(start + Self.serverPageSize, all.count)]), all.count)
    }

    static func missing(_ field: String) -> JSONObject {
        ["status": .string("MISSING_DATA"), "info": .string("Missing \(field)")]
    }

    /// `{"status": "OK", "response": [entry]}`: "OK" at the top on errors too, as Mosyle sends it.
    static func entry(_ entry: JSONObject) -> Data {
        json(["status": .string("OK"), "response": .array([.object(entry)])])
    }

    static func json(_ object: JSONObject) -> Data { Data(JSONValue.dumps(.object(object)).utf8) }
}
#endif
