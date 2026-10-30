#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
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
///   parameter against the contract's own table, written out here (`parameters`: an unknown name, a `limit` outside 1
///   to 1000, a value outside a listed set such as an `include` name or an audit type: 400), and page with real
///   `links.next` URLs and cursors (a cursor it never gave is 400). An endpoint Apple doesn't document (abapit's
///   `mdmDevices/{id}`) and any School read of a Business-only collection are unhandled.
/// - The Business-only reads serve what `add(_:)`, `relate(_:_:_:to:)` and `setDetails(_:_:)` hold: the configuration
///   list sends a custom setting's profile as null, a blueprint lists the members it was asked to include up to
///   `limit[<name>]` and includes their resources, and the audit log requires its range and really filters by it, the
///   types, the actor and the subject.
/// - Failures can be queued: 401 once, 403 for a section, 429 with or without `Retry-After`, any status or body for a
///   path (`queue`, which may go on into the query: `/v1/blueprints/B1?include=` fails only the read that includes);
///   a blueprint read whose include names a forbidden collection is refused (`refuseIncludes(with:)`, 400 by default,
///   as abapit saw); `repeatCursors(on:)` makes a list's cursor never move.
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
        /// The Business-only collections, by type: users, userGroups, organizationalUnits, apps, packages, blueprints,
        /// configurations, mdmDevices, auditEvents.
        var collections: [String: [Resource]] = [:]
        /// Members by `<collection>/<id>/<relationship>`: a group's or an org unit's users, a blueprint's members.
        var members: [String: [String]] = [:]
        /// `mdmDevices/{id}/details` by the device's id.
        var details: [String: Resource] = [:]
        var includeRefusal = 400
        var repeatingCursors: Set<String> = []
        var forbiddenPaths: Set<String> = []
        var queued: [(path: String, status: Int, headers: [String: String], body: Data?)] = []
        var unauthorizedOnce = false
        var tokenFailures: [(status: Int, error: String?)] = []
        var requests: [String] = []
        var mints = 0
        var alwaysUnauthorized = false
        var transportFailures = 0
        var expiresIn = 3600
        var reportsTotal = false
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
    /// Resources of the Business-only collections, each filed by its `type`: `users`, `userGroups`,
    /// `organizationalUnits`, `apps`, `packages`, `blueprints`, `configurations` (with `customSettingsValues`, which only
    /// the single read sends), `mdmDevices` and `auditEvents` (their `eventDateTime`, `type`, `actorId` and `subjectId`
    /// are what the filters match).
    public func add(_ resources: [Resource]) {
        state.withLock { state in for resource in resources { state.collections[resource.type, default: []].append(resource) } }
    }
    /// `ids` as the members of `relationship` of the `collection` item `id`: a group's or an org unit's `users`, or a
    /// blueprint's `apps`, `packages`, `configurations`, `orgDevices`, `users` or `userGroups` (each a linkage of that type).
    public func relate(_ collection: String, _ id: String, _ relationship: String, to ids: [String]) {
        state.withLock { $0.members["\(collection)/\(id)/\(relationship)"] = ids }
    }
    /// An Apple-managed device's `mdmDevices/{id}/details`.
    public func setDetails(_ device: String, _ details: Resource) { state.withLock { $0.details[device] = details } }
    /// The status a blueprint read answers when its `include` names a relationship `forbid` refused: 400 unless set (what
    /// abapit saw), or 403.
    public func refuseIncludes(with status: Int) { state.withLock { $0.includeRefusal = status } }
    /// Every page under `path` names its own cursor as the next one, as a broken cursor would: the client must stop.
    public func repeatCursors(on path: String) { state.withLock { _ = $0.repeatingCursors.insert(path) } }
    /// Every request under `path` answers 403, as a role without that permission gets.
    public func forbid(_ path: String) { state.withLock { _ = $0.forbiddenPaths.insert(path) } }
    /// The next request under `path` answers `status` (429 with `Retry-After` in `headers`, 500, …) with Apple's
    /// `ErrorResponse`, or with `body` as given: a 200 that isn't the documented shape (`{}`, one object for a list),
    /// bytes that aren't JSON, an `ErrorResponse` whose `code` or `source.parameter` is prose or an identifier. `path`
    /// may go on into the query (`/v1/orgDevices?cursor=`) to fail a later page and not the first. The client handles
    /// each of these, so the stub has to be able to send them (invariant 5; Phase 1b verifier round 1).
    public func queue(_ status: Int, for path: String, headers: [String: String] = [:], body: String? = nil) {
        state.withLock { $0.queued.append((path, status, headers, body.map { Data($0.utf8) })) }
    }
    /// The next resource request answers 401, once: a token that expired early.
    public func expireTokensOnce() { state.withLock { $0.unauthorizedOnce = true } }
    /// The next token request answers `status` (429, 500), with `error` as its OAuth `error` when given.
    public func failNextToken(_ status: Int, error: String? = nil) { state.withLock { $0.tokenFailures.append((status, error)) } }
    /// Every resource request answers 401, as an account whose key was revoked: a fresh token doesn't help.
    public func revokeAccount() { state.withLock { $0.alwaysUnauthorized = true } }
    /// The next `count` requests fail before reaching "Apple" (offline, a reset connection).
    public func failTransport(_ count: Int) { state.withLock { $0.transportFailures = count } }
    /// Tokens' `expires_in` from now on.
    public func tokenLifetime(_ seconds: Int) { state.withLock { $0.expiresIn = seconds } }
    /// Apple's example has no `meta.paging.total`; the stub adds one only when asked.
    public func reportTotals() { state.withLock { $0.reportsTotal = true } }

    /// Every request, as `METHOD host/path?query`: what the tests assert on.
    public var requests: [String] { state.withLock { $0.requests } }
    public var mints: Int { state.withLock { $0.mints } }

    // MARK: Transport

    public func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = APIHost(of: url) else { throw StubFailure.unhandled("\(request.url?.absoluteString ?? "?")") }
        let offline = state.withLock { state -> Bool in
            guard state.transportFailures > 0 else { return false }
            state.transportFailures -= 1
            return true
        }
        if offline { throw URLError(.networkConnectionLost) }
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
        // The transport's cap, as URLSessionTransport enforces it.
        if body.count > limit { throw HTTPFailure.tooLarge(limit: limit) }
        return (body, response)
    }

    // MARK: the token endpoint

    private func token(_ request: URLRequest) -> (Int, [String: String], Data) {
        if let failure = state.withLock({ $0.tokenFailures.isEmpty ? nil : $0.tokenFailures.removeFirst() }) {
            return (failure.status, [:], Self.json(["error": .string(failure.error ?? (failure.status == 429 ? "rate_limited" : "server_error"))]))
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
            $0.tokens[value] = Token(clientID: clientID, scope: account.scope, expires: Date(timeIntervalSince1970: TimeInterval(now + $0.expiresIn)))
        }
        let lifetime = state.withLock { $0.expiresIn }
        return (200, [:], Self.json(["access_token": .string(value), "token_type": .string("Bearer"), "expires_in": .number(String(lifetime)),
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
            if state.alwaysUnauthorized { return false }
            if state.unauthorizedOnce {
                state.unauthorizedOnce = false
                return false
            }
            guard bearer.hasPrefix("Bearer "), let token = state.tokens[String(bearer.dropFirst(7))] else { return false }
            return token.scope == scope && token.expires > now()
        }
        guard valid else { return Self.error(401, "NOT_AUTHORIZED", "Unauthorized", "Authentication credentials are missing or invalid.") }
        let target = path + (url.query(percentEncoded: true).map { "?\($0)" } ?? "")
        if let queued = state.withLock({ state -> (Int, [String: String], Data?)? in
            guard let index = state.queued.firstIndex(where: { target.hasPrefix($0.path) }) else { return nil }
            let item = state.queued.remove(at: index)
            return (item.status, item.headers, item.body)
        }) {
            if let body = queued.2 { return (queued.0, queued.1, body) }
            let (status, headers, body) = Self.error(queued.0, "QUEUED", "Queued failure", "A failure the test queued.")
            return (status, queued.1.merging(headers) { a, _ in a }, body)
        }
        if forbidden(path) {
            return Self.error(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons", "The API account's role doesn't allow it.")
        }
        let query = Self.query(url)
        let segments = path.split(separator: "/").map(String.init)
        guard segments.first == "v1", segments.count >= 2 else { throw StubFailure.unhandled(path) }
        let schoolSections: Set = ["orgDevices", "mdmServers", "orgDeviceActivities"]
        if scope == "school", !schoolSections.contains(segments[1]) {
            throw StubFailure.unhandled("School has no \(segments[1]) endpoint")
        }
        // The endpoint Apple documents for this path, or none: `mdmDevices/{id}` (abapit's read) is unhandled.
        let template = "/v1/" + ([segments[1]] + (segments.count > 2 ? ["{id}"] + segments.dropFirst(3) : [])).joined(separator: "/")
        guard Self.parameters[template] != nil else { throw StubFailure.unhandled("GET \(path)") }
        if let bad = Self.check(query, template: template) { return bad }
        let id = segments.count > 2 ? segments[2] : ""
        switch template {
        case "/v1/orgDevices":
            return page(state.withLock { $0.devices }, url: url, query: query, host: host)
        case "/v1/orgDevices/{id}":
            guard let device = state.withLock({ $0.devices.first { $0.id == id } }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": device.asJSON, "links": .object(["self": .string(url.absoluteString)])]))
        case "/v1/orgDevices/{id}/appleCareCoverage":
            guard state.withLock({ $0.devices.contains { $0.id == id } }) else { return Self.notFound(path) }
            return page(state.withLock { $0.coverage[id] ?? [] }, url: url, query: query, host: host)
        case "/v1/orgDevices/{id}/activationLockStatus":
            guard let lock = state.withLock({ $0.locks[id] }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": lock.asJSON]))
        case "/v1/orgDevices/{id}/assignedServer":
            // abapit saw 404 for an unassigned device (client.py:176-182).
            guard let service = state.withLock({ state in state.assignments[id].flatMap { service in state.services.first { $0.id == service } } })
            else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": service.asJSON]))
        case "/v1/orgDevices/{id}/relationships/assignedServer":
            // Assumed to match the full read's 404 (docs/domains/apple-reads.md: check live).
            guard let service = state.withLock({ $0.assignments[id] }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": .object(["type": .string("mdmServers"), "id": .string(service)])]))
        case "/v1/mdmServers":
            return page(state.withLock { $0.services }, url: url, query: query, host: host)
        case "/v1/mdmServers/{id}":
            guard let service = state.withLock({ $0.services.first { $0.id == id } }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": service.asJSON]))
        case "/v1/mdmServers/{id}/relationships/devices":
            guard state.withLock({ $0.services.contains { $0.id == id } }) else { return Self.notFound(path) }
            let linkages = state.withLock { state in
                state.assignments.filter { $0.value == id }.keys.sorted().map { Resource(type: "orgDevices", id: $0) }
            }
            return page(linkages, url: url, query: query, host: host, linkagesOnly: true)
        case "/v1/auditEvents":
            return auditEvents(url: url, query: query, host: host)
        case "/v1/configurations":
            // abapit: the list sends a custom setting's `customSettingsValues` as null; only the single read carries it.
            let listed = collection("configurations").map { configuration in
                var attributes = configuration.attributes
                if attributes["customSettingsValues"] != nil { attributes["customSettingsValues"] = .null }
                return Resource(type: configuration.type, id: configuration.id, attributes: attributes)
            }
            return page(listed, url: url, query: query, host: host)
        case "/v1/blueprints":
            let include = query["include"].map { $0.split(separator: ",").map(String.init) } ?? []
            var included: [Resource] = []
            let blueprints = collection("blueprints").map { blueprint in
                let (json, resources) = blueprintJSON(blueprint, include: include, query: query, host: host)
                included += resources
                return json
            }
            return page(blueprints, url: url, query: query, host: host, included: included)
        case "/v1/blueprints/{id}":
            guard let blueprint = collection("blueprints").first(where: { $0.id == id }) else { return Self.notFound(path) }
            let include = query["include"].map { $0.split(separator: ",").map(String.init) } ?? []
            if let refused = refusal(include) { return refused }
            let (json, included) = blueprintJSON(blueprint, include: include, query: query, host: host)
            var body: JSONObject = ["data": json, "links": .object(["self": .string(url.absoluteString)])]
            if !include.isEmpty { body["included"] = .array(included.map(\.asJSON)) }
            return (200, [:], Self.json(body))
        case _ where segments.count == 5 && segments[3] == "relationships":
            // A group's or an org unit's users, a blueprint's members: linkages of the relationship's own type.
            guard collection(segments[1]).contains(where: { $0.id == id }) else { return Self.notFound(path) }
            let ids = state.withLock { $0.members["\(segments[1])/\(id)/\(segments[4])"] ?? [] }
            return page(ids.map { Resource(type: segments[4], id: $0) }, url: url, query: query, host: host, linkagesOnly: true)
        case "/v1/mdmDevices/{id}/details":
            // Assumed: a device with no details on record answers 404 (check live).
            guard let details = state.withLock({ $0.details[id] }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": details.asJSON, "links": .object(["self": .string(url.absoluteString)])]))
        case _ where segments.count == 2:
            return page(collection(segments[1]), url: url, query: query, host: host)
        case _ where segments.count == 3:
            guard let item = collection(segments[1]).first(where: { $0.id == id }) else { return Self.notFound(path) }
            return (200, [:], Self.json(["data": item.asJSON, "links": .object(["self": .string(url.absoluteString)])]))
        default:
            throw StubFailure.unhandled("GET \(path)")
        }
    }

    private func forbidden(_ path: String) -> Bool { state.withLock { $0.forbiddenPaths.contains { path.hasPrefix($0) } } }

    private func collection(_ name: String) -> [Resource] { state.withLock { $0.collections[name] ?? [] } }

    /// Apple refuses a blueprint read whose `include` names a relationship the role can't read: abapit saw a role that
    /// gets 403 on users and user groups get 400 for the blueprint with them included (client.py `blueprint`).
    private func refusal(_ include: [String]) -> (Int, [String: String], Data)? {
        guard include.contains(where: { forbidden("/v1/\($0)") }) else { return nil }
        let status = state.withLock { $0.includeRefusal }
        return status == 403
            ? Self.error(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons", "The API account's role can't read an included relationship.")
            : Self.error(status, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "An included relationship can't be read.", parameter: "include")
    }

    /// A blueprint as `Blueprint` documents it: its six relationships with Apple's links, and for each included one its
    /// linkages up to `limit[<name>]` with `meta.paging` (the next cursor when more remain, the total when asked), and
    /// the resources of those linkages that the stub holds.
    private func blueprintJSON(_ blueprint: Resource, include: [String], query: [String: String], host: APIHost) -> (JSONValue, [Resource]) {
        let base = "https://\(host.rawValue)/v1/blueprints/\(blueprint.id)"
        var relationships: JSONObject = [:], included: [Resource] = []
        for name in Self.blueprintRelationships {
            var relationship: JSONObject = ["links": .object(["self": .string("\(base)/relationships/\(name)"), "include": .string("\(base)?include=\(name)")])]
            if include.contains(name) {
                let ids = state.withLock { $0.members["blueprints/\(blueprint.id)/\(name)"] ?? [] }
                let limit = query["limit[\(name)]"].flatMap(Int.init) ?? Self.includeLimit
                let shown = Array(ids.prefix(limit))
                relationship["data"] = .array(shown.map { .object(["type": .string(name), "id": .string($0)]) })
                var paging: JSONObject = ["limit": .number(String(limit))]
                if ids.count > shown.count { paging["nextCursor"] = .string(String(shown.count)) }
                if state.withLock({ $0.reportsTotal }) { paging["total"] = .number(String(ids.count)) }
                relationship["meta"] = .object(["paging": .object(paging)])
                let held = name == "orgDevices" ? state.withLock { $0.devices } : collection(name)
                included += shown.compactMap { id in held.first { $0.id == id } }
            }
            relationships[name] = .object(relationship)
        }
        return (.object(["type": .string(blueprint.type), "id": .string(blueprint.id), "attributes": .object(blueprint.attributes),
                         "relationships": .object(relationships)]), included)
    }

    /// `GET auditEvents`: both timestamps required (400 as Apple's contract marks them), each ISO 8601; the events in
    /// the range, of the types asked, by the actor and of the subject asked, a cursor at a time. Apple filters, so the
    /// stub really does.
    private func auditEvents(url: URL, query: [String: String], host: APIHost) -> (Int, [String: String], Data) {
        for name in ["filter[startTimestamp]", "filter[endTimestamp]"] where query[name] == nil {
            return Self.error(400, "PARAMETER_ERROR.REQUIRED", "A parameter is required", "\(name) is required.", parameter: name)
        }
        guard let start = Self.instant(query["filter[startTimestamp]"]) else {
            return Self.error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "Not an ISO 8601 timestamp.", parameter: "filter[startTimestamp]")
        }
        guard let end = Self.instant(query["filter[endTimestamp]"]) else {
            return Self.error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "Not an ISO 8601 timestamp.", parameter: "filter[endTimestamp]")
        }
        // Assumed: a range that ends before it starts is refused (check live).
        guard start <= end else {
            return Self.error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "The range ends before it starts.", parameter: "filter[endTimestamp]")
        }
        let types = query["filter[type]"].map { Set($0.split(separator: ",").map(String.init)) }
        func same(_ attribute: JSONValue?, _ asked: String?) -> Bool {
            asked.map { asked in attribute?.string.map { $0.utf8.elementsEqual(asked.utf8) } ?? false } ?? true
        }
        let events = collection("auditEvents").filter { event in
            let attributes = event.attributes
            guard let when = Self.instant(attributes["eventDateTime"]?.string), start <= when, when <= end else { return false }
            return (types.map { types in attributes["type"]?.string.map(types.contains) ?? false } ?? true)
                && same(attributes["actorId"], query["filter[actorId]"]) && same(attributes["subjectId"], query["filter[subjectId]"])
        }
        return page(events, url: url, query: query, host: host)
    }

    private static func instant(_ text: String?) -> Date? {
        guard let text else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: text)
    }

    /// A page of `items` from the `cursor` offset, `limit` long, with `links.next` when more remain. A cursor the stub
    /// never gave is refused, as Apple refuses one; under `repeatCursors(on:)` every page names its own cursor as next.
    private func page(_ items: [Resource], url: URL, query: [String: String], host: APIHost, linkagesOnly: Bool = false) -> (Int, [String: String], Data) {
        page(items.map { linkagesOnly ? JSONValue.object(["type": .string($0.type), "id": .string($0.id)]) : $0.asJSON }, url: url, query: query,
             host: host)
    }

    private func page(_ items: [JSONValue], url: URL, query: [String: String], host: APIHost, included: [Resource]? = nil) -> (Int, [String: String], Data) {
        let limit = query["limit"].flatMap(Int.init) ?? 100
        let start: Int
        if let cursor = query["cursor"] {
            guard let offset = Int(cursor), offset >= 0, String(offset) == cursor else {
                return Self.error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "The cursor isn't one this endpoint gave.", parameter: "cursor")
            }
            start = offset
        } else {
            start = 0
        }
        let target = url.path(percentEncoded: false)
        let repeats = state.withLock { $0.repeatingCursors.contains { target.hasPrefix($0) } }
        let slice = items.dropFirst(start).prefix(limit)
        var links: JSONObject = ["self": .string(url.absoluteString)]
        var paging: JSONObject = ["limit": .number(String(limit))]
        if repeats || start + slice.count < items.count {
            let next = repeats ? start : start + slice.count
            // As Apple's example: the next link carries the cursor alone (get-org-devices.response.json).
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "cursor", value: String(next))]
            links["next"] = .string(components.url!.absoluteString)
            paging["nextCursor"] = .string(String(next))
        }
        if state.withLock({ $0.reportsTotal }) { paging["total"] = .number(String(items.count)) }
        var body: JSONObject = ["data": .array(Array(slice)), "links": .object(links), "meta": .object(["paging": .object(paging)])]
        if let included, query["include"] != nil { body["included"] = .array(included.map(\.asJSON)) }
        return (200, [:], Self.json(body))
    }

    // MARK: validation and bodies

    /// A blueprint's relationships, each named for the type it holds, in the order the contract lists them.
    static let blueprintRelationships = ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"]
    /// How many members of an included relationship come without `limit[<name>]`. Undocumented: assumed small, so a client
    /// that leaves the limit out sees its blueprints cut (check live).
    public static let includeLimit = 10

    /// Every GET's query parameters, written out from Contracts/apple/business-2.6.json (School's are the same where it has
    /// the endpoint), never from the client: each name, and the values it allows when the contract lists them. `limit` and
    /// `limit[…]` take 1 to 1000 (the contract's `maximum`). `AppleStubTests` holds the table to both contracts.
    public static let parameters: [String: [String: [String]?]] = [
        "/v1/apps": [
            "fields[apps]": ["name", "bundleId", "websiteUrl", "version", "supportedOS", "isCustomApp", "appStoreUrl"],
            "limit": nil,
        ],
        "/v1/apps/{id}": [
            "fields[apps]": ["name", "bundleId", "websiteUrl", "version", "supportedOS", "isCustomApp", "appStoreUrl"],
        ],
        "/v1/auditEvents": [
            "cursor": nil,
            "fields[auditEvents]": [
                "eventDateTime", "type", "category", "actorType", "actorId", "actorName", "subjectType", "subjectId", "subjectName", "outcome",
                "groupId", "eventDataPropertyKey", "eventDataDeviceAddedToOrg", "eventDataDeviceRemovedFromOrg", "eventDataDeviceAssignedToServer",
                "eventDataDeviceIsErased", "eventDataDeviceUnassignedFromServer", "eventDataSubjectHasICloudStoragePurchaseAdded",
                "eventDataSubjectHasICloudStoragePurchaseRemoved", "eventDataSubjectHasAppleCarePurchaseAdded",
                "eventDataSubjectHasAppleCarePurchaseRemoved", "eventDataConfigSettingsCreated", "eventDataConfigSettingsUpdated",
                "eventDataConfigSettingsDeleted", "eventDataCollectionCreated", "eventDataCollectionUpdated", "eventDataCollectionDeleted",
                "eventDataSubscriptionCreated", "eventDataSubscriptionUpdated", "eventDataSubscriptionDeleted", "eventDataAccountRoleLocationChanged",
                "eventDataAccountAdded", "eventDataAccountDeleted", "eventDataExternalAccountAssociated", "eventDataExternalAccountDisassociated",
                "eventDataDomainAdded", "eventDataDomainRemoved", "eventDataDomainVerified", "eventDataApiAccountCreatedWithKey",
                "eventDataApiAccountCreatedWithoutKey", "eventDataApiAccountDeleted", "eventDataApiAccountKeyGenerated",
                "eventDataApiAccountKeyRevoked", "eventDataApiAccountNameChanged", "eventDataApiAccountRoleLocationChanged", "eventDataRoleCreated",
                "eventDataRoleUpdated", "eventDataTermsAccepted", "eventDataDomainFederationEnabled", "eventDataDomainFederationDisabled",
                "eventDataBatchPasswordResetInitiated", "eventDataExternalAccountInvited", "eventDataAccountImageSet",
                "eventDataAccountImageReplaced", "eventDataAccountImageRemoved", "eventDataIdpCreated", "eventDataIdpUpdated", "eventDataIdpDeleted",
                "eventDataIdpAccountSyncEnabled", "eventDataIdpAccountSyncDisabled", "eventDataAppleServicesSettingsUpdated",
                "eventDataAccountPasswordChanged"
            ],
            "filter[actorId]": nil,
            "filter[endTimestamp]": nil,
            "filter[startTimestamp]": nil,
            "filter[subjectId]": nil,
            "filter[type]": [
                "DEVICE_ADDED_TO_ORG", "DEVICE_REMOVED_FROM_ORG", "DEVICE_ASSIGNED_TO_SERVER", "DEVICE_UNASSIGNED_FROM_SERVER",
                "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED", "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_REMOVED", "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED",
                "SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED", "DEVICE_IS_ERASED", "CONFIG_SETTINGS_CREATED", "CONFIG_SETTINGS_UPDATED",
                "CONFIG_SETTINGS_DELETED", "COLLECTION_CREATED", "COLLECTION_UPDATED", "COLLECTION_DELETED", "SUBSCRIPTION_CREATED",
                "SUBSCRIPTION_UPDATED", "SUBSCRIPTION_DELETED", "ACCOUNT_ROLE_LOCATION_CHANGED", "ACCOUNT_ADDED", "ACCOUNT_DELETED",
                "EXTERNAL_ACCOUNT_ASSOCIATED", "EXTERNAL_ACCOUNT_DISASSOCIATED", "DOMAIN_ADDED", "DOMAIN_REMOVED", "DOMAIN_VERIFIED",
                "API_ACCOUNT_CREATED_WITH_KEY", "API_ACCOUNT_CREATED_WITHOUT_KEY", "API_ACCOUNT_DELETED", "API_ACCOUNT_KEY_REVOKED",
                "API_ACCOUNT_KEY_GENERATED", "API_ACCOUNT_ROLE_LOCATION_CHANGED", "API_ACCOUNT_NAME_CHANGED", "ROLE_CREATED", "ROLE_UPDATED",
                "TERMS_ACCEPTED", "DOMAIN_FEDERATION_ENABLED", "DOMAIN_FEDERATION_DISABLED", "BATCH_PASSWORD_RESET_INITIATED",
                "EXTERNAL_ACCOUNT_INVITED", "ACCOUNT_IMAGE_SET", "ACCOUNT_IMAGE_REPLACED", "ACCOUNT_IMAGE_REMOVED", "IDP_CREATED", "IDP_UPDATED",
                "IDP_DELETED", "IDP_ACCOUNT_SYNC_ENABLED", "IDP_ACCOUNT_SYNC_DISABLED", "APPLE_SERVICES_SETTINGS_UPDATED", "ACCOUNT_PASSWORD_CHANGED"
            ],
            "limit": nil,
        ],
        "/v1/blueprints": [
            "fields[blueprints]": [
                "name", "description", "status", "createdDateTime", "updatedDateTime", "appLicenseDeficient", "apps", "packages", "configurations",
                "orgDevices", "users", "userGroups"
            ],
            "include": ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"],
            "limit": nil,
            "limit[apps]": nil,
            "limit[configurations]": nil,
            "limit[orgDevices]": nil,
            "limit[packages]": nil,
            "limit[userGroups]": nil,
            "limit[users]": nil,
        ],
        "/v1/blueprints/{id}": [
            "fields[blueprints]": [
                "name", "description", "status", "createdDateTime", "updatedDateTime", "appLicenseDeficient", "apps", "packages", "configurations",
                "orgDevices", "users", "userGroups"
            ],
            "include": ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"],
            "limit[apps]": nil,
            "limit[configurations]": nil,
            "limit[orgDevices]": nil,
            "limit[packages]": nil,
            "limit[userGroups]": nil,
            "limit[users]": nil,
        ],
        "/v1/blueprints/{id}/relationships/apps": [
            "limit": nil,
        ],
        "/v1/blueprints/{id}/relationships/configurations": [
            "limit": nil,
        ],
        "/v1/blueprints/{id}/relationships/orgDevices": [
            "limit": nil,
        ],
        "/v1/blueprints/{id}/relationships/packages": [
            "limit": nil,
        ],
        "/v1/blueprints/{id}/relationships/userGroups": [
            "limit": nil,
        ],
        "/v1/blueprints/{id}/relationships/users": [
            "limit": nil,
        ],
        "/v1/configurations": [
            "fields[configurations]": ["type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime"],
            "limit": nil,
        ],
        "/v1/configurations/{id}": [
            "fields[configurations]": ["type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime"],
        ],
        "/v1/mdmDevices": [
            "fields[mdmDevices]": ["serialNumber", "deviceName", "productFamily", "enrolledUserId", "details"],
            "limit": nil,
        ],
        "/v1/mdmDevices/{id}/details": [
            "fields[mdmDeviceDetails]": [
                "serialNumber", "deviceName", "deviceModel", "osVersion", "platform", "imei", "meid", "wifiMacAddress", "bluetoothMacAddress",
                "ethernetMacAddress", "lastCheckInDateTime", "isFirewallEnabled", "isFileVaultEnabled", "storageFreeCapacity", "storageTotalCapacity",
                "deviceLockStatus", "deviceEraseStatus", "lostModeStatus"
            ],
        ],
        "/v1/mdmServers": [
            "fields[mdmServers]": [
                "serverName", "enableMdmDisownFlag", "defaultProductFamilies", "status", "serverType", "deviceCount", "lastConnectedDateTime",
                "lastConnectedIp", "createdDateTime", "updatedDateTime", "devices"
            ],
            "limit": nil,
        ],
        "/v1/mdmServers/{id}": [
            "fields[mdmServers]": [
                "serverName", "enableMdmDisownFlag", "defaultProductFamilies", "status", "serverType", "deviceCount", "lastConnectedDateTime",
                "lastConnectedIp", "createdDateTime", "updatedDateTime", "devices"
            ],
        ],
        "/v1/mdmServers/{id}/relationships/devices": [
            "limit": nil,
        ],
        "/v1/orgDeviceActivities/{id}": [
            "fields[orgDeviceActivities]": ["status", "subStatus", "createdDateTime", "completedDateTime", "downloadUrl"],
        ],
        "/v1/orgDevices": [
            "fields[orgDevices]": [
                "serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel", "productFamily", "productType",
                "deviceCapacity", "partNumber", "orderNumber", "color", "status", "orderDateTime", "imei", "meid", "eid", "purchaseSourceId",
                "purchaseSourceType", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress", "assignedServer", "appleCareCoverage"
            ],
            "limit": nil,
        ],
        "/v1/orgDevices/{id}": [
            "fields[orgDevices]": [
                "serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel", "productFamily", "productType",
                "deviceCapacity", "partNumber", "orderNumber", "color", "status", "orderDateTime", "imei", "meid", "eid", "purchaseSourceId",
                "purchaseSourceType", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress", "assignedServer", "appleCareCoverage"
            ],
        ],
        "/v1/orgDevices/{id}/activationLockStatus": [
            "fields[activationLockStatus]": ["isLocked", "lockType"],
        ],
        "/v1/orgDevices/{id}/appleCareCoverage": [
            "fields[appleCareCoverage]": [
                "status", "paymentType", "description", "agreementNumber", "startDateTime", "endDateTime", "isRenewable", "isCanceled",
                "contractCancelDateTime"
            ],
            "limit": nil,
        ],
        "/v1/orgDevices/{id}/assignedServer": [
            "fields[mdmServers]": ["serverName", "serverType", "createdDateTime", "updatedDateTime", "devices"],
        ],
        "/v1/orgDevices/{id}/relationships/assignedServer": [:],
        "/v1/organizationalUnits": [
            "fields[organizationalUnits]": ["name", "description", "createdDateTime", "updatedDateTime", "users"],
            "limit": nil,
        ],
        "/v1/organizationalUnits/{id}": [
            "fields[organizationalUnits]": ["name", "description", "createdDateTime", "updatedDateTime", "users"],
        ],
        "/v1/organizationalUnits/{id}/relationships/users": [
            "limit": nil,
        ],
        "/v1/packages": [
            "fields[packages]": ["name", "url", "hash", "bundleIds", "description", "version", "createdDateTime", "updatedDateTime"],
            "limit": nil,
        ],
        "/v1/packages/{id}": [
            "fields[packages]": ["name", "url", "hash", "bundleIds", "description", "version", "createdDateTime", "updatedDateTime"],
        ],
        "/v1/userGroups": [
            "fields[userGroups]": ["ouId", "name", "type", "totalMemberCount", "createdDateTime", "updatedDateTime", "status", "users"],
            "limit": nil,
        ],
        "/v1/userGroups/{id}": [
            "fields[userGroups]": ["ouId", "name", "type", "totalMemberCount", "createdDateTime", "updatedDateTime", "status", "users"],
        ],
        "/v1/userGroups/{id}/relationships/users": [
            "limit": nil,
        ],
        "/v1/users": [
            "fields[users]": [
                "firstName", "lastName", "middleName", "status", "managedAppleAccount", "isExternalUser", "roleOuList", "email", "employeeNumber",
                "costCenter", "division", "department", "jobTitle", "startDateTime", "createdDateTime", "updatedDateTime", "phoneNumbers"
            ],
            "limit": nil,
        ],
        "/v1/users/{id}": [
            "fields[users]": [
                "firstName", "lastName", "middleName", "status", "managedAppleAccount", "isExternalUser", "roleOuList", "email", "employeeNumber",
                "costCenter", "division", "department", "jobTitle", "startDateTime", "createdDateTime", "updatedDateTime", "phoneNumbers"
            ],
        ],
    ]

    /// The endpoints whose answer is a page (`PagedDocumentLinks`): they take the `cursor` Apple's own next link carries,
    /// documented or not (only `auditEvents` documents it).
    public static let paged: Set = [
        "/v1/apps", "/v1/auditEvents", "/v1/blueprints", "/v1/blueprints/{id}/relationships/apps", "/v1/blueprints/{id}/relationships/configurations",
        "/v1/blueprints/{id}/relationships/orgDevices", "/v1/blueprints/{id}/relationships/packages", "/v1/blueprints/{id}/relationships/userGroups",
        "/v1/blueprints/{id}/relationships/users", "/v1/configurations", "/v1/mdmDevices", "/v1/mdmServers", "/v1/mdmServers/{id}/relationships/devices",
        "/v1/orgDevices", "/v1/orgDevices/{id}/appleCareCoverage", "/v1/organizationalUnits", "/v1/organizationalUnits/{id}/relationships/users",
        "/v1/packages", "/v1/userGroups", "/v1/userGroups/{id}/relationships/users", "/v1/users",
    ]

    /// A query Apple would refuse with 400: a parameter the endpoint doesn't document, a `limit` outside 1 to 1000, or a
    /// value outside a listed set (an empty one included: `include=` and `apps,,users` aren't lists of names).
    private static func check(_ query: [String: String], template: String) -> (Int, [String: String], Data)? {
        let documented = parameters[template] ?? [:]
        let allowed = Set(documented.keys).union(paged.contains(template) ? ["cursor"] : [])
        if let unknown = query.keys.sorted().first(where: { !allowed.contains($0) }) {
            return error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "\(unknown) isn't a parameter of this endpoint.", parameter: unknown)
        }
        for (name, value) in query.sorted(by: { $0.key < $1.key }) where name == "limit" || name.hasPrefix("limit[") {
            guard let number = Int(value), (1...1000).contains(number) else {
                return error(400, "PARAMETER_ERROR.INVALID", "A parameter has an invalid value", "\(name) must be 1 to 1000.", parameter: name)
            }
        }
        for (name, given) in query.sorted(by: { $0.key < $1.key }) {
            guard let values = documented[name] ?? nil,
                  let bad = given.split(separator: ",", omittingEmptySubsequences: false).map(String.init).first(where: { !values.contains($0) })
            else { continue }
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
#endif
