import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
}

/// One query parameter, in order: Apple's bracketed names (`fields[orgDevices]`, `filter[startTimestamp]`)
/// are encoded when the URL is built.
public struct QueryItem: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A read: a request that changes nothing on the tenant (invariant 2). Apple's are GETs; Mosyle's are
/// POSTs whose `(path, operation)` is on the read allowlist. Only the read builders make one (`package`
/// init), so a screen can't send an arbitrary request.
public struct ReadRequest: Sendable, Equatable {
    public let host: APIHost
    public let method: HTTPMethod
    /// `/v1/orgDevices/C02X…`.
    public let path: String
    /// `/v1/orgDevices/{id}`: what the log says, never an identifier.
    public let template: String
    public let query: [QueryItem]
    /// A Mosyle read's JSON body.
    public let body: Data?

    package init(host: APIHost, method: HTTPMethod = .get, path: String, template: String? = nil, query: [QueryItem] = [], body: Data? = nil) {
        self.host = host
        self.method = method
        self.path = path
        self.template = template ?? path
        self.query = query
        self.body = body
    }

    /// The same read with one query parameter replaced (a cursor), or added.
    package func setting(_ name: String, to value: String) -> ReadRequest {
        var items = query.filter { $0.name != name }
        items.append(QueryItem(name, value))
        return ReadRequest(host: host, method: method, path: path, template: template, query: items, body: body)
    }
}

/// A credential exchange: Apple's token request, Mosyle's `/login`. Not a read and not a write: it changes
/// nothing on the tenant, but it carries a secret, so only `TokenBroker` and `MosyleSession` make one.
public struct AuthRequest: Sendable {
    public let host: APIHost
    public let path: String
    public let contentType: String
    public let headers: [String: String]
    package let body: Data

    package init(host: APIHost, path: String, contentType: String, headers: [String: String] = [:], body: Data) {
        self.host = host
        self.path = path
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }
}

/// The access token rides in `headers` and the email and password in `body`: printing, `dump` and a `Mirror` show
/// the header names only, as `Secret` shows nothing (Phase 7a review L6).
extension AuthRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "credential exchange: POST \(host.rawValue)\(path), headers \(headers.keys.sorted()), body \(body.count) bytes, redacted"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["host": host.rawValue, "path": path, "contentType": contentType, "headers": headers.keys.sorted(),
                                "body": "\(body.count) bytes"], displayStyle: .struct)
    }
}

extension URL {
    /// `https://<host><path>?<query>`, each name and value percent-encoded except RFC 3986's unreserved
    /// characters (so `fields[orgDevices]` goes as `fields%5BorgDevices%5D`, as abapit's httpx sent it).
    package static func make(host: APIHost, path: String, query: [QueryItem] = []) -> URL? {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        guard path.hasPrefix("/"), let encodedPath = path.addingPercentEncoding(withAllowedCharacters: unreserved.union(["/"])) else {
            return nil
        }
        let text = "https://\(host.rawValue)\(encodedPath)" + (query.isEmpty ? "" : "?" + query.map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&"))
        return URL(string: text)
    }
}
