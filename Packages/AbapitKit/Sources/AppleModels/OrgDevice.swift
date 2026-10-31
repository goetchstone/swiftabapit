import Foundation
import JSONAPI

/// An organization device (`orgDevices`): Apple Business and Apple School Manager both.
public struct OrgDevice: ResourceView {
    public static let resourceType = "orgDevices"
    public static let fields = [
        "serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel", "productFamily",
        "productType", "deviceCapacity", "partNumber", "orderNumber", "color", "status", "orderDateTime", "imei", "meid", "eid",
        "purchaseSourceId", "purchaseSourceType", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress",
        "isMdmMigrationCapable", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime",
    ]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var serialNumber: String { attributes.string("serialNumber") ?? resource.id }
    public var deviceModel: String? { attributes.string("deviceModel") }
    public var productFamily: OpenEnum<ProductFamily>? { attributes.open("productFamily") }
    public var productType: String? { attributes.string("productType") }
    public var deviceCapacity: String? { attributes.string("deviceCapacity") }
    public var color: String? { attributes.string("color") }
    public var status: OpenEnum<DeviceStatus>? { attributes.open("status") }
    public var orderNumber: String? { attributes.string("orderNumber") }
    public var partNumber: String? { attributes.string("partNumber") }
    public var orderDate: ISODate? { attributes.date("orderDateTime") }
    public var addedToOrgDate: ISODate? { attributes.date("addedToOrgDateTime") }
    /// Only a single device's GET carries it (plan §2.1).
    public var releasedFromOrgDate: ISODate? { attributes.date("releasedFromOrgDateTime") }
    public var updatedDate: ISODate? { attributes.date("updatedDateTime") }
    /// Lists read as every view reads one (`JSONObject.list(_:_:)`): nil when missing or when an item isn't a string
    /// (Phase 2a review L6: Phase 1's reader kept the items that fit, so this read `[]` where `MDMDeviceDetail.imei`
    /// read nil).
    public var imei: [String]? { attributes.list("imei", \.string) }
    public var meid: [String]? { attributes.list("meid", \.string) }
    public var eid: String? { attributes.string("eid") }
    public var purchaseSourceID: String? { attributes.string("purchaseSourceId") }
    public var purchaseSourceType: OpenEnum<PurchaseSourceType>? { attributes.open("purchaseSourceType") }
    public var wifiMAC: String? { attributes.string("wifiMacAddress") }
    public var bluetoothMAC: String? { attributes.string("bluetoothMacAddress") }
    public var ethernetMACs: [String]? { attributes.list("ethernetMacAddress", \.string) }
    public var isMigrationCapable: Bool? { attributes.bool("isMdmMigrationCapable") }
    public var migrationStatus: OpenEnum<MigrationStatus>? { attributes.open("mdmMigrationStatus") }
    public var migrationDeadline: ISODate? { attributes.date("mdmMigrationDeadlineDateTime") }

    /// Every identifier Find (⌘L) matches exactly, as abapit's `/find` did: serial, IMEI, MEID, EID, order
    /// number and the network addresses (plan §4). A list that isn't a list of strings gives none.
    public var identifiers: [String] {
        [serialNumber, eid, orderNumber, wifiMAC, bluetoothMAC].compactMap { $0 } + (imei ?? []) + (meid ?? []) + (ethernetMACs ?? [])
    }
    public var misreadLists: [String] { misread(["imei": imei == nil, "meid": meid == nil, "ethernetMacAddress": ethernetMACs == nil]) }
}

/// `appleCareCoverage`: one coverage of a device.
public struct AppleCareCoverage: ResourceView {
    public static let resourceType = "appleCareCoverage"
    public static let fields = ["agreementNumber", "contractCancelDateTime", "description", "endDateTime", "isCanceled", "isRenewable",
                                "paymentType", "startDateTime", "status"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var summary: String? { attributes.string("description") }
    public var status: OpenEnum<CoverageStatus>? { attributes.open("status") }
    public var paymentType: OpenEnum<PaymentType>? { attributes.open("paymentType") }
    public var start: ISODate? { attributes.date("startDateTime") }
    public var end: ISODate? { attributes.date("endDateTime") }
    public var isCanceled: Bool { attributes.bool("isCanceled") ?? false }
    public var cancelDate: ISODate? { attributes.date("contractCancelDateTime") }
    public var isRenewable: Bool? { attributes.bool("isRenewable") }
    public var agreementNumber: String? { attributes.string("agreementNumber") }
}

/// `activationLockStatus`: whether the device is locked, and by whom (Business 2.5, School 1.7).
public struct ActivationLockStatus: ResourceView {
    public static let resourceType = "activationLockStatus"
    public static let fields = ["isLocked", "lockType"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var isLocked: Bool? { attributes.bool("isLocked") }
    public var lockType: OpenEnum<LockType>? { attributes.open("lockType") }
    /// A person's Apple Account holds it: blocks redeploying and releasing the device.
    public var blocksRelease: Bool { isLocked == true && lockType == .known(.user) }
}

/// `mdmServers`: a device management service, with its health fields (plan §2.1).
public struct MDMService: ResourceView {
    public static let resourceType = "mdmServers"
    public static let fields = ["createdDateTime", "defaultProductFamilies", "deviceCount", "enableMdmDisownFlag", "lastConnectedDateTime",
                                "lastConnectedIp", "serverName", "serverType", "status", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String { attributes.string("serverName") ?? resource.id }
    public var type: OpenEnum<ServiceType>? { attributes.open("serverType") }
    public var status: OpenEnum<ServiceStatus>? { attributes.open("status") }
    public var deviceCount: Int? { attributes.int("deviceCount") }
    public var lastConnected: ISODate? { attributes.date("lastConnectedDateTime") }
    /// Shown, never exported by default (plan §3.9).
    public var lastConnectedIP: String? { attributes.string("lastConnectedIp") }
    /// Nil when missing or when an item isn't a string, as every list reads (Phase 2a review L6).
    public var defaultProductFamilies: [OpenEnum<ServiceProductFamily>]? { attributes.list("defaultProductFamilies") { $0.open() } }
    public var misreadLists: [String] { misread(["defaultProductFamilies": defaultProductFamilies == nil]) }
    public var disownFlag: Bool? { attributes.bool("enableMdmDisownFlag") }
    public var created: ISODate? { attributes.date("createdDateTime") }

    /// Days since it last connected, at `now`; nil when Apple doesn't say.
    public func daysSinceConnected(now: Date) -> Int? {
        lastConnected.map { Int(now.timeIntervalSince($0.date) / 86_400) }
    }
}
