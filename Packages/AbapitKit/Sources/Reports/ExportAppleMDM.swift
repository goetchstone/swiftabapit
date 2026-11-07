import AppleModels
import JSONAPI

extension ExportPolicy {
    /// The Apple MDM view's export (plan Phase 2; Appendix B's `/export/mdm-enrolled.csv`, now with the posture): the
    /// table's columns in its order (the device's serial, name, family and enrolled user, `detailsStatus`, then its details'
    /// OS, last check-in, FileVault, firewall, lock, erase and lost-mode status and storage), then the rest of Apple's
    /// documented `MDMDeviceDetail` attributes in `fields` order. Nothing here is secret; a key Apple adds later, to the
    /// list or the details, is not exported until it is listed here (invariant 11).
    ///
    /// `detailsStatus` is this app's, not Apple's: what was read of the device's details ("Read", "No details", "Role can't
    /// read", "Failed: …", "Not read"), so a row whose posture cells are empty says why, and none reads as "off".
    public static let appleMDM = Columns([
        "serialNumber", "deviceName", "productFamily", "enrolledUserId", "detailsStatus",
        "osVersion", "lastCheckInDateTime", "isFileVaultEnabled", "isFirewallEnabled", "deviceLockStatus", "deviceEraseStatus",
        "lostModeStatus", "storageFreeCapacity", "storageTotalCapacity",
        "deviceModel", "platform", "imei", "meid", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress",
    ])
}

extension CSV.Item {
    /// One Apple MDM row: the device's id; its details' attributes with the list's own set over them, so a name both carry
    /// is the list's, as the table shows it; and `detailsStatus`, set last, so nothing Apple sends under that name stands
    /// in for it. Which of these attributes leave the app is `ExportPolicy.appleMDM`'s to say.
    public init(_ device: MDMDevice, details: MDMDeviceDetail?, detailsStatus: String) {
        var attributes = (details?.attributes ?? [:]).merging(device.attributes)
        attributes["detailsStatus"] = .string(detailsStatus)
        self.init(id: device.id, attributes: attributes)
    }
}
