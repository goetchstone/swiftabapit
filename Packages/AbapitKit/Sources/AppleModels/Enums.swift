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
