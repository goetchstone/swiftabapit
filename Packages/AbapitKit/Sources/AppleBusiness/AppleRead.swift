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

    /// The devices `filter` lets through (every device by default), Apple filtering (Business 2.7, School 1.8), a cursor at
    /// a time. No `fields[orgDevices]`: it can't name the MDM-migration attributes, which the device table filters on
    /// (docs/domains/apple-reads.md).
    public static func devices(_ scope: Scope, matching filter: DeviceFilter = .all) -> ReadRequest {
        ReadRequest(host: host(scope), path: "/v1/orgDevices", query: filter.items + [QueryItem("limit", String(pageLimit))])
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

    // MARK: Business only: people, content, Apple MDM, audit and webhooks (plan §2.4: School has none of these endpoints)

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

    /// The webhooks (Business 2.8): where Apple sends the organization's device changes.
    public static func webhooks() -> ReadRequest { list("/v1/webhooks") }
    public static func webhook(id: String) -> ReadRequest? { single("/v1/webhooks/{id}", id) }
    /// A webhook's deliveries over `query`, each with the event it sent (`include=event`), a cursor at a time: Apple filters.
    public static func webhookDeliveries(id: String, _ query: WebhookDeliveryQuery = .all) -> ReadRequest? {
        single("/v1/webhooks/{id}/deliveries", id, paged: true, query: query.items)
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

/// What a device-list read asks Apple to filter (`GET orgDevices`, Business 2.7 and School 1.8), checked when it is made, as
/// `AuditQuery` is: nothing typed into a filter reaches a query unchecked, and a filter no device could match is refused in
/// words rather than sent. Apple filters; the client never filters what it asked Apple to (plan §2.1). Each filter is
/// assumed to narrow the others (Apple ANDs them: check live), and a list's values to widen each other (OR).
public struct DeviceFilter: Sendable, Equatable {
    /// `filter[serialNumber]` and `filter[orderNumber]`: identifiers of `AppleRead.isPathSafe`'s shape, so a comma (Apple's
    /// separator), `&`, `=`, `#`, `%`, a blank, a line break or anything non-ASCII can't go out; each once, in the order
    /// given; at most `maximumIdentifiers` of each.
    public let serialNumbers: [String]
    public let orderNumbers: [String]
    /// `filter[status]`, `filter[productFamily]` and `filter[purchaseSourceType]`: Apple's values only (the ones their
    /// descriptions list), each once.
    public let statuses: [DeviceStatus]
    public let productFamilies: [ProductFamily]
    public let purchaseSourceTypes: [PurchaseSourceType]
    /// `filter[addedToOrgDateTime]` and `filter[orderDateTime]`, with their `[GT]`, `[GTE]`, `[LT]` and `[LTE]` forms.
    public let addedToOrg: DateFilter
    public let ordered: DateFilter

    /// Every device: nothing filtered.
    public static let all = DeviceFilter(checked: [], [], [], [], [], .any, .any)

    /// The most serial numbers, and the most order numbers, one filter takes, each counted once. Apple documents no limit
    /// on a list's length; a long one makes a long URL, which a server may refuse or cut. 100 until Apple's limit is checked
    /// live (the contract-2.8 review's L6).
    public static let maximumIdentifiers = 100

    /// One date attribute's filter: instants matched exactly (`filter[<attribute>]`, joined by commas), a lower bound
    /// (`[GT]` or `[GTE]`) and an upper bound (`[LT]` or `[LTE]`). One bound of each side, so two lower bounds can't be
    /// asked; `DeviceFilter` checks the dates and that they can match.
    public struct DateFilter: Sendable, Equatable {
        public enum Lower: Sendable, Equatable {
            /// `[GT]`: after this instant.
            case after(Date)
            /// `[GTE]`: at or after it.
            case atOrAfter(Date)
        }

        public enum Upper: Sendable, Equatable {
            /// `[LT]`: before this instant.
            case before(Date)
            /// `[LTE]`: at or before it.
            case atOrBefore(Date)
        }

        public let exactly: [Date]
        public let lower: Lower?
        public let upper: Upper?

        public static let any = DateFilter()

        public init(exactly: [Date] = [], lower: Lower? = nil, upper: Upper? = nil) {
            self.exactly = exactly
            self.lower = lower
            self.upper = upper
        }

        public var isEmpty: Bool { exactly.isEmpty && lower == nil && upper == nil }
    }

    /// The device attributes a filter names, for its words.
    public enum Field: String, Sendable {
        case serialNumber, orderNumber, status, productFamily, purchaseSourceType, addedToOrgDateTime, orderDateTime

        var words: String {
            switch self {
            case .serialNumber: "serial number"
            case .orderNumber: "order number"
            case .status: "status"
            case .productFamily: "product family"
            case .purchaseSourceType: "purchase source"
            case .addedToOrgDateTime: "date added to the organization"
            case .orderDateTime: "order date"
            }
        }

        /// `words` after its article, capitalized to open a sentence: "A serial number", "An order date".
        var opening: String { ([.orderNumber, .orderDateTime].contains(self) ? "An " : "A ") + words }
    }

    public enum Invalid: Error, Equatable, Sendable {
        /// A serial or order number that isn't an identifier's shape (`AppleRead.isPathSafe`).
        case notAnIdentifier(Field)
        /// More serial or order numbers than `maximumIdentifiers`, each counted once.
        case tooMany(Field)
        /// A value this version doesn't know: it never goes to Apple.
        case unknownValue(Field, String)
        /// A date before 1970 or past 9999, or not a number.
        case outOfRange(Field)
        /// The lower bound is past the upper one, or at it while either leaves that instant out: no device could match.
        case emptyRange(Field)
        /// An instant asked for exactly that its own bounds leave out: it could never match.
        case outsideItsRange(Field)

        /// What was refused, in words: never the value, which may be anything typed or read.
        public var message: String {
            switch self {
            case .notAnIdentifier(let field):
                "\(field.opening) to filter on can only be letters, digits, -, _ and . (not first), 1 to 128 of them: one per entry, never joined by commas."
            case .tooMany(let field):
                "At most \(DeviceFilter.maximumIdentifiers) different \(field.words)s can be filtered on at once: filter on fewer, or on something else."
            case .unknownValue(let field, _): "This version doesn't know one of the values asked for as the \(field.words), so it can't filter on it."
            case .outOfRange(let field): "\(field.opening) to filter on is before 1970 or after 9999."
            case .emptyRange(let field): "The range of the \(field.words) ends before it starts, so no device could match."
            case .outsideItsRange(let field): "\(field.opening) asked for exactly is outside the range given with it, so it could never match."
            }
        }
    }

    /// The filter, checked: identifiers of an identifier's shape, Apple's values only (an `.unknown` one throws, so a raw
    /// value read from a device never goes out unchecked), dates cut to whole seconds (a timestamp says no fraction)
    /// between 1970 and 9999, and bounds that some device could fall between. Duplicates go, the order stays.
    public init(serialNumbers: [String] = [], orderNumbers: [String] = [], statuses: [OpenEnum<DeviceStatus>] = [],
                productFamilies: [OpenEnum<ProductFamily>] = [], purchaseSourceTypes: [OpenEnum<PurchaseSourceType>] = [],
                addedToOrg: DateFilter = .any, ordered: DateFilter = .any) throws(Invalid) {
        self.init(checked: try Self.identifiers(serialNumbers, .serialNumber), try Self.identifiers(orderNumbers, .orderNumber),
                  try Self.known(statuses, .status), try Self.known(productFamilies, .productFamily),
                  try Self.known(purchaseSourceTypes, .purchaseSourceType), try Self.dates(addedToOrg, .addedToOrgDateTime),
                  try Self.dates(ordered, .orderDateTime))
    }

    private init(checked serials: [String], _ orders: [String], _ statuses: [DeviceStatus], _ families: [ProductFamily],
                 _ sources: [PurchaseSourceType], _ added: DateFilter, _ ordered: DateFilter) {
        serialNumbers = serials
        orderNumbers = orders
        self.statuses = statuses
        productFamilies = families
        purchaseSourceTypes = sources
        addedToOrg = added
        self.ordered = ordered
    }

    public var isEmpty: Bool { self == .all }

    /// Each once, by bytes: `String ==` would take two spellings of one identifier for one (failure-log 2026-10-16); at
    /// most `maximumIdentifiers` of them.
    private static func identifiers(_ ids: [String], _ field: Field) throws(Invalid) -> [String] {
        var kept: [String] = []
        for id in ids {
            guard AppleRead.isPathSafe(id) else { throw .notAnIdentifier(field) }
            if !kept.contains(where: { $0.utf8.elementsEqual(id.utf8) }) { kept.append(id) }
        }
        guard kept.count <= maximumIdentifiers else { throw .tooMany(field) }
        return kept
    }

    private static func known<Known: KnownValues>(_ values: [OpenEnum<Known>], _ field: Field) throws(Invalid) -> [Known] {
        var kept: [Known] = []
        for value in values {
            guard let known = value.known else { throw .unknownValue(field, value.rawValue) }
            if !kept.contains(known) { kept.append(known) }
        }
        return kept
    }

    /// `filter`'s dates cut to whole seconds and checked: each between 1970 and 9999, the lower bound below the upper
    /// one (or equal, when both take that instant in), and every exact instant inside them.
    private static func dates(_ filter: DateFilter, _ field: Field) throws(Invalid) -> DateFilter {
        func cut(_ date: Date) throws(Invalid) -> Date {
            let seconds = date.timeIntervalSince1970.rounded(.down)
            guard seconds.isFinite, seconds >= 0, seconds <= AuditQuery.latest else { throw .outOfRange(field) }
            return Date(timeIntervalSince1970: seconds)
        }
        var exactly: [Date] = []
        for date in filter.exactly {
            let instant = try cut(date)
            if !exactly.contains(instant) { exactly.append(instant) }
        }
        var lower: DateFilter.Lower?, upper: DateFilter.Upper?
        switch filter.lower {
        case .after(let date)?: lower = .after(try cut(date))
        case .atOrAfter(let date)?: lower = .atOrAfter(try cut(date))
        case nil: break
        }
        switch filter.upper {
        case .before(let date)?: upper = .before(try cut(date))
        case .atOrBefore(let date)?: upper = .atOrBefore(try cut(date))
        case nil: break
        }
        let checked = DateFilter(exactly: exactly, lower: lower, upper: upper)
        if let from = checked.lowest, let to = checked.highest, from.date > to.date || (from.date == to.date && !(from.taken && to.taken)) {
            throw .emptyRange(field)
        }
        if exactly.contains(where: { !checked.admits($0) }) { throw .outsideItsRange(field) }
        return checked
    }

    /// The filter's parameters, in the contract's order of attributes; each list joined by commas.
    var items: [QueryItem] {
        var items: [QueryItem] = []
        func add(_ parameter: String, _ values: [String]) {
            if !values.isEmpty { items.append(QueryItem(parameter, values.joined(separator: ","))) }
        }
        add("filter[serialNumber]", serialNumbers)
        add("filter[status]", statuses.map(\.rawValue))
        add("filter[productFamily]", productFamilies.map(\.rawValue))
        add("filter[purchaseSourceType]", purchaseSourceTypes.map(\.rawValue))
        add("filter[orderNumber]", orderNumbers)
        for (name, filter) in [("filter[addedToOrgDateTime]", addedToOrg), ("filter[orderDateTime]", ordered)] {
            add(name, filter.exactly.map(AuditQuery.timestamp))
            switch filter.lower {
            case .after(let date)?: add(name + "[GT]", [AuditQuery.timestamp(date)])
            case .atOrAfter(let date)?: add(name + "[GTE]", [AuditQuery.timestamp(date)])
            case nil: break
            }
            switch filter.upper {
            case .before(let date)?: add(name + "[LT]", [AuditQuery.timestamp(date)])
            case .atOrBefore(let date)?: add(name + "[LTE]", [AuditQuery.timestamp(date)])
            case nil: break
            }
        }
        return items
    }
}

extension DeviceFilter.DateFilter {
    /// The lower bound's instant, and whether it is taken in (`[GTE]`).
    var lowest: (date: Date, taken: Bool)? {
        switch lower {
        case .after(let date)?: (date, false)
        case .atOrAfter(let date)?: (date, true)
        case nil: nil
        }
    }

    /// The upper bound's instant, and whether it is taken in (`[LTE]`).
    var highest: (date: Date, taken: Bool)? {
        switch upper {
        case .before(let date)?: (date, false)
        case .atOrBefore(let date)?: (date, true)
        case nil: nil
        }
    }

    /// Whether `date` is inside the bounds.
    func admits(_ date: Date) -> Bool {
        let above = lowest.map { $0.taken ? date >= $0.date : date > $0.date } ?? true
        let below = highest.map { $0.taken ? date <= $0.date : date < $0.date } ?? true
        return above && below
    }
}

/// What a webhook's deliveries read asks Apple for (`GET webhooks/{id}/deliveries`, Business 2.8), checked when it is made,
/// as `AuditQuery` is: the creation range's bounds whole seconds, 1970 to 9999, the start before the end; Apple's delivery
/// states only, each once. The events always come with them (`include=event`): the deliveries are read for what they sent
/// (plan §8.0, the change feed).
public struct WebhookDeliveryQuery: Sendable, Equatable {
    /// `filter[createdDateTimeAtOrAfter]`: deliveries created at or after this instant.
    public let createdAtOrAfter: Date?
    /// `filter[createdDateTimeAtBefore]`: deliveries created before this instant.
    public let createdBefore: Date?
    /// `filter[deliveryState]`, in the order given.
    public let states: [WebhookDeliveryState]

    /// Every delivery Apple keeps (check live how long that is).
    public static let all = WebhookDeliveryQuery(checked: nil, nil, [])

    public enum Invalid: Error, Equatable, Sendable {
        /// A bound before 1970 or past 9999, or not a number.
        case outOfRange
        /// The range ends before it starts, or where it starts: no delivery could match.
        case emptyRange
        /// A state this version doesn't know: it never goes to Apple.
        case unknownState(String)

        public var message: String {
            switch self {
            case .outOfRange: "A date to read deliveries from or to is before 1970 or after 9999."
            case .emptyRange: "The range of deliveries ends before it starts, so none could match."
            case .unknownState: "This version doesn't know one of the delivery states asked for, so it can't filter on it."
            }
        }
    }

    public init(createdAtOrAfter: Date? = nil, createdBefore: Date? = nil, states: [OpenEnum<WebhookDeliveryState>] = []) throws(Invalid) {
        var from: Date?, to: Date?
        if let createdAtOrAfter { from = try Self.cut(createdAtOrAfter) }
        if let createdBefore { to = try Self.cut(createdBefore) }
        if let from, let to, from >= to { throw .emptyRange }
        var known: [WebhookDeliveryState] = []
        for state in states {
            guard let value = state.known else { throw .unknownState(state.rawValue) }
            if !known.contains(value) { known.append(value) }
        }
        self.init(checked: from, to, known)
    }

    private init(checked from: Date?, _ to: Date?, _ states: [WebhookDeliveryState]) {
        createdAtOrAfter = from
        createdBefore = to
        self.states = states
    }

    /// The last `days` days up to `now`.
    public static func last(days: Int, now: Date = Date(), states: [OpenEnum<WebhookDeliveryState>] = []) throws(Invalid) -> WebhookDeliveryQuery {
        try WebhookDeliveryQuery(createdAtOrAfter: now.addingTimeInterval(-Double(days) * 86_400), states: states)
    }

    /// The date cut to whole seconds, as a timestamp says it, when it is one `AuditQuery.timestamp` can write.
    private static func cut(_ date: Date) throws(Invalid) -> Date {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        guard seconds.isFinite, seconds >= 0, seconds <= AuditQuery.latest else { throw .outOfRange }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The query's parameters, in the contract's order, then the include.
    var items: [QueryItem] {
        var items: [QueryItem] = []
        if let createdBefore { items.append(QueryItem("filter[createdDateTimeAtBefore]", AuditQuery.timestamp(createdBefore))) }
        if let createdAtOrAfter { items.append(QueryItem("filter[createdDateTimeAtOrAfter]", AuditQuery.timestamp(createdAtOrAfter))) }
        if !states.isEmpty { items.append(QueryItem("filter[deliveryState]", states.map(\.rawValue).joined(separator: ","))) }
        return items + [QueryItem("include", "event")]
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
