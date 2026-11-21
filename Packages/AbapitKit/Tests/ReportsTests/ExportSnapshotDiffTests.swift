import AppleModels
import Foundation
import JSONAPI
import Testing

@testable import Reports

/// The Changes screen's CSV (`ExportHistory.snapshotDiff`): an export names its columns (invariant 11), a value under a secret's name
/// is withheld at any depth, and a comparison with nothing to say is one row, never a bare header.
@Suite("Snapshot diff CSV")
struct ExportSnapshotDiffTests {
    static func snapshot(_ items: [String: JSONObject]) -> SnapshotDiff.Snapshot {
        SnapshotDiff.Snapshot(rows: items.map { (resource: "devices", id: $0.key, attributes: $0.value) })
    }

    @Test func aSecretNamedFieldIsWithheldWhateverItsDepth() {
        let old = Self.snapshot(["D1": ["name": .string("Lab"), "token": .string("CANARYOLDTOKEN"),
                                       "config": .object(["password": .string("CANARYOLDPW"), "ssid": .string("net")])]])
        let new = Self.snapshot(["D1": ["name": .string("Lab 2"), "token": .string("CANARYNEWTOKEN"),
                                        "config": .object(["password": .string("CANARYNEWPW"), "ssid": .string("net2")])]])
        let csv = ExportHistory.snapshotDiff(older: "2026-11-01T00:00:00Z", newer: "2026-11-02T00:00:00Z", deltas: SnapshotDiff.diff(old: old, new: new), notCompared: [])
        #expect(!csv.contains("CANARY"), "\(csv)")
        #expect(csv.contains(",token,") && csv.contains("name,Lab,Lab 2"), "\(csv)")
        #expect(csv.contains(AuditEvent.withheld), "\(csv)")
        #expect(SnapshotDiff.shown(.string("CANARYX"), field: "apiToken") == AuditEvent.withheld)
        #expect(!SnapshotDiff.shown(.object(["password": .string("CANARYX"), "ok": .string("fine")]), field: "settings").contains("CANARYX"))
        #expect(SnapshotDiff.shown(.null, field: "name") == "—" && SnapshotDiff.shown(.string("plain"), field: "name") == "plain")
    }

    @Test func theColumnsAreFixedAndNothingToSayIsOneRow() {
        let csv = ExportHistory.snapshotDiff(older: "a", newer: "b", deltas: [], notCompared: [])
        #expect(csv == "id,older,newer,change,resource,label,field,old,new,note\r\n,a,b,no differences,,,,,,\r\n", "\(csv.debugDescription)")
        let skipped = ExportHistory.snapshotDiff(older: "a", newer: "b", deltas: [], notCompared: [.init(resource: "devices", why: "not read in the newer snapshot, so no change is shown.")])
        #expect(skipped == "id,older,newer,change,resource,label,field,old,new,note\r\n,a,b,not compared,devices,,,,,\"not read in the newer snapshot, so no change is shown.\"\r\n", "\(skipped.debugDescription)")
    }

    /// A resource read in part has a `partial` row, and "no differences" is only for a comparison with nothing at all to say.
    @Test func aPartReadIsNeverNoDifferences() {
        let csv = ExportHistory.snapshotDiff(older: "a", newer: "b", deltas: [], notCompared: [],
                                             partial: [.init(resource: "devices", why: "read in part in the newer snapshot (page cap)")])
        #expect(csv == "id,older,newer,change,resource,label,field,old,new,note\r\n,a,b,partial,devices,,,,,read in part in the newer snapshot (page cap)\r\n", "\(csv.debugDescription)")
    }

    /// A cell that reads as a formula is guarded as in every export.
    @Test func aFormulaIsGuarded() {
        let old = Self.snapshot(["D1": ["name": .string("a")]])
        let new = Self.snapshot(["D1": ["name": .string("=HYPERLINK(\"x\")")]])
        let csv = ExportHistory.snapshotDiff(older: "a", newer: "b", deltas: SnapshotDiff.diff(old: old, new: new), notCompared: [])
        #expect(csv.contains("\"'=HYPERLINK") && !csv.contains(",=HYPERLINK") && !csv.contains("\"=HYPERLINK"), "\(csv.debugDescription)")
    }
}
