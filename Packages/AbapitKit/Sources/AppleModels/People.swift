import Foundation
import JSONAPI

/// `users`: a person in the organization (Business only). Apple's people are read-only at 2.6 (plan §2.4).
public struct User: ResourceView {
    public static let resourceType = "users"
    public static let fields = [
        "firstName", "middleName", "lastName", "status", "managedAppleAccount", "isExternalUser", "roleOuList", "email",
        "employeeNumber", "costCenter", "division", "department", "jobTitle", "startDateTime", "createdDateTime", "updatedDateTime",
        "phoneNumbers",
    ]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var firstName: String? { attributes.string("firstName") }
    public var middleName: String? { attributes.string("middleName") }
    public var lastName: String? { attributes.string("lastName") }
    /// The name parts Apple sent, in order; nil when it sent none.
    public var fullName: String? {
        let parts = [firstName, middleName, lastName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    public var status: OpenEnum<UserStatus>? { attributes.open("status") }
    public var managedAppleAccount: String? { attributes.string("managedAppleAccount") }
    public var isExternalUser: Bool? { attributes.bool("isExternalUser") }
    /// The roles the person holds, each in an organizational unit.
    public var roleOuList: [UserRoleOuMapping]? { UserRoleOuMapping.list("roleOuList", in: attributes) }
    public var email: String? { attributes.string("email") }
    public var employeeNumber: String? { attributes.string("employeeNumber") }
    public var costCenter: String? { attributes.string("costCenter") }
    public var division: String? { attributes.string("division") }
    public var department: String? { attributes.string("department") }
    public var jobTitle: String? { attributes.string("jobTitle") }
    public var startDate: ISODate? { attributes.date("startDateTime") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
    public var phoneNumbers: [UserPhoneNumber]? { UserPhoneNumber.list("phoneNumbers", in: attributes) }

    public var unreadNested: [NestedKey] {
        UserPhoneNumber.unread(phoneNumbers, in: "phoneNumbers") + UserRoleOuMapping.unread(roleOuList, in: "roleOuList")
    }
    public var misreadLists: [String] { misread(["roleOuList": roleOuList == nil, "phoneNumbers": phoneNumbers == nil]) }
}

/// `UserPhoneNumber`: one of a user's numbers.
public struct UserPhoneNumber: ObjectView {
    public static let fields = ["phoneNumber", "type"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    public var phoneNumber: String? { object.string("phoneNumber") }
    public var type: OpenEnum<UserPhoneNumberType>? { object.open("type") }
}

/// `UserRoleOuMapping`: a role a user holds in an organizational unit.
public struct UserRoleOuMapping: ObjectView {
    public static let fields = ["roleName", "ouId"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    public var roleName: String? { object.string("roleName") }
    public var ouID: String? { object.string("ouId") }
}

/// `userGroups`: a group of users (Business only); its members are `userGroups/{id}/relationships/users`.
public struct UserGroup: ResourceView {
    public static let resourceType = "userGroups"
    public static let fields = ["ouId", "name", "type", "totalMemberCount", "status", "createdDateTime", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String? { attributes.string("name") }
    public var ouID: String? { attributes.string("ouId") }
    public var type: OpenEnum<UserGroupType>? { attributes.open("type") }
    /// Apple's count, which no page cap cuts.
    public var totalMemberCount: Int? { attributes.int("totalMemberCount") }
    public var status: OpenEnum<UserGroupStatus>? { attributes.open("status") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
}

/// `organizationalUnits`: an org unit (Business only); its members are `organizationalUnits/{id}/relationships/users`.
public struct OrganizationalUnit: ResourceView {
    public static let resourceType = "organizationalUnits"
    public static let fields = ["name", "description", "createdDateTime", "updatedDateTime"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var name: String? { attributes.string("name") }
    public var summary: String? { attributes.string("description") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
}
