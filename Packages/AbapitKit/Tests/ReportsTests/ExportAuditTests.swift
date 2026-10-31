import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// The audit list's CSV (invariant 11): the common attributes only, in Apple's order, and nothing of a payload.
@Suite("Audit export")
struct ExportAuditTests {
    /// Exactly Apple's common attributes, in its order: a payload key, or an attribute Apple adds later, isn't a column.
    @Test func theColumnsAreTheCommonAttributes() {
        #expect(ExportPolicy.auditEvents.names == AuditEvent.fields)
        let payloadKeys = Set(AuditEventType.allCases.map(\.payload.key))
        #expect(ExportPolicy.auditEvents.names.allSatisfy { !payloadKeys.contains($0) })
        #expect(ExportPolicy.auditEvents.names.allSatisfy { ExportPolicy.permits($0, includeNotByDefault: false) })
    }

    /// A payload's values never reach the file, whatever the type: a canary in each type's payload, an unknown type's and
    /// an attribute Apple adds beside them.
    @Test func noPayloadLeavesInTheCSV() {
        let events = AuditEventType.allCases.enumerated().map { index, type in
            CSV.Item(id: "E\(index)", attributes: [
                "eventDateTime": .string("2026-10-30T12:00:00Z"), "type": .string(type.rawValue), "actorId": .string("A1"),
                "eventDataPropertyKey": .string(type.payload.key),
                type.payload.key: .object(["serialNumber": .string("CANARY-\(index)"), "keyId": .string("CANARY-KEY")]),
            ])
        } + [CSV.Item(id: "U1", attributes: ["type": .string("FUTURE_TYPE"), "eventDataFutureType": .object(["x": .string("CANARY-U")]),
                                             "newAttribute": .string("CANARY-NEW")])]
        let text = CSV.text(events, columns: ExportPolicy.auditEvents)
        #expect(!text.contains("CANARY"), "\(text)")
        #expect(text.hasPrefix("id,eventDateTime,type,category,actorType,actorId,actorName,subjectType,subjectId,subjectName,outcome,groupId,eventDataPropertyKey\r\n"))
        #expect(text.contains("E0,2026-10-30T12:00:00Z,DEVICE_ADDED_TO_ORG,,,A1,,,,,,,eventDataDeviceAddedToOrg\r\n"))
        #expect(text.contains("U1,,FUTURE_TYPE,,,,,,,,,,\r\n"))
    }
}
