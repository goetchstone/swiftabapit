import Foundation
import Orgs
import Wire

/// Every Apple read this app sends: the only place a `ReadRequest` for Apple is made (invariant 2). Each
/// path, parameter and value is in `Contracts/apple/*.json` (`AppleBusinessTests` checks).
public enum AppleRead {
    /// Apple's page limit (`limit` maximum 1000).
    public static let pageLimit = 1000

    static func host(_ scope: Scope) -> APIHost { scope == .business ? .appleBusiness : .appleSchool }

    /// An identifier that may go into a path: letters, digits, `-`, `_` and `.`, not starting with a dot, at
    /// most 128 characters. Apple's serials and ids are all of this shape; anything else (a `/`, `..`, a
    /// space typed into Find) would steer the path, so it is never sent.
    public static func isPathSafe(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Every device. No `fields[orgDevices]`: it can't name the MDM-migration attributes, which the device
    /// table filters on (docs/domains/apple-reads.md).
    public static func devices(_ scope: Scope) -> ReadRequest {
        ReadRequest(host: host(scope), path: "/v1/orgDevices", query: [QueryItem("limit", String(pageLimit))])
    }

    /// One device, every attribute (`releasedFromOrgDateTime` comes only here).
    public static func device(_ scope: Scope, serial: String) -> ReadRequest? {
        guard isPathSafe(serial) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/orgDevices/\(serial)", template: "/v1/orgDevices/{id}")
    }

    public static func appleCare(_ scope: Scope, serial: String) -> ReadRequest? {
        guard isPathSafe(serial) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/orgDevices/\(serial)/appleCareCoverage",
                    template: "/v1/orgDevices/{id}/appleCareCoverage", query: [QueryItem("limit", String(pageLimit))])
    }

    public static func activationLock(_ scope: Scope, serial: String) -> ReadRequest? {
        guard isPathSafe(serial) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/orgDevices/\(serial)/activationLockStatus",
                    template: "/v1/orgDevices/{id}/activationLockStatus")
    }

    /// The service a device is assigned to, whole (404 when unassigned).
    public static func assignedService(_ scope: Scope, serial: String) -> ReadRequest? {
        guard isPathSafe(serial) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/orgDevices/\(serial)/assignedServer", template: "/v1/orgDevices/{id}/assignedServer")
    }

    /// The same as a linkage only: cheaper in sweeps and in the Guard's re-validation reads.
    public static func assignedServiceID(_ scope: Scope, serial: String) -> ReadRequest? {
        guard isPathSafe(serial) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/orgDevices/\(serial)/relationships/assignedServer",
                    template: "/v1/orgDevices/{id}/relationships/assignedServer")
    }

    /// The services, without their device relationships.
    public static func services(_ scope: Scope) -> ReadRequest {
        ReadRequest(host: host(scope), path: "/v1/mdmServers",
                    query: [QueryItem("fields[mdmServers]", "serverName,serverType,status,deviceCount,lastConnectedDateTime,lastConnectedIp,"
                                      + "defaultProductFamilies,enableMdmDisownFlag,createdDateTime,updatedDateTime"),
                            QueryItem("limit", String(pageLimit))])
    }

    public static func service(_ scope: Scope, id: String) -> ReadRequest? {
        guard isPathSafe(id) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/mdmServers/\(id)", template: "/v1/mdmServers/{id}")
    }

    /// The serials assigned to a service, as linkages.
    public static func serviceDevices(_ scope: Scope, id: String) -> ReadRequest? {
        guard isPathSafe(id) else { return nil }
        return ReadRequest(host: host(scope), path: "/v1/mdmServers/\(id)/relationships/devices",
                    template: "/v1/mdmServers/{id}/relationships/devices", query: [QueryItem("limit", String(pageLimit))])
    }

    /// A read probe: the section's collection, one item (abapit's `READ_PROBES`). The audit endpoint needs its
    /// two timestamps.
    public static func probe(_ scope: Scope, section: AppleSectionPath, now: Date) -> ReadRequest {
        var query = [QueryItem("limit", "1")]
        if section.needsTimeRange {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime]
            query = [QueryItem("filter[startTimestamp]", format.string(from: now.addingTimeInterval(-86_400))),
                     QueryItem("filter[endTimestamp]", format.string(from: now))] + query
        }
        return ReadRequest(host: host(scope), path: section.path, query: query)
    }
}

/// A section's collection for a probe: a path, and whether it needs the audit endpoint's time range.
public struct AppleSectionPath: Sendable, Equatable {
    public let path: String
    public let needsTimeRange: Bool

    public init(path: String) {
        self.path = path
        needsTimeRange = path == "/v1/auditEvents"
    }
}
