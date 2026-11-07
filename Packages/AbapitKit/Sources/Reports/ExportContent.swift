import Foundation

/// The Content screen's exports (plan Phase 2; invariant 11: CSV export is an allowlist). Each list exports its table's
/// columns first, then the rest of Apple's documented attributes in the view's order. Two attributes are left out on
/// purpose, because a value can't be masked through a column list:
/// - a package's `url`: a custom package's location can carry credentials (a user and password, a signed query), and the
///   detail shows it with those masked (`ContentWords.location` in the screen models);
/// - a configuration's `customSettingsValues`: a custom setting's profile holds Wi-Fi and VPN passwords and certificate
///   keys (Phase 2a review M2). The list sends it as null anyway; the single read is the detail's, never an export's.
extension ExportPolicy {
    /// Apps (`ContentApp.fields`): every one documented; the App Store and website addresses are public.
    public static let apps = Columns(["name", "bundleId", "version", "supportedOS", "isCustomApp", "appStoreUrl", "websiteUrl"])

    /// Packages (`ContentPackage.fields`), without `url`.
    public static let packages = Columns(["name", "version", "bundleIds", "hash", "description", "createdDateTime", "updatedDateTime"])

    /// Blueprints (`Blueprint.fields`). Their members are relationships, not attributes: the detail lists them.
    public static let blueprints = Columns(["name", "status", "appLicenseDeficient", "description", "createdDateTime", "updatedDateTime"])

    /// Configurations (`Configuration.fields`), without `customSettingsValues`.
    public static let configurations = Columns(["name", "type", "configuredForPlatforms", "createdDateTime", "updatedDateTime"])
}
