import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Synchronization
import Vault
import Wire

/// A strict stand-in for Apple's token endpoint and the Apple Business / School APIs (plan §6.3,
/// invariant 5). An unhandled request throws `StubFailure.unhandled`; every failure mode is written from
/// `Contracts/apple/*.json` (status codes, parameters, `allowedValues`, `maximum`) or from behaviour abapit
/// saw live, never from convention. Where Apple's behaviour isn't documented or observed, the choice is
/// named in docs/domains/apple-reads.md as an assumption to check live.
///
/// - The token endpoint verifies the client assertion as Apple must: `alg` ES256, `kid`, `iss`/`sub`,
///   `aud` the **v2** URL, `exp` in the future and under 180 days, and a **raw** `r‖s` signature by the
///   registered public key (a DER signature, the classic ES256 bug, fails). Anything else is
///   `invalid_client`. The form must be in the body.
/// - Resources check the bearer (unknown, expired, or another scope's token is 401), validate every query
///   parameter (unknown name, `limit` over 1000, a `fields[…]` value Apple doesn't allow: 400), and page
///   with real `links.next` URLs.
/// - Failures can be queued: 401 once, 403 for a section, 429 with or without `Retry-After`.
public final class AppleStub: Transport, Sendable {
    public struct Account: Sendable {
        public let clientID: String
        public let keyID: String
        public let teamID: String
        public let scope: String
        public let publicKey: P256.Signing.PublicKey

        public init(clientID: String, keyID: String, teamID: String = "", scope: String = "business", publicKey: P256.Signing.PublicKey) {
            self.clientID = clientID
            self.keyID = keyID
            self.teamID = teamID
            self.scope = scope
            self.publicKey = publicKey
        }
    }

    public enum StubFailure: Error, Equatable, Sendable {
        case unhandled(String)
    }

    private struct Token { let clientID: String; let scope: String; let expires: Date }

    private struct State {
        var accounts: [String: Account] = [:]
        var tokens: [String: Token] = [:]
        var devices: [Resource] = []
        var services: [Resource] = []
        var assignments: [String: String] = [:]
        var coverage: [String: [Resource]] = [:]
        var locks: [String: Resource] = [:]
        var forbiddenPaths: Set<String> = []
        var queued: [(path: String, status: Int, headers: [String: String])] = []
        var unauthorizedOnce = false
        var tokenFailures: [Int] = []
        var requests: [String] = []
        var mints = 0
    }

    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: arranging

    public func register(_ account: Account) { state.withLock { $0.accounts[account.clientID] = account } }
    public func add(devices: [Resource]) { state.withLock { $0.devices += devices } }
    public func add(services: [Resource]) { state.withLock { $0.services += services } }
    public func assign(_ serial: String, to service: String?) { state.withLock { $0.assignments[serial] = service } }
    public func setCoverage(_ serial: String, _ rows: [Resource]) { state.withLock { $0.coverage[serial] = rows } }
    public func setLock(_ serial: String, isLocked: Bool, lockType: String) {
        state.withLock {
            $0.locks[serial] = Resource(type: "activationLockStatus", id: serial,
                                         attributes: ["isLocked": .bool(isLocked), "lockType": .string(lockType)])
        }
    }
    /// Every request under `path` answers 403, as a role without that permission gets.
    public func forbid(_ path: String) { state.withLock { _ = $0.forbiddenPaths.insert(path) } }
    /// The next request under `path` answers `status` (429 with `Retry-After` in `headers`, 500, …).
    public func queue(_ status: Int, for path: String, headers: [String: String] = [:]) {
        state.withLock { $0.queued.append((path, status, headers)) }
    }
    /// The next resource request answers 401, once: a token that expired early.
    public func expireTokensOnce() { state.withLock { $0.unauthorizedOnce = true } }
    /// The next token request answers `status` (429, 500).
    public func failNextToken(_ status: Int) { state.withLock { $0.tokenFailures.append(status) } }

    /// Every request, as `METHOD host/path?query`: what the tests assert on.
    public var requests: [String] { state.withLock { $0.requests } }
    public var mints: Int { state.withLock { $0.mints } }

    // MARK: Transport

    public func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = APIHost(of: url) else { throw StubFailure.unhandled("\(request.url?.absoluteString ?? "?")") }
        let method = request.httpMethod ?? "GET"
        let path = url.path(percentEncoded: false)
        state.withLock { $0.requests.append("\(method) \(host.rawValue)\(path)\(url.query(percentEncoded: true).map { "?\($0)" } ?? "")") }
        let (status, headers, body): (Int, [String: String], Data)
        switch (host, method, path) {
        case (.appleAccount, "POST", "/auth/oauth2/token"):
            (status, headers, body) = token(request)
        case (.appleBusiness, "GET", _), (.appleSchool, "GET", _):
            (status, headers, body) = try resource(request, host: host, url: url)
        default:
            throw StubFailure.unhandled("\(method) \(host.rawValue)\(path)")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/2",
                                       headerFields: ["Content-Type": "application/json"].merging(headers) { $1 })!
        return (body, response)
    }

    // MARK: the token endpoint

    private func token(_ request: URLRequest) -> (Int, [String: String], Data) {
        if let failure = state.withLock({ $0.tokenFailures.isEmpty ? nil : $0.tokenFailures.removeFirst() }) {
            return (failure, [:], Self.json(["error": .string(failure == 429 ? "rate_limited" : "server_error")]))
        }
        let invalid = (400, [String: String](), Self.json(["error": .string("invalid_client")]))
        guard request.url?.query == nil, request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
              let body = request.httpBody else {
            return (400, [:], Self.json(["error": .string("invalid_request")]))
        }
        let form = Self.form(body)
        guard form["grant_type"] == "client_credentials",
              form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
              let clientID = form["client_id"], let assertion = form["client_assertion"], let scope = form["scope"] else {
            return (400, [:], Self.json(["error": .string("invalid_request")]))
        }
        guard let account = state.withLock({ $0.accounts[clientID] }) else { return invalid }
        guard scope == "\(account.scope).api" else { return (400, [:], Self.json(["error": .string("invalid_scope")])) }
        let parts = assertion.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Base64URL.decode(parts[0]), let payloadData = Base64URL.decode(parts[1]),
              let signature = Base64URL.decode(parts[2]),
              let header = JSONValue.parse(String(decoding: headerData, as: UTF8.self))?.object,
              let payload = JSONValue.parse(String(decoding: payloadData, as: UTF8.self))?.object else { return invalid }
        let now = Int(now().timeIntervalSince1970)
        guard header["alg"]?.string == "ES256", header["kid"]?.string == account.keyID,
              payload["sub"]?.string == clientID, payload["iss"]?.string == (account.teamID.isEmpty ? clientID : account.teamID),
              payload["aud"]?.string == "https://account.apple.com/auth/oauth2/v2/token",
              let iat = payload["iat"]?.int, let exp = payload["exp"]?.int, exp > now, iat <= now + 60, exp - iat < 180 * 86_400,
              payload["jti"]?.string?.isEmpty == false,
              signature.count == 64, let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              account.publicKey.isValidSignature(raw, for: Data("\(parts[0]).\(parts[1])".utf8)) else { return invalid }
        let value = "stub-token-" + UUID().uuidString
        state.withLock {
            $0.mints += 1
            $0.tokens[value] = Token(clientID: clientID, scope: account.scope, expires: Date(timeIntervalSince1970: TimeInterval(now + 3600)))
        }
        return (200, [:], Self.json(["access_token": .string(value), "token_type": .string("Bearer"), "expires_in": .number("3600"),
                                     "scope": .string(scope)]))
    }

    // MARK: resources

    private static let business: APIHost = .appleBusiness

    private func resource(_ request: URLRequest, host: APIHost, url: URL) throws -> (Int, [String: String], Data) {
        let path = url.path(percentEncoded: false)
        let scope = host == .appleBusiness ? "business" : "school"
        // The bearer: issued here, unexpired, for this host's scope.
        let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let valid = state.withLock { state -> Bool in
            if state.unauthorizedOnce {
                state.unauthorizedOnce = false
                return false
            }
            guard bearer.hasPrefix("Bearer "), let token = state.tokens[String(bearer.dropFirst(7))] else { return false }
            return token.scope == scope && token.expires > now()
        }
        guard valid else { return Self.error(401, "NOT_AUTHORIZED", "Unauthorized", "Authentication credentials are missing or invalid.") }
        if let queued = state.withLock({ state -> (Int, [String: String])? in
            guard let index = state.queued.firstIndex(where: { path.hasPrefix($0.path) }) else { return nil }
            let item = state.queued.remove(at: index)
            return (item.status, item.headers)
        }) {
            let (status, headers, body) = Self.error(queued.0, "QUEUED", "Queued failure", "A failure the test queued.")
            return (status, queued.1.merging(headers) { a, _ in a }, body)
        }
        if state.withLock({ $0.forbiddenPaths.contains { path.hasPrefix($0) } }) {
            return Self.error(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons", "The API account's role doesn't allow it.")
        }
        let query = Self.query(url)
        let segments = path.split(separator: "/").map(String.init)
        guard segments.first == "v1", segments.count >= 2 else { throw StubFailure.unhandled(path) }
        let schoolSections: Set = ["orgDevices", "mdmServers", "orgDeviceActivities"]
        if scope == "school", !schoolSections.contains(segments[1]) {
            throw StubFailure.unhandled("School has no \(segments[1]) endpoint")
        }
        switch Array(segments.dropFirst()) {
        case ["orgDevices"]:
            if let bad = Self.check(query, allowed: ["limit", "cursor", "fields[orgDevices]"], fields: ("fields[orgDevices]", Self.orgDeviceFields)) {
                return bad
            }
            return page(state.withLock { $0.devices }, url: url, query: query, host: host)
        case let s where s.count == 2 && s[0] == "orgDevices":
            if let bad = Self.check(query, allowed: ["fields[orgDevices]"], fields: ("fields[orgDevices]", Self.orgDeviceFields)) { return bad }
            guard let device = state.withLock({ $0.devices.first { $0.id == s[1] } }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": device.asJSON, "links": .object(["self": .string(url.absoluteString)])]))
        case let s where s.count == 3 && s[0] == "orgDevices" && s[2] == "appleCareCoverage":
            if let bad = Self.check(query, allowed: ["limit", "fields[appleCareCoverage]"], fields: nil) { return bad }
            guard state.withLock({ $0.devices.contains { $0.id == s[1] } }) else { return Self.notFound(path) }
            return page(state.withLock { $0.coverage[s[1]] ?? [] }, url: url, query: query, host: host)
        case let s where s.count == 3 && s[0] == "orgDevices" && s[2] == "activationLockStatus":
            if let bad = Self.check(query, allowed: ["fields[activationLockStatus]"], fields: nil) { return bad }
            guard let lock = state.withLock({ $0.locks[s[1]] }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": lock.asJSON]))
        case let s where s.count == 3 && s[0] == "orgDevices" && s[2] == "assignedServer":
            // abapit saw 404 for an unassigned device (client.py:176-182).
            guard let id = state.withLock({ $0.assignments[s[1]] }),
                  let service = state.withLock({ $0.services.first { $0.id == id } }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": service.asJSON]))
        case let s where s.count == 4 && s[0] == "orgDevices" && s[2] == "relationships" && s[3] == "assignedServer":
            // Assumed to match the full read's 404 (docs/domains/apple-reads.md: check live).
            guard let id = state.withLock({ $0.assignments[s[1]] }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": .object(["type": .string("mdmServers"), "id": .string(id)])]))
        case ["mdmServers"]:
            if let bad = Self.check(query, allowed: ["limit", "fields[mdmServers]"], fields: ("fields[mdmServers]", Self.serviceFields)) {
                return bad
            }
            return page(state.withLock { $0.services }, url: url, query: query, host: host)
        case let s where s.count == 2 && s[0] == "mdmServers":
            guard let service = state.withLock({ $0.services.first { $0.id == s[1] } }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": service.asJSON]))
        case let s where s.count == 4 && s[0] == "mdmServers" && s[2] == "relationships" && s[3] == "devices":
            if let bad = Self.check(query, allowed: ["limit"], fields: nil) { return bad }
            guard state.withLock({ $0.services.contains { $0.id == s[1] } }) else { return Self.notFound(path) }
            let linkages = state.withLock { state in
                state.assignments.filter { $0.value == s[1] }.keys.sorted().map { Resource(type: "orgDevices", id: $0) }
            }
            return page(linkages, url: url, query: query, host: host, linkagesOnly: true)
        case ["auditEvents"]:
            guard query["filter[startTimestamp]"] != nil, query["filter[endTimestamp]"] != nil else {
                return Self.error(400, "PARAMETER_ERROR.REQUIRED", "A parameter is required", "filter[startTimestamp] and filter[endTimestamp] are required.",
                                  parameter: "filter[startTimestamp]")
            }
            return page([], url: url, query: query, host: host)
        case ["mdmDevices"], ["users"], ["userGroups"], ["organizationalUnits"], ["apps"], ["packages"], ["blueprints"], ["configurations"]:
            if let bad = Self.check(query, allowed: ["limit", "cursor"], fields: nil) { return bad }
            return page([], url: url, query: query, host: host)
        default:
            throw StubFailure.unhandled("GET \(path)")
        }
    }

    /// A page of `items` from the `cursor` offset, `limit` long, with `links.next` when more remain.
    private func page(_ items: [Resource], url: URL, query: [String: String], host: APIHost, linkagesOnly: Bool = false)
        -> (Int, [String: String], Data) {
        let limit = query["limit"].flatMap(Int.init) ?? 100
        let start = query["cursor"].flatMap(Int.init) ?? 0
        let slice = items.dropFirst(start).prefix(limit)
        var links: JSONObject = ["self": .string(url.absoluteString)]
        if start + slice.count < items.count {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: String(start + slice.count))]
            links["next"] = .string(components.url!.absoluteString)
        }
        let data = slice.map { linkagesOnly ? JSONValue.object(["type": .string($0.type), "id": .string($0.id)]) : $0.asJSON }
        return (200, [:], Self.json(["data": .array(Array(data)), "links": .object(links),
                                     "meta": .object(["paging": .object(["limit": .number(String(limit)), "total": .number(String(items.count))])])]))
    }

    // MARK: validation and bodies

    /// `fields[orgDevices]`'s allowed values (Contracts/apple/business-2.6.json).
    public static let orgDeviceFields: Set = ["serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel",
                                              "productFamily", "productType", "deviceCapacity", "partNumber", "orderNumber", "color", "status",
                                              "orderDateTime", "imei", "meid", "eid", "purchaseSourceId", "purchaseSourceType", "wifiMacAddress",
                                              "bluetoothMacAddress", "ethernetMacAddress", "assignedServer", "appleCareCoverage"]
    public static let serviceFields: Set = ["serverName", "enableMdmDisownFlag", "defaultProductFamilies", "status", "serverType", "deviceCount",
                                            "lastConnectedDateTime", "lastConnectedIp", "createdDateTime", "updatedDateTime", "devices"]

    private static func check(_ query: [String: String], allowed: Set<String>, fields: (String, Set<String>)?) -> (Int, [String: String], Data)? {
        if let unknown = query.keys.sorted().first(where: { !allowed.contains($0) }) {
            return error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "\(unknown) isn't a parameter of this endpoint.", parameter: unknown)
        }
        if let limit = query["limit"], Int(limit).map({ !(1...1000).contains($0) }) ?? true {
            return error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "limit must be 1 to 1000.", parameter: "limit")
        }
        if let (name, values) = fields, let given = query[name],
           let bad = given.split(separator: ",").map(String.init).first(where: { !values.contains($0) }) {
            return error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "\(bad) isn't allowed in \(name).", parameter: name)
        }
        return nil
    }

    private static func query(_ url: URL) -> [String: String] {
        var found: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { found[item.name] = item.value ?? "" }
        return found
    }

    private static func form(_ body: Data) -> [String: String] {
        var found: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            if parts.count == 2 { found[parts[0]] = parts[1] }
        }
        return found
    }

    private static func notFound(_ path: String) -> (Int, [String: String], Data) {
        error(404, "NOT_FOUND", "The specified resource does not exist", "There is no resource at \(path).")
    }

    /// Apple's `ErrorResponse`: `{errors: [{id, status, code, title, detail, source}]}`.
    static func error(_ status: Int, _ code: String, _ title: String, _ detail: String, parameter: String? = nil) -> (Int, [String: String], Data) {
        var item: JSONObject = ["id": .string(UUID().uuidString), "status": .string(String(status)), "code": .string(code),
                                "title": .string(title), "detail": .string(detail)]
        if let parameter { item["source"] = .object(["parameter": .string(parameter)]) }
        return (status, [:], json(["errors": .array([.object(item)])]))
    }

    static func json(_ object: JSONObject) -> Data { Data(JSONValue.dumps(.object(object)).utf8) }
}
