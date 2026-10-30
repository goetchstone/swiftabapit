import Foundation
import JSONAPI

/// `apps`: an app the organization holds (Business only); its id is the App Store's Adam ID. Named for the Content
/// section, not `App`, which SwiftUI's app protocol takes. Apps and Books licences are another API (plan §2.4): the
/// only licence fact here is a blueprint's `appLicenseDeficient`.
public struct ContentApp: ResourceView {
    public static let resourceType = "apps"
    public static let fields = ["name", "bundleId", "websiteUrl", "version", "supportedOS", "isCustomApp", "appStoreUrl"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String? { attributes.string("name") }
    public var bundleID: String? { attributes.string("bundleId") }
    public var version: String? { attributes.string("version") }
    public var supportedOS: [OpenEnum<SupportedOS>]? { attributes.list("supportedOS") { $0.open() } }
    public var isCustomApp: Bool? { attributes.bool("isCustomApp") }
    /// Shown, never fetched: not a host on the app's allowlist (plan §3.3).
    public var appStoreURL: String? { attributes.string("appStoreUrl") }
    public var websiteURL: String? { attributes.string("websiteUrl") }
}

/// `packages`: a custom package (Business only).
public struct ContentPackage: ResourceView {
    public static let resourceType = "packages"
    public static let fields = ["name", "url", "hash", "bundleIds", "description", "version", "createdDateTime", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String? { attributes.string("name") }
    /// The package's location. Shown, never fetched: it isn't on the app's host allowlist (plan §3.3, invariant 4).
    public var url: String? { attributes.string("url") }
    public var hash: String? { attributes.string("hash") }
    public var bundleIDs: [String]? { attributes.list("bundleIds", \.string) }
    public var summary: String? { attributes.string("description") }
    public var version: String? { attributes.string("version") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
}

/// `blueprints`: a set of apps, packages and configurations for a set of devices, users and groups (Business only).
/// Its members come as linkages (`blueprints/{id}/relationships/<name>`), or with the blueprint when the read asks
/// for them (`include`, capped per relationship by `limit[<name>]`).
public struct Blueprint: ResourceView {
    public static let resourceType = "blueprints"
    public static let fields = ["name", "description", "status", "appLicenseDeficient", "createdDateTime", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String? { attributes.string("name") }
    public var summary: String? { attributes.string("description") }
    public var status: OpenEnum<BlueprintStatus>? { attributes.open("status") }
    /// Apple's flag that the blueprint's apps are short of licences: the only licence fact this app shows (plan §2.4).
    public var appLicenseDeficient: Bool? { attributes.bool("appLicenseDeficient") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }

    /// A blueprint's six relationships, each named for the JSON:API type it holds.
    public enum Relationship: String, CaseIterable, Sendable {
        case apps, packages, configurations, orgDevices, users, userGroups

        /// The type of the linkages and included resources it holds.
        public var resourceType: String {
            switch self {
            case .apps: ContentApp.resourceType
            case .packages: ContentPackage.resourceType
            case .configurations: Configuration.resourceType
            case .orgDevices: OrgDevice.resourceType
            case .users: User.resourceType
            case .userGroups: UserGroup.resourceType
            }
        }
    }

    /// What a read with `include` said of one relationship.
    public struct Related: Sendable, Equatable {
        /// The members Apple listed, in its order.
        public let linkages: [Linkage]
        /// Apple says the blueprint holds more than it listed (its `meta.paging` has a next cursor, or a total past
        /// the count): the include's limit cut it, and the screen says "showing N of ≥M" (invariant 8).
        public let isTruncated: Bool

        public init(linkages: [Linkage], isTruncated: Bool) {
            self.linkages = linkages
            self.isTruncated = isTruncated
        }
    }

    /// A relationship whose `data` isn't a list of linkages of its own type: never read as an empty one (failure-log
    /// 2026-10-16, "a list that wasn't a list read as none").
    public struct Malformed: Error, Equatable, Sendable {
        public let relationship: Relationship
        public init(relationship: Relationship) { self.relationship = relationship }
    }

    /// The members Apple listed for `relationship`, when the read included it; nil when Apple sent links only (a read
    /// without `include`, and every write's answer), which says nothing about the members.
    public func related(_ relationship: Relationship) throws(Malformed) -> Related? {
        guard let value = resource.relationships[relationship.rawValue] else { return nil }
        guard let object = value.object else { throw Malformed(relationship: relationship) }
        guard let data = object["data"] else { return nil }
        let linkages = data.list { item in
            Linkage(item).flatMap { $0.type.utf8.elementsEqual(relationship.resourceType.utf8) ? $0 : nil }
        }
        guard let linkages else { throw Malformed(relationship: relationship) }
        let paging = object["meta"]?["paging"]
        let more = paging?["nextCursor"]?.string.map { !$0.isEmpty } ?? false
        let total = paging?["total"]?.int.map { $0 > linkages.count } ?? false
        return Related(linkages: linkages, isTruncated: more || total)
    }

    /// The resources of `relationship`'s type among a read's `included`, in Apple's order. For one blueprint's read
    /// (`GET blueprints/{id}?include=…`), where everything included is this blueprint's, as abapit grouped them.
    public func included(_ relationship: Relationship, from included: [Resource]) -> [Resource] {
        included.filter { $0.type.utf8.elementsEqual(relationship.resourceType.utf8) }
    }
}

/// `configurations`: a configuration (Business only). Apple documents its attributes as two objects,
/// `ConfigurationCommon` and the custom-setting part.
public struct Configuration: ResourceView {
    public static let resourceType = "configurations"
    public static let fields = ["type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var type: OpenEnum<ConfigurationType>? { attributes.open("type") }
    public var name: String? { attributes.string("name") }
    public var platforms: [OpenEnum<ConfigurationPlatform>]? { attributes.list("configuredForPlatforms") { $0.open() } }
    /// A custom setting's profile. Only the single read carries it: the list sends `null` (abapit `client.py`).
    public var customSettings: CustomSettingsValues? { attributes["customSettingsValues"]?.object.map(CustomSettingsValues.init) }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
}

/// `CustomSettingsValues`: a `CUSTOM_SETTING`'s profile and its file name.
public struct CustomSettingsValues: ObjectView {
    public static let fields = ["configurationProfile", "filename"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    /// The profile as Apple sent it. Apple types it `byte` (base64); its examples send the XML itself. It may hold
    /// passwords and keys: show it through `profileText`, never raw (invariant 11).
    public var configurationProfile: String? { object.string("configurationProfile") }
    public var filename: String? { object.string("filename") }
    /// The profile as the detail view shows it, secrets masked.
    public var profileText: ProfileText? { configurationProfile.map(ProfileText.init) }
}
