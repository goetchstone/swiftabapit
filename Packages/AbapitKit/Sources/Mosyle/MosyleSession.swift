import Foundation
import HTTPCore
import JSONAPI
import MosyleModels
import Vault
import Wire

/// One Mosyle org's login (plan §3.5): `POST /v1/login` with the access token in the `accessToken` header and
/// the admin's email and password in the body; the JWT comes back in the response's `Authorization` header.
/// Single-flight, memory only, re-logged once on a 401. The JWT's own `exp` sets its life (else 23 h; Mosyle's
/// `Expires` header is PHP's fixed 1981 date and is ignored), renewed 60 s early or halfway through a shorter life.
/// The Logs Stream is a second service with its own token and login on its own host.
public actor MosyleSession: Authorizer {
    public enum Service: Sendable {
        case business, logs

        var host: APIHost { self == .business ? .mosyle : .mosyleLogs }
        var tokenKind: VaultItem.Kind { self == .business ? .mosyleAccessToken : .mosyleLogsToken }
    }

    public static let fallbackLifetime: Duration = .seconds(23 * 3600)
    public static let refreshEarly: Duration = .seconds(60)

    /// How long before its end a JWT that lives `lifetime` is renewed: 60 s, or half a shorter life. A flat 60 s
    /// renewed a 45 s JWT on every read (Phase 7a review M2: 5 pings, 5 logins).
    static func margin(for lifetime: Duration) -> Duration { min(refreshEarly, lifetime / 2) }

    public let org: String
    public let service: Service
    private let vault: Vault
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// The access token and the JWT it was exchanged for, together: both memory only, both dropped on a 401.
    private var session: (token: Secret, jwt: Secret, renew: ContinuousClock.Instant)?
    private var minting: Task<(Secret, Secret, ContinuousClock.Instant), any Error>?
    public private(set) var logins = 0

    public init(org: String, service: Service, vault: Vault, http: HTTPClient, now: @escaping @Sendable () -> Date = { Date() },
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.org = org
        self.service = service
        self.vault = vault
        self.http = http
        self.now = now
        self.clock = clock
    }

    public func headers(for host: APIHost) async throws -> [String: String] {
        guard host == service.host else { throw MosyleAPIError.wrongHost(host.rawValue) }
        let (token, jwt) = try await current()
        return ["accessToken": String(decoding: token.bytes, as: UTF8.self), "Authorization": "Bearer " + String(decoding: jwt.bytes, as: UTF8.self)]
    }

    /// Drops the session only if the refused request carried its JWT: a late 401 for an older one keeps the new
    /// login (Phase 1a's review: one expiry minted three tokens).
    public func invalidate(rejected: [String: String]) {
        guard let session, rejected["Authorization"] == "Bearer " + String(decoding: session.jwt.bytes, as: UTF8.self) else { return }
        self.session = nil
    }

    private func current() async throws -> (Secret, Secret) {
        if let session, clock() < session.renew { return (session.token, session.jwt) }
        if let minting { let made = try await minting.value; return (made.0, made.1) }
        let task = Task { try await self.login() }
        minting = task
        defer { minting = nil }
        let made = try await task.value
        session = made
        return (made.0, made.1)
    }

    private func login() async throws -> (Secret, Secret, ContinuousClock.Instant) {
        logins += 1
        func item(_ kind: VaultItem.Kind) throws -> VaultItem {
            guard let item = VaultItem(org: org, kind: kind) else { throw MosyleAPIError.vault("This organization's id can't hold secrets.") }
            return item
        }
        let token: Secret, email: Secret, password: Secret
        do {
            token = try await vault.secret(item(service.tokenKind))
            email = try await vault.secret(item(.mosyleEmail))
            password = try await vault.secret(item(.mosylePassword))
        } catch let error as VaultError {
            throw MosyleAPIError.vault(error.guidance)
        }
        let body: JSONObject = ["email": .string(String(decoding: email.bytes, as: UTF8.self)),
                                "password": .string(String(decoding: password.bytes, as: UTF8.self))]
        let started = clock()
        let response = try await http.authenticate(AuthRequest(host: service.host, path: "/v1/login", contentType: "application/json",
                                                               headers: ["accessToken": String(decoding: token.bytes, as: UTF8.self)],
                                                               body: Data(JSONValue.dumps(.object(body)).utf8)))
        // A refused login is about the credentials; a 429 or a 5xx isn't, and must not send the operator to re-enter
        // them (Phase 7a review M2). A login is never retried (plan §3.4.3).
        switch response.status {
        case 200..<300: break
        case 429: throw MosyleAPIError.rateLimited
        case 500...599: throw MosyleAPIError.server(status: response.status)
        default: throw MosyleAPIError.login(status: response.status)
        }
        guard let jwt = Self.bearer(response) else { throw MosyleAPIError.noToken }
        let lifetime = Self.lifetime(of: jwt, now: now())
        return (token, Secret(jwt), started.advanced(by: lifetime - Self.margin(for: lifetime)))
    }

    /// The JWT from the `Authorization` header (`Bearer x` or bare), else from the body as abapit tolerated.
    static func bearer(_ response: HTTPResponse) -> String? {
        // `Bearer ` with nothing after it is no token, not the token "Bearer".
        func strip(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "bearer" { return nil }
            let token = trimmed.lowercased().hasPrefix("bearer ") ? String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces) : trimmed
            return token.isEmpty || token.contains(" ") ? nil : token
        }
        if let header = response.headers["authorization"], let token = strip(header) { return token }
        let body = JSONValue.parse(String(decoding: response.body, as: UTF8.self))
        return (body?["Authorization"]?.string ?? body?["token"]?.string).flatMap(strip)
    }

    /// From the JWT's `exp` claim, never past the fallback; the fallback when there is none or it can't be read. An
    /// `exp` at or before now is read as unreadable: Mosyle just issued this JWT, so the claim is stale or this Mac's
    /// clock runs ahead, and a zero life logged in again for every read (Phase 7a review M2: 7 reads, 7 logins). If
    /// the JWT really has expired, Mosyle's 401 brings one fresh login.
    static func lifetime(of jwt: String, now: Date) -> Duration {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
              let exp = JSONValue.parse(String(decoding: payload, as: UTF8.self))?["exp"]?.double else { return fallbackLifetime }
        // Clamped as a number first: `Duration.seconds` traps past about 1.7e20 (Phase 1a's review H1).
        let remaining = exp - now.timeIntervalSince1970
        guard remaining.isFinite, remaining > 0 else { return fallbackLifetime }
        return .seconds(min(remaining, Double(fallbackLifetime.components.seconds)))
    }
}

/// A Mosyle failure: an HTTP status, or Mosyle's own status inside an HTTP 200 (plan §3.5; defect 3).
public enum MosyleAPIError: Error, Equatable, Sendable {
    case unauthorized
    /// A 403. Not logged in again: abapit re-logged on 403 as on 401, but plan §3.5 re-logs on 401 only, and a fresh
    /// login can't lift a permission or an IP restriction (Phase 7a review L5; check live what Mosyle's 403 means).
    case forbidden
    case login(status: Int)
    case noToken
    case invalidMethod
    case status(OpenEnum<MosyleStatus>, info: String?)
    /// An HTTP 200 that isn't an answer Mosyle sends (Phase 7a review H2), with what is wrong with it.
    case malformed(String)
    /// A request that isn't on `MosyleRead.allowed` as it would be sent, refused before it left (review M4).
    case notARead(String)
    case rateLimited
    case server(status: Int)
    case unexpected(status: Int)
    case notJSON(bytes: Int)
    case http(HTTPFailure)
    case vault(String)
    case wrongHost(String)

    public var message: String {
        switch self {
        case .unauthorized:
            "Mosyle refused this organization's credentials, even after a fresh login. If the access token is restricted to "
                + "certain IP addresses, this Mac's may not be one."
        case .forbidden:
            "Mosyle refused this read (HTTP 403). The admin account or the access token may not be allowed it, or the token "
                + "may be restricted to other IP addresses."
        case .login(let status): "Mosyle's login refused the email, password or access token (HTTP \(status))."
        case .noToken: "Mosyle's login answered without a token."
        case .invalidMethod: "Mosyle refused the request's method (INVALID_METHOD)."
        case .status(let status, let info): "Mosyle answered \(status.rawValue)\(info.map { ": \($0)" } ?? ".")"
        case .malformed(let reason): "Mosyle's answer couldn't be read as a list: \(reason). Nothing was read from it."
        case .notARead(let template): "\(template) isn't a Mosyle read this app may send, so it wasn't sent."
        case .rateLimited: "Mosyle is rate-limiting this organization. Try again in a minute."
        case .server(let status): "Mosyle's service failed (HTTP \(status)). Try again later."
        case .unexpected(let status): "Mosyle answered HTTP \(status), which this app doesn't expect."
        case .notJSON(let bytes): "Mosyle's answer wasn't readable (\(bytes) bytes that aren't JSON)."
        case .http(let failure): failure.message
        case .vault(let guidance): guidance
        case .wrongHost(let host): "A request for \(host) was refused: it isn't this organization's Mosyle service."
        }
    }
}
