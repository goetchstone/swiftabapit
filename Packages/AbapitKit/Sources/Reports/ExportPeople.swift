import Foundation

/// The People screen's exports (invariant 11: an export names its columns). Each is its table's columns, then the rest of
/// Apple's documented attributes of the resource in its view's `fields` order, so every column is a documented attribute
/// and a key Apple adds later is not exported until it is listed here. Nothing here is secret; a user's phone numbers and
/// roles are written as the CSV writes any list of objects (each item as JSON, joined by "; ").
extension ExportPolicy {
    /// Users: the table's name (first, middle, last), Managed Apple Account, email, status, external, department, job title
    /// and start date, then `User.fields`' others.
    public static let users = Columns([
        "firstName", "middleName", "lastName", "managedAppleAccount", "email", "status", "isExternalUser", "department", "jobTitle",
        "startDateTime", "roleOuList", "employeeNumber", "costCenter", "division", "createdDateTime", "updatedDateTime", "phoneNumbers",
    ])

    /// User groups: the table's name, type, status, Apple's member count and org unit, then `UserGroup.fields`' others.
    public static let userGroups = Columns(["name", "type", "status", "totalMemberCount", "ouId", "createdDateTime", "updatedDateTime"])

    /// Org units: the table's name and description, then `OrganizationalUnit.fields`' others.
    public static let organizationalUnits = Columns(["name", "description", "createdDateTime", "updatedDateTime"])
}
