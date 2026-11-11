import Foundation
import JSONAPI

/// The Mosyle screens' and the reconciliation's exports (invariant 11: an export names its columns). Each is the adapter's
/// own names, which its allowlist already cut to (MosyleModels' `MosyleAdapter`), so a field Mosyle adds is never exported
/// until it is listed here; the Activation Lock bypass codes are on no list and the denylist refuses them besides.
extension ExportPolicy {
    /// Mosyle's devices: the table's columns (serial, name, model, family, OS, last check-in, user), then every other
    /// attribute the adapter keeps, in its order.
    public static let mosyleDevices = Columns([
        "serialNumber", "deviceName", "deviceModel", "productFamily", "osVersion", "lastCheckIn", "currentUser", "status",
        "enrolledAt", "lastMdmCheckIn", "lastPush", "appInfoUpdated", "deviceUdid", "deviceModelId", "modelName", "enrollmentType",
        "managementStatus", "userId", "userEmail", "userName", "batteryLevel", "totalDiskGB", "availableDiskGB", "isSupervised",
        "lostModeStatus", "assetTag", "imei", "meid", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress", "managedBy",
    ])

    /// Mosyle's users: abapit's four names (`adapt_user`).
    public static let mosyleUsers = Columns(["name", "email", "identifier", "userType"])

    /// Mosyle's user groups and device groups: abapit's four names (`adapt_group`).
    public static let mosyleGroups = Columns(["name", "identifier", "memberCount", "os"])

    /// Custom device attributes: what each is and where it came from. Not its `value`: an operator may keep anything in
    /// one, and only the screen shows it.
    public static let mosyleAttributes = Columns(["name", "identifier", "os", "source", "updated", "deleted"])

    /// The admin log: who did what, when, from where.
    public static let mosyleAdminLogs = Columns(["when", "admin", "action", "ip"])

    /// The reconciliation, as abapit's `/export/reconciliation.csv` wrote it: one row per serial (its id), every bucket.
    public static let reconciliation = Columns([
        "serial", "presence", "abm_status", "mosyle_status", "productFamily", "deviceModel", "osVersion", "lastCheckIn",
        "addedToOrgDateTime", "currentUser",
    ])

    /// Mosyle's OS versions, as abapit's `mosyle-os-breakdown.csv` wrote them (each version its id).
    public static let osBreakdown = Columns(["osVersion", "count", "percent"])

    /// Mosyle's stale devices: abapit's row, the serial its id.
    public static let staleDevices = Columns(["deviceModel", "productFamily", "osVersion", "lastCheckIn", "currentUser", "days_stale"])
}

extension Reconciliation {
    /// The CSV of `rows` (Apple only, both, Mosyle only, as abapit's export ordered them).
    public static func csv(_ rows: [Row]) -> String {
        CSV.text(rows.map { CSV.Item(id: $0.serial, attributes: $0.attributes) }, columns: ExportPolicy.reconciliation)
    }
}

extension OSBreakdown {
    public var csv: String {
        CSV.text(rows.map { row in
            CSV.Item(id: row.version, attributes: ["osVersion": .string(row.version), "count": .number(String(row.count)),
                                                   "percent": .number(String(row.percent))])
        }, columns: ExportPolicy.osBreakdown)
    }
}

extension StaleDevices {
    public static func csv(_ rows: [Row]) -> String {
        CSV.text(rows.map { row in
            CSV.Item(id: row.serial, attributes: ["deviceModel": row.deviceModel, "productFamily": row.productFamily, "osVersion": row.osVersion,
                                                  "lastCheckIn": row.lastCheckIn, "currentUser": row.currentUser,
                                                  "days_stale": row.daysStale.map { .number(String($0)) } ?? .null])
        }, columns: ExportPolicy.staleDevices)
    }
}
