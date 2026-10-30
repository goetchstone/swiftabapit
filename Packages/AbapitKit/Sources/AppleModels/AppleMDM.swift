import Foundation
import JSONAPI

/// `mdmDevices`: a device enrolled in Apple's built-in device management (Business only). Its posture is a second
/// read, `mdmDevices/{id}/details`: abapit read the undocumented `mdmDevices/{id}` (plan §2.3, defect 11). Apple gives
/// no example of either.
public struct MDMDevice: ResourceView {
    public static let resourceType = "mdmDevices"
    public static let fields = ["serialNumber", "deviceName", "productFamily", "enrolledUserId"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var serialNumber: String? { attributes.string("serialNumber") }
    public var deviceName: String? { attributes.string("deviceName") }
    /// A plain string in Apple's docs, with no example: read as `OrgDevice`'s values (assumed; an unknown value
    /// survives raw and the acceptance pass names it).
    public var productFamily: OpenEnum<ProductFamily>? { attributes.open("productFamily") }
    public var enrolledUserID: String? { attributes.string("enrolledUserId") }
}

/// `mdmDeviceDetails`: an Apple-managed device's posture, `GET mdmDevices/{id}/details` (plan §2.1).
public struct MDMDeviceDetail: ResourceView {
    public static let resourceType = "mdmDeviceDetails"
    public static let fields = [
        "serialNumber", "deviceName", "deviceModel", "osVersion", "platform", "imei", "meid", "wifiMacAddress", "bluetoothMacAddress",
        "ethernetMacAddress", "lastCheckInDateTime", "isFirewallEnabled", "isFileVaultEnabled", "storageFreeCapacity",
        "storageTotalCapacity", "deviceLockStatus", "deviceEraseStatus", "lostModeStatus",
    ]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var serialNumber: String? { attributes.string("serialNumber") }
    public var deviceName: String? { attributes.string("deviceName") }
    public var deviceModel: String? { attributes.string("deviceModel") }
    public var osVersion: String? { attributes.string("osVersion") }
    /// A plain string in Apple's docs, values undocumented: shown as it comes.
    public var platform: String? { attributes.string("platform") }
    public var imei: [String]? { attributes.list("imei", \.string) }
    public var meid: [String]? { attributes.list("meid", \.string) }
    public var wifiMAC: String? { attributes.string("wifiMacAddress") }
    public var bluetoothMAC: String? { attributes.string("bluetoothMacAddress") }
    /// One address here, where `OrgDevice` lists several.
    public var ethernetMAC: String? { attributes.string("ethernetMacAddress") }
    public var lastCheckIn: ISODate? { attributes.date("lastCheckInDateTime") }
    public var isFirewallEnabled: Bool? { attributes.bool("isFirewallEnabled") }
    public var isFileVaultEnabled: Bool? { attributes.bool("isFileVaultEnabled") }
    /// Integers in Apple's docs, read as bytes (assumed; check live).
    public var storageFree: Int? { attributes.int("storageFreeCapacity") }
    public var storageTotal: Int? { attributes.int("storageTotalCapacity") }
    public var lockStatus: OpenEnum<DeviceLockStatus>? { attributes.open("deviceLockStatus") }
    public var eraseStatus: OpenEnum<DeviceEraseStatus>? { attributes.open("deviceEraseStatus") }
    public var lostModeStatus: OpenEnum<LostModeStatus>? { attributes.open("lostModeStatus") }
}
