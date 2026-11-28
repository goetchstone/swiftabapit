import Foundation
import Wire

/// What carries a request: `URLSessionTransport` in the app, a strict stub in tests (`TestSupport`). This is
/// the only file that names `URLSession` (`SourceScanTests`).
public protocol Transport: Sendable {
    /// The response, its body capped at `limit` bytes. A redirect is followed only for a GET, to the same allowlisted
    /// host, under `/v1/`; a response that isn't HTTP is a transport failure.
    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse)
}

/// One ephemeral session per org (plan §3.3): no cookies (Mosyle sets `PHPSESSID`), no URL cache, no
/// credential storage, TLS 1.2 at least. HTTP/2 is negotiated by URLSession on its own.
public final class URLSessionTransport: NSObject, Transport, URLSessionTaskDelegate {
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        // The allowlist holds here too, before a connection: `HTTPClient` checks it first, and is this method's only
        // caller by a source scan, not by a type (invariant 4; failure-log 2026-11-28).
        guard let url = request.url, APIHost(of: url) != nil else { throw HTTPFailure.refusedHost(request.url?.host() ?? "?") }
        let (bytes, response) = try await session.bytes(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(limit) { throw HTTPFailure.tooLarge(limit: limit) }
        var body = Data()
        body.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(limit))))
        for try await byte in bytes {
            guard body.count < limit else { throw HTTPFailure.tooLarge(limit: limit) }
            body.append(byte)
        }
        return (body, http)
    }

    /// A redirect is followed only for a GET, within the same allowlisted host, to where a next link may go: the API
    /// hosts don't redirect, and one that did could otherwise carry the bearer token elsewhere (invariant 4) or, on a
    /// 307 or 308, replay a POST's body to a path nothing previewed. The completion-handler form:
    /// Swift 6.4 crashes emitting the async form's Objective-C thunk (docs/domains/http-core.md).
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let original = task.originalRequest
        completionHandler(Self.followable(method: original?.httpMethod, from: original?.url, to: request.url) ? request : nil)
    }

    static func followable(method: String?, from original: URL?, to target: URL?) -> Bool {
        guard method == HTTPMethod.get.rawValue, let original, let target, let host = APIHost(of: original) else { return false }
        return HTTPClient.staysInTheAPI(target, on: host)
    }
}
