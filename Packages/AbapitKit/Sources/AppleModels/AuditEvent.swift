import Foundation
import JSONAPI

/// `auditEvents`: one entry of the organization's audit log (Business 2.6). The common attributes are typed here; the
/// payload sits under one more attribute, `eventData<Type>`, whose fields depend on the type (plan §2.1). Apple names
/// that attribute in `eventDataPropertyKey`.
public struct AuditEvent: ResourceView {
    public static let resourceType = "auditEvents"
    /// `AuditEventCommonAttributes`: every type's. The payload's key and fields are `AuditEventType.payload`'s.
    public static let fields = ["eventDateTime", "type", "category", "actorType", "actorId", "actorName", "subjectType", "subjectId",
                                "subjectName", "outcome", "groupId", "eventDataPropertyKey"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var type: OpenEnum<AuditEventType>? { attributes.open("type") }
    public var eventDate: ISODate? { attributes.date("eventDateTime") }
    public var category: OpenEnum<AuditEventCategory>? { attributes.open("category") }
    public var actorType: OpenEnum<AuditEventActorType>? { attributes.open("actorType") }
    /// What `filter[actorId]` matches: "what did this API key do?"
    public var actorID: String? { attributes.string("actorId") }
    public var actorName: String? { attributes.string("actorName") }
    public var subjectType: OpenEnum<AuditEventSubjectType>? { attributes.open("subjectType") }
    /// What `filter[subjectId]` matches (Device 360's timeline). Apple documents no payload field for a domain event:
    /// its domain is presumably the subject (check live).
    public var subjectID: String? { attributes.string("subjectId") }
    public var subjectName: String? { attributes.string("subjectName") }
    public var outcome: OpenEnum<AuditEventOutcome>? { attributes.open("outcome") }
    public var groupID: String? { attributes.string("groupId") }
    public var eventDataPropertyKey: String? { attributes.string("eventDataPropertyKey") }

    /// The payload: the object under `eventDataPropertyKey` when Apple names one that holds an object, else under the
    /// type's own key; nil when neither holds one. A type this version doesn't know keeps its payload raw (`fields` nil).
    /// The type's key is read when the named one misses: Apple's object names spell `Icloud` and `Applecare` where its
    /// attribute keys spell `ICloud` and `AppleCare`, and a named key that missed left the payload unread and uncounted
    /// while the acceptance pass said `ok` (Phase 2a review M1). What went wrong is `payloadProblems`.
    public var payload: AuditEventPayload? { lookup.payload }

    /// What was wrong with where Apple put the payload, in `PayloadProblem`'s order: the acceptance pass says each.
    public var payloadProblems: [PayloadProblem] { PayloadProblem.allCases.filter(lookup.problems.contains) }

    /// What was wrong with where Apple put an event's payload: never "no payload" with nothing said (Phase 2a review M1).
    public enum PayloadProblem: String, CaseIterable, Sendable {
        /// `eventDataPropertyKey` names an attribute the event doesn't have.
        case namedKeyAbsent = "payload key named but absent"
        /// `eventDataPropertyKey` is `""`.
        case namedKeyEmpty = "payload key named empty"
        /// `eventDataPropertyKey` is neither a string nor null.
        case namedKeyNotAString = "payload key named by a non-string"
        /// The attribute named, or the type's own, holds something that isn't an object (`null` included).
        case notAnObject = "payload not an object"
    }

    private var lookup: (payload: AuditEventPayload?, problems: [PayloadProblem]) {
        let schema = type?.known?.payload
        var problems: [PayloadProblem] = []
        func object(under key: String, named: Bool) -> JSONObject? {
            switch attributes[key] {
            case .object(let object)?: return object
            case nil: if named { problems.append(.namedKeyAbsent) }
            case _?: problems.append(.notAnObject)
            }
            return nil
        }
        var named: String?
        switch attributes["eventDataPropertyKey"] {
        case nil, .null?: break
        case .string(let key)? where key.isEmpty: problems.append(.namedKeyEmpty)
        case .string(let key)?: named = key
        case _?: problems.append(.namedKeyNotAString)
        }
        if let named, let object = object(under: named, named: true) {
            return (AuditEventPayload(key: named, object: object, fields: schema?.fields), problems)
        }
        // The type's key, unless it is the one just tried: compared by bytes, as the typed reads find keys.
        if let key = schema?.key, !(named?.utf8.elementsEqual(key.utf8) ?? false), let object = object(under: key, named: false) {
            return (AuditEventPayload(key: key, object: object, fields: schema?.fields), problems)
        }
        return (nil, problems)
    }

    /// Attributes neither common nor the type's payload key: an unknown type's key is one, and so is a key Apple names
    /// that isn't its type's. The payload's own are `payload.unreadFields`; the acceptance pass counts both.
    public var unreadAttributes: [String] {
        attributes.keys(notIn: Self.fields + (type?.known.map { [$0.payload.key] } ?? []))
    }
}

/// An audit event's payload: the object it came in, which it keeps, read with its type's field list.
public struct AuditEventPayload: Sendable, Equatable {
    /// The attribute it was read under.
    public let key: String
    public let object: JSONObject
    /// The fields Apple documents for its type; nil for a type this version doesn't know, whose payload is shown raw.
    public let fields: [String]?

    public init(key: String, object: JSONObject, fields: [String]?) {
        self.key = key
        self.object = object
        self.fields = fields
    }

    /// Fields Apple sent that its type doesn't list. None for an unknown type: the type itself is what's unknown.
    public var unreadFields: [String] { fields.map { object.keys(notIn: $0) } ?? [] }

    /// A field's value, only where the type documents the field: what isn't documented is unread and shown raw,
    /// never read as if it were.
    private func value(_ field: String) -> JSONValue? {
        guard let fields, fields.contains(where: { $0.utf8.elementsEqual(field.utf8) }) else { return nil }
        return object[field]
    }

    private func string(_ field: String) -> String? { value(field)?.string }
    private func strings(_ field: String) -> [String]? { value(field)?.list(\.string) }

    // Device lifecycle.
    public var serialNumber: String? { string("serialNumber") }
    public var targetServerName: String? { string("targetServerName") }
    public var purchaseSourceID: String? { string("purchaseSourceId") }
    public var purchaseSourceType: OpenEnum<PurchaseSourceType>? { value("purchaseSourceType")?.open() }
    public var releaseEntityID: String? { string("releaseEntityId") }
    public var releaseEntityType: OpenEnum<AuditEventReleaseEntityType>? { value("releaseEntityType")?.open() }

    // Subscriptions and purchases.
    public var subscriptionID: String? { string("subscriptionId") }
    public var planCaption: String? { string("planCaption") }

    // Device-management settings and collections.
    public var configID: String? { string("configId") }
    /// A plain string in Apple's docs (not `ConfigurationType`): shown as it comes.
    public var configType: String? { string("configType") }
    public var configVersion: String? { string("configVersion") }
    public var name: String? { string("name") }
    public var summary: String? { string("description") }

    // Access and security: API accounts, roles, identity providers, terms, Apple services.
    public var keyID: String? { string("keyId") }
    public var newName: String? { string("newName") }
    /// A person's (`accountRoleLocationList`) or an API account's (`apiAccountRoleLocationList`) roles after the change.
    public var roleLocations: [AuditEventRoleLocation]? {
        (value("accountRoleLocationList") ?? value("apiAccountRoleLocationList"))?.list { $0.object.map(AuditEventRoleLocation.init) }
    }
    public var privileges: [String]? { strings("privileges") }
    public var privilegesAdded: [String]? { strings("privilegesAdded") }
    public var privilegesRemoved: [String]? { strings("privilegesRemoved") }
    public var termsName: String? { string("termsName") }
    public var activityID: String? { string("activityId") }
    public var scimActivityID: String? { string("scimActivityId") }
    public var idpProtocol: OpenEnum<AuditEventIdpProtocol>? { value("protocol")?.open() }
    public var vendorName: OpenEnum<AuditEventIdpVendorName>? { value("vendorName")?.open() }
    public var settingsEnabled: [String]? { strings("settingsEnabled") }
    public var settingsDisabled: [String]? { strings("settingsDisabled") }
}

/// `AuditEventAccountRoleLocation`: a role held in a location.
public struct AuditEventRoleLocation: ObjectView {
    public static let fields = ["roleName", "locationUniqueIdentifier"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    public var roleName: String? { object.string("roleName") }
    public var locationID: String? { object.string("locationUniqueIdentifier") }
}

/// `AuditEventType`: the 50 types Business 2.6 documents.
public enum AuditEventType: String, KnownValues {
    case deviceAddedToOrg = "DEVICE_ADDED_TO_ORG", deviceRemovedFromOrg = "DEVICE_REMOVED_FROM_ORG",
         deviceAssignedToServer = "DEVICE_ASSIGNED_TO_SERVER",
         deviceUnassignedFromServer = "DEVICE_UNASSIGNED_FROM_SERVER",
         subjectHasIcloudStoragePurchaseAdded = "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED",
         subjectHasIcloudStoragePurchaseRemoved = "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_REMOVED",
         subjectHasApplecarePurchaseAdded = "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED",
         subjectHasApplecarePurchaseRemoved = "SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED",
         deviceIsErased = "DEVICE_IS_ERASED", configSettingsCreated = "CONFIG_SETTINGS_CREATED",
         configSettingsUpdated = "CONFIG_SETTINGS_UPDATED", configSettingsDeleted = "CONFIG_SETTINGS_DELETED",
         collectionCreated = "COLLECTION_CREATED", collectionUpdated = "COLLECTION_UPDATED",
         collectionDeleted = "COLLECTION_DELETED", subscriptionCreated = "SUBSCRIPTION_CREATED",
         subscriptionUpdated = "SUBSCRIPTION_UPDATED", subscriptionDeleted = "SUBSCRIPTION_DELETED",
         accountRoleLocationChanged = "ACCOUNT_ROLE_LOCATION_CHANGED", accountAdded = "ACCOUNT_ADDED",
         accountDeleted = "ACCOUNT_DELETED", externalAccountAssociated = "EXTERNAL_ACCOUNT_ASSOCIATED",
         externalAccountDisassociated = "EXTERNAL_ACCOUNT_DISASSOCIATED", domainAdded = "DOMAIN_ADDED",
         domainRemoved = "DOMAIN_REMOVED", domainVerified = "DOMAIN_VERIFIED",
         apiAccountCreatedWithKey = "API_ACCOUNT_CREATED_WITH_KEY",
         apiAccountCreatedWithoutKey = "API_ACCOUNT_CREATED_WITHOUT_KEY", apiAccountDeleted = "API_ACCOUNT_DELETED",
         apiAccountKeyRevoked = "API_ACCOUNT_KEY_REVOKED", apiAccountKeyGenerated = "API_ACCOUNT_KEY_GENERATED",
         apiAccountRoleLocationChanged = "API_ACCOUNT_ROLE_LOCATION_CHANGED",
         apiAccountNameChanged = "API_ACCOUNT_NAME_CHANGED", roleCreated = "ROLE_CREATED", roleUpdated = "ROLE_UPDATED",
         termsAccepted = "TERMS_ACCEPTED", domainFederationEnabled = "DOMAIN_FEDERATION_ENABLED",
         domainFederationDisabled = "DOMAIN_FEDERATION_DISABLED",
         batchPasswordResetInitiated = "BATCH_PASSWORD_RESET_INITIATED",
         externalAccountInvited = "EXTERNAL_ACCOUNT_INVITED", accountImageSet = "ACCOUNT_IMAGE_SET",
         accountImageReplaced = "ACCOUNT_IMAGE_REPLACED", accountImageRemoved = "ACCOUNT_IMAGE_REMOVED",
         idpCreated = "IDP_CREATED", idpUpdated = "IDP_UPDATED", idpDeleted = "IDP_DELETED",
         idpAccountSyncEnabled = "IDP_ACCOUNT_SYNC_ENABLED", idpAccountSyncDisabled = "IDP_ACCOUNT_SYNC_DISABLED",
         appleServicesSettingsUpdated = "APPLE_SERVICES_SETTINGS_UPDATED",
         accountPasswordChanged = "ACCOUNT_PASSWORD_CHANGED"

    /// Where a type's payload is and what it holds: the attribute key, and the payload's fields.
    public struct PayloadSchema: Sendable, Equatable {
        public let key: String
        public let fields: [String]
    }

    /// Each type's payload, from Apple's `AuditEvent<Type>Attributes` (its one key) and `AuditEvent<Type>` (the
    /// fields), written out here and held to the contract by `AuditEventTests`. Fourteen payloads have no fields in
    /// Apple's docs (`fourteenPayloadsHaveNoFields`): what they hold live is unread, and the acceptance pass names it.
    public var payload: PayloadSchema {
        switch self {
        case .deviceAddedToOrg: PayloadSchema(key: "eventDataDeviceAddedToOrg", fields: ["purchaseSourceId", "purchaseSourceType", "serialNumber"])
        case .deviceRemovedFromOrg: PayloadSchema(key: "eventDataDeviceRemovedFromOrg", fields: ["releaseEntityId", "releaseEntityType", "serialNumber"])
        case .deviceAssignedToServer: PayloadSchema(key: "eventDataDeviceAssignedToServer", fields: ["serialNumber", "targetServerName"])
        case .deviceUnassignedFromServer: PayloadSchema(key: "eventDataDeviceUnassignedFromServer", fields: ["serialNumber"])
        case .subjectHasIcloudStoragePurchaseAdded: PayloadSchema(key: "eventDataSubjectHasICloudStoragePurchaseAdded", fields: ["subscriptionId"])
        case .subjectHasIcloudStoragePurchaseRemoved: PayloadSchema(key: "eventDataSubjectHasICloudStoragePurchaseRemoved", fields: ["subscriptionId"])
        case .subjectHasApplecarePurchaseAdded: PayloadSchema(key: "eventDataSubjectHasAppleCarePurchaseAdded", fields: ["subscriptionId"])
        case .subjectHasApplecarePurchaseRemoved: PayloadSchema(key: "eventDataSubjectHasAppleCarePurchaseRemoved", fields: ["subscriptionId"])
        case .deviceIsErased: PayloadSchema(key: "eventDataDeviceIsErased", fields: [])
        case .configSettingsCreated: PayloadSchema(key: "eventDataConfigSettingsCreated", fields: ["configId", "configType", "configVersion"])
        case .configSettingsUpdated: PayloadSchema(key: "eventDataConfigSettingsUpdated", fields: ["configId", "configType", "configVersion"])
        case .configSettingsDeleted: PayloadSchema(key: "eventDataConfigSettingsDeleted", fields: ["configId", "configType", "configVersion"])
        case .collectionCreated: PayloadSchema(key: "eventDataCollectionCreated", fields: ["description", "name"])
        case .collectionUpdated: PayloadSchema(key: "eventDataCollectionUpdated", fields: ["description", "name"])
        case .collectionDeleted: PayloadSchema(key: "eventDataCollectionDeleted", fields: ["description", "name"])
        case .subscriptionCreated: PayloadSchema(key: "eventDataSubscriptionCreated", fields: ["planCaption"])
        case .subscriptionUpdated: PayloadSchema(key: "eventDataSubscriptionUpdated", fields: ["planCaption"])
        case .subscriptionDeleted: PayloadSchema(key: "eventDataSubscriptionDeleted", fields: ["planCaption"])
        case .accountRoleLocationChanged: PayloadSchema(key: "eventDataAccountRoleLocationChanged", fields: ["accountRoleLocationList"])
        case .accountAdded: PayloadSchema(key: "eventDataAccountAdded", fields: [])
        case .accountDeleted: PayloadSchema(key: "eventDataAccountDeleted", fields: [])
        case .externalAccountAssociated: PayloadSchema(key: "eventDataExternalAccountAssociated", fields: [])
        case .externalAccountDisassociated: PayloadSchema(key: "eventDataExternalAccountDisassociated", fields: [])
        case .domainAdded: PayloadSchema(key: "eventDataDomainAdded", fields: [])
        case .domainRemoved: PayloadSchema(key: "eventDataDomainRemoved", fields: [])
        case .domainVerified: PayloadSchema(key: "eventDataDomainVerified", fields: [])
        case .apiAccountCreatedWithKey: PayloadSchema(key: "eventDataApiAccountCreatedWithKey", fields: ["keyId"])
        case .apiAccountCreatedWithoutKey: PayloadSchema(key: "eventDataApiAccountCreatedWithoutKey", fields: [])
        case .apiAccountDeleted: PayloadSchema(key: "eventDataApiAccountDeleted", fields: [])
        case .apiAccountKeyRevoked: PayloadSchema(key: "eventDataApiAccountKeyRevoked", fields: ["keyId"])
        case .apiAccountKeyGenerated: PayloadSchema(key: "eventDataApiAccountKeyGenerated", fields: ["keyId"])
        case .apiAccountRoleLocationChanged: PayloadSchema(key: "eventDataApiAccountRoleLocationChanged", fields: ["apiAccountRoleLocationList"])
        case .apiAccountNameChanged: PayloadSchema(key: "eventDataApiAccountNameChanged", fields: ["newName"])
        case .roleCreated: PayloadSchema(key: "eventDataRoleCreated", fields: ["privileges"])
        case .roleUpdated: PayloadSchema(key: "eventDataRoleUpdated", fields: ["privilegesAdded", "privilegesRemoved"])
        case .termsAccepted: PayloadSchema(key: "eventDataTermsAccepted", fields: ["termsName"])
        case .domainFederationEnabled: PayloadSchema(key: "eventDataDomainFederationEnabled", fields: ["activityId", "scimActivityId"])
        case .domainFederationDisabled: PayloadSchema(key: "eventDataDomainFederationDisabled", fields: ["activityId"])
        case .batchPasswordResetInitiated: PayloadSchema(key: "eventDataBatchPasswordResetInitiated", fields: ["activityId"])
        case .externalAccountInvited: PayloadSchema(key: "eventDataExternalAccountInvited", fields: [])
        case .accountImageSet: PayloadSchema(key: "eventDataAccountImageSet", fields: [])
        case .accountImageReplaced: PayloadSchema(key: "eventDataAccountImageReplaced", fields: [])
        case .accountImageRemoved: PayloadSchema(key: "eventDataAccountImageRemoved", fields: [])
        case .idpCreated: PayloadSchema(key: "eventDataIdpCreated", fields: ["protocol", "vendorName"])
        case .idpUpdated: PayloadSchema(key: "eventDataIdpUpdated", fields: ["vendorName"])
        case .idpDeleted: PayloadSchema(key: "eventDataIdpDeleted", fields: ["vendorName"])
        case .idpAccountSyncEnabled: PayloadSchema(key: "eventDataIdpAccountSyncEnabled", fields: ["activityId", "vendorName"])
        case .idpAccountSyncDisabled: PayloadSchema(key: "eventDataIdpAccountSyncDisabled", fields: ["activityId", "vendorName"])
        case .appleServicesSettingsUpdated: PayloadSchema(key: "eventDataAppleServicesSettingsUpdated", fields: ["settingsDisabled", "settingsEnabled"])
        case .accountPasswordChanged: PayloadSchema(key: "eventDataAccountPasswordChanged", fields: ["activityId"])
        }
    }
}
