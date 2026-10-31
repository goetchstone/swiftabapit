import Foundation

extension ExportPolicy {
    /// The Activity screen's export (invariant 11: an allowlist): an audit event's common attributes, Apple's
    /// `AuditEventCommonAttributes` in its order (`AuditEvent.fields`, held by a test). No payload: abapit had no audit
    /// export at all (its `/export/{resource}.csv` at 3890091 serves no audit resource), and a payload's fields depend on
    /// its type, so one table can't hold them as columns; the inspector shows them. `eventDataPropertyKey` says where
    /// the payload was. A key Apple adds later is not exported until it is listed here.
    public static let auditEvents = Columns([
        "eventDateTime", "type", "category", "actorType", "actorId", "actorName", "subjectType", "subjectId", "subjectName",
        "outcome", "groupId", "eventDataPropertyKey",
    ])
}
