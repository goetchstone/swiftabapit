import Foundation
import HTTPCore
import JSONAPI

/// An Apple API failure, classified on the HTTP status plus Apple's dot-separated error `code`, never on
/// the prose (plan §3.3). Each case says what the operator can do; none carries a body or a token.
public enum AppleAPIError: Error, Equatable, Sendable {
    case unauthorized
    /// 403: the API account's role can't do this. A read probe turns it into "your role can't read this".
    case forbidden(code: String?)
    case notFound
    case conflict(code: String?, detail: String?)
    case unprocessable(pointer: String?, detail: String?)
    case badRequest(code: String?, parameter: String?, detail: String?)
    case rateLimited
    case server(status: Int)
    case unexpected(status: Int)
    case notJSON(bytes: Int)
    /// A 2xx whose JSON isn't the shape the endpoint documents (`{}`, a list for a single item, a linkage with no
    /// type): never read as "none" (Phase 1a's review: a malformed 200 read as "unassigned").
    case malformed(String)
    case http(HTTPFailure)
    case token(TokenFailure)
    case vault(String)
    case wrongHost(String)

    /// A non-2xx response as an error.
    init(_ response: HTTPResponse) {
        let body = ErrorBody(response.body)?.errors.first
        switch response.status {
        case 401: self = .unauthorized
        case 403: self = .forbidden(code: body?.code)
        case 404: self = .notFound
        case 409: self = .conflict(code: body?.code, detail: body?.detail)
        case 422: self = .unprocessable(pointer: body?.pointer, detail: body?.detail)
        case 400: self = .badRequest(code: body?.code, parameter: body?.parameter, detail: body?.detail)
        case 429: self = .rateLimited
        case 500...599: self = .server(status: response.status)
        default: self = .unexpected(status: response.status)
        }
    }

    public var message: String {
        switch self {
        case .unauthorized: "Apple didn't accept this account's token, even a fresh one. Check the key in Settings."
        case .forbidden: "This API account's role can't do this."
        case .notFound: "Apple has no such item."
        case .conflict(_, let detail): "Apple refused it as a conflict\(detail.map { ": \($0)" } ?? ".")"
        case .unprocessable(let pointer, let detail):
            "Apple couldn't process it\(pointer.map { " (\($0))" } ?? "")\(detail.map { ": \($0)" } ?? ".")"
        case .badRequest(_, let parameter, let detail):
            "Apple refused the request\(parameter.map { " (\($0))" } ?? "")\(detail.map { ": \($0)" } ?? ".")"
        case .rateLimited: "Apple is rate-limiting this account. It was retried; try again in a minute."
        case .server(let status): "Apple's service failed (HTTP \(status)). Try again later."
        case .unexpected(let status): "Apple answered HTTP \(status), which this app doesn't expect."
        case .notJSON(let bytes): "Apple's answer wasn't readable (\(bytes) bytes that aren't JSON)."
        case .malformed(let what): "Apple's answer wasn't the shape it documents (\(what))."
        case .http(let failure): failure.message
        case .token(let failure): failure.message
        case .vault(let guidance): guidance
        case .wrongHost(let host): "A request for \(host) was refused: it isn't this organization's API."
        }
    }
}
