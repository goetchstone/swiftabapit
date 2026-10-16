import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Vault
import Wire

/// One org's bearer token (plan §3.4.3): minted on demand, kept in memory only, refreshed 60 s before it
/// ends, dropped on a 401, and single-flight — concurrent requests share one mint, because the token
/// endpoint rate-limits too. Never printed, never on disk (defect 9: abapit's `tokens.json`).
public actor TokenBroker: Authorizer {
    public struct Account: Sendable, Equatable {
        public let org: String
        public let scope: Scope
        public let clientID: String
        public let keyID: String
        public let teamID: String

        public init(org: String, scope: Scope, clientID: String, keyID: String, teamID: String) {
            self.org = org
            self.scope = scope
            self.clientID = clientID
            self.keyID = keyID
            self.teamID = teamID
        }

        /// The account an Apple org's profile names; nil when the profile isn't usable.
        public init?(_ profile: OrgProfile) {
            guard profile.provider == .known(.apple), profile.problem == nil, let scope = profile.scope.known else { return nil }
            self.init(org: profile.id, scope: scope, clientID: profile.clientID, keyID: profile.keyID, teamID: profile.teamID)
        }

        public var host: APIHost { scope == .business ? .appleBusiness : .appleSchool }
        public var tokenScope: String { scope == .business ? "business.api" : "school.api" }
    }

    public static let tokenPath = "/auth/oauth2/token"
    public static let refreshEarly: Duration = .seconds(60)

    public let account: Account
    private let vault: Vault
    private let http: HTTPClient
    private let now: @Sendable () -> Date
    private let clock: @Sendable () -> ContinuousClock.Instant
    private var token: (value: Secret, expires: ContinuousClock.Instant)?
    private var minting: Task<Secret, any Error>?
    /// Mints so far: what the tests count.
    public private(set) var mints = 0

    public init(account: Account, vault: Vault, http: HTTPClient, now: @escaping @Sendable () -> Date = { Date() },
                clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.account = account
        self.vault = vault
        self.http = http
        self.now = now
        self.clock = clock
    }

    public func headers(for host: APIHost) async throws -> [String: String] {
        guard host == account.host else { throw AppleAPIError.wrongHost(host.rawValue) }
        let bearer = try await current()
        return ["Authorization": "Bearer " + String(decoding: bearer.bytes, as: UTF8.self)]
    }

    /// Drops the token only if the rejected request carried it: a late 401 for an older token keeps the new one.
    public func invalidate(rejected: [String: String]) {
        guard let token, rejected["Authorization"] == "Bearer " + String(decoding: token.value.bytes, as: UTF8.self) else { return }
        self.token = nil
    }

    private func current() async throws -> Secret {
        if let token, clock() < token.expires.advanced(by: .zero - Self.refreshEarly) { return token.value }
        if let minting { return try await minting.value }
        let task = Task { try await self.mint() }
        minting = task
        defer { minting = nil }
        return try await task.value
    }

    private func mint() async throws -> Secret {
        mints += 1
        guard let key = VaultItem(org: account.org, kind: .appleKey) else { throw AppleAPIError.token(.notConfigured) }
        let claims = ClientAssertion.Claims(clientID: account.clientID, keyID: account.keyID, teamID: account.teamID, now: now())
        let assertion = try await ClientAssertion.sign(claims, with: key, vault: vault)
        let form: [(String, String)] = [
            ("grant_type", "client_credentials"), ("client_id", account.clientID),
            ("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            ("client_assertion", String(decoding: assertion.bytes, as: UTF8.self)), ("scope", account.tokenScope),
        ]
        // The form goes in the body, never the query string (Apple's curl example puts it in the URL; plan §3.4.3).
        let body = Data(form.map { "\(Self.formEncode($0.0))=\(Self.formEncode($0.1))" }.joined(separator: "&").utf8)
        let started = clock()
        let response = try await http.authenticate(AuthRequest(host: .appleAccount, path: Self.tokenPath,
                                                               contentType: "application/x-www-form-urlencoded", body: body))
        guard response.isSuccess else { throw AppleAPIError.token(TokenFailure(response)) }
        guard let object = JSONValue.parse(String(decoding: response.body, as: UTF8.self))?.object,
              let value = object["access_token"]?.string, !value.isEmpty else { throw AppleAPIError.token(.malformed) }
        let seconds = max(object["expires_in"]?.int ?? 3600, 120)
        let secret = Secret(value)
        token = (secret, started.advanced(by: .seconds(seconds)))
        return secret
    }

    /// `application/x-www-form-urlencoded`: everything but the unreserved characters percent-encoded.
    static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
}

/// Why a token couldn't be minted, from the OAuth `error` code, never the body's prose.
public enum TokenFailure: Error, Equatable, Sendable {
    case notConfigured
    case invalidClient
    case invalidRequest
    case unauthorizedClient
    case invalidScope
    case rateLimited
    case malformed
    case status(Int, String?)

    init(_ response: HTTPResponse) {
        let code = JSONValue.parse(String(decoding: response.body, as: UTF8.self))?["error"]?.string
        switch (response.status, code) {
        case (429, _): self = .rateLimited
        case (_, "invalid_client"): self = .invalidClient
        case (_, "invalid_request"): self = .invalidRequest
        case (_, "unauthorized_client"): self = .unauthorizedClient
        case (_, "invalid_scope"): self = .invalidScope
        default: self = .status(response.status, code.map { String($0.prefix(64)) })
        }
    }

    public var message: String {
        switch self {
        case .notConfigured: "This organization's API account isn't set up: add its key in Settings."
        case .invalidClient:
            "Apple refused the API account (invalid_client): check the client ID, the key ID and that the key is the one Apple generated for it."
        case .invalidRequest: "Apple refused the token request as malformed (invalid_request)."
        case .unauthorizedClient: "Apple says this API account may not use this scope (unauthorized_client)."
        case .invalidScope: "Apple refused the scope: an Apple School Manager account can't use the Apple Business API, and the other way round."
        case .rateLimited: "Apple's token service is rate-limiting this account (HTTP 429). Wait a minute and try again."
        case .malformed: "Apple's token service answered without a token."
        case .status(let status, let code): "Apple's token service answered HTTP \(status)\(code.map { " (\($0))" } ?? "")."
        }
    }
}
