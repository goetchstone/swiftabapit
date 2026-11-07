import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// Invariant 11 for the Apple MDM export: a fixed list of columns, the table's first, then every other documented
/// attribute of the device and its details; one column of ours, `detailsStatus`, says what was read of each device's
/// details, so an empty posture cell is never taken for "off".
@Suite("Apple MDM export")
struct ExportAppleMDMTests {
    static func cells(_ text: String) -> [[String]] {
        text.components(separatedBy: "\r\n").filter { !$0.isEmpty }.map { $0.components(separatedBy: ",") }
    }

    /// The table's columns in its order, then the rest of `MDMDeviceDetail.fields` in Apple's order: each of the two views'
    /// documented attributes once, nothing else but `detailsStatus`, and nothing the denylist would drop (so a listed
    /// column can't vanish unsaid).
    @Test func theColumnsAreTheTablesThenEveryDocumentedAttribute() {
        let columns = ExportPolicy.appleMDM.names
        let table = ["serialNumber", "deviceName", "productFamily", "enrolledUserId", "detailsStatus", "osVersion", "lastCheckInDateTime",
                     "isFileVaultEnabled", "isFirewallEnabled", "deviceLockStatus", "deviceEraseStatus", "lostModeStatus",
                     "storageFreeCapacity", "storageTotalCapacity"]
        #expect(columns == table + MDMDeviceDetail.fields.filter { !table.contains($0) })
        #expect(Set(columns).count == columns.count)
        #expect(Set(columns) == Set(MDMDevice.fields + MDMDeviceDetail.fields + ["detailsStatus"]))
        for column in columns {
            #expect(!ExportPolicy.isSensitive(column), "\(column)")
            #expect(!ExportPolicy.isNotByDefault(column), "\(column)")
        }
    }

    /// One row: the device's id, its list attributes (they win where the details repeat one: the table shows the list's
    /// name), its details' beside them, and what was read. A key off the list, a bypass code included, never leaves.
    @Test func aRowIsTheDeviceThenItsDetailsThenWhatWasRead() {
        let device = MDMDevice(resource: Resource(type: "mdmDevices", id: "S1", attributes: [
            "serialNumber": .string("S1"), "deviceName": .string("List name"), "productFamily": .string("Mac"),
            "enrolledUserId": .string("U1"), "activationLockBypassCode": .string("canary-device-bypass"),
        ]))
        let details = MDMDeviceDetail(resource: Resource(type: "mdmDeviceDetails", id: "S1", attributes: [
            "serialNumber": .string("S1"), "deviceName": .string("Details name"), "osVersion": .string("27.0.1"),
            "isFileVaultEnabled": .bool(false), "imei": .array([.string("350000000000014"), .string("350000000000022")]),
            "activationLockBypassCode": .string("canary-details-bypass"), "someFutureAttribute": .string("canary-future"),
            "detailsStatus": .string("forged"),
        ]))
        let read = CSV.Item(device, details: details, detailsStatus: "Read")
        #expect(read.id == "S1")
        let text = CSV.text([read, CSV.Item(device, details: nil, detailsStatus: "Not read")], columns: ExportPolicy.appleMDM)
        let rows = Self.cells(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ["id"] + ExportPolicy.appleMDM.names)
        #expect(rows[1] == ["S1", "S1", "List name", "Mac", "U1", "Read", "27.0.1", "", "False"] + Array(repeating: "", count: 8)
                + ["350000000000014; 350000000000022", "", "", "", ""], "\(rows[1])")
        #expect(rows[2] == ["S1", "S1", "List name", "Mac", "U1", "Not read"] + Array(repeating: "", count: 16), "\(rows[2])")
        #expect(!text.contains("canary") && !text.contains("forged"), "\(text)")
        // The id column is the device's id, which Apple doesn't promise is its serial.
        let other = MDMDevice(resource: Resource(type: "mdmDevices", id: "D-7", attributes: ["serialNumber": .string("S7")]))
        #expect(Self.cells(CSV.text([CSV.Item(other, details: nil, detailsStatus: "Not read")], columns: ExportPolicy.appleMDM))[1].prefix(2)
                == ["D-7", "S7"])
    }
}
