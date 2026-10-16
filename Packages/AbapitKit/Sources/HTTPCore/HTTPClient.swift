import Foundation
import os
import Wire

/// What authenticates a request: Apple's `TokenBroker`, Mosyle's session. Headers are added at send time
/// and never stored with the request (a held write's digest excludes them, plan §3.8).
public protocol Authorizer: Sendable {
    func headers(for host: APIHost) async throws -> [String: String]
    /// A 401: drop the cached token, so the next `headers` mints a fresh one.
    func invalidate() async
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

/// The reads and credential exchanges of one org (plan §3.3). Writes arrive in Phase 4, through
/// `send(_:ticket:)`, which only ChangeCore's executor can call.
///
/// - Reads retry transport failures up to 4 times with backoff; a 429 waits for `Retry-After` (seconds or
///   an HTTP date, at most 60 s) or backs off exponentially, and halves the limiter's rate; a 401 drops the
///   token and retries once. Any other status is returned as is.
/// - A credential exchange is never retried, but on a 429 the limiter learns.
public actor HTTPClient {
    public static let bodyLimit = 32 * 1024 * 1024
    public static let attempts = 5
    public static let longestWait: Duration = .seconds(60)

    private let transport: any Transport
    private let limiter: RateLimiter
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clock: @Sendable () -> Date
    private static let log = Logger(subsystem: "io.github.goetchstone.swiftabapit", category: "http")

    public init(transport: any Transport, limiter: RateLimiter,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.limiter = limiter
        self.sleep = sleep
        self.clock = clock
    }

    public var learnedReadsPerMinute: Double { get async { await limiter.readsPerMinute } }

    package func read(_ request: ReadRequest, authorizer: any Authorizer) async throws -> HTTPResponse {
        guard let url = URL.make(host: request.host, path: request.path, query: request.query) else {
            throw HTTPFailure.refusedHost(request.host.rawValue)
        }
        return try await read(url: url, host: request.host, method: request.method, template: request.template,
                              body: request.body, authorizer: authorizer)
    }

    /// A next-page link Apple returned: followed only when it stays on `host`, under `/v1/`.
    package func read(next url: URL, on host: APIHost, template: String, authorizer: any Authorizer) async throws -> HTTPResponse {
        guard APIHost(of: url) == host, url.path(percentEncoded: true).hasPrefix("/v1/") else {
            throw HTTPFailure.refusedHost(url.host(percentEncoded: false) ?? "?")
        }
        return try await read(url: url, host: host, method: .get, template: template, body: nil, authorizer: authorizer)
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
            for (name, value) in try await authorizer.headers(for: host) { request.setValue(value, forHTTPHeaderField: name) }
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
                await authorizer.invalidate()
                continue
            }
            if response.status == 429 {
                await limiter.throttled(.read)
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
            let (body, http) = try await transport.send(request, limit: Self.bodyLimit)
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
        if let value = response.headers["retry-after"]?.trimmingCharacters(in: .whitespaces) {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return min(.seconds(seconds), longestWait) }
            if let date = httpDate(value) { return min(.seconds(max(date.timeIntervalSince(now), 0)), longestWait) }
        }
        return min(.seconds(1 << min(attempt, 6)), longestWait)
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
