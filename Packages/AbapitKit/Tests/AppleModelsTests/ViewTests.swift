import AppleModels
import Foundation
import JSONAPI
import Testing

/// The views' typed reads: what each field reads, nil for a field that is missing or of another type (invariant 10:
/// Apple adds and nulls fields across versions), and the parts Apple gave no example for.
@Suite("Apple model views")
struct ViewTests {
    static func resource(_ type: String, _ attributes: JSONObject, relationships: JSONObject = [:]) -> Resource {
        Resource(type: type, id: "id-1", attributes: attributes, relationships: relationships)
    }

    /// Every attribute set to a value of a type no field has (an object), so every typed read is nil.
    static func mistyped(_ fields: [String]) -> JSONObject {
        var attributes = JSONObject()
        for field in fields { attributes[field] = .object(["x": .number("1")]) }
        return attributes
    }

    @Test func aUserReadsNilForWhatIsMissingOrMistyped() {
        for attributes in [JSONObject(), Self.mistyped(User.fields)] {
            let user = User(resource: Self.resource("users", attributes))
            #expect(user.firstName == nil && user.middleName == nil && user.lastName == nil && user.fullName == nil)
            #expect(user.email == nil && user.managedAppleAccount == nil && user.isExternalUser == nil && user.status == nil)
            #expect(user.employeeNumber == nil && user.costCenter == nil && user.division == nil && user.department == nil)
            #expect(user.jobTitle == nil && user.startDate == nil && user.created == nil && user.updated == nil)
            #expect(user.phoneNumbers == nil && user.roleOuList == nil)
        }
        // A list holding something that isn't one of its items is not a list of them: nil, never the items that fit.
        let mixed = User(resource: Self.resource("users", ["phoneNumbers": .array([.object(["phoneNumber": .string("1")]), .string("2")]),
                                                         "roleOuList": .array([.null])]))
        #expect(mixed.phoneNumbers == nil && mixed.roleOuList == nil)
        let empty = User(resource: Self.resource("users", ["phoneNumbers": .array([]), "roleOuList": .array([])]))
        #expect(empty.phoneNumbers == [] && empty.roleOuList == [])
    }

    @Test func aUsersNameIsItsPartsThatAreThere() {
        #expect(User(resource: Self.resource("users", ["firstName": .string("Ana"), "lastName": .string("Ruiz")])).fullName == "Ana Ruiz")
        #expect(User(resource: Self.resource("users", ["middleName": .string(""), "lastName": .string("Ruiz")])).fullName == "Ruiz")
        #expect(User(resource: Self.resource("users", ["firstName": .string("")])).fullName == nil)
    }

    @Test func aPhoneNumberAndARoleKeepWhatTheyDontRead() {
        let phone = UserPhoneNumber(["phoneNumber": .string("+1"), "type": .string("PAGER"), "extension": .string("22")])
        #expect(phone.type == .unknown("PAGER") && phone.phoneNumber == "+1")
        #expect(phone.unreadFields == ["extension"])
        let role = UserRoleOuMapping(["roleName": .number("1"), "ouId": .string("OU1"), "scope": .string("x")])
        #expect(role.roleName == nil && role.ouID == "OU1" && role.unreadFields == ["scope"])
    }

    @Test func groupsUnitsAppsAndPackagesReadNilForWhatIsMissingOrMistyped() {
        for attributes in [JSONObject(), Self.mistyped(UserGroup.fields)] {
            let group = UserGroup(resource: Self.resource("userGroups", attributes))
            #expect(group.name == nil && group.ouID == nil && group.type == nil && group.status == nil)
            #expect(group.totalMemberCount == nil && group.created == nil && group.updated == nil)
        }
        for attributes in [JSONObject(), Self.mistyped(OrganizationalUnit.fields)] {
            let unit = OrganizationalUnit(resource: Self.resource("organizationalUnits", attributes))
            #expect(unit.name == nil && unit.summary == nil && unit.created == nil && unit.updated == nil)
        }
        for attributes in [JSONObject(), Self.mistyped(ContentApp.fields)] {
            let app = ContentApp(resource: Self.resource("apps", attributes))
            #expect(app.name == nil && app.bundleID == nil && app.version == nil && app.isCustomApp == nil && app.supportedOS == nil)
            #expect(app.appStoreURL == nil && app.websiteURL == nil)
        }
        for attributes in [JSONObject(), Self.mistyped(ContentPackage.fields)] {
            let package = ContentPackage(resource: Self.resource("packages", attributes))
            #expect(package.name == nil && package.summary == nil && package.version == nil && package.bundleIDs == nil)
            #expect(package.hash == nil && package.url == nil && package.created == nil && package.updated == nil)
        }
        // A count written as a fraction is not a count.
        #expect(UserGroup(resource: Self.resource("userGroups", ["totalMemberCount": .number("2.5")])).totalMemberCount == nil)
    }

    // MARK: Blueprints

    static func included(_ relationship: String, _ ids: [String], meta: JSONObject? = nil) -> JSONValue {
        var object: JSONObject = ["data": .array(ids.map { .object(["type": .string(relationship), "id": .string($0)]) })]
        if let meta { object["meta"] = .object(meta) }
        return .object(object)
    }

    @Test func aBlueprintReadsItsIncludedRelationships() throws {
        let blueprint = Blueprint(resource: Self.resource("blueprints", ["name": .string("Onboarding")], relationships: [
            "apps": Self.included("apps", ["361309726", "409201541"]),
            "users": Self.included("users", ["u1"], meta: ["paging": .object(["nextCursor": .string("abc"), "limit": .number("1")])]),
            "userGroups": Self.included("userGroups", ["g1", "g2"], meta: ["paging": .object(["total": .number("5")])]),
            "orgDevices": Self.included("orgDevices", [], meta: ["paging": .object(["total": .number("0"), "nextCursor": .string("")])]),
            "packages": .object(["links": .object(["self": .string("https://api-business.apple.com/v1/blueprints/b/relationships/packages")])]),
        ]))
        let apps = try #require(try blueprint.related(.apps))
        #expect(apps.linkages == [Linkage(type: "apps", id: "361309726"), Linkage(type: "apps", id: "409201541")])
        #expect(!apps.isTruncated)
        // Apple says there is more than it included (a next cursor, or a total past what came): the screen says so.
        #expect(try blueprint.related(.users)?.isTruncated == true)
        #expect(try blueprint.related(.userGroups)?.isTruncated == true)
        #expect(try blueprint.related(.orgDevices) == Blueprint.Related(linkages: [], isTruncated: false))
        // Links only, or nothing: not included, so not read. Never "none".
        #expect(try blueprint.related(.packages) == nil)
        #expect(try blueprint.related(.configurations) == nil)
    }

    /// A relationship's `data` that isn't a list of linkages of its own type is malformed, never an empty list (failure-log
    /// 2026-10-16, "a list that wasn't a list read as none").
    @Test(arguments: [
        JSONValue.object(["data": .object([:])]), .object(["data": .null]), .object(["data": .string("apps")]),
        .object(["data": .array([.object(["type": .string("apps")])])]),
        .object(["data": .array([.object(["type": .string("packages"), "id": .string("p1")])])]),
        .object(["data": .array([.object(["type": .string("apps"), "id": .string("a1")]), .number("1")])]),
        .string("apps"),
    ])
    func aRelationshipThatIsntALinkageListIsMalformed(value: JSONValue) {
        let blueprint = Blueprint(resource: Self.resource("blueprints", [:], relationships: ["apps": value]))
        #expect(throws: Blueprint.Malformed(relationship: .apps)) { try blueprint.related(.apps) }
    }

    @Test func aBlueprintsIncludedResourcesAreFoundByType() throws {
        let included = [
            Resource(type: "apps", id: "a1", attributes: ["name": .string("Pages")]),
            Resource(type: "configurations", id: "c1"),
            Resource(type: "apps", id: "a2"),
            Resource(type: "app\u{73}\u{301}", id: "a3"),
        ]
        let blueprint = Blueprint(resource: Self.resource("blueprints", [:]))
        #expect(blueprint.included(.apps, from: included).map(\.id) == ["a1", "a2"])
        #expect(blueprint.included(.configurations, from: included).map(\.id) == ["c1"])
        #expect(blueprint.included(.users, from: included).isEmpty)
        #expect(Blueprint.Relationship.apps.resourceType == ContentApp.resourceType)
        #expect(Blueprint.Relationship.orgDevices.resourceType == OrgDevice.resourceType)
        #expect(Blueprint.Relationship.users.resourceType == User.resourceType)
        #expect(Blueprint.Relationship.userGroups.resourceType == UserGroup.resourceType)
        #expect(Blueprint.Relationship.packages.resourceType == ContentPackage.resourceType)
        #expect(Blueprint.Relationship.configurations.resourceType == Configuration.resourceType)
    }

    @Test func aBlueprintReadsNilForWhatIsMissingOrMistyped() {
        for attributes in [JSONObject(), Self.mistyped(Blueprint.fields)] {
            let blueprint = Blueprint(resource: Self.resource("blueprints", attributes))
            #expect(blueprint.name == nil && blueprint.summary == nil && blueprint.status == nil)
            #expect(blueprint.appLicenseDeficient == nil && blueprint.created == nil && blueprint.updated == nil)
        }
        #expect(Blueprint(resource: Self.resource("blueprints", ["status": .string("TO_BE_DELETED")])).status == .known(.toBeDeleted))
    }

    // MARK: Configurations

    /// The list carries `customSettingsValues: null`; only the single GET carries the profile (abapit client.py).
    @Test func aConfigurationsCustomSettingsComeOnlyWithTheSingleRead() {
        let listed = Configuration(resource: Self.resource("configurations", ["type": .string("WIFI"), "customSettingsValues": .null]))
        #expect(listed.customSettings == nil)
        #expect(listed.type == .known(.wifi) && listed.type?.known?.isWritable == false)
        #expect(listed.unreadAttributes.isEmpty)
        let single = Configuration(resource: Self.resource("configurations", [
            "type": .string("CUSTOM_SETTING"),
            "customSettingsValues": .object(["configurationProfile": .string("<plist/>"), "filename": .string("x.mobileconfig"),
                                             "signed": .bool(true)]),
        ]))
        #expect(single.type?.known?.isWritable == true)
        #expect(single.customSettings?.configurationProfile == "<plist/>" && single.customSettings?.filename == "x.mobileconfig")
        #expect(single.customSettings?.unreadFields == ["signed"])
        for attributes in [JSONObject(), Self.mistyped(Configuration.fields)] {
            let configuration = Configuration(resource: Self.resource("configurations", attributes))
            #expect(configuration.name == nil && configuration.type == nil && configuration.platforms == nil)
            #expect(configuration.customSettings?.configurationProfile == nil && configuration.created == nil && configuration.updated == nil)
        }
        #expect(ConfigurationType.allCases.filter(\.isWritable) == [.customSetting])
    }

    /// What a configuration hands out has its custom settings withheld whatever their shape, keys kept and Apple's order
    /// with them; a null and a string file name stay; anything else, a file name that isn't a string included, is the
    /// marker. AbapitKit still reads the profile as it came (Phase 2a review M2).
    @Test func aConfigurationWithholdsItsCustomSettingsWhateverTheirShape() throws {
        let secret: JSONValue = .string("hunter2")
        for shape in [secret, .array([secret]), .number("4321"), .bool(true)] {
            let configuration = Configuration(resource: Self.resource("configurations", ["name": .string("n"), "customSettingsValues": shape, "type": .string("X")]))
            #expect(configuration.attributes.keys == ["name", "customSettingsValues", "type"])
            #expect(configuration.attributes["customSettingsValues"] == .string(CustomSettingsValues.withheld) && configuration.customSettings == nil, "\(shape)")
            #expect(configuration.received.attributes["customSettingsValues"] == shape)
        }
        let settings = try #require(Configuration(resource: Self.resource("configurations", ["customSettingsValues": .object([
            "configurationProfile": secret, "filename": .object(["x": secret]), "extra": .array([secret]), "gone": .null])])).customSettings)
        #expect(settings.object.keys == ["configurationProfile", "filename", "extra", "gone"] && settings.filename == nil && settings.object["gone"] == .null)
        for key in ["configurationProfile", "filename", "extra"] { #expect(settings.object[key] == .string(CustomSettingsValues.withheld), "\(key)") }
        #expect(settings.configurationProfile == "hunter2" && settings.received["extra"] == .array([secret]))
        // A resource of any type passes through the same: a blueprint's `included` goes through it.
        let other = Resource(type: "apps", id: "a", attributes: ["name": .string("Pages")])
        #expect(Configuration.withholdingProfile(other) == other)
    }

    // MARK: Apple MDM (no example from Apple)

    @Test func anMDMDeviceReadsItsFields() {
        let device = MDMDevice(resource: Self.resource("mdmDevices", [
            "serialNumber": .string("C02TEST0001"), "deviceName": .string("Front desk"), "productFamily": .string("Mac"),
            "enrolledUserId": .string("u-1"),
        ]))
        #expect(device.serialNumber == "C02TEST0001" && device.deviceName == "Front desk" && device.enrolledUserID == "u-1")
        #expect(device.productFamily == .known(.mac))
        #expect(device.unreadAttributes.isEmpty)
        for attributes in [JSONObject(), Self.mistyped(MDMDevice.fields)] {
            let empty = MDMDevice(resource: Self.resource("mdmDevices", attributes))
            #expect(empty.serialNumber == nil && empty.deviceName == nil && empty.productFamily == nil && empty.enrolledUserID == nil)
        }
    }

    @Test func anMDMDevicesDetailsReadTheirPosture() {
        let detail = MDMDeviceDetail(resource: Self.resource("mdmDeviceDetails", [
            "serialNumber": .string("C02TEST0001"), "deviceName": .string("Front desk"), "deviceModel": .string("MacBook Air"),
            "osVersion": .string("27.0"), "platform": .string("macOS"), "imei": .array([.string("35")]), "meid": .array([]),
            "wifiMacAddress": .string("aa"), "bluetoothMacAddress": .string("bb"), "ethernetMacAddress": .string("cc"),
            "lastCheckInDateTime": .string("2026-10-01T08:00:00Z"), "isFirewallEnabled": .bool(true), "isFileVaultEnabled": .bool(false),
            "storageFreeCapacity": .number("120000000000"), "storageTotalCapacity": .number("494384795648"),
            "deviceLockStatus": .string("UNLOCKED"), "deviceEraseStatus": .string("NOT_ERASED"), "lostModeStatus": .string("DISABLED"),
        ]))
        #expect(detail.serialNumber == "C02TEST0001" && detail.deviceName == "Front desk" && detail.deviceModel == "MacBook Air")
        #expect(detail.osVersion == "27.0" && detail.platform == "macOS" && detail.imei == ["35"] && detail.meid == [])
        #expect(detail.wifiMAC == "aa" && detail.bluetoothMAC == "bb" && detail.ethernetMAC == "cc")
        #expect(detail.lastCheckIn == ISODate.parse("2026-10-01T08:00:00Z"))
        #expect(detail.isFirewallEnabled == true && detail.isFileVaultEnabled == false)
        #expect(detail.storageFree == 120_000_000_000 && detail.storageTotal == 494_384_795_648)
        #expect(detail.lockStatus == .known(.unlocked) && detail.eraseStatus == .known(.notErased) && detail.lostModeStatus == .known(.disabled))
        #expect(detail.unreadAttributes.isEmpty)
        for attributes in [JSONObject(), Self.mistyped(MDMDeviceDetail.fields)] {
            let empty = MDMDeviceDetail(resource: Self.resource("mdmDeviceDetails", attributes))
            #expect(empty.serialNumber == nil && empty.deviceName == nil && empty.deviceModel == nil && empty.osVersion == nil)
            #expect(empty.platform == nil && empty.imei == nil && empty.meid == nil && empty.wifiMAC == nil && empty.bluetoothMAC == nil)
            #expect(empty.ethernetMAC == nil && empty.lastCheckIn == nil && empty.isFirewallEnabled == nil && empty.isFileVaultEnabled == nil)
            #expect(empty.storageFree == nil && empty.storageTotal == nil && empty.lockStatus == nil && empty.eraseStatus == nil)
            #expect(empty.lostModeStatus == nil)
        }
        let locked = MDMDeviceDetail(resource: Self.resource("mdmDeviceDetails", [
            "deviceLockStatus": .string("LOCKED"), "deviceEraseStatus": .string("ERASED"), "lostModeStatus": .string("ENABLED")]))
        #expect(locked.lockStatus == .known(.locked) && locked.eraseStatus == .known(.erased) && locked.lostModeStatus == .known(.enabled))
    }
}
