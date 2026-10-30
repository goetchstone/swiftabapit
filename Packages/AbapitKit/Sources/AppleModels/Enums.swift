import Foundation
import JSONAPI

// Apple's value sets, each checked against Contracts/apple/business-2.6.json by AppleModelsTests. Fields the
// contract types as plain strings (productFamily, status, purchaseSourceType, serverType) take their values
// from the plan's Appendix A and Apple's examples; they are open enums all the same.

public enum ProductFamily: String, KnownValues {
    case iPhone, iPad, mac = "Mac", appleTV = "AppleTV", watch = "Watch", vision = "Vision"
}

public enum DeviceStatus: String, KnownValues {
    case assigned = "ASSIGNED", unassigned = "UNASSIGNED"
}

/// Where a device came from: `OrgDevice`'s `purchaseSourceType` (a plain string in Apple's docs, these values in its
/// examples and Appendix A) and the device-added audit payload's (`AuditEventPurchaseSourceType`, the same three).
public enum PurchaseSourceType: String, KnownValues {
    case apple = "APPLE", reseller = "RESELLER", manuallyAdded = "MANUALLY_ADDED"
}

/// `MdmMigrationStatus`.
public enum MigrationStatus: String, KnownValues {
    case requested = "REQUESTED", started = "STARTED", success = "SUCCESS", failed = "FAILED"
}

/// `AppleCareCoverageStatus`.
public enum CoverageStatus: String, KnownValues {
    case active = "ACTIVE", inactive = "INACTIVE"
}

/// `AppleCareCoveragePaymentType`.
public enum PaymentType: String, KnownValues {
    case abeSubscription = "ABE_SUBSCRIPTION", paidUpFront = "PAID_UP_FRONT", subscription = "SUBSCRIPTION", none = "NONE"
}

/// `ActivationLockType`: who holds the lock. `USER` means a person's Apple Account: the device can't be
/// redeployed or released until they remove it (plan §2.1).
public enum LockType: String, KnownValues {
    case mdm = "MDM", user = "USER", none = "NONE"
}

/// `MdmServerStatus`.
public enum ServiceStatus: String, KnownValues {
    case active = "ACTIVE", inactive = "INACTIVE", deleted = "DELETED"
}

/// The `serverType` values Apple documents in its examples and Appendix A.
public enum ServiceType: String, KnownValues {
    case mdm = "MDM", appleConfigurator = "APPLE_CONFIGURATOR", appleMDM = "APPLE_MDM"
}

/// `MdmServerProductFamily`: a service's default for new devices.
public enum ServiceProductFamily: String, KnownValues {
    case appleTV = "APPLE_TV", iPad = "IPAD", iPhone = "IPHONE", iPod = "IPOD", mac = "MAC", vision = "VISION", watch = "WATCH"
}

/// `UserStatus`.
public enum UserStatus: String, KnownValues {
    case new = "NEW", released = "RELEASED", active = "ACTIVE", deactivated = "DEACTIVATED", locked = "LOCKED",
         lockedForSharedIPad = "LOCKED_FOR_SHARED_IPAD"
}

/// `UserPhoneNumberType`.
public enum UserPhoneNumberType: String, KnownValues {
    case work = "WORK", home = "HOME", mobile = "MOBILE"
}

/// `UserGroupType`.
public enum UserGroupType: String, KnownValues {
    case standard = "STANDARD", smart = "SMART"
}

/// `UserGroupStatus`: Apple documents one value so far.
public enum UserGroupStatus: String, KnownValues {
    case active = "ACTIVE"
}

/// `SupportedOS`: the platforms an app runs on.
public enum SupportedOS: String, KnownValues {
    case unspecified = "SUPPORTED_OS_UNSPECIFIED", iPadOS = "SUPPORTED_OS_IPADOS", iOS = "SUPPORTED_OS_IOS", macOS = "SUPPORTED_OS_MACOS",
         tvOS = "SUPPORTED_OS_TVOS", watchOS = "SUPPORTED_OS_WATCHOS", visionOS = "SUPPORTED_OS_VISIONOS"
}

/// `BlueprintStatus`.
public enum BlueprintStatus: String, KnownValues {
    case active = "ACTIVE", toBeDeleted = "TO_BE_DELETED"
}

/// `ConfigurationType`: 22 built-in types the app shows read-only, and `CUSTOM_SETTING`, the one Apple lets a client
/// write (plan §2.1; Phase 5).
public enum ConfigurationType: String, KnownValues {
    case airDrop = "AIR_DROP", airPrint = "AIR_PRINT", appAccess = "APP_ACCESS", appleIntelligenceSiri = "APPLE_INTELLIGENCE_SIRI",
         applicationLayerFirewall = "APPLICATION_LAYER_FIREWALL", authenticationScreenLock = "AUTHENTICATION_SCREEN_LOCK",
         certificate = "CERTIFICATE", conferenceRoomDisplay = "CONFERENCE_ROOM_DISPLAY", contentCaching = "CONTENT_CACHING",
         customProfile = "CUSTOM_PROFILE", customSetting = "CUSTOM_SETTING", dataManagement = "DATA_MANAGEMENT",
         energySaver = "ENERGY_SAVER", fileVault = "FILE_VAULT", gateKeeper = "GATE_KEEPER", iCloud = "ICLOUD",
         loginWindow = "LOGIN_WINDOW", mediaManagement = "MEDIA_MANAGEMENT", softwareUpdate = "SOFTWARE_UPDATE", vpn = "VPN",
         webClip = "WEB_CLIP", webFilter = "WEB_FILTER", wifi = "WIFI"

    /// Only a custom setting can be created, changed or deleted through the API.
    public var isWritable: Bool { self == .customSetting }
}

/// `ConfigurationPlatform`. `PLATFORM_IOS` covers iPadOS too.
public enum ConfigurationPlatform: String, KnownValues {
    case macOS = "PLATFORM_MACOS", iOS = "PLATFORM_IOS", tvOS = "PLATFORM_TVOS", visionOS = "PLATFORM_VISIONOS"
}

/// `DeviceEraseStatus`.
public enum DeviceEraseStatus: String, KnownValues {
    case notErased = "NOT_ERASED", erased = "ERASED"
}

/// `DeviceLockStatus`.
public enum DeviceLockStatus: String, KnownValues {
    case locked = "LOCKED", unlocked = "UNLOCKED"
}

/// `LostModeStatus`.
public enum LostModeStatus: String, KnownValues {
    case enabled = "ENABLED", disabled = "DISABLED"
}

/// `AuditEventActorType`: who did it.
public enum AuditEventActorType: String, KnownValues {
    case user = "USER", apiUser = "API_USER", system = "SYSTEM"
}

/// `AuditEventCategory`. Apple says its list is incomplete (plan §3.3): a new value survives raw.
public enum AuditEventCategory: String, KnownValues {
    case organization = "ORGANIZATION", accountActivity = "ACCOUNT_ACTIVITY", deviceInventory = "DEVICE_INVENTORY",
         purchasing = "PURCHASING", deviceManagement = "DEVICE_MANAGEMENT"
}

/// `AuditEventOutcome`.
public enum AuditEventOutcome: String, KnownValues {
    case success = "SUCCESS", failure = "FAILURE"
}

/// `AuditEventSubjectType`: what it was done to. Apple says its list is incomplete (plan §3.3).
public enum AuditEventSubjectType: String, KnownValues {
    case organization = "ORGANIZATION", user = "USER", location = "LOCATION", device = "DEVICE", collection = "COLLECTION",
         deviceManagementSetting = "DEVICE_MANAGEMENT_SETTING", subscription = "SUBSCRIPTION", domain = "DOMAIN", apiUser = "API_USER"
}

/// `AuditEventReleaseEntityType`: who released a device from the organization.
public enum AuditEventReleaseEntityType: String, KnownValues {
    case user = "USER", mdm = "MDM", reseller = "RESELLER", api = "API", replacement = "REPLACEMENT"
}

/// `AuditEventIdpProtocol`.
public enum AuditEventIdpProtocol: String, KnownValues {
    case oidc = "OIDC", saml = "SAML"
}

/// `AuditEventIdpVendorName`.
public enum AuditEventIdpVendorName: String, KnownValues {
    case google = "GOOGLE", microsoft = "MICROSOFT", microsoftOIDC = "MICROSOFT_OIDC", genericIdP = "GENERIC_IDP"
}
