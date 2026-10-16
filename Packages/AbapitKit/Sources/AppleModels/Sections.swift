import Foundation

/// What a scope can read, abapit's `BUSINESS_SECTIONS` / `SCHOOL_SECTIONS` (client.py:29-51): navigation is
/// gated on it, and School has no people, content or audit endpoints (plan §2.4).
public enum AppleSection: String, CaseIterable, Sendable {
    case devices, mdmServers = "mdm_servers", mdmEnrolled = "mdm_enrolled", users, userGroups = "user_groups",
         orgUnits = "org_units", apps, packages, blueprints, configurations, auditEvents = "audit_events"

    public var displayName: String {
        switch self {
        case .devices: "Devices"
        case .mdmServers: "Device management services"
        case .mdmEnrolled: "Apple MDM enrolled"
        case .users: "Users"
        case .userGroups: "User groups"
        case .orgUnits: "Org units"
        case .apps: "Apps"
        case .packages: "Packages"
        case .blueprints: "Blueprints"
        case .configurations: "Configurations"
        case .auditEvents: "Audit events"
        }
    }

    /// The collection a read probe lists with `limit=1` (abapit's `READ_PROBES`).
    public var path: String {
        switch self {
        case .devices: "/v1/orgDevices"
        case .mdmServers: "/v1/mdmServers"
        case .mdmEnrolled: "/v1/mdmDevices"
        case .users: "/v1/users"
        case .userGroups: "/v1/userGroups"
        case .orgUnits: "/v1/organizationalUnits"
        case .apps: "/v1/apps"
        case .packages: "/v1/packages"
        case .blueprints: "/v1/blueprints"
        case .configurations: "/v1/configurations"
        case .auditEvents: "/v1/auditEvents"
        }
    }

    public var businessOnly: Bool { ![.devices, .mdmServers].contains(self) }
}
