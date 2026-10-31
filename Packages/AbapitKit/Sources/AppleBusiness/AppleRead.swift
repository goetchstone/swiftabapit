import AppleModels
import Foundation
import JSONAPI
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

    // MARK: Business only: people, content, Apple MDM and audit (plan §2.4: School has none of these endpoints)

    // These take no scope: they go to the Business host only, and `AppleClient` refuses them for a School org before
    // anything is built (`AppleAPIError.notInScope`). A School token sent here would also be refused by its broker.

    public static func users() -> ReadRequest { list("/v1/users") }
    public static func user(id: String) -> ReadRequest? { single("/v1/users/{id}", id) }
    public static func userGroups() -> ReadRequest { list("/v1/userGroups") }
    public static func userGroup(id: String) -> ReadRequest? { single("/v1/userGroups/{id}", id) }
    /// A group's members, as `users` linkages.
    public static func userGroupMembers(id: String) -> ReadRequest? { single("/v1/userGroups/{id}/relationships/users", id, paged: true) }
    public static func organizationalUnits() -> ReadRequest { list("/v1/organizationalUnits") }
    public static func organizationalUnit(id: String) -> ReadRequest? { single("/v1/organizationalUnits/{id}", id) }
    /// An org unit's members, as `users` linkages (abapit fetched them and never showed them).
    public static func organizationalUnitMembers(id: String) -> ReadRequest? {
        single("/v1/organizationalUnits/{id}/relationships/users", id, paged: true)
    }

    public static func apps() -> ReadRequest { list("/v1/apps") }
    /// One app; its id is the App Store's Adam ID.
    public static func app(id: String) -> ReadRequest? { single("/v1/apps/{id}", id) }
    public static func packages() -> ReadRequest { list("/v1/packages") }
    public static func package(id: String) -> ReadRequest? { single("/v1/packages/{id}", id) }
    /// The blueprints, without their members (abapit's list asked for none either).
    public static func blueprints() -> ReadRequest { list("/v1/blueprints") }

    /// One blueprint, with the members of `include` listed and their resources included, each relationship asked for
    /// at the most Apple sends (`limit[<name>]`, maximum 1000): what that cuts, `Blueprint.Related.isTruncated` says. The
    /// names come from `Blueprint.Relationship`, a closed enum of Apple's six, in its order.
    public static func blueprint(id: String, include: Set<Blueprint.Relationship> = []) -> ReadRequest? {
        let included = Blueprint.Relationship.allCases.filter(include.contains)
        let query = included.isEmpty ? [] : [QueryItem("include", included.map(\.rawValue).joined(separator: ","))]
            + included.map { QueryItem("limit[\($0.rawValue)]", String(pageLimit)) }
        return single("/v1/blueprints/{id}", id, query: query)
    }

    /// A blueprint's members of one relationship, as linkages of its type.
    public static func blueprintMembers(id: String, _ relationship: Blueprint.Relationship) -> ReadRequest? {
        single("/v1/blueprints/{id}/relationships/\(relationship.rawValue)", id, paged: true)
    }

    /// The configurations. A custom setting's profile comes only with the single read (abapit: the list sends
    /// `customSettingsValues` as null).
    public static func configurations() -> ReadRequest { list("/v1/configurations") }
    public static func configuration(id: String) -> ReadRequest? { single("/v1/configurations/{id}", id) }

    /// The devices enrolled in Apple's built-in device management.
    public static func mdmDevices() -> ReadRequest { list("/v1/mdmDevices") }
    /// One such device's posture: the documented `mdmDevices/{id}/details`, not abapit's undocumented `mdmDevices/{id}`
    /// (plan §2.3, defect 11).
    public static func mdmDeviceDetails(id: String) -> ReadRequest? { single("/v1/mdmDevices/{id}/details", id) }

    /// The audit log over `query`'s range, filtered by Apple (never here: plan §2.1), a cursor at a time.
    public static func auditEvents(_ query: AuditQuery) -> ReadRequest {
        var items = [QueryItem("filter[startTimestamp]", AuditQuery.timestamp(query.start)),
                     QueryItem("filter[endTimestamp]", AuditQuery.timestamp(query.end))]
        if !query.types.isEmpty { items.append(QueryItem("filter[type]", query.types.map(\.rawValue).joined(separator: ","))) }
        if let actor = query.actorID { items.append(QueryItem("filter[actorId]", actor)) }
        if let subject = query.subjectID { items.append(QueryItem("filter[subjectId]", subject)) }
        items.append(QueryItem("limit", String(pageLimit)))
        return ReadRequest(host: .appleBusiness, path: "/v1/auditEvents", query: items)
    }

    private static func list(_ path: String) -> ReadRequest {
        ReadRequest(host: .appleBusiness, path: path, query: [QueryItem("limit", String(pageLimit))])
    }

    /// `template` with its `{id}` replaced, when `id` can go in a path; a paged one asks for a full page.
    private static func single(_ template: String, _ id: String, paged: Bool = false, query: [QueryItem] = []) -> ReadRequest? {
        guard isPathSafe(id) else { return nil }
        return ReadRequest(host: .appleBusiness, path: template.replacingOccurrences(of: "{id}", with: id), template: template,
                           query: query + (paged ? [QueryItem("limit", String(pageLimit))] : []))
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

/// What an audit read asks Apple for (`GET auditEvents`), checked when it is made, so nothing typed into a filter reaches
/// a query unchecked. Apple filters; the client never filters what it asked Apple to (plan §2.1: abapit filtered by
/// subject itself).
public struct AuditQuery: Sendable, Equatable {
    /// The longest range one read covers: abapit's views capped theirs at 365 days. Apple documents no cap (check live).
    public static let longestSpan: TimeInterval = 365 * 86_400
    /// The latest instant a timestamp can say in `YYYY-MM-DDTHH:MM:SSZ`, 9999-12-31T23:59:59Z.
    static let latest: TimeInterval = 253_402_300_799

    /// The range's bounds, in whole seconds: both required, the start before the end.
    public let start: Date
    public let end: Date
    /// `filter[type]`: Apple's types only, each once, in the order given.
    public let types: [AuditEventType]
    /// `filter[actorId]` and `filter[subjectId]`: one id each, as Apple supports.
    public let actorID: String?
    public let subjectID: String?

    public enum Invalid: Error, Equatable, Sendable {
        /// The start isn't before the end, once both are cut to whole seconds.
        case emptyRange
        /// The range covers more than `longestSpan`.
        case tooLong
        /// A bound before 1970 or past 9999, or not a number.
        case outOfRange
        /// A type this version doesn't know: it never goes to Apple.
        case unknownType(String)
        /// An actor or subject id that isn't an identifier's shape (`AppleRead.isPathSafe`).
        case notAnID
    }

    /// The range cut to whole seconds (a timestamp says no fraction), and the filters checked: `types` must be Apple's
    /// (an `.unknown` one throws, so a raw value read from an event never goes out unchecked), and an id must have an
    /// identifier's shape: letters, digits, `-`, `_` and `.`, which a comma (Apple's list separator), `&`, `=`, `#`, `%`, a
    /// space, a line break or anything non-ASCII don't.
    public init(start: Date, end: Date, types: [OpenEnum<AuditEventType>] = [], actorID: String? = nil, subjectID: String? = nil) throws(Invalid) {
        let from = start.timeIntervalSince1970.rounded(.down), to = end.timeIntervalSince1970.rounded(.down)
        guard from.isFinite, to.isFinite, from >= 0, to <= Self.latest else { throw .outOfRange }
        guard from < to else { throw .emptyRange }
        guard to - from <= Self.longestSpan else { throw .tooLong }
        var known: [AuditEventType] = []
        for type in types {
            guard let value = type.known else { throw .unknownType(type.rawValue) }
            if !known.contains(value) { known.append(value) }
        }
        for id in [actorID, subjectID].compactMap({ $0 }) where !AppleRead.isPathSafe(id) { throw .notAnID }
        self.start = Date(timeIntervalSince1970: from)
        self.end = Date(timeIntervalSince1970: to)
        self.types = known
        self.actorID = actorID
        self.subjectID = subjectID
    }

    /// The last `days` days up to `now`.
    public static func last(days: Int, now: Date = Date(), types: [OpenEnum<AuditEventType>] = [], actorID: String? = nil,
                            subjectID: String? = nil) throws(Invalid) -> AuditQuery {
        try AuditQuery(start: now.addingTimeInterval(-Double(days) * 86_400), end: now, types: types, actorID: actorID, subjectID: subjectID)
    }

    /// `2026-10-30T12:00:00Z`: whole seconds, UTC, `Z`.
    static func timestamp(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        format.timeZone = TimeZone(identifier: "UTC")
        return format.string(from: date)
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
