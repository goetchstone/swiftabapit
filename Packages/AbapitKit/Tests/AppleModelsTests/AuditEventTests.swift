import AppleModels
import Foundation
import JSONAPI
import Testing

/// Audit events (Business 2.6): the common attributes, and each type's payload under its `eventData<Type>` key, held
/// to Apple's `AuditEvent<Type>Attributes` and `AuditEvent<Type>` objects for all 50 types (plan §2.1).
@Suite("Audit events")
struct AuditEventTests {
    /// The contract's name for a type: `DEVICE_ADDED_TO_ORG` is `DeviceAddedToOrg`, as in
    /// `AuditEventDeviceAddedToOrgAttributes`.
    static func camel(_ value: String) -> String {
        value.lowercased().split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func property(_ object: String) -> [[String: Any]] {
        let record = ModelContractTests.objects[object] as? [String: Any] ?? [:]
        return record["properties"] as? [[String: Any]] ?? []
    }

    /// The members of `AuditEvent.attributes`, Apple's union of the 50 attributes objects.
    static var union: [String] {
        let attributes = property("AuditEvent").first { $0["name"] as? String == "attributes" }
        return (attributes?["type"] as? [String: Any])?["types"] as? [String] ?? []
    }

    /// Every type's row is the contract's: its attributes object is in Apple's union, its one property is the row's key,
    /// and the payload object it names has exactly the row's fields. A payload Apple's docs give no properties (its
    /// page lists none, so the manifest has no object for it) has none in the row: what it holds live is counted as
    /// unread by the acceptance pass.
    @Test func everyTypesPayloadIsTheContracts() throws {
        let union = Set(Self.union)
        #expect(union.count == 50 && AuditEventType.allCases.count == 50)
        var named: Set<String> = []
        for type in AuditEventType.allCases {
            let object = "AuditEvent\(Self.camel(type.rawValue))Attributes"
            #expect(union.contains(object), "\(type.rawValue): no \(object) in AuditEvent's attributes")
            named.insert(object)
            let properties = Self.property(object)
            #expect(properties.count == 1, "\(object)")
            let key = try #require(properties.first?["name"] as? String)
            #expect(Array(type.payload.key.utf8) == Array(key.utf8), "\(type.rawValue): the row says \(type.payload.key), Apple says \(key)")
            let payload = try #require(((properties.first?["type"] as? [String: Any])?["types"] as? [String])?.first, "\(object)")
            let fields = Self.property(payload).compactMap { $0["name"] as? String }
            #expect(type.payload.fields.count == Set(type.payload.fields).count, "\(type.rawValue): a field listed twice")
            #expect(Set(type.payload.fields) == Set(fields), "\(type.rawValue): the row reads \(type.payload.fields), \(payload) has \(fields)")
        }
        #expect(named == union)
    }

    /// Fourteen payloads have no fields: the manifest has no object for them, Apple's pages listing no properties. The
    /// table's comment and the runbook said fifteen (Phase 2a review L6).
    @Test func fourteenPayloadsHaveNoFields() throws {
        let empty = AuditEventType.allCases.filter(\.payload.fields.isEmpty)
        let undocumented = try AuditEventType.allCases.filter { type in
            let properties = Self.property("AuditEvent\(Self.camel(type.rawValue))Attributes")
            let payload = try #require(((properties.first?["type"] as? [String: Any])?["types"] as? [String])?.first, "\(type.rawValue)")
            return ModelContractTests.objects[payload] == nil
        }
        #expect(empty.count == 14 && empty == undocumented)
    }

    /// The second place Apple lists the keys: `fields[auditEvents]` on the list is the common attributes and every
    /// type's key, each once.
    @Test func everyPayloadKeyIsASparseField() throws {
        let endpoints = ModelContractTests.manifest["endpoints"] as? [[String: Any]] ?? []
        let list = try #require(endpoints.first { $0["path"] as? String == "/v1/auditEvents" && $0["method"] as? String == "GET" })
        let parameters = list["parameters"] as? [[String: Any]] ?? []
        let fields = try #require(parameters.first { $0["name"] as? String == "fields[auditEvents]" }?["allowedValues"] as? [String])
        let keys = AuditEventType.allCases.map(\.payload.key)
        #expect(Set(keys).count == 50)
        #expect(fields.count == AuditEvent.fields.count + keys.count)
        #expect(Set(fields) == Set(AuditEvent.fields + keys))
    }

    static func event(_ type: String, _ extra: JSONObject = [:]) -> AuditEvent {
        var attributes: JSONObject = [
            "eventDateTime": .string("2026-10-20T09:15:00Z"), "type": .string(type), "category": .string("DEVICE_MANAGEMENT"),
            "actorType": .string("API_USER"), "actorId": .string("a-1"), "actorName": .string("abapit key"), "subjectType": .string("DEVICE"),
            "subjectId": .string("s-1"), "subjectName": .string("C02TEST0001"), "outcome": .string("SUCCESS"), "groupId": .string("g-1"),
        ]
        attributes = attributes.merging(extra)
        return AuditEvent(resource: Resource(type: "auditEvents", id: "e-1", attributes: attributes))
    }

    @Test func theCommonAttributesReadTyped() {
        let event = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .string("eventDataDeviceAssignedToServer")])
        #expect(event.type == .known(.deviceAssignedToServer))
        #expect(event.eventDate == ISODate.parse("2026-10-20T09:15:00Z"))
        #expect(event.category == .known(.deviceManagement) && event.actorType == .known(.apiUser) && event.subjectType == .known(.device))
        #expect(event.actorID == "a-1" && event.actorName == "abapit key" && event.subjectID == "s-1" && event.subjectName == "C02TEST0001")
        #expect(event.outcome == .known(.success) && event.groupID == "g-1" && event.eventDataPropertyKey == "eventDataDeviceAssignedToServer")
        let empty = AuditEvent(resource: Resource(type: "auditEvents", id: "e"))
        #expect(empty.type == nil && empty.eventDate == nil && empty.category == nil && empty.actorType == nil && empty.actorID == nil)
        #expect(empty.actorName == nil && empty.subjectType == nil && empty.subjectID == nil && empty.subjectName == nil)
        #expect(empty.outcome == nil && empty.groupID == nil && empty.eventDataPropertyKey == nil && empty.payload == nil)
        // Apple's category and subject lists are incomplete (plan §3.3): a value it adds survives raw.
        let future = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["category": .string("SECURITY"), "subjectType": .string("ROLE")])
        #expect(future.category == .unknown("SECURITY") && future.subjectType == .unknown("ROLE"))
    }

    /// The payload is read under `eventDataPropertyKey` when Apple names one, else the type's own key.
    @Test func thePayloadIsReadUnderTheKeyAppleNames() throws {
        let payload: JSONValue = .object(["serialNumber": .string("C02TEST0001"), "targetServerName": .string("Mosyle")])
        let keyed = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .string("eventDataDeviceAssignedToServer"),
                                                            "eventDataDeviceAssignedToServer": payload])
        #expect(keyed.payload?.key == "eventDataDeviceAssignedToServer")
        #expect(keyed.payload?.serialNumber == "C02TEST0001" && keyed.payload?.targetServerName == "Mosyle")
        #expect(keyed.unreadAttributes.isEmpty && keyed.payload?.unreadFields == [] && keyed.payloadProblems.isEmpty)

        let unkeyed = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataDeviceAssignedToServer": payload])
        #expect(unkeyed.payload?.serialNumber == "C02TEST0001" && unkeyed.payloadProblems.isEmpty)
        // A null key is no key named.
        #expect(Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .null, "eventDataDeviceAssignedToServer": payload])
            .payloadProblems.isEmpty)

        // Apple names another key: the payload is read there, and that key, not being the type's, is unread: the
        // acceptance pass says so.
        let elsewhere = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .string("eventDataDeviceMoved"),
                                                                "eventDataDeviceMoved": payload])
        #expect(elsewhere.payload?.key == "eventDataDeviceMoved" && elsewhere.payload?.targetServerName == "Mosyle")
        #expect(elsewhere.unreadAttributes == ["eventDataDeviceMoved"] && elsewhere.payloadProblems.isEmpty)
        // Apple names a key it didn't send: the type's own is read, and the miss is said (Phase 2a review M1: this read
        // nil, counted nothing, and the pass said `ok`).
        let missing = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .string("eventDataDeviceMoved"),
                                                              "eventDataDeviceAssignedToServer": payload])
        #expect(missing.payload?.key == "eventDataDeviceAssignedToServer" && missing.payload?.serialNumber == "C02TEST0001")
        #expect(missing.payloadProblems == [.namedKeyAbsent])
        // Nothing under either: no payload, and still said.
        let nowhere = Self.event("DEVICE_ASSIGNED_TO_SERVER", ["eventDataPropertyKey": .string("eventDataDeviceMoved")])
        #expect(nowhere.payload == nil && nowhere.payloadProblems == [.namedKeyAbsent])
    }

    /// The contract's object names spell `Icloud` and `Applecare` (`AuditEventSubjectHasIcloudStoragePurchaseAddedAttributes`)
    /// where its attribute keys spell `ICloud` and `AppleCare`: whichever Apple names, the payload is read under the key
    /// that holds it, its fields are counted, and a named key that isn't there is said (Phase 2a review M1).
    @Test(arguments: [
        (AuditEventType.subjectHasIcloudStoragePurchaseAdded, "eventDataSubjectHasIcloudStoragePurchaseAdded"),
        (.subjectHasIcloudStoragePurchaseRemoved, "eventDataSubjectHasIcloudStoragePurchaseRemoved"),
        (.subjectHasApplecarePurchaseAdded, "eventDataSubjectHasApplecarePurchaseAdded"),
        (.subjectHasApplecarePurchaseRemoved, "eventDataSubjectHasApplecarePurchaseRemoved"),
    ])
    func eitherSpellingOfAPayloadKeyIsReadOrSaid(type: AuditEventType, contractSpelling: String) throws {
        let payload: JSONValue = .object(["subscriptionId": .string("sub-1"), "brandNewField": .string("x")])
        #expect(!type.payload.key.utf8.elementsEqual(contractSpelling.utf8), "the two spellings differ")
        // Apple names the contract's spelling and sends the attribute key's: read there, the miss said.
        let named = Self.event(type.rawValue, ["eventDataPropertyKey": .string(contractSpelling), type.payload.key: payload])
        let read = try #require(named.payload)
        #expect(Array(read.key.utf8) == Array(type.payload.key.utf8) && read.subscriptionID == "sub-1" && read.unreadFields == ["brandNewField"])
        #expect(named.payloadProblems == [.namedKeyAbsent] && named.unreadAttributes.isEmpty)
        // Apple names and sends the contract's spelling: read where it names, and the key, not the type's, is unread.
        let both = Self.event(type.rawValue, ["eventDataPropertyKey": .string(contractSpelling), contractSpelling: payload])
        #expect(both.payload?.subscriptionID == "sub-1" && both.payload?.unreadFields == ["brandNewField"] && both.payloadProblems.isEmpty)
        #expect(both.unreadAttributes == [contractSpelling])
        // Apple names the attribute key's spelling and sends the contract's: no payload where either says, and both said:
        // the named key's absence, and the attribute it did send as unread.
        let crossed = Self.event(type.rawValue, ["eventDataPropertyKey": .string(type.payload.key), contractSpelling: payload])
        #expect(crossed.payload == nil && crossed.payloadProblems == [.namedKeyAbsent] && crossed.unreadAttributes == [contractSpelling])
    }

    /// An empty key, a key that isn't a string, and a payload that isn't an object are each said, never read as "no
    /// payload" with nothing counted; the type's own key is read when it holds an object.
    @Test func aPayloadKeyOrPayloadOfAnotherShapeIsSaid() throws {
        let payload: JSONValue = .object(["serialNumber": .string("C02"), "brandNewField": .string("x")])
        let key = AuditEventType.deviceUnassignedFromServer.payload.key
        let empty = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .string(""), key: payload])
        #expect(empty.payload?.serialNumber == "C02" && empty.payload?.unreadFields == ["brandNewField"] && empty.payloadProblems == [.namedKeyEmpty])
        let number = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .number("1"), key: payload])
        #expect(number.payload?.serialNumber == "C02" && number.payloadProblems == [.namedKeyNotAString])
        for shape in [JSONValue.array([payload]), .string("C02"), .number("1"), .bool(true), .null] {
            let unnamed = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", [key: shape])
            #expect(unnamed.payload == nil && unnamed.payloadProblems == [.notAnObject], "\(shape)")
            let named = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .string(key), key: shape])
            #expect(named.payload == nil && named.payloadProblems == [.notAnObject], "\(shape)")
            // Named elsewhere and not an object there: the type's own key is read.
            let elsewhere = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .string("eventDataMoved"), "eventDataMoved": shape,
                                                                         key: payload])
            #expect(elsewhere.payload?.serialNumber == "C02" && elsewhere.payloadProblems == [.notAnObject], "\(shape)")
        }
        // Both wrong: each said once, in order.
        let twice = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .string("eventDataMoved"), "eventDataMoved": .null, key: .null])
        #expect(twice.payload == nil && twice.payloadProblems == [.notAnObject])
        let absentThenList = Self.event("DEVICE_UNASSIGNED_FROM_SERVER", ["eventDataPropertyKey": .string("eventDataMoved"), key: .array([])])
        #expect(absentThenList.payloadProblems == [.namedKeyAbsent, .notAnObject])
        // A named key that only looks like the type's (U+212A KELVIN SIGN for its `K`) is another key: compared by bytes,
        // the type's own is still read.
        let lookalike = Self.event("API_ACCOUNT_CREATED_WITH_KEY", ["eventDataPropertyKey": .string("eventDataApiAccountCreatedWith\u{212A}ey"),
                                                                    "eventDataApiAccountCreatedWithKey": .object(["keyId": .string("K1")])])
        #expect(lookalike.payload?.keyID == "K1" && lookalike.payloadProblems == [.namedKeyAbsent])
        // A type this version doesn't know has no key of its own: a key it names that holds nothing is said.
        #expect(Self.event("PASSKEY_ADDED", ["eventDataPropertyKey": .string("eventDataPasskeyAdded")]).payloadProblems == [.namedKeyAbsent])
    }

    /// Unread attributes are those neither common nor the type's key; the payload's are those its type doesn't list.
    @Test func whatIsUnreadIsCountedAtBothLevels() {
        let event = Self.event("SUBSCRIPTION_CREATED", [
            "eventDataPropertyKey": .string("eventDataSubscriptionCreated"),
            "eventDataSubscriptionCreated": .object(["planCaption": .string("AppleCare+ for Mac"), "seats": .number("40")]),
            "eventDataSubscriptionUpdated": .object([:]), "riskScore": .number("3"),
        ])
        #expect(event.unreadAttributes == ["eventDataSubscriptionUpdated", "riskScore"])
        #expect(event.payload?.planCaption == "AppleCare+ for Mac")
        #expect(event.payload?.unreadFields == ["seats"])
    }

    /// A type this version doesn't know keeps its payload raw: no field list, nothing read typed, nothing called unread
    /// inside it; the key it came under is unread, as is the type.
    @Test func anUnknownTypesPayloadStaysRaw() {
        let event = Self.event("PASSKEY_ADDED", ["eventDataPropertyKey": .string("eventDataPasskeyAdded"),
                                                "eventDataPasskeyAdded": .object(["serialNumber": .string("C02"), "keyId": .string("k")])])
        #expect(event.type == .unknown("PASSKEY_ADDED"))
        #expect(event.payload?.fields == nil && event.payload?.object["keyId"] == .string("k"))
        #expect(event.payload?.serialNumber == nil && event.payload?.keyID == nil)
        #expect(event.payload?.unreadFields == [])
        #expect(event.unreadAttributes == ["eventDataPasskeyAdded"])
        // With no key named and no type known, there is no payload to find.
        #expect(Self.event("PASSKEY_ADDED", ["eventDataPasskeyAdded": .object([:])]).payload == nil)
    }

    static func payload(_ type: AuditEventType, _ fields: JSONObject) throws -> AuditEventPayload {
        try #require(Self.event(type.rawValue, [type.payload.key: .object(fields)]).payload)
    }

    /// The fields the audit views use read typed, each only on the types Apple documents it for.
    @Test func thePayloadFieldsTheViewsUseReadTyped() throws {
        let added = try Self.payload(.deviceAddedToOrg, ["serialNumber": .string("C02"), "purchaseSourceId": .string("R-1"),
                                                         "purchaseSourceType": .string("RESELLER")])
        #expect(added.serialNumber == "C02" && added.purchaseSourceID == "R-1" && added.purchaseSourceType == .known(.reseller))
        let removed = try Self.payload(.deviceRemovedFromOrg, ["serialNumber": .string("C02"), "releaseEntityId": .string("x"),
                                                               "releaseEntityType": .string("REPLACEMENT")])
        #expect(removed.serialNumber == "C02" && removed.releaseEntityID == "x" && removed.releaseEntityType == .known(.replacement))
        #expect(try Self.payload(.deviceUnassignedFromServer, ["serialNumber": .string("C03")]).serialNumber == "C03")
        #expect(try Self.payload(.subjectHasApplecarePurchaseAdded, ["subscriptionId": .string("sub")]).subscriptionID == "sub")
        #expect(try Self.payload(.subjectHasIcloudStoragePurchaseRemoved, ["subscriptionId": .string("sub")]).subscriptionID == "sub")
        let config = try Self.payload(.configSettingsUpdated, ["configId": .string("c"), "configType": .string("WIFI"), "configVersion": .string("3")])
        #expect(config.configID == "c" && config.configType == "WIFI" && config.configVersion == "3")
        let collection = try Self.payload(.collectionCreated, ["name": .string("Lab"), "description": .string("iPads")])
        #expect(collection.name == "Lab" && collection.summary == "iPads")
        for type in [AuditEventType.subscriptionCreated, .subscriptionUpdated, .subscriptionDeleted] {
            #expect(try Self.payload(type, ["planCaption": .string("Apple Business Essentials")]).planCaption == "Apple Business Essentials")
        }
        for type in [AuditEventType.apiAccountCreatedWithKey, .apiAccountKeyGenerated, .apiAccountKeyRevoked] {
            #expect(try Self.payload(type, ["keyId": .string("K1")]).keyID == "K1")
        }
        #expect(try Self.payload(.apiAccountNameChanged, ["newName": .string("Reports key")]).newName == "Reports key")
        let location: JSONValue = .array([.object(["roleName": .string("Device Enrollment Manager"), "locationUniqueIdentifier": .string("L1")])])
        let account = try Self.payload(.accountRoleLocationChanged, ["accountRoleLocationList": location])
        #expect(account.roleLocations?.map(\.roleName) == ["Device Enrollment Manager"] && account.roleLocations?.first?.locationID == "L1")
        let apiAccount = try Self.payload(.apiAccountRoleLocationChanged, ["apiAccountRoleLocationList": location])
        #expect(apiAccount.roleLocations?.first?.roleName == "Device Enrollment Manager")
        #expect(try Self.payload(.roleCreated, ["privileges": .array([.string("DEVICES_READ")])]).privileges == ["DEVICES_READ"])
        let role = try Self.payload(.roleUpdated, ["privilegesAdded": .array([.string("A")]), "privilegesRemoved": .array([.string("B")])])
        #expect(role.privilegesAdded == ["A"] && role.privilegesRemoved == ["B"])
        #expect(try Self.payload(.termsAccepted, ["termsName": .string("Apple Business Agreement")]).termsName == "Apple Business Agreement")
        let federation = try Self.payload(.domainFederationEnabled, ["activityId": .string("act"), "scimActivityId": .string("scim")])
        #expect(federation.activityID == "act" && federation.scimActivityID == "scim")
        #expect(try Self.payload(.batchPasswordResetInitiated, ["activityId": .string("act")]).activityID == "act")
        #expect(try Self.payload(.accountPasswordChanged, ["activityId": .string("act")]).activityID == "act")
        let idp = try Self.payload(.idpCreated, ["protocol": .string("OIDC"), "vendorName": .string("MICROSOFT_OIDC")])
        #expect(idp.idpProtocol == .known(.oidc) && idp.vendorName == .known(.microsoftOIDC))
        #expect(try Self.payload(.idpAccountSyncDisabled, ["vendorName": .string("OKTA"), "activityId": .string("a")]).vendorName == .unknown("OKTA"))
        let settings = try Self.payload(.appleServicesSettingsUpdated, ["settingsEnabled": .array([.string("ICLOUD")]),
                                                                        "settingsDisabled": .array([])])
        #expect(settings.settingsEnabled == ["ICLOUD"] && settings.settingsDisabled == [])
    }

    /// A field read typed only where its type documents it: Apple lists no serial for an erase, so one that comes is
    /// unread, shown raw, and not read as if it were documented.
    @Test func aFieldIsReadOnlyOnTheTypesThatDocumentIt() throws {
        let erased = try Self.payload(.deviceIsErased, ["serialNumber": .string("C02")])
        #expect(erased.serialNumber == nil && erased.unreadFields == ["serialNumber"])
        let subscription = try Self.payload(.subscriptionCreated, ["keyId": .string("K"), "planCaption": .number("1")])
        #expect(subscription.keyID == nil && subscription.planCaption == nil && subscription.unreadFields == ["keyId"])
        // A list with an item of another type is not a list of strings.
        #expect(try Self.payload(.roleCreated, ["privileges": .array([.string("A"), .number("1")])]).privileges == nil)
        let location = try Self.payload(.accountRoleLocationChanged, ["accountRoleLocationList": .array([.object(["roleName": .string("R"),
                                                                                                                   "scope": .string("all")])])])
        #expect(location.roleLocations?.first?.unreadFields == ["scope"])
        // The payload says them under the field that holds them, for either list, and only where its type documents the
        // list (Phase 2a review L1).
        #expect(location.unreadNested == [NestedKey(attribute: "accountRoleLocationList", key: "scope")])
        let api = try Self.payload(.apiAccountRoleLocationChanged, ["apiAccountRoleLocationList": .array([.object(["expiry": .string("x")]),
                                                                                                          .object(["scope": .string("all")])])])
        #expect(api.unreadNested == [NestedKey(attribute: "apiAccountRoleLocationList", key: "expiry"), NestedKey(attribute: "apiAccountRoleLocationList", key: "scope")])
        let undocumented = try Self.payload(.accountAdded, ["accountRoleLocationList": .array([.object(["scope": .string("all")])])])
        #expect(undocumented.unreadNested.isEmpty && undocumented.unreadFields == ["accountRoleLocationList"])
    }
}
