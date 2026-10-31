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
    public var misreadLists: [String] { misread(["supportedOS": supportedOS == nil]) }
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
    public var misreadLists: [String] { misread(["bundleIds": bundleIDs == nil]) }
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
    /// without `include`, and every write's answer), which says nothing about the members. `package`: nil reads the same
    /// after a refused include, so the app counts members through `BlueprintRead.members`, which says the refusal
    /// (verifier round 3 of the Phase 2a fixes: `related(.users)?.linkages.count ?? 0` read a refusal as no members).
    package func related(_ relationship: Relationship) throws(Malformed) -> Related? {
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
///
/// A custom setting's profile can hold Wi-Fi and VPN passwords and a certificate's key, so the compiler holds it, as it
/// holds CSV's columns (`ExportPolicy.Columns`): `resource` is the resource with `customSettingsValues` withheld
/// (`withholdingProfile`), and the profile as Apple sent it is `received`, `package`, which the app and the screen
/// models can't name. An every-attribute view (the device inspector's `ForEach(attributes.keys)`), a dump, a CSV or
/// `"\(configuration)"` of a configuration is safe because what it can reach is withheld; the detail shows the profile
/// through `customSettings?.profileText`, masked (Phase 2a review M2: masking was held by a doc comment).
public struct Configuration: ResourceView, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let resourceType = "configurations"
    public static let fields = ["type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime"]

    /// The resource, its profile withheld.
    public let resource: Resource
    /// The resource as Apple sent it, profile and all: for `ProfileText` and Phase 5's writer. Whether Phase 3's snapshots
    /// keep it is the operator's open decision, not a use: a snapshot is SQLite on disk, outside the Keychain, and the
    /// profile holds Wi-Fi and VPN passwords (invariants 3 and 11; verifier round 2), so until it is decided a snapshot
    /// stores `resource`. `BoundaryTests.onlyTheListedLinesReadTheRawProfile` lists every line in AbapitKit that names it.
    package let received: Resource

    public init(resource: Resource) {
        received = resource
        self.resource = Self.withholdingProfile(resource)
    }

    public var type: OpenEnum<ConfigurationType>? { attributes.open("type") }
    public var name: String? { attributes.string("name") }
    public var platforms: [OpenEnum<ConfigurationPlatform>]? { attributes.list("configuredForPlatforms") { $0.open() } }
    /// A custom setting's profile. Only the single read carries it: the list sends `null` (abapit `client.py`).
    public var customSettings: CustomSettingsValues? { received.attributes["customSettingsValues"]?.object.map(CustomSettingsValues.init) }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }

    public var unreadNested: [NestedKey] { CustomSettingsValues.unread(customSettings.map { [$0] }, in: "customSettingsValues") }
    public var misreadLists: [String] { misread(["configuredForPlatforms": platforms == nil]) }

    /// What was wrong with the shape of a custom setting's profile, in `ProfileProblem`'s order: the acceptance pass says
    /// each with a count. Read as no custom settings, or no profile text, a string `customSettingsValues` or an object
    /// `configurationProfile` printed `configurations/{id}: ok, 1 item` with nothing said (verifier round 2; RULE-FEEDBACK
    /// 2026-10-30: a test asserting nil for an odd shape asserts that it is said).
    public var profileProblems: [ProfileProblem] {
        switch received.attributes["customSettingsValues"] {
        case nil, .null?: []
        case .object(let values)?:
            switch values["configurationProfile"] {
            case nil, .null?, .string?: []
            case _?: [.profileNotAString]
            }
        case _?: [.customSettingsNotAnObject]
        }
    }

    /// A custom setting's profile this version can't read, said rather than read as none.
    public enum ProfileProblem: String, CaseIterable, Sendable {
        /// `customSettingsValues` is neither an object nor null: no custom settings are read.
        case customSettingsNotAnObject = "custom settings not an object"
        /// `configurationProfile` is neither a string nor null: no profile text is shown.
        case profileNotAString = "profile not a string"
    }

    /// `resource` with `customSettingsValues` withheld: an object as `CustomSettingsValues.withholding` leaves it, any
    /// other value but `null` replaced by `CustomSettingsValues.withheld`. Any resource, whatever its type: a blueprint's
    /// `included` goes through it too, so a profile Apple includes with a configuration is withheld there as well.
    package static func withholdingProfile(_ resource: Resource) -> Resource {
        guard let values = resource.attributes["customSettingsValues"], values != .null else { return resource }
        var attributes = resource.attributes
        attributes["customSettingsValues"] = values.object.map { .object(CustomSettingsValues.withholding($0)) } ?? .string(CustomSettingsValues.withheld)
        return Resource(type: resource.type, id: resource.id, attributes: attributes, relationships: resource.relationships)
    }

    /// Equal when what anyone outside AbapitKit can see is, as for `CustomSettingsValues`: the `==` Swift writes would
    /// compare `received`, so the app could test a guessed profile against the one Apple sent (verifier round 3 of the
    /// Phase 2a fixes; Phase 2b's SwiftUI diffing is the likely reason to want `Equatable`).
    public static func == (one: Self, other: Self) -> Bool { one.resource == other.resource && one.customSettings == other.customSettings }

    // What prints and reflects is the withheld resource: a struct's default description and mirror show every stored
    // property, `package` ones included.
    public var description: String { "Configuration(\(resource))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["resource": resource]) }
}

/// `CustomSettingsValues`: a `CUSTOM_SETTING`'s profile and its file name.
public struct CustomSettingsValues: ObjectView, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let fields = ["configurationProfile", "filename"]
    /// What stands where a value is withheld.
    public static let withheld = "(withheld: it may hold secrets)"

    /// The object, every value but the file name withheld (`withholding`).
    public let object: JSONObject
    /// The object as Apple sent it.
    package let received: JSONObject

    public init(_ object: JSONObject) {
        received = object
        self.object = Self.withholding(object)
    }

    /// The profile as Apple sent it. Apple types it `byte` (base64); its examples send the XML itself. It may hold
    /// passwords and keys, so only AbapitKit reads it; everyone else gets `profileText` (invariant 11).
    package var configurationProfile: String? { received.string("configurationProfile") }
    /// Read as it came: a string file name is never withheld, and anything else isn't one.
    public var filename: String? { received.string("filename") }
    /// The profile as the detail view shows it, secrets masked.
    public var profileText: ProfileText? { configurationProfile.map(ProfileText.init) }

    /// `object` with every value but a string `filename` and `null` replaced by `withheld`, its keys kept (the acceptance
    /// pass counts them). A key Apple adds beside the profile is unread and may be the profile in another form, so its
    /// value is withheld too.
    package static func withholding(_ object: JSONObject) -> JSONObject {
        var out = object
        for (key, value) in object where value != .null {
            if key.utf8.elementsEqual("filename".utf8), value.string != nil { continue }
            out[key] = .string(withheld)
        }
        return out
    }

    /// Equal when what anyone outside AbapitKit can see is: the withheld object and the masked profile. The `==` Swift
    /// writes for an `ObjectView` compared `received` too, so the app could test a guessed profile, secret and all, against
    /// the one Apple sent (verifier round 2: an equality oracle).
    public static func == (one: Self, other: Self) -> Bool { one.object == other.object && one.profileText == other.profileText }

    public var description: String { "CustomSettingsValues(\(object))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["object": object]) }
}
