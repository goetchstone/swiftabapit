import Foundation
import JSONAPI
import MosyleModels
import Testing
@testable import Reports

/// The Mosyle exports (invariant 11): each a list of the adapter's own names, none the denylist refuses, and the devices'
/// list exactly what the adapter keeps, so an attribute it starts keeping is decided here, not exported unseen.
@Suite("Mosyle exports")
struct ExportMosyleTests {
    static let lists: [(String, ExportPolicy.Columns)] = [
        ("devices", ExportPolicy.mosyleDevices), ("users", ExportPolicy.mosyleUsers), ("groups", ExportPolicy.mosyleGroups), ("attributes", ExportPolicy.mosyleAttributes),
        ("admin logs", ExportPolicy.mosyleAdminLogs), ("reconciliation", ExportPolicy.reconciliation), ("OS versions", ExportPolicy.osBreakdown), ("stale", ExportPolicy.staleDevices),
    ]

    @Test func everyColumnIsWritten() {
        for (name, columns) in Self.lists {
            #expect(columns.names.allSatisfy { ExportPolicy.permits($0, includeNotByDefault: false) }, "\(name)")
            #expect(Set(columns.names).count == columns.names.count, "\(name)")
        }
    }

    @Test func theDevicesExportIsWhatTheAdapterKeeps() {
        #expect(Set(ExportPolicy.mosyleDevices.names) == MosyleAdapter.deviceAttributes)
        #expect(Set(ExportPolicy.mosyleAttributes.names).isSubset(of: Set(MosyleAdapter.attributeFields.map(\.name) + ["os"])))
        #expect(!ExportPolicy.mosyleAttributes.names.contains("value"))
        #expect(Set(ExportPolicy.mosyleAdminLogs.names) == Set(MosyleAdapter.adminLogFields.map(\.name)))
    }

    /// A device's bypass codes, sent or not, never reach its CSV: the adapter drops them, and no list names them.
    @Test func aDevicesBypassCodesNeverReachItsCSV() {
        let raw: JSONObject = ["serial_number": .string("C02TEST"), "activation_bypass": .string("CANARY-1"), "activation_bypass_mdm": .string("CANARY-2")]
        let device = MosyleAdapter.device(raw)
        let text = CSV.text([CSV.Item(device)], columns: ExportPolicy.mosyleDevices)
        #expect(text.hasPrefix("id,serialNumber,deviceName,") && text.contains("C02TEST") && !text.contains("CANARY"))
    }

    @Test func theReconciliationCSVIsAbapitsRows() {
        let report = Reconciliation(apple: [Resource(type: "orgDevices", id: "C02A", attributes: ["status": .string("ASSIGNED")])],
                                    mosyle: [Resource(type: "orgDevices", id: "c02a", attributes: ["osVersion": .string("27.0")]),
                                             Resource(type: "orgDevices", id: "C02B", attributes: [:])])
        let lines = Reconciliation.csv(report.rows).split(separator: "\r\n")
        #expect(lines.first == "id,serial,presence,abm_status,mosyle_status,productFamily,deviceModel,osVersion,lastCheckIn,addedToOrgDateTime,currentUser")
        #expect(lines.dropFirst().map { String($0.prefix { $0 != "," }) } == ["C02A", "C02B"])
        #expect(lines.dropFirst().first?.contains(",both,ASSIGNED,,") == true)
    }
}
