import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport

/// The sidebar's rules (plan §4): which sections an org's scope shows, which probe locks each, what Refresh and the
/// snapshot harness can name. The app's `ContentView` only draws `SidebarItem.shown(for:)` and routes `showing(_:for:)`,
/// so the rules are held here, where `swift test` reaches them.
@Suite("Navigation")
struct NavigationTests {
    static func org(_ scope: String, provider: String = "apple", capabilities: [String: String] = [:]) -> OrgProfile {
        var profile = OrgProfile(raw: ["id": .string("o"), "name": .string("O"), "provider": .string(provider), "scope": .string(scope),
                                       "client_id": .string("BUSINESSAPI.x"), "key_id": .string("k")])
        profile.capabilities = capabilities
        return profile
    }

    /// Apple School Manager has no people, content, Apple MDM or audit endpoints (plan §2.4): those sections are hidden,
    /// not shown empty. The Overview stays: it reads devices and services too.
    @Test func aSchoolOrgHidesTheBusinessOnlySections() {
        #expect(SidebarItem.shown(for: Self.org("school")) == [.overview, .devices, .services, .reports, .settings])
    }

    @Test func aBusinessOrgShowsEverySectionInOrder() {
        #expect(SidebarItem.shown(for: Self.org("business"))
                == [.overview, .devices, .services, .appleMDM, .people, .content, .activity, .reports, .settings])
        #expect(SidebarItem.allCases == SidebarItem.shown(for: Self.org("business")))
    }

    /// No org, a scope this version doesn't know, or another provider hides nothing: each screen says why it can't
    /// read (`LoadState.unusable`), which a hidden section couldn't. Provider rules arrive with Mosyle (Phase 7).
    @Test func onlyAKnownSchoolScopeHidesASection() {
        #expect(SidebarItem.shown(for: nil) == SidebarItem.allCases)
        #expect(SidebarItem.shown(for: Self.org("district")) == SidebarItem.allCases)
        #expect(SidebarItem.shown(for: Self.org("school", provider: "mosyle")) == SidebarItem.allCases)
    }

    /// A section is Business-only when every read it shows is: the Overview's audit panel says "not in scope" itself.
    @Test func eachSectionReadsWhatItShows() {
        let reads = Dictionary(uniqueKeysWithValues: SidebarItem.allCases.map { ($0, $0.reads) })
        #expect(reads == [
            .overview: [.devices, .mdmServers, .auditEvents], .devices: [.devices], .services: [.mdmServers],
            .appleMDM: [.mdmEnrolled], .people: [.users, .userGroups, .orgUnits],
            .content: [.apps, .packages, .blueprints, .configurations], .activity: [.auditEvents], .reports: [], .settings: [],
        ])
        #expect(SidebarItem.allCases.filter(\.isBusinessOnly) == [.appleMDM, .people, .content, .activity])
        // Every Apple read the client has is some section's: none is left without a screen.
        #expect(Set(SidebarItem.allCases.flatMap(\.reads)) == Set(AppleSection.allCases))
    }

    /// The section on screen: the chosen one, unless the org's scope hides it, then the Overview (a School org opened on
    /// People, or an org switch from a Business org's Content).
    @Test func aHiddenSectionShowsTheOverview() {
        let school = Self.org("school"), business = Self.org("business")
        #expect(SidebarItem.showing(.people, for: school) == .overview)
        #expect(SidebarItem.showing(.activity, for: school) == .overview)
        #expect(SidebarItem.showing(.devices, for: school) == .devices)
        #expect(SidebarItem.showing(.people, for: business) == .people)
        #expect(SidebarItem.showing(.appleMDM, for: nil) == .appleMDM)
        #expect(SidebarItem.showing(nil, for: business) == .overview)
    }

    /// The probe whose "forbidden" locks each section: Phase 1's five as they were, and Apple MDM's own.
    @Test func eachSectionLocksOnItsProbe() {
        let probes = Dictionary(uniqueKeysWithValues: SidebarItem.allCases.map { ($0, $0.probed?.rawValue) })
        #expect(probes == [.overview: nil, .devices: "devices", .services: "mdm_servers", .appleMDM: "mdm_enrolled", .people: "users",
                           .content: "apps", .activity: "audit_events", .reports: nil, .settings: nil])
        let locked = Self.org("business", capabilities: ["mdm_enrolled": "forbidden", "users": "ok", "audit_events": "error 500"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: locked) } == [.appleMDM])
        #expect(!SidebarItem.appleMDM.isLocked(for: nil))
        #expect(!SidebarItem.appleMDM.isLocked(for: Self.org("business")))
    }

    /// Titles are distinct (each sidebar row's label), and the raw values are the names `ABAPIT_SCREEN` and the
    /// accessibility identifiers use, unchanged from Phase 1 for its sections.
    @Test func everySectionHasOneTitleAndOneName() {
        #expect(SidebarItem.allCases.map(\.title)
                == ["Overview", "Devices", "Services", "Apple MDM", "People", "Content", "Activity", "Reports", "Settings"])
        #expect(SidebarItem.allCases.map(\.rawValue)
                == ["overview", "devices", "services", "apple-mdm", "people", "content", "activity", "reports", "settings"])
        #expect(SidebarItem.allCases.map(\.phrase)
                == ["overview", "devices", "services", "Apple MDM", "people", "content", "activity", "reports", "settings"])
    }

    /// `scripts/screenshots.sh` names sections by raw value; a name that isn't one would open the Overview and pass.
    /// Every section with a screen has a run, every section with an inspector a `:first` run and a narrow one in the
    /// smallest window (pre-commit: a new inspector gets a `narrow-*` run), and the Overview's narrow run stays.
    @Test func everyScreenHasASnapshot() throws {
        let script = try String(contentsOf: Fixtures.repoRoot.appending(path: "scripts/screenshots.sh"), encoding: .utf8)
        let list = try #require(script.firstRange(of: "for spec in ").map { script[$0.upperBound...] }?.split(separator: ";").first)
        let specs = list.split(whereSeparator: { $0 == " " || $0 == "\\" || $0 == "\n" }).map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
        #expect(specs.count >= 19, "\(specs)")
        let names = Set(SidebarItem.allCases.map(\.rawValue))
        for spec in specs { #expect(spec.count >= 2 && names.contains(spec[1]), "\(spec.joined(separator: ":")) names no section") }
        let screens = Set(specs.map { $0[1] })
        #expect(screens == names.subtracting(["reports"]), "\(screens.sorted())")
        let inspected = Set(specs.filter { $0.count > 2 && $0[2] == "first" }.map { $0[1] })
        #expect(inspected == ["devices", "people", "content", "apple-mdm", "activity"], "\(inspected.sorted())")
        let narrow = specs.filter { $0[0].hasPrefix("narrow-") }
        #expect(narrow.allSatisfy { $0.count == 4 && $0[3] == "smallest" })
        #expect(Set(narrow.filter { $0[2] == "first" }.map { $0[1] }) == inspected)
        #expect(narrow.contains { $0[1] == "overview" && $0[2].isEmpty })
        #expect(Set(specs.map { $0[0] }).count == specs.count, "two runs write one picture")
    }
}

/// What every screen model shares: a failed read's state in words, and the Dashboard's reuse of the Devices read.
@Suite("Screen scaffold")
@MainActor
struct ScaffoldTests {
    /// Invariant 8's states from an error: a 403 is "your role can't read this", a School org's Business-only read is
    /// "not in scope" in words, anything else failed with its message. Never an empty list.
    @Test func aReadsErrorBecomesItsState() {
        #expect(LoadState(after: AppleAPIError.forbidden(code: nil)) == .forbidden)
        #expect(LoadState(after: AppleAPIError.notInScope(.users)) == .notInScope("Apple School Manager's API has no users to read."))
        #expect(LoadState(after: AppleAPIError.server(status: 503)) == .failed("Apple's service failed (HTTP 503). Try again later."))
        #expect(!LoadState.notInScope("x").isLoading)
    }

    /// The Dashboard counts what the Devices screen reads, so its load is that read, and Refresh forces it.
    @Test func theDashboardLoadsTheDevicesRead() async throws {
        let world = try await World.make()
        #expect(world.dashboard.devices === world.devices)
        world.dashboard.load()
        await world.settled(2)
        #expect(world.devices.state.isLoading == false && world.devices.rows.count == 3)
        world.dashboard.load()
        #expect(world.devices.readsFinished == 2 && !world.devices.state.isLoading, "an unforced load read again")
        world.dashboard.load(force: true)
        #expect(world.devices.state.isLoading)
        await world.settled(4)
        #expect(world.devices.rows.count == 3)
    }

    /// A School org in the world reads what School has (its devices, from the School host) and is refused the rest
    /// before anything is sent: what the units' not-in-scope tests stand on.
    @Test func aSchoolWorldReadsItsDevicesAndNoBusinessRead() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.count == 3 && world.devices.devicesReadWhole, "\(world.devices.state)")
        let client = try #require(world.orgs.appleClient)
        await #expect(throws: AppleAPIError.notInScope(.users)) { try await client.user("u1") }
        let requests = world.stubs["a"]!.requests
        #expect(requests.contains { $0.hasPrefix("GET api-school.apple.com/v1/orgDevices") }, "\(requests)")
        #expect(!requests.contains { $0.contains("/v1/users") })
    }

    /// The five Phase 2b models are built over the world's orgs, as AppServices builds them, and a load before the units
    /// fill them is harmless.
    @Test func theWorldBuildsEveryScreenModel() async throws {
        let world = try await World.make()
        world.people.load(force: false)
        world.content.load(force: true)
        world.appleMDM.load(force: false)
        world.activity.load(force: true)
        #expect(world.orgs.generation == 0)
    }
}
