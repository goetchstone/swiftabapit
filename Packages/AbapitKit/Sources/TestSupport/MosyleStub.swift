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
///   `Authorization` header, with PHP's fixed `Expires: Thu, 19 Nov 1981 08:52:00 GMT` beside it.
/// - Every other request needs both `accessToken` and `Authorization: Bearer <jwt>` of a live login, else 401
///   `{"error": …}`.
/// - Lists page at **50 rows whatever `page_size` asks** (abapit recorded `"page_size":50`; it asked for 500 and
///   stopped after the first short page: defect 2). Devices need `os` (else `MISSING_DATA`), refuse a column they
///   don't have (`UNKNOWN_COLUMNS`), answer `DEVICES_NOTFOUND` past the end, and return only `specific_columns`
///   when given. Device groups answer with an object, not a list.
/// - The top-level `"status": "OK"` is sent on errors too, as Mosyle does.
public final class MosyleStub: Transport, Sendable {
    public struct Account: Sendable {
        public let accessToken: String
        public let email: String
        public let password: String

        public init(accessToken: String, email: String, password: String) {
            self.accessToken = accessToken
            self.email = email
            self.password = password
        }
    }

    public enum StubFailure: Error, Equatable, Sendable {
        case unhandled(String)
    }

    /// Mosyle's page size, whatever the request asks.
    public static let serverPageSize = 50
    /// The columns a device has here: the adapter's, plus the Activation Lock bypass codes the adapter must drop.
    public static let deviceColumns: Set<String> = Set(MosyleAdapter.deviceColumns + ["activation_bypass", "activation_bypass_code"])

    private struct State {
        var account: Account?
        var jwts: [String: Date] = [:]
        var devices: [String: [JSONObject]] = [:]
        var users: [JSONObject] = []
        var userGroups: [JSONObject] = []
        var deviceGroups: [String: [JSONObject]] = [:]
        var queued: [(path: String, status: Int, headers: [String: String])] = []
        var envelopeFailures: [(path: String, status: String)] = []
        var requests: [String] = []
        var bodies: [JSONObject] = []
        var logins = 0
        var jwtLifetime: TimeInterval = 24 * 3600
        var jwtExpClaim: JSONValue?
        var revoked = false
        var expireOnce = false
        var transportFailures = 0
        var ignoresPage = false
        var ignoresColumns = false
        var rowsAsString = false
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
    /// The next request under `path` answers `status` (429 with `Retry-After` in `headers`, 500, …).
    public func queue(_ status: Int, for path: String, headers: [String: String] = [:]) {
        state.withLock { $0.queued.append((path, status, headers)) }
    }
    /// The next request under `path` answers HTTP 200 with this status in its entry (`UNKNOWN_COLUMNS`, a new code).
    public func failEnvelope(_ status: String, for path: String) { state.withLock { $0.envelopeFailures.append((path, status)) } }
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
    /// A tenant that sends every column, `specific_columns` or not.
    public func ignoreColumns() { state.withLock { $0.ignoresColumns = true } }
    /// `rows` as a string (`"120"`), as some operations send it.
    public func sendRowsAsStrings() { state.withLock { $0.rowsAsString = true } }

    /// Every request, as `METHOD host/path operation`.
    public var requests: [String] { state.withLock { $0.requests } }
    /// Every list request's body, for asserting on `specific_columns` and paging.
    public var bodies: [JSONObject] { state.withLock { $0.bodies } }
    public var logins: Int { state.withLock { $0.logins } }

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
        state.withLock { $0.requests.append("\(method) \(host.rawValue)\(path) \(operation)".trimmingCharacters(in: .whitespaces)) }
        guard url.query == nil else { throw StubFailure.unhandled("a query string on \(path): Mosyle reads take a body") }

        let (status, headers, body): (Int, [String: String], Data)
        if method != "POST" {
            (status, headers, body) = (405, [:], Self.json(["status": .string("INVALID_METHOD"), "info": .string("Method not allowed")]))
        } else if let object {
            if path == "/v1/login" {
                (status, headers, body) = login(request, object, host: host)
            } else if host == .mosyle {
                (status, headers, body) = try business(request, path: path, object)
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

    // MARK: login

    private func login(_ request: URLRequest, _ object: JSONObject, host: APIHost) -> (Int, [String: String], Data) {
        state.withLock { state in
            guard let account = state.account, host == .mosyle,
                  request.value(forHTTPHeaderField: "accessToken") == account.accessToken,
                  object["email"]?.string == account.email, object["password"]?.string == account.password else {
                return (401, [:], Self.json(["error": .string("Invalid credentials")]))
            }
            state.logins += 1
            let expires = now().addingTimeInterval(state.jwtLifetime)
            let exp = state.jwtExpClaim ?? .number(String(Int(expires.timeIntervalSince1970)))
            let payload = Self.json(["exp": exp, "jti": .string(UUID().uuidString)])
            let jwt = "eyJhbGciOiJIUzI1NiJ9." + Base64URL.encode(payload) + ".c2ln"
            state.jwts[jwt] = expires
            return (200, ["Authorization": "Bearer \(jwt)", "Expires": "Thu, 19 Nov 1981 08:52:00 GMT",
                          "Set-Cookie": "PHPSESSID=stub; path=/"],
                    Self.json(["status": .string("OK")]))
        }
    }

    // MARK: Mosyle Business

    private func business(_ request: URLRequest, path: String, _ object: JSONObject) throws -> (Int, [String: String], Data) {
        let refusal: (Int, [String: String], Data)? = state.withLock { state in
            if let index = state.queued.firstIndex(where: { path.hasPrefix($0.path) }) {
                let failure = state.queued.remove(at: index)
                return (failure.status, failure.headers, Self.json(["error": .string("queued \(failure.status)")]))
            }
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let jwt = bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : ""
            guard !state.revoked, request.value(forHTTPHeaderField: "accessToken") == state.account?.accessToken,
                  let expires = state.jwts[jwt], expires > now() else {
                return (401, [:], Self.json(["error": .string("Unauthorized")]))
            }
            if state.expireOnce {
                state.expireOnce = false
                state.jwts = [:]
                return (401, [:], Self.json(["error": .string("Unauthorized")]))
            }
            if let index = state.envelopeFailures.firstIndex(where: { path.hasPrefix($0.path) }) {
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
        case ("/v1/users", "list_users"): return list(state.withLock { $0.users }, key: "users", options)
        case ("/v1/usergroups", "list_usergroup"): return list(state.withLock { $0.userGroups }, key: "usergroups", options)
        case ("/v1/devicegroups", "list_devicegroup"):
            guard let os = options["os"]?.string, !os.isEmpty else { return (200, [:], Self.entry(Self.missing("os"))) }
            let groups = state.withLock { $0.deviceGroups[os] ?? [] }
            let (rows, _) = page(groups, options)
            // Device groups answer with an object, not a one-entry list (plan §3.5).
            return (200, [:], Self.json(["status": .string("OK"), "response": .object(["devicegroups": .array(rows.map(JSONValue.object))])]))
        default:
            throw StubFailure.unhandled("\(path) \(object["operation"]?.string ?? "")")
        }
    }

    private func devices(_ options: JSONObject) -> (Int, [String: String], Data) {
        guard let os = options["os"]?.string, !os.isEmpty else { return (200, [:], Self.entry(Self.missing("os"))) }
        var columns: [String]?
        if case .array(let names)? = options["specific_columns"] {
            let asked = names.compactMap(\.string)
            let unknown = asked.filter { !Self.deviceColumns.contains($0) }
            guard unknown.isEmpty, asked.count == names.count else {
                return (200, [:], Self.entry(["status": .string("UNKNOWN_COLUMNS"), "info": .string("Unknown columns: \(unknown.joined(separator: ", "))")]))
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
        return (200, [:], Self.entry(["devices": .array(shown.map(JSONValue.object)), "rows": rowsValue(total),
                                      "page": options["page"] ?? .number("1"), "page_size": .number(String(Self.serverPageSize))]))
    }

    private func list(_ all: [JSONObject], key: String, _ options: JSONObject) -> (Int, [String: String], Data) {
        let (rows, total) = page(all, options)
        return (200, [:], Self.entry([key: .array(rows.map(JSONValue.object)), "rows": rowsValue(total)]))
    }

    /// The page `options` asks for, at Mosyle's page size; the first page again for a tenant that ignores paging.
    private func page(_ all: [JSONObject], _ options: JSONObject) -> ([JSONObject], Int) {
        let asked = max(options["page"]?.int ?? 1, 1)
        let number = state.withLock { $0.ignoresPage } ? 1 : asked
        let start = (number - 1) * Self.serverPageSize
        guard start < all.count else { return ([], all.count) }
        return (Array(all[start..<min(start + Self.serverPageSize, all.count)]), all.count)
    }

    private func rowsValue(_ total: Int) -> JSONValue {
        state.withLock { $0.rowsAsString } ? .string(String(total)) : .number(String(total))
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
