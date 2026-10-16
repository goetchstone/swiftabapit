import Foundation

/// The only hosts the app talks to (plan §3.3, invariant 4). Anything else — a redirect, a `links.next`
/// that names another host, an activity's presigned `downloadUrl` — is refused; a download link is opened
/// in the browser instead.
public enum APIHost: String, CaseIterable, Sendable {
    /// Apple's OAuth token endpoint.
    case appleAccount = "account.apple.com"
    case appleBusiness = "api-business.apple.com"
    case appleSchool = "api-school.apple.com"
    case mosyle = "businessapi.mosyle.com"
    case mosyleLogs = "businessapilogs.mosyle.com"

    /// The host of an `https` URL with no user, password or port, when it is one of these.
    public init?(of url: URL) {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let name = url.host(percentEncoded: false), let host = APIHost(rawValue: name) else { return nil }
        self = host
    }
}
