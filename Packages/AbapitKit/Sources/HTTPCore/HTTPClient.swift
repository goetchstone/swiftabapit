import Foundation
import os
import Wire

/// What authenticates a request: Apple's `TokenBroker`, Mosyle's session. Headers are added at send time
/// and never stored with the request (a held write's digest excludes them, plan §3.8).
public protocol Authorizer: Sendable {
    func headers(for host: APIHost) async throws -> [String: String]
    /// A 401 for a request sent with `rejected`: drop the cached credential if it is still that one, so the next
    /// `headers` mints a fresh one. A late 401 for an older token must not throw away a newer one (Phase 1a's
    /// review: one expiry minted three tokens).
    func invalidate(rejected: [String: String]) async
}

/// An HTTP answer, whatever its status: each API's client classifies it.
public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// A login's answer holds the JWT in a header (and sometimes its body), and a list's body is tenant data: printing,
/// `dump` and a `Mirror` show the status, the header names and the body's size only (Phase 7a review L6).
extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "HTTPResponse(\(status), headers: \(headers.keys.sorted()), body: \(body.count) bytes, redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["status": status, "headers": headers.keys.sorted(), "body": "\(body.count) bytes"], displayStyle: .struct)
    }
}

/// The reads and credential exchanges of one org (plan §3.3). Writes arrive in Phase 4, through
/// `send(_:ticket:)`, which only ChangeCore's executor can call.
///
/// - Reads retry transport failures up to 4 times with backoff; a 429 waits for `Retry-After` (seconds or
///   an HTTP date, at most 60 s) or backs off exponentially, and halves the limiter's rate; a `Retry-After`
///   also holds the limiter's read lane that long, for every read waiting on it; a 401 drops the
///   token and retries once. Any other status is returned as is.
/// - A credential exchange is never retried, but on a 429 the limiter learns.
public actor HTTPClient {
    public static let bodyLimit = 32 * 1024 * 1024
    public static let attempts = 5
    public static let longestWait: Duration = .seconds(60)

    /// A read as it will be sent (invariant 2): Apple's are GETs with no body; Mosyle's are POSTs with a body and no
    /// query (its session checks the operation); the token host takes no read. Checked as each request leaves, because
    /// a builder scan can't see every way a request is made (failure-log 2026-11-18).
    /// What a refusal may say of a request's path: its template, or, when it has none (the template is then the raw path,
    /// which can hold an identifier), only that it has none.
    static func nameable(_ request: ReadRequest) -> String {
        request.template == request.path ? "a path with no template" : request.template
    }

    static func isReadShaped(_ request: ReadRequest) -> Bool {
        switch request.host {
        case .appleBusiness, .appleSchool: request.method == .get && request.body == nil
        case .mosyle, .mosyleLogs: request.method == .post && request.body != nil && request.query.isEmpty
        case .appleAccount: false
        }
    }

    /// The only credential exchanges: Apple's token request and Mosyle's two logins. Unlabelled pairs, because
    /// `RouteTests` counts the argument lists in this file that open with a host label.
    static let logins: [(APIHost, String)] = [(.appleAccount, "/auth/oauth2/token"), (.mosyle, "/v1/login"), (.mosyleLogs, "/v1/login")]

    private let transport: any Transport
    private let limiter: RateLimiter
    private let bodyLimit: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clock: @Sendable () -> Date
    private static let log = Logger(subsystem: "io.github.goetchstone.swiftabapit", category: "http")

    public init(transport: any Transport, limiter: RateLimiter, bodyLimit: Int = HTTPClient.bodyLimit,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.limiter = limiter
        self.bodyLimit = bodyLimit
        self.sleep = sleep
        self.clock = clock
    }

    public var learnedReadsPerMinute: Double { get async { await limiter.readsPerMinute } }

    package func read(_ request: ReadRequest, authorizer: any Authorizer) async throws -> HTTPResponse {
        guard Self.isReadShaped(request) else { throw HTTPFailure.notARead("\(request.method.rawValue) \(request.host.rawValue) \(Self.nameable(request))") }
        guard let url = URL.make(host: request.host, path: request.path, query: request.query) else {
            throw HTTPFailure.refusedHost(request.host.rawValue)
        }
        return try await read(url: url, host: request.host, method: request.method, template: request.template,
                              body: request.body, authorizer: authorizer)
    }

    /// Whether `url` stays in the API: on `host`, under `/v1/`. The rule for a next link. A dot segment in any spelling
    /// (`..`, `%2e%2E`, `.%2e`) or a bad escape is refused: decoded, it would climb out of `/v1/`. So is a segment with a `;`
    /// (a path parameter): some servers strip it, so `/v1/..;/v2` would climb out there.
    static func staysInTheAPI(_ url: URL, on host: APIHost) -> Bool {
        let path = url.path(percentEncoded: true)
        return APIHost(of: url) == host && path.hasPrefix("/v1/")
            && !path.split(separator: "/").contains(where: { segment in
                guard let decoded = String(segment).removingPercentEncoding else { return true }
                return decoded == "." || decoded == ".." || decoded.contains("/") || decoded.contains(";")
            })
    }

    /// A next-page link Apple returned: followed only when it stays on `host`, under `/v1/`.
    package func read(next url: URL, on host: APIHost, template: String, keeping limit: String? = nil,
                      authorizer: any Authorizer) async throws -> HTTPResponse {
        guard host == .appleBusiness || host == .appleSchool else { throw HTTPFailure.notARead("GET \(host.rawValue) \(template)") }
        guard Self.staysInTheAPI(url, on: host) else { throw HTTPFailure.refusedHost(url.host(percentEncoded: false) ?? "?") }
        var target = url
        // Apple's example next link carries only `cursor`; asked once for 1000 a page, keep asking for 1000, or the
        // page cap would cover a tenth of the fleet (Phase 1a's review). Check live.
        if let limit, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           !(components.queryItems ?? []).contains(where: { $0.name == "limit" }) {
            // Apple's query goes out byte for byte: `queryItems` decodes and re-encodes it, and `%2B` went out as `+`
            // (failure-log 2026-11-28). This setter traps on a value that isn't percent-encoded, so `limit` is encoded first.
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? [])
                + [URLQueryItem(name: "limit", value: limit.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")]
            target = components.url ?? url
        }
        return try await read(url: target, host: host, method: .get, template: template, body: nil, authorizer: authorizer)
    }

    private func read(url: URL, host: APIHost, method: HTTPMethod, template: String, body: Data?, authorizer: any Authorizer) async throws -> HTTPResponse {
        var refreshed = false
        var attempt = 0
        while true {
            try await limiter.acquire(.read)
            var request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let credentials = try await authorizer.headers(for: host)
            for (name, value) in credentials { request.setValue(value, forHTTPHeaderField: name) }
            let started = ContinuousClock.now
            let response: HTTPResponse
            do {
                response = try await exchange(request)
            } catch let failure as HTTPFailure where failure != .transport(code: URLError.cancelled.rawValue) {
                if case .transport = failure, attempt < Self.attempts - 1 {
                    attempt += 1
                    Self.log.info("\(method.rawValue, privacy: .public) \(host.rawValue, privacy: .public) \(template, privacy: .public): transport failure, retry \(attempt)")
                    try await sleep(.milliseconds(500 * attempt))
                    continue
                }
                throw failure
            }
            Self.log.info("\(method.rawValue, privacy: .public) \(host.rawValue, privacy: .public) \(template, privacy: .public) -> \(response.status) (\((ContinuousClock.now - started).components.seconds * 1000 + (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000) ms)")
            if response.status == 401, !refreshed {
                refreshed = true
                await authorizer.invalidate(rejected: credentials)
                continue
            }
            if response.status == 429 {
                // The server's `Retry-After` holds the lane, so the other reads in flight (a sweep's) wait it out too.
                await limiter.throttled(.read, retryAfter: Self.retryAfter(response, now: clock()))
                if attempt < Self.attempts - 1 {
                    attempt += 1
                    try await sleep(Self.wait(after: response, attempt: attempt, now: clock()))
                    continue
                }
                return response
            }
            if response.isSuccess { await limiter.succeeded(.read) }
            return response
        }
    }

    /// Apple's token request or Mosyle's `/login`: sent once, never retried (a credential exchange is
    /// rate-limited itself; plan §3.4.3). The body and the response are secrets; nothing of either is logged.
    package func authenticate(_ exchange: AuthRequest) async throws -> HTTPResponse {
        // A login goes to a login endpoint and carries no header but Mosyle's access token: anything else would be a
        // POST of any body, with any credential, past the read check above and the Executor.
        guard Self.logins.contains(where: { $0.0 == exchange.host && $0.1 == exchange.path }),
              exchange.headers.keys.allSatisfy({ $0 == "accessToken" && (exchange.host == .mosyle || exchange.host == .mosyleLogs) }) else {
            throw HTTPFailure.notARead("POST \(exchange.host.rawValue) \(exchange.path)")
        }
        guard let url = URL.make(host: exchange.host, path: exchange.path) else { throw HTTPFailure.refusedHost(exchange.host.rawValue) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = exchange.body
        request.setValue(exchange.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in exchange.headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await self.exchange(request)
        Self.log.info("POST \(exchange.host.rawValue, privacy: .public) \(exchange.path, privacy: .public) -> \(response.status)")
        if response.status == 429 { await limiter.throttled(.read) }
        return response
    }

    private func exchange(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url, APIHost(of: url) != nil else { throw HTTPFailure.refusedHost(request.url?.host() ?? "?") }
        do {
            let (body, http) = try await transport.send(request, limit: bodyLimit)
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: body)
        } catch let failure as HTTPFailure {
            throw failure
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HTTPFailure.transport(code: error.code.rawValue)
        }
    }

    /// `Retry-After` in seconds or as an HTTP date, else 2^attempt seconds; never more than 60 s (plan §3.3).
    static func wait(after response: HTTPResponse, attempt: Int, now: Date) -> Duration {
        retryAfter(response, now: now) ?? min(.seconds(1 << min(attempt, 6)), longestWait)
    }

    /// The response's `Retry-After`, in seconds or as an HTTP date, never more than 60 s; nil when it has none this reads.
    static func retryAfter(_ response: HTTPResponse, now: Date) -> Duration? {
        guard let value = response.headers["retry-after"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        let ceiling = Double(longestWait.components.seconds)
        // Clamped as a number first: `Duration.seconds` traps past about 1.7e20 (Phase 1a's review).
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return .seconds(min(seconds, ceiling)) }
        if let date = httpDate(value) {
            let wait = date.timeIntervalSince(now)
            return .seconds(wait.isFinite ? min(max(wait, 0), ceiling) : ceiling)
        }
        return nil
    }

    /// RFC 9110's IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`).
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: text)
    }
}
