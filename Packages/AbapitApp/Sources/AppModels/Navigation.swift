import AppleModels
import Foundation
import Orgs

/// The sidebar, mirroring abapit's navigation (plan §4; Appendix B): each section, what it reads, the probe that locks
/// it and whether the org's scope shows it. Here rather than in the app so `swift test` holds the rules; the app adds
/// only symbols and the launch's section (`App/AbapitApp.swift`). The raw value names a section to `ABAPIT_SCREEN`,
/// `scripts/screenshots.sh` and the accessibility identifiers (`sidebar.<raw>`).
public enum SidebarItem: String, CaseIterable, Identifiable, Sendable {
    /// The Dashboard (Appendix B: "Overview › Dashboard").
    case overview
    case devices
    /// Device management services: Phase 1 gave them a row of their own.
    case services
    /// Appendix B's "Devices › Apple MDM": the devices Apple's own MDM enrolls, beside the services.
    case appleMDM = "apple-mdm"
    case people, content
    /// Appendix B's "Activity › Audit" and its views; Phase 3 adds Changes.
    case activity
    case reports, settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .appleMDM: "Apple MDM"
        default: rawValue.capitalized
        }
    }

    /// The title inside a sentence: "can't read people", "can't read Apple MDM".
    public var phrase: String { self == .appleMDM ? title : title.lowercased() }

    /// The Apple reads the section shows. A School org hides a section when every one is Business-only (plan §2.4).
    /// Phase 3's Changes are local history, readable in either scope: when Activity shows them, it lists none here.
    public var reads: [AppleSection] {
        switch self {
        case .overview: [.devices, .mdmServers, .auditEvents]
        case .devices: [.devices]
        case .services: [.mdmServers]
        case .appleMDM: [.mdmEnrolled]
        case .people: [.users, .userGroups, .orgUnits]
        case .content: [.apps, .packages, .blueprints, .configurations]
        case .activity: [.auditEvents]
        case .reports, .settings: []
        }
    }

    /// The probe whose "forbidden" locks the whole section: a lock and "your role can't read this" (invariant 8). A
    /// screen whose other reads the role can't do says so in its own panels.
    public var probed: AppleSection? {
        switch self {
        case .devices: .devices
        case .services: .mdmServers
        case .appleMDM: .mdmEnrolled
        case .people: .users
        case .content: .apps
        case .activity: .auditEvents
        case .overview, .reports, .settings: nil
        }
    }

    /// Whether Apple School Manager's API has nothing this section reads.
    public var isBusinessOnly: Bool { !reads.isEmpty && reads.allSatisfy(\.businessOnly) }

    /// Whether the last permissions check found the org's role can't read the section's probe.
    public func isLocked(for org: OrgProfile?) -> Bool {
        guard let probed, let org else { return false }
        return org.deniedSections.contains(probed.rawValue)
    }

    /// The sections the sidebar lists for `org`: a known School org's hides the Business-only ones rather than showing
    /// them empty (plan §4). No org, an unknown scope or another provider hides nothing: each screen then says why it
    /// can't read, which a hidden section couldn't.
    public static func shown(for org: OrgProfile?) -> [SidebarItem] {
        guard let org, org.provider == .known(.apple), org.scope == .known(.school) else { return allCases }
        return allCases.filter { !$0.isBusinessOnly }
    }

    /// The section on screen: `chosen` when the org shows it, else the Overview (a School org opened on People, or an
    /// org switch away from a Business org's Content).
    public static func showing(_ chosen: SidebarItem?, for org: OrgProfile?) -> SidebarItem {
        guard let chosen, shown(for: org).contains(chosen) else { return .overview }
        return chosen
    }
}
