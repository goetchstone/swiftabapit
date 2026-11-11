import AppleModels
import Foundation
import Orgs

/// The sidebar, mirroring abapit's navigation (plan §4; Appendix B): each section, what it reads, when the recorded probes
/// lock it and whether the org's scope shows it. Here rather than in the app so `swift test` holds the rules; the app adds
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
    /// Mosyle Business (Phase 7): the Mosyle org in view, the active one or the one the Apple org is paired with.
    case mosyle
    /// Apple Business against Mosyle Business, by serial (Phase 7).
    case reconciliation
    case reports, settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .appleMDM: "Apple MDM"
        default: rawValue.capitalized
        }
    }

    /// The title inside a sentence: "can't read people", "can't read Apple MDM", "Mosyle".
    public var phrase: String { [.appleMDM, .mosyle].contains(self) ? title : title.lowercased() }

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
        case .mosyle, .reconciliation, .reports, .settings: []
        }
    }

    /// The sections a Mosyle Business org shows: Mosyle's own, and Settings. Apple's screens have nothing to read for it, and
    /// the reconciliation runs from the Apple org it is paired with (`OrgsModel.reconciles`).
    public static let mosyleSections: [SidebarItem] = [.mosyle, .settings]

    /// Whether Apple School Manager's API has nothing this section reads.
    public var isBusinessOnly: Bool { !reads.isEmpty && reads.allSatisfy(\.businessOnly) }

    /// Whether the last permissions check found the org's role can't read anything the section shows: every one of its
    /// `reads` probed "forbidden". The lock then takes the screen's place with "your role can't read this" (invariant 8).
    /// A section the role can read part of shows its screen, and each refused panel says so in its own `.forbidden`
    /// (Phase 2b review M1: one probe, users or apps, locked all of People or Content, though their models show the groups
    /// beside refused users and the blueprints beside refused apps). A read with no probe result recorded (not probed, as
    /// a School org's Business-only reads aren't, or probed before this version) isn't denied, and neither is an error.
    public func isLocked(for org: OrgProfile?) -> Bool {
        guard let org, !reads.isEmpty else { return false }
        let denied = org.deniedSections
        return reads.allSatisfy { denied.contains($0.rawValue) }
    }

    /// What a locked section says in its screen's place. Here so a test reads it: in the app's `ContentView` a locked
    /// Overview, which M1's rule made possible, read "can't read overview." (Phase 2b verifier round 1).
    public var lockedNote: String {
        let what = self == .overview ? "anything the Overview shows: its devices, services and audit log" : phrase
        return "The last permissions check found this API account's role can't read \(what)."
    }

    /// The sections the sidebar lists for `org`: a known School org's hides the Business-only ones rather than showing
    /// them empty, and a Mosyle Business org's shows Mosyle's (plan §4: hidden by provider and scope). No org, an unknown
    /// scope or an unknown provider hides nothing: each screen then says why it can't read, which a hidden section couldn't.
    public static func shown(for org: OrgProfile?) -> [SidebarItem] {
        if org?.provider == .known(.mosyle) { return mosyleSections }
        guard let org, org.provider == .known(.apple), org.scope == .known(.school) else { return allCases }
        return allCases.filter { !$0.isBusinessOnly }
    }

    /// The section on screen: `chosen` when the org shows it, else the Overview (a School org opened on People, or an
    /// org switch away from a Business org's Content), or Mosyle for a Mosyle org, which has no Overview.
    public static func showing(_ chosen: SidebarItem?, for org: OrgProfile?) -> SidebarItem {
        let sections = shown(for: org)
        guard let chosen, sections.contains(chosen) else { return sections.contains(.overview) ? .overview : sections[0] }
        return chosen
    }
}
