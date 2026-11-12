import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport

/// The sidebar's rules (plan §4): which sections an org's scope shows, when the recorded probes lock one, what Refresh and the
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
        #expect(SidebarItem.shown(for: Self.org("school")) == [.overview, .devices, .services, .mosyle, .reconciliation, .reports, .settings])
    }

    @Test func aBusinessOrgShowsEverySectionInOrder() {
        #expect(SidebarItem.shown(for: Self.org("business"))
                == [.overview, .devices, .services, .appleMDM, .people, .content, .activity, .mosyle, .reconciliation, .reports, .settings])
        #expect(SidebarItem.allCases == SidebarItem.shown(for: Self.org("business")))
    }

    /// No org, a scope this version doesn't know, or a provider it doesn't know hides nothing: each screen says why it can't
    /// read (`LoadState.unusable`), which a hidden section couldn't. A Mosyle Business org shows Mosyle's sections (Phase 7),
    /// whatever its scope says.
    @Test func onlyAKnownSchoolScopeOrMosyleHidesASection() {
        #expect(SidebarItem.shown(for: nil) == SidebarItem.allCases)
        #expect(SidebarItem.shown(for: Self.org("district")) == SidebarItem.allCases)
        #expect(SidebarItem.shown(for: Self.org("business", provider: "jamf")) == SidebarItem.allCases)
        #expect(SidebarItem.shown(for: Self.org("school", provider: "mosyle")) == [.mosyle, .settings])
        #expect(SidebarItem.shown(for: Self.org("business", provider: "mosyle")) == SidebarItem.mosyleSections)
    }

    /// A section is Business-only when every read it shows is: the Overview's audit panel says "not in scope" itself.
    @Test func eachSectionReadsWhatItShows() {
        let reads = Dictionary(uniqueKeysWithValues: SidebarItem.allCases.map { ($0, $0.reads) })
        #expect(reads == [
            .overview: [.devices, .mdmServers, .auditEvents], .devices: [.devices], .services: [.mdmServers],
            .appleMDM: [.mdmEnrolled], .people: [.users, .userGroups, .orgUnits],
            .content: [.apps, .packages, .blueprints, .configurations], .activity: [.auditEvents], .mosyle: [], .reconciliation: [],
            .reports: [], .settings: [],
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
        // A Mosyle org has no Overview: its first section.
        #expect(SidebarItem.showing(.people, for: Self.org("business", provider: "mosyle")) == .mosyle)
        #expect(SidebarItem.showing(nil, for: Self.org("business", provider: "mosyle")) == .mosyle)
        #expect(SidebarItem.showing(.settings, for: Self.org("business", provider: "mosyle")) == .settings)
        #expect(SidebarItem.showing(.activity, for: school) == .overview)
        #expect(SidebarItem.showing(.devices, for: school) == .devices)
        #expect(SidebarItem.showing(.people, for: business) == .people)
        #expect(SidebarItem.showing(.appleMDM, for: nil) == .appleMDM)
        #expect(SidebarItem.showing(nil, for: business) == .overview)
    }

    /// A section locks when the recorded probes refused every read it shows; an error isn't a refusal, and no probe on
    /// record locks nothing.
    @Test func aSectionLocksWhenEveryReadIsDenied() {
        let locked = Self.org("business", capabilities: ["mdm_enrolled": "forbidden", "users": "ok", "audit_events": "error 500"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: locked) } == [.appleMDM])
        #expect(!SidebarItem.appleMDM.isLocked(for: nil))
        #expect(!SidebarItem.appleMDM.isLocked(for: Self.org("business")))
        let every = Dictionary(uniqueKeysWithValues: AppleSection.allCases.map { ($0.rawValue, "forbidden") })
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: Self.org("business", capabilities: every)) }
                == [.overview, .devices, .services, .appleMDM, .people, .content, .activity], "Reports and Settings read nothing of Apple's")
        let people = Self.org("business", capabilities: ["users": "forbidden", "user_groups": "forbidden", "org_units": "forbidden"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: people) } == [.people])
        let content = Self.org("business", capabilities: ["apps": "forbidden", "packages": "forbidden", "blueprints": "forbidden",
                                                          "configurations": "forbidden"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: content) } == [.content])
        #expect(SidebarItem.activity.isLocked(for: Self.org("business", capabilities: ["audit_events": "forbidden"])))
    }

    /// Phase 2b review M1: one refused probe locked all of People (users) or Content (apps), though their models show the
    /// groups and org units beside refused users, the blueprints and configurations beside refused apps. A section the
    /// role can read part of shows its screen, and the refused panel says so itself.
    @Test func aPartlyDeniedSectionIsUnlocked() {
        let partly = Self.org("business", capabilities: [
            "apps": "forbidden", "packages": "ok", "blueprints": "ok", "configurations": "ok",
            "users": "forbidden", "user_groups": "ok", "org_units": "ok",
            "devices": "forbidden", "mdm_servers": "forbidden", "audit_events": "ok",
        ])
        #expect(!SidebarItem.people.isLocked(for: partly) && !SidebarItem.content.isLocked(for: partly))
        #expect(!SidebarItem.overview.isLocked(for: partly), "the Overview's audit card can still be read")
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: partly) } == [.devices, .services])
        // Two of three refused is still part.
        let two = Self.org("business", capabilities: ["users": "forbidden", "user_groups": "forbidden", "org_units": "ok"])
        #expect(!SidebarItem.people.isLocked(for: two))
    }

    /// Whichever read is the one refused, or the one readable, a section of several stays unlocked (Phase 2b verifier round
    /// 1, mutant N-lockLastOnly: every partly refused case above had its last read readable, so a lock on the last read alone
    /// passed, and a role refused only org units, configurations or the audit log lost all of People, Content or the Overview).
    @Test func aSectionOfSeveralReadsLocksOnNoOneOfThem() {
        for section in SidebarItem.allCases where section.reads.count > 1 {
            for read in section.reads {
                let others = section.reads.filter { $0 != read }.map(\.rawValue)
                let onlyThis = Dictionary(uniqueKeysWithValues: others.map { ($0, "ok") } + [(read.rawValue, "forbidden")])
                #expect(!section.isLocked(for: Self.org("business", capabilities: onlyThis)), "\(section): only \(read) refused")
                let allButThis = Dictionary(uniqueKeysWithValues: others.map { ($0, "forbidden") } + [(read.rawValue, "ok")])
                #expect(!section.isLocked(for: Self.org("business", capabilities: allButThis)), "\(section): only \(read) readable")
            }
        }
        let lasts = Self.org("business", capabilities: ["users": "ok", "user_groups": "ok", "org_units": "forbidden", "apps": "ok",
                                                        "configurations": "forbidden", "devices": "ok", "mdm_servers": "ok",
                                                        "audit_events": "forbidden"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: lasts) } == [.activity])
    }

    /// A locked section's sentence names what the role can't read; the Overview's names its three reads, never "can't read
    /// overview." (Phase 2b verifier round 1: M1's rule let the Overview lock, and the view's sentence wasn't written for it).
    @Test func aLockedSectionSaysWhatItCantRead() {
        #expect(SidebarItem.overview.lockedNote
                == "The last permissions check found this API account's role can't read anything the Overview shows: its devices, services and audit log.")
        #expect(SidebarItem.people.lockedNote == "The last permissions check found this API account's role can't read people.")
        #expect(SidebarItem.appleMDM.lockedNote == "The last permissions check found this API account's role can't read Apple MDM.")
        for section in SidebarItem.allCases where section != .overview {
            #expect(section.lockedNote == "The last permissions check found this API account's role can't read \(section.phrase).")
        }
    }

    /// A read with no probe result on record isn't denied: an older check that didn't probe it, or a School org, whose
    /// Business-only reads aren't probed. A School org's Overview with its devices and services refused still shows, its
    /// audit card saying not in scope; its scope rule hides the Business-only sections as before.
    @Test func aReadNoProbeRecordedDoesntLock() {
        let older = Self.org("business", capabilities: ["users": "forbidden", "user_groups": "forbidden"])
        #expect(!SidebarItem.people.isLocked(for: older), "org units were never probed")
        let errors = Self.org("business", capabilities: ["users": "forbidden", "user_groups": "error 500", "org_units": "error"])
        #expect(!SidebarItem.people.isLocked(for: errors), "an error isn't a refusal")
        let school = Self.org("school", capabilities: ["devices": "forbidden", "mdm_servers": "forbidden"])
        #expect(SidebarItem.allCases.filter { $0.isLocked(for: school) } == [.devices, .services])
        #expect(SidebarItem.shown(for: school) == [.overview, .devices, .services, .mosyle, .reconciliation, .reports, .settings])
        let schoolAll = Self.org("school", capabilities: ["devices": "forbidden", "mdm_servers": "forbidden", "audit_events": "forbidden"])
        #expect(SidebarItem.overview.isLocked(for: schoolAll), "every read recorded refused")
    }

    /// Titles are distinct (each sidebar row's label), and the raw values are the names `ABAPIT_SCREEN` and the
    /// accessibility identifiers use, unchanged from Phase 1 for its sections.
    @Test func everySectionHasOneTitleAndOneName() {
        #expect(SidebarItem.allCases.map(\.title)
                == ["Overview", "Devices", "Services", "Apple MDM", "People", "Content", "Activity", "Mosyle", "Reconciliation", "Reports", "Settings"])
        #expect(SidebarItem.allCases.map(\.rawValue)
                == ["overview", "devices", "services", "apple-mdm", "people", "content", "activity", "mosyle", "reconciliation", "reports", "settings"])
        #expect(SidebarItem.allCases.map(\.phrase)
                == ["overview", "devices", "services", "Apple MDM", "people", "content", "activity", "Mosyle", "reconciliation", "reports",
                    "settings"])
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
        #expect(inspected == ["devices", "people", "content", "apple-mdm", "activity", "mosyle"], "\(inspected.sorted())")
        let narrow = specs.filter { $0[0].hasPrefix("narrow-") }
        #expect(narrow.allSatisfy { $0.count == 4 && $0[3] == "smallest" })
        #expect(Set(narrow.filter { $0[2] == "first" }.map { $0[1] }) == inspected)
        #expect(narrow.contains { $0[1] == "overview" && $0[2].isEmpty })
        #expect(Set(specs.map { $0[0] }).count == specs.count, "two runs write one picture")
        // A run's demo (its fifth field) is one the app knows, `1` unless given; the client runs ask for two clients and draw
        // the switcher and Settings by client (the review of PR 18: a misspelt demo fell through to the real store, green).
        let demos = specs.map { $0.count > 4 ? $0[4] : "" }
        #expect(demos.allSatisfy { ["", "1", "clients", "apple"].contains($0) }, "\(demos)")
        #expect(Set(specs.filter { $0.count > 4 && $0[4] == "clients" }.map { $0[1] }) == ["overview", "settings"])
        // A run's sheet (its sixth field) is one Settings opens: each add sheet drawn once, with its customer question, in a
        // demo where some client has room for that kind (`apple`: the Mosyle sheet names the Apple org; `clients`: the Apple
        // sheet lists the client with no Apple org).
        let sheets = specs.filter { $0.count > 5 }.map { "\($0[1]):\($0[4]):\($0[5])" }
        #expect(sheets.sorted() == ["settings:apple:add-mosyle", "settings:clients:add-apple"], "\(sheets)")
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
        // The webhooks, no section yet, say it in the same words (the contract-2.8 review's L4: they read as failed).
        #expect(LoadState(after: AppleAPIError.webhooksNotInScope) == .notInScope("Apple School Manager's API has no webhooks to read."))
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

    /// Refresh on each section reads that section's own model again, and no other (Phase 2b review L10, mutant X1: People's
    /// Refresh sent to the devices left every suite green while the routing sat in the app's `ContentView`).
    @Test func refreshReadsTheSectionsOwnModel() async throws {
        for section in SidebarItem.allCases {
            let world = try await World.make(mosyle: true)
            world.screens.refresh(section)
            let loading: [String: Bool] = [
                "devices": world.devices.state.isLoading, "audit": world.dashboard.auditState.isLoading,
                "people": world.people.users.state.isLoading, "content": world.content.apps.state.isLoading,
                "appleMDM": world.appleMDM.state.isLoading, "activity": world.activity.state.isLoading,
                "mosyle": world.mosyle.devices.state.isLoading,
            ]
            let expected: Set<String> = switch section {
            case .overview: ["devices", "audit"]
            case .people: ["people"]
            case .content: ["content"]
            case .appleMDM: ["appleMDM"]
            case .activity: ["activity"]
            case .mosyle: ["mosyle"]
            case .reconciliation: ["devices", "mosyle"]
            case .devices, .services, .reports, .settings: ["devices"]
            }
            #expect(Set(loading.filter(\.value).keys) == expected, "\(section)")
        }
        // A Refresh reads again what an unforced load wouldn't.
        let world = try await World.make()
        world.people.load()
        await eventually("people read") { !world.people.users.state.isLoading && world.people.users.state != .idle }
        world.screens.refresh(.people)
        #expect(world.people.users.state.isLoading)
    }

    /// Refresh on a section already read reads it again, in every section (Phase 2b verifier round 1, mutants
    /// N-refreshContentUnforced and N-refreshAppleMDMUnforced: an unforced `load()` from Refresh read nothing after the first
    /// read, and only People's force was held).
    @Test func refreshOnASectionAlreadyReadReadsAgain() async throws {
        for section in SidebarItem.allCases {
            let world = try await World.make(mosyle: true)
            switch section {
            case .overview: world.dashboard.load()
            case .people: world.people.load()
            case .content: world.content.load()
            case .appleMDM: world.appleMDM.load()
            case .activity: world.activity.load()
            case .mosyle: world.mosyle.load()
            case .reconciliation: world.reconciliation.load()
            case .devices, .services, .reports, .settings: world.devices.load()
            }
            await eventually("\(section) read once") {
                world.devices.readsFinished + world.dashboard.readsFinished + world.people.readsFinished + world.content.readsFinished
                    + world.appleMDM.readsFinished + world.activity.readsFinished + world.mosyle.readsFinished > 0
                    && ![world.devices.state, world.dashboard.auditState, world.people.users.state, world.content.apps.state,
                         world.appleMDM.state, world.activity.state, world.mosyle.devices.state].contains { $0.isLoading }
            }
            world.screens.refresh(section)
            let loading = [world.devices.state, world.dashboard.auditState, world.people.users.state, world.content.apps.state,
                           world.appleMDM.state, world.activity.state, world.mosyle.devices.state].filter(\.isLoading).count
            #expect(loading == ([.overview, .reconciliation].contains(section) ? 2 : 1), "\(section)")
        }
    }

    static func failed<Value>(_ panel: Panel<Value>) -> String? { if case .failed(let why) = panel { why } else { nil } }

    /// With no organization every screen model says one sentence, Apple School Manager named too, and with one this
    /// version can't use, one other (Phase 2b review L10: six copies, Apple MDM's without "or Apple School Manager", and the
    /// inspectors' "This organization can't be used: there is none.").
    @Test func everyScreenSaysWhyNothingCanBeReadAlike() async throws {
        #expect(ScreenWords.noOrganization == "No organization yet: add an Apple Business or Apple School Manager API account in Settings.")
        for (world, said) in [(try await World.make(profiles: []), ScreenWords.noOrganization),
                              (try await World.make(profiles: [World.unusable]), nil)] {
            for section in SidebarItem.allCases { world.screens.refresh(section) }
            world.detail.show("ADEV0000001")
            world.content.selection = "1000000001"
            world.people.selectedGroup = "G1"
            world.people.selectedUnit = "OU1"
            let expected = said ?? ScreenWords.unusable(world.orgs)
            #expect(expected.hasPrefix(said == nil ? "This organization can't be used: " : "No organization yet: "), "\(expected)")
            let states: [LoadState] = [
                world.devices.state, world.devices.servicesState, world.dashboard.auditState, world.people.users.state, world.people.groups.state,
                world.people.units.state, world.people.groupMembers.state, world.people.unitMembers.state, world.content.apps.state,
                world.content.packages.state, world.content.blueprints.state, world.content.configurations.state, world.appleMDM.state,
                world.activity.state,
            ]
            #expect(states.allSatisfy { $0 == .unusable(expected) }, "\(states)")
            let panels = [Self.failed(world.detail.device), Self.failed(world.detail.coverage), Self.failed(world.detail.lock),
                          Self.failed(world.detail.service), Self.failed(world.detail.timeline), Self.failed(world.content.detail.item)]
            #expect(panels.allSatisfy { $0 == expected }, "\(panels)")
        }
    }

    /// One rule for Export on every screen, in the model: an empty list, or a search that hides every row, has nothing to
    /// export (Phase 2b review L10: People said so and the other screens left it to their views).
    @Test func everyScreenSaysAnEmptyListHasNothingToExport() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        for section: SidebarItem in [.overview, .people, .content, .appleMDM, .activity] { world.screens.refresh(section) }
        await world.settled(2)
        await eventually("every list read") {
            world.dashboard.readsFinished >= 1 && world.people.readsFinished >= 3 && world.content.readsFinished >= 4
                && world.appleMDM.readsFinished >= 1 && world.activity.readsFinished >= 1
        }
        let said = "There's nothing to export."
        #expect(ScreenWords.nothingToExport == said)
        #expect(world.devices.exportBlocked == said && world.appleMDM.exportBlocked == said && world.activity.exportBlocked == said)
        for tab in PeopleModel.Tab.allCases { #expect(world.people.exportBlocked(tab) == said, "\(tab)") }
        for kind in ContentKind.allCases { #expect(world.content.exportBlocked(for: kind) == said, "\(kind)") }

        let stocked = try await World.make()
        stocked.devices.load()
        await stocked.settled(2)
        #expect(stocked.devices.exportBlocked == nil)
        stocked.devices.search = "nothing like this"
        #expect(stocked.devices.shown.isEmpty && stocked.devices.exportBlocked == said)
    }

    /// A search that hides every row has nothing to export, on every list of every screen: the views only disable Export on
    /// `exportBlocked`, so the model is the only guard (Phase 2b verifier round 1, mutants N-exportContentIgnoresSearch and
    /// N-exportUnitsIgnoresSearch: Content's lists and People's org units counted the rows read, not the rows shown).
    @Test func aSearchThatHidesEveryRowHasNothingToExport() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        DemoOrg.load(into: world.stubs["a"]!)
        for section: SidebarItem in [.devices, .people, .content, .appleMDM, .activity] { world.screens.refresh(section) }
        await eventually("every list read") {
            world.people.readsFinished >= 3 && world.content.readsFinished >= 4 && world.appleMDM.readsFinished >= 1
                && world.activity.readsFinished >= 1 && !world.devices.state.isLoading
        }
        await eventually("the Apple MDM details read") { world.appleMDM.exportBlocked == nil }
        for tab in PeopleModel.Tab.allCases { #expect(world.people.exportBlocked(tab) == nil, "\(tab) exports before the search") }
        for kind in ContentKind.allCases { #expect(world.content.exportBlocked(for: kind) == nil, "\(kind) exports before the search") }
        #expect(world.devices.exportBlocked == nil && world.activity.exportBlocked == nil)
        let nothing = "nothing like this at all"
        world.people.search = nothing
        world.content.search = nothing
        world.appleMDM.search = nothing
        world.activity.search = nothing
        world.devices.search = nothing
        for tab in PeopleModel.Tab.allCases { #expect(world.people.exportBlocked(tab) == ScreenWords.nothingToExport, "\(tab)") }
        for kind in ContentKind.allCases { #expect(world.content.exportBlocked(for: kind) == ScreenWords.nothingToExport, "\(kind)") }
        #expect(world.appleMDM.shown.isEmpty && world.appleMDM.exportBlocked == ScreenWords.nothingToExport)
        #expect(world.activity.shown.isEmpty && world.activity.exportBlocked == ScreenWords.nothingToExport)
        #expect(world.devices.shown.isEmpty && world.devices.exportBlocked == ScreenWords.nothingToExport)
    }

    /// The content detail's errors are said as every list's are (`LoadState(after:)`): a 403 is the role's, a failure and a
    /// School org's scope in their words.
    @Test func aContentDetailsErrorIsSaidAsAListsIs() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Resource(type: "apps", id: "1000000001", attributes: ["name": .string("One")])])
        world.content.load()
        await eventually("the lists") { world.content.readsFinished >= 4 }
        world.stubs["a"]!.queue(403, for: "/v1/apps/1000000001")
        world.content.selection = "1000000001"
        await eventually("the refused detail") { world.content.detail.readsFinished >= 1 }
        if case .forbidden = world.content.detail.item {} else { Issue.record("\(world.content.detail.item)") }
        world.stubs["a"]!.queue(503, for: "/v1/apps/1000000001")
        world.content.load(force: true)
        await eventually("the failed detail") { world.content.detail.readsFinished >= 2 }
        #expect(Self.failed(world.content.detail.item) == "Apple's service failed (HTTP 503). Try again later.")
        if case .failed(let why) = LoadState(after: AppleAPIError.server(status: 503)) { #expect(Self.failed(world.content.detail.item) == why) }

        let school = try await World.make(profiles: [World.profile("a", scope: .school)])
        school.content.selection = "1000000001"
        await eventually("the School detail") { school.content.detail.readsFinished >= 1 }
        #expect(Self.failed(school.content.detail.item) == "Apple School Manager's API has no apps to read.")
        #expect(!school.stubs["a"]!.requests.contains { $0.contains("/v1/apps") })
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
