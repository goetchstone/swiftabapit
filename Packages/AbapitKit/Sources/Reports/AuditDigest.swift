import Foundation
import JSONAPI

/// The Activity views over Apple's audit log (plan Phase 2, "Audit"; Appendix B), each a fixed set of
/// `AuditEventType` values. Apple documents 50 at Business 2.6 (`Contracts/apple/business-2.6.json`), and
/// `ReportsTests` holds each of them to exactly one view or to `otherTypes`, so a type Apple adds fails a test until
/// it is placed rather than vanishing from every view. The values are Apple's strings, matched byte for byte.
public enum AuditView: String, CaseIterable, Sendable {
    /// abapit's `SUBSCRIPTION_EVENTS`: Apple has no subscription endpoint, so these events are the only place it
    /// reports subscription and purchase activity.
    case subscriptions
    /// abapit's `DEVICE_LIFECYCLE_EVENTS`, Apple's names (`…_TO_SERVER`; abapit's demo data said `…_TO_MDM`, defect
    /// 12): added, removed, assigned, unassigned, erased.
    case deviceLifecycle
    /// New, no abapit counterpart: who can get in and with what. Accounts, API accounts and their keys, roles,
    /// domains and federation, identity providers, passwords and resets, external accounts. Two more belong here:
    /// `TERMS_ACCEPTED` is an administrator's account agreeing to Apple's terms for the organization (`termsName`),
    /// an act that binds it and that an access review asks after; `APPLE_SERVICES_SETTINGS_UPDATED`
    /// (`settingsEnabled`, `settingsDisabled`) decides which Apple services the organization's accounts may sign in
    /// to.
    case accessAndSecurity

    public var types: [String] {
        switch self {
        case .subscriptions:
            ["SUBSCRIPTION_CREATED", "SUBSCRIPTION_UPDATED", "SUBSCRIPTION_DELETED", "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED",
             "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_REMOVED", "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED", "SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED"]
        case .deviceLifecycle:
            ["DEVICE_ADDED_TO_ORG", "DEVICE_REMOVED_FROM_ORG", "DEVICE_ASSIGNED_TO_SERVER", "DEVICE_UNASSIGNED_FROM_SERVER", "DEVICE_IS_ERASED"]
        case .accessAndSecurity:
            ["ACCOUNT_ADDED", "ACCOUNT_DELETED", "ACCOUNT_ROLE_LOCATION_CHANGED",
             "API_ACCOUNT_CREATED_WITH_KEY", "API_ACCOUNT_CREATED_WITHOUT_KEY", "API_ACCOUNT_DELETED", "API_ACCOUNT_KEY_GENERATED",
             "API_ACCOUNT_KEY_REVOKED", "API_ACCOUNT_ROLE_LOCATION_CHANGED", "API_ACCOUNT_NAME_CHANGED",
             "ROLE_CREATED", "ROLE_UPDATED",
             "DOMAIN_ADDED", "DOMAIN_REMOVED", "DOMAIN_VERIFIED", "DOMAIN_FEDERATION_ENABLED", "DOMAIN_FEDERATION_DISABLED",
             "IDP_CREATED", "IDP_UPDATED", "IDP_DELETED", "IDP_ACCOUNT_SYNC_ENABLED", "IDP_ACCOUNT_SYNC_DISABLED",
             "ACCOUNT_PASSWORD_CHANGED", "BATCH_PASSWORD_RESET_INITIATED",
             "EXTERNAL_ACCOUNT_ASSOCIATED", "EXTERNAL_ACCOUNT_DISASSOCIATED", "EXTERNAL_ACCOUNT_INVITED",
             "TERMS_ACCEPTED", "APPLE_SERVICES_SETTINGS_UPDATED"]
        }
    }

    /// Apple's types no view shows; the full Audit list still does. `CONFIG_SETTINGS_*` record a configuration's
    /// content (`configId`, `configType`, `configVersion`) and `COLLECTION_*` a collection's name and description:
    /// device management, not access. `ACCOUNT_IMAGE_*` is an account's picture, which in Access & Security would bury
    /// the role and key changes the view is for.
    public static let otherTypes = [
        "CONFIG_SETTINGS_CREATED", "CONFIG_SETTINGS_UPDATED", "CONFIG_SETTINGS_DELETED",
        "COLLECTION_CREATED", "COLLECTION_UPDATED", "COLLECTION_DELETED",
        "ACCOUNT_IMAGE_SET", "ACCOUNT_IMAGE_REPLACED", "ACCOUNT_IMAGE_REMOVED",
    ]
}

/// abapit's `reports.audit_digest` (held to the `audit_digest` cases in `Tests/Fixtures/parity/reports.json`): the
/// events of a set of types, newest first, with a count per type. The events are `auditEvents` resources as Apple
/// sent them.
public struct AuditDigest: Sendable {
    /// The events of the set, newest first (`newestFirst`).
    public let rows: [Resource]
    /// Per type, most first; equal counts in the order the rows first show them (Python's `Counter.most_common` over
    /// the sorted rows).
    public let counts: [Tally]
    /// How many events were read, of any type.
    public let scanned: Int

    public var total: Int { rows.count }

    public init(_ events: [Resource], view: AuditView) { self.init(events, types: view.types) }

    /// Types match byte for byte, as Python's `in` compares code points: `String ==` and `Set<String>` fold canonical
    /// equivalents, so a U+212A KELVIN SIGN for the `K` of `API_ACCOUNT_KEY_REVOKED` would match. An event whose type
    /// isn't a string, or that has no attributes, is no row.
    public init(_ events: [Resource], types: [String]) {
        let wanted = Set(types.map { Array($0.utf8) })
        rows = Self.newestFirst(events.filter { Self.type(of: $0).map { wanted.contains(Array($0.utf8)) } ?? false })
        var counter = Counter()
        for row in rows { counter.add(Self.type(of: row) ?? "") }
        counts = counter.mostCommon()
        scanned = events.count
    }

    /// Newest first by the instant `eventDateTime` names (`ISODate`). A listed deviation: abapit sorted the strings,
    /// which put `T09:00:00-08:00` (17:00 UTC) after `T16:00:00Z`, `T08:00:00Z` before `T08:00:00.5Z`, and `not a date`
    /// first. Equal instants, however they are spelled, keep their order in `events` (compared as `Date`s: `ISODate`'s
    /// `==` compares the offset too), and an event with no date to read (missing, null, empty, not a date, not a
    /// string) comes after every dated one, in its order. The audit endpoint has no `sort` (plan §2.4), so the order
    /// Apple sends is no order.
    public static func newestFirst(_ events: [Resource]) -> [Resource] {
        events.enumerated()
            .map { (offset: $0.offset, date: ISODate.parse($0.element.attributes["eventDateTime"]?.string)?.date, event: $0.element) }
            .sorted { a, b in
                switch (a.date, b.date) {
                case let (x?, y?) where x != y: x > y
                case (.some, .none): true
                case (.none, .some): false
                default: a.offset < b.offset
                }
            }
            .map(\.event)
    }

    /// How many events the dashboard shows.
    public static let recentLimit = 10

    /// The dashboard's recent events: the newest `recentLimit` of `events` by instant (`newestFirst`). abapit's
    /// dashboard showed the first 10 the API returned for the last 7 days, in the API's order, which isn't by time:
    /// a listed deviation. The caller picks the window it reads.
    public static func recent(_ events: [Resource]) -> [Resource] { Array(newestFirst(events).prefix(recentLimit)) }

    static func type(of event: Resource) -> String? { event.attributes["type"]?.string }
}
