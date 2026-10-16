import Foundation

/// Why a request got no HTTP answer the caller can read. An HTTP status, any status, is a response: the
/// client of each API classifies it (Apple's `ErrorResponse` codes, Mosyle's envelope).
public enum HTTPFailure: Error, Equatable, Sendable {
    /// No answer: offline, DNS, TLS, a timeout (`URLError.Code`).
    case transport(code: Int)
    /// A URL whose host isn't on the allowlist, or a next-page link that left the API (invariant 4).
    case refusedHost(String)
    /// A body past the cap (invariant 7).
    case tooLarge(limit: Int)

    public var message: String {
        switch self {
        case .transport(let code):
            switch URLError.Code(rawValue: code) {
            case .notConnectedToInternet, .networkConnectionLost: "This Mac is offline."
            case .timedOut: "The server didn't answer in time."
            case .cannotFindHost, .dnsLookupFailed: "The server's name couldn't be found."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                "A secure connection to the server couldn't be made."
            default: "The request didn't reach the server (URL error \(code))."
            }
        case .refusedHost(let host): "A request to \(host) was refused: it isn't one of the hosts this app talks to."
        case .tooLarge(let limit): "The server sent more than \(limit / 1_048_576) MB, so the response was dropped."
        }
    }
}
