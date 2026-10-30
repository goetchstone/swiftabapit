import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// The models against Apple's own documentation (plan §3.10, invariant 10): every attribute a view reads is
/// one Apple documents, every enum's known cases are Apple's values, and Apple's examples decode.
@Suite("Apple models against the contract")
struct ModelContractTests {
    static var manifest: [String: Any] {
        let url = Fixtures.contracts.appending(path: "apple/business-2.6.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    static var objects: [String: Any] { manifest["objects"] as? [String: Any] ?? [:] }

    static func properties(_ object: String) -> [String] {
        let record = objects[object] as? [String: Any] ?? [:]
        return (record["properties"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    static func values(_ enumName: String) -> [String] {
        let enums = manifest["enums"] as? [String: Any] ?? [:]
        return (enums[enumName] as? [String: Any])?["values"] as? [String] ?? []
    }

    /// The `type` values Apple allows for a resource object.
    static func resourceType(_ object: String) -> [String] {
        let record = objects[object] as? [String: Any] ?? [:]
        let type = (record["properties"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "type" }
        return type?["allowedValues"] as? [String] ?? []
    }

    /// Each view reads exactly the attributes Apple documents for it: none it doesn't, and it doesn't skip one. A
    /// configuration's attributes are two objects in Apple's docs (`ConfigurationCommon` and the custom-setting
    /// part); an audit event's are the common ones, its payload being its type's own (`AuditEventTests`).
    @Test(arguments: [
        ("OrgDevice.Attributes", OrgDevice.fields), ("AppleCareCoverage.Attributes", AppleCareCoverage.fields),
        ("ActivationLockStatus.Attributes", ActivationLockStatus.fields), ("MdmServer.Attributes", MDMService.fields),
        ("User.Attributes", User.fields), ("UserPhoneNumber", UserPhoneNumber.fields), ("UserRoleOuMapping", UserRoleOuMapping.fields),
        ("UserGroup.Attributes", UserGroup.fields), ("OrganizationalUnit.Attributes", OrganizationalUnit.fields),
        ("App.Attributes", ContentApp.fields), ("Package.Attributes", ContentPackage.fields), ("Blueprint.Attributes", Blueprint.fields),
        ("ConfigurationCommon+ConfigurationCustomSetting", Configuration.fields), ("CustomSettingsValues", CustomSettingsValues.fields),
        ("MdmDevice.Attributes", MDMDevice.fields), ("MdmDeviceDetail.Attributes", MDMDeviceDetail.fields),
        ("AuditEventCommonAttributes", AuditEvent.fields), ("AuditEventAccountRoleLocation", AuditEventRoleLocation.fields),
    ])
    func aViewReadsApplesAttributes(object: String, fields: [String]) {
        let documented = object.split(separator: "+").flatMap { Self.properties(String($0)) }
        #expect(!documented.isEmpty, "no \(object) in the manifest")
        #expect(fields.count == Set(fields).count, "\(object): a field listed twice")
        #expect(Set(fields) == Set(documented), "\(object): reads \(Set(fields).subtracting(documented).sorted()), skips \(Set(documented).subtracting(fields).sorted())")
    }

    /// Each view reads the JSON:API type Apple's resource object allows.
    @Test(arguments: [
        ("OrgDevice", OrgDevice.resourceType), ("AppleCareCoverage", AppleCareCoverage.resourceType),
        ("ActivationLockStatus", ActivationLockStatus.resourceType), ("MdmServer", MDMService.resourceType), ("User", User.resourceType),
        ("UserGroup", UserGroup.resourceType), ("OrganizationalUnit", OrganizationalUnit.resourceType), ("App", ContentApp.resourceType),
        ("Package", ContentPackage.resourceType), ("Blueprint", Blueprint.resourceType), ("Configuration", Configuration.resourceType),
        ("MdmDevice", MDMDevice.resourceType), ("MdmDeviceDetail", MDMDeviceDetail.resourceType), ("AuditEvent", AuditEvent.resourceType),
    ])
    func aViewReadsApplesType(object: String, type: String) {
        #expect(Self.resourceType(object) == [type], "\(object)")
    }

    /// A blueprint's relationships are Apple's six, each holding linkages of the type Apple allows.
    @Test func aBlueprintsRelationshipsAreApples() {
        #expect(Set(Blueprint.Relationship.allCases.map(\.rawValue)) == Set(Self.properties("Blueprint.Relationships")))
        for relationship in Blueprint.Relationship.allCases {
            let name = relationship.rawValue.prefix(1).uppercased() + relationship.rawValue.dropFirst()
            #expect(Self.resourceType("Blueprint.Relationships.\(name).Data") == [relationship.resourceType], "\(relationship)")
        }
    }

    static func raw<T: KnownValues>(_: T.Type) -> [String] { T.allCases.map(\.rawValue) }

    /// An enum Apple names has exactly Apple's values as known cases, each once. `PurchaseSourceType` serves both
    /// `OrgDevice` (a plain string in Apple's docs) and the device-added audit payload (`AuditEventPurchaseSourceType`).
    @Test(arguments: [
        ("MdmMigrationStatus", raw(MigrationStatus.self)), ("AppleCareCoverageStatus", raw(CoverageStatus.self)),
        ("AppleCareCoveragePaymentType", raw(PaymentType.self)), ("ActivationLockType", raw(LockType.self)),
        ("MdmServerStatus", raw(ServiceStatus.self)), ("MdmServerProductFamily", raw(ServiceProductFamily.self)),
        ("UserStatus", raw(UserStatus.self)), ("UserPhoneNumberType", raw(UserPhoneNumberType.self)),
        ("UserGroupType", raw(UserGroupType.self)), ("UserGroupStatus", raw(UserGroupStatus.self)), ("SupportedOS", raw(SupportedOS.self)),
        ("BlueprintStatus", raw(BlueprintStatus.self)), ("ConfigurationType", raw(ConfigurationType.self)),
        ("ConfigurationPlatform", raw(ConfigurationPlatform.self)), ("DeviceEraseStatus", raw(DeviceEraseStatus.self)),
        ("DeviceLockStatus", raw(DeviceLockStatus.self)), ("LostModeStatus", raw(LostModeStatus.self)),
        ("AuditEventType", raw(AuditEventType.self)), ("AuditEventActorType", raw(AuditEventActorType.self)),
        ("AuditEventCategory", raw(AuditEventCategory.self)), ("AuditEventOutcome", raw(AuditEventOutcome.self)),
        ("AuditEventSubjectType", raw(AuditEventSubjectType.self)), ("AuditEventPurchaseSourceType", raw(PurchaseSourceType.self)),
        ("AuditEventReleaseEntityType", raw(AuditEventReleaseEntityType.self)), ("AuditEventIdpProtocol", raw(AuditEventIdpProtocol.self)),
        ("AuditEventIdpVendorName", raw(AuditEventIdpVendorName.self)),
    ])
    func namedEnumsHaveApplesValues(name: String, known: [String]) {
        let documented = Self.values(name)
        #expect(!documented.isEmpty, "no \(name) in the manifest")
        #expect(known.count == Set(known).count, "\(name): a value listed twice")
        #expect(Set(known) == Set(documented), "\(name): adds \(Set(known).subtracting(documented).sorted()), lacks \(Set(documented).subtracting(known).sorted())")
    }

    /// Every enum Apple documents is held by the test above, but the activity types, which are a write's (Phase 4,
    /// held by `ContractManifestTests`): a new enum in the contract is a failing test until it is modelled or listed.
    @Test func everyContractEnumIsHeld() {
        let enums = Set((Self.manifest["enums"] as? [String: Any] ?? [:]).keys)
        let held: Set = ["MdmMigrationStatus", "AppleCareCoverageStatus", "AppleCareCoveragePaymentType", "ActivationLockType", "MdmServerStatus",
                         "MdmServerProductFamily", "UserStatus", "UserPhoneNumberType", "UserGroupType", "UserGroupStatus", "SupportedOS",
                         "BlueprintStatus", "ConfigurationType", "ConfigurationPlatform", "DeviceEraseStatus", "DeviceLockStatus",
                         "LostModeStatus", "AuditEventType", "AuditEventActorType", "AuditEventCategory", "AuditEventOutcome",
                         "AuditEventSubjectType", "AuditEventPurchaseSourceType", "AuditEventReleaseEntityType", "AuditEventIdpProtocol",
                         "AuditEventIdpVendorName"]
        #expect(enums.subtracting(held) == ["OrgDeviceActivityType"])
        #expect(held.isSubset(of: enums))
    }

    static func example(_ name: String, scope: String = "business") throws -> Document {
        try Document.parse(Data(contentsOf: Fixtures.docc.appending(path: "\(scope)/\(name).response.json")))
    }

    /// Every view, by the JSON:API type it reads.
    static let views: [String: any ResourceView.Type] = Dictionary(uniqueKeysWithValues: ([
        OrgDevice.self, AppleCareCoverage.self, ActivationLockStatus.self, MDMService.self, User.self, UserGroup.self,
        OrganizationalUnit.self, ContentApp.self, ContentPackage.self, Blueprint.self, Configuration.self, MDMDevice.self,
        MDMDeviceDetail.self, AuditEvent.self,
    ] as [any ResourceView.Type]).map { ($0.resourceType, $0) })

    /// Types Apple's examples hold that have no view yet: an activity is a write's answer (Phase 4).
    static let noView: Set = ["orgDeviceActivities"]

    /// Attributes Apple's examples send that the views don't read, by example (both scopes), each with why. Apple's own
    /// device examples say `purchaseSourceUid` where its field list says `purchaseSourceId` (2.6): the view reads the
    /// documented name and lets the example's survive raw.
    static let knownUnread: [String: Set<String>] = ["get-org-devices.response.json": ["purchaseSourceUid"],
                                                     "get-orgdevice-information.response.json": ["purchaseSourceUid"]]

    /// Types Apple gave no example for: their views are held to the field lists alone, and to their own tests
    /// (`ViewTests`, `AuditEventTests`).
    static let noExample: Set = ["mdmDevices", "mdmDeviceDetails", "auditEvents"]

    /// Every response example Apple wrote, both scopes, decodes into its type's view with nothing unread but the listed
    /// gap, its data and anything included alike; and every view but those Apple gave no example for is reached.
    @Test func everyExampleDecodesIntoItsView() throws {
        var reached: Set<String> = [], files = 0
        for scope in ["business", "school"] {
            let folder = Fixtures.docc.appending(path: scope)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.contains(".response") {
                let document = try Document.parse(Data(contentsOf: folder.appending(path: name)))
                let resources = document.resources + document.included
                #expect(!resources.isEmpty, "\(scope)/\(name) holds no resource")
                files += 1
                for resource in resources where !Self.noView.contains(resource.type) {
                    let view = try #require(Self.views[resource.type], "\(scope)/\(name): no view reads \(resource.type)")
                    let decoded = view.init(resource: resource)
                    #expect(decoded.id == resource.id)
                    #expect(Set(decoded.unreadAttributes) == Self.knownUnread[name] ?? [],
                            "\(scope)/\(name): \(resource.type) leaves \(decoded.unreadAttributes) unread")
                    reached.insert(resource.type)
                }
            }
        }
        #expect(files >= 50)
        #expect(Set(Self.views.keys).subtracting(reached) == Self.noExample)
    }

    /// Apple's examples read typed: each enum value they hold is a known one, and the fields read what they say.
    @Test func applesExamplesReadTyped() throws {
        let devices = try Self.example("get-org-devices").resources.map(OrgDevice.init)
        let device = try #require(devices.first)
        #expect(device.serialNumber == "XABC123X0ABC123X0")
        #expect(device.productFamily == .known(.mac))
        #expect(device.status == .known(.unassigned))
        #expect(device.imei?.count == 2)
        #expect(device.attributes["purchaseSourceUid"] != nil)

        let coverage = try Self.example("get-all-applecare-coverage-for-an-orgdevice").resources.map(AppleCareCoverage.init)
        #expect(coverage.contains { $0.paymentType == .known(.abeSubscription) })

        let lock = try ActivationLockStatus(resource: #require(Self.example("get-the-activation-lock-status-information-for-an-orgdevice").resource))
        #expect(lock.isLocked == true && lock.lockType == .known(.mdm) && !lock.blocksRelease)

        let services = try Self.example("get-mdm-servers").resources.map(MDMService.init)
        #expect(services.first?.name == "Test Device Management Service")
        #expect(services.first?.type == .known(.mdm))

        let user = try User(resource: #require(Self.example("get-user-information").resource))
        #expect(user.firstName == "John" && user.middleName == "A" && user.lastName == "Doe")
        #expect(user.fullName == "John A Doe")
        #expect(user.status == .known(.active))
        #expect(user.isExternalUser == false)
        #expect(user.managedAppleAccount == "john.doe@appleid.example.com" && user.email == "john.doe@example.com")
        #expect(user.employeeNumber == "EMP001" && user.costCenter == "CC100" && user.division == "Engineering")
        #expect(user.department == "IT" && user.jobTitle == "Software Engineer")
        #expect(user.startDate == ISODate.parse("2023-01-15T08:00:00Z"))
        #expect(user.created == ISODate.parse("2023-01-10T10:30:00Z") && user.updated == ISODate.parse("2024-06-01T14:22:00Z"))
        #expect(user.phoneNumbers?.map(\.phoneNumber) == ["+1-555-123-4567"])
        #expect(user.phoneNumbers?.first?.type == .known(.work))
        #expect(user.roleOuList?.map(\.roleName) == ["Administrator"] && user.roleOuList?.first?.ouID == "OU123456")
        #expect(try Self.example("get-users").resources.map(User.init).first?.id == "1234567890")

        let group = try UserGroup(resource: #require(Self.example("get-usergroup-information").resource))
        #expect(group.name == "Engineering Team" && group.ouID == "OU789012" && group.totalMemberCount == 25)
        #expect(group.type == .known(.standard) && group.status == .known(.active))
        #expect(group.created != nil && group.updated != nil)

        let unit = try OrganizationalUnit(resource: #require(Self.example("get-organizationalunit-information").resource))
        #expect(unit.name == "Engineering" && unit.summary == "Engineering organizational unit")
        #expect(unit.created != nil && unit.updated != nil)

        let app = try ContentApp(resource: #require(Self.example("get-app-information").resource))
        #expect(app.id == "361309726" && app.name == "Pages" && app.bundleID == "com.apple.Pages" && app.version == "14.0")
        #expect(app.supportedOS == [.known(.iOS), .known(.macOS)])
        #expect(app.isCustomApp == false)
        #expect(app.appStoreURL == "https://apps.apple.com/app/pages/id361309726" && app.websiteURL == "https://www.apple.com/pages/")

        let package = try ContentPackage(resource: #require(Self.example("get-package-information").resource))
        #expect(package.name == "Enterprise Software Suite" && package.version == "2.5.1")
        #expect(package.bundleIDs == ["com.example.enterpriseapp"] && package.hash == "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6")
        #expect(package.url == "https://example.com/packages/enterprise-suite.pkg")
        #expect(package.summary == "Complete enterprise productivity software suite" && package.created != nil && package.updated != nil)

        let blueprint = try Blueprint(resource: #require(Self.example("update-a-blueprint").resource))
        #expect(blueprint.name == "Engineering Onboarding" && blueprint.summary == "Updated description")
        #expect(blueprint.status == .known(.active) && blueprint.appLicenseDeficient == false)
        #expect(blueprint.created != nil && blueprint.updated != nil)
        // Apple's write answers carry links only: nothing was included, so no relationship was read.
        for relationship in Blueprint.Relationship.allCases { #expect(try blueprint.related(relationship) == nil) }

        let configuration = try Configuration(resource: #require(Self.example("get-configuration-information").resource))
        #expect(configuration.name == "Wi-Fi Configuration" && configuration.type == .known(.customSetting))
        #expect(configuration.platforms == [.known(.iOS), .known(.macOS)])
        #expect(configuration.customSettings?.filename == "WiFi.mobileconfig")
        #expect(configuration.customSettings?.configurationProfile?.hasPrefix("<?xml") == true)
        // Apple's example profile is cut short ("..."), so it isn't a property list: said, never shown.
        #expect(configuration.customSettings?.profileText == .notShown(ProfileText.unreadable))
    }

    @Test func anUnknownValueSurvivesRaw() {
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "X", attributes: [
            "productFamily": .string("Glasses"), "status": .string("PENDING_RELEASE"), "brandNewField": .bool(true)]))
        #expect(device.productFamily == .unknown("Glasses"))
        #expect(device.status?.rawValue == "PENDING_RELEASE")
        #expect(device.unreadAttributes == ["brandNewField"])
        let app = ContentApp(resource: Resource(type: "apps", id: "1", attributes: ["supportedOS": .array([.string("SUPPORTED_OS_GLASSOS")])]))
        #expect(app.supportedOS == [.unknown("SUPPORTED_OS_GLASSOS")])
    }

    /// A key that only looks like a field is unread, and the field beside it is read: keys are compared by their bytes,
    /// as the typed reads find them (the failure-log's rule: never compare Apple's text as `Character`s).
    @Test func aLookalikeKeyIsUnread() {
        let user = User(resource: Resource(type: "users", id: "u", attributes: ["e\u{301}mail": .string("x"), "email": .string("y")]))
        #expect(user.unreadAttributes == ["e\u{301}mail"])
        #expect(user.email == "y")
        let device = MDMDevice(resource: Resource(type: "mdmDevices", id: "m", attributes: ["deviceNam\u{E9}": .string("x")]))
        #expect(device.unreadAttributes == ["deviceNam\u{E9}"])
        #expect(device.deviceName == nil)
        // U+212A KELVIN SIGN is canonically `K`, so `String ==` calls these keys a field and every typed read misses
        // them: compared as bytes, each is unread (Phase 2a review L4: the `==` mutant left every test green). Asserted as
        // bytes too, since `==` on the names would pass either way.
        let kelvin = "eventDataProperty\u{212A}ey", typeKey = "eventDataApiAccountCreatedWith\u{212A}ey"
        let event = AuditEvent(resource: Resource(type: "auditEvents", id: "e", attributes: [
            "type": .string("API_ACCOUNT_CREATED_WITH_KEY"), kelvin: .string("eventDataApiAccountCreatedWithKey"), typeKey: .object([:])]))
        #expect(event.unreadAttributes.map { Array($0.utf8) } == [Array(kelvin.utf8), Array(typeKey.utf8)])
        #expect(event.eventDataPropertyKey == nil && event.payload == nil)
    }

    @Test func findMatchesEveryIdentifier() {
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "C02X", attributes: [
            "serialNumber": .string("C02X"), "imei": .array([.string("111"), .string("222")]), "meid": .array([.string("333")]),
            "eid": .string("444"), "orderNumber": .string("O-1"), "wifiMacAddress": .string("aa:bb"), "bluetoothMacAddress": .string("cc:dd"),
            "ethernetMacAddress": .array([.string("ee:ff")])]))
        #expect(Set(device.identifiers) == ["C02X", "111", "222", "333", "444", "O-1", "aa:bb", "cc:dd", "ee:ff"])
    }

    /// Every view reads a list one way (Phase 2a review L6: Phase 1's reader kept the items that fit, so `OrgDevice.imei`
    /// read `[]` where `MDMDeviceDetail.imei` read nil): nil when missing, not a list or holding anything else, `[]` when
    /// empty, the items when every one reads. A list that isn't one gives Find no identifiers.
    @Test func everyViewReadsAListTheSameWay() {
        let mixed: JSONValue = .array([.string("351234"), .number("5")]), strings: JSONValue = .array([.string("351234")])
        for (value, read) in [(mixed, nil), (.string("351234"), nil), (.array([]), []), (strings, ["351234"])] as [(JSONValue, [String]?)] {
            let device = OrgDevice(resource: Resource(type: "orgDevices", id: "C02X", attributes: ["imei": value, "meid": value, "ethernetMacAddress": value]))
            let detail = MDMDeviceDetail(resource: Resource(type: "mdmDeviceDetails", id: "d", attributes: ["imei": value, "meid": value]))
            #expect(device.imei == read && device.meid == read && device.ethernetMACs == read && detail.imei == read && detail.meid == read, "\(value)")
            #expect(device.identifiers == ["C02X"] + (read ?? []) + (read ?? []) + (read ?? []), "\(value)")
            let service = MDMService(resource: Resource(type: "mdmServers", id: "s", attributes: ["defaultProductFamilies": value]))
            #expect(service.defaultProductFamilies?.map(\.rawValue) == read, "\(value)")
        }
        let missing = OrgDevice(resource: Resource(type: "orgDevices", id: "C02X"))
        #expect(missing.imei == nil && missing.meid == nil && missing.ethernetMACs == nil && missing.identifiers == ["C02X"])
        #expect(MDMService(resource: Resource(type: "mdmServers", id: "s")).defaultProductFamilies == nil)
    }
}
