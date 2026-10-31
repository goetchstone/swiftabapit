import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Reports
import Testing
import TestSupport

/// Content's screen model (plan Phase 2; Appendix B: apps, packages, blueprints, configurations), invariant 8's tests for
/// it: four lists read side by side, each with its own state; an org switch, a superseded load and a refresh write
/// nothing of the old read; truncated, forbidden, failed, not in scope and unusable each said; a detail per list; a
/// blueprint's members said as read, cut, unlisted or refused (no count); a custom setting's profile only masked
/// (invariant 11), the demo's canary in nothing the model exposes, its CSV included.
@MainActor
@Suite("Content", .serialized)
struct ContentTests {
    static func app(_ index: Int) -> Resource {
        Resource(type: "apps", id: String(2_000_000_000 + index), attributes: [
            "name": .string(String(format: "App %05d", index)), "bundleId": .string("com.example.app\(index)"),
        ])
    }

    /// The demo's content in org a's stub, its blueprints' devices org a's (`ADEV…`, Macs).
    static func stocked(_ world: World) {
        DemoContent.load(into: world.stubs["a"]!, fleet: (0..<3).map { World.device(World.prefix("a"), $0) })
    }

    /// Waits until `reads` list reads, superseded ones too, have returned.
    static func settled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) content reads, \(world.content.readsFinished) so far") { world.content.readsFinished >= reads }
    }

    static func detailSettled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) detail reads, \(world.content.detail.readsFinished) so far") { world.content.detail.readsFinished >= reads }
    }

    static func isLoaded(_ state: LoadState) -> Bool { if case .loaded = state { true } else { false } }

    static func detail(_ world: World) throws -> ContentDetail {
        guard case .loaded(let detail) = world.content.detail.item else { throw Unexpected(world.content.detail.item) }
        return detail
    }

    struct Unexpected: Error, CustomStringConvertible {
        let description: String
        init(_ value: Any) { description = "\(value)" }
    }

    static let laterAppPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/apps" && ($0.query() ?? "").contains("cursor=") }
    static let appPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/apps" }

    // MARK: the lists

    @Test func everyListLoadsSideBySideSortedByName() async throws {
        let world = try await World.make()
        Self.stocked(world)
        let content = world.content
        #expect(content.apps.state == .idle)
        content.load()
        #expect(content.apps.state.isLoading && content.configurations.state.isLoading)
        await Self.settled(world, 4)
        let counts: [Int] = [content.apps.rows.count, content.packages.rows.count, content.blueprints.rows.count, content.configurations.rows.count]
        #expect(counts == [12, 4, 4, 8])
        #expect([content.apps.state, content.packages.state, content.blueprints.state, content.configurations.state].allSatisfy(Self.isLoaded))
        let apps = content.apps.shown(matching: "")
        #expect(apps.first?.name == "Example Badge" && apps.last?.name == "Example Training", "\(apps.map(\.name))")
        let badge = try #require(apps.first)
        #expect(badge.bundleID == "com.example.badge" && badge.version == "1.0.4" && badge.platforms == "iOS" && badge.source == "Custom")
        #expect(apps.first { $0.name == "Example Notes" }?.platforms == "macOS, iOS, iPadOS, visionOS")
        #expect(apps.first { $0.name == "Example Chat" }?.source == "App Store")
        let wifi = try #require(content.configurations.rows.first { $0.id == "demo-config-02" })
        #expect(wifi.type == "Wi-Fi" && wifi.platforms == "iOS and iPadOS, macOS")
        #expect(content.blueprints.rows.first { $0.id == "demo-blueprint-03" }?.licences == "Too few")
        #expect(content.blueprints.rows.first { $0.id == "demo-blueprint-04" }?.status == "To be deleted")
        #expect(content.packages.rows.first { $0.id == "demo-package-02" }?.bundleIDs == "com.example.vpnclient, com.example.vpnclient.helper")
        // Loaded once: the view's `.task` reading again on show reads nothing new.
        let sent = world.stubs["a"]!.requests.count
        content.load()
        #expect(content.readsFinished == 4 && world.stubs["a"]!.requests.count == sent)
        // Nothing reads the single items, the members or a profile until a row is chosen.
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("/v1/configurations/") || $0.contains("/v1/blueprints/") })
    }

    @Test func theSearchFiltersEachListByWhatItShows() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        let content = world.content
        #expect(content.apps.shown(matching: "help").map(\.name) == ["Example Help Desk"])
        #expect(content.apps.shown(matching: " com.example.maps ").map(\.name) == ["Example Maps"])
        #expect(content.apps.shown(matching: "1000000003").map(\.name) == ["Example Reader"])
        #expect(content.configurations.shown(matching: "wi-fi").map(\.id) == ["demo-config-02", "demo-config-01"])
        #expect(content.apps.shown(matching: "nothing like this").isEmpty)
        // The CSV is what the table shows, with the list's columns.
        content.search = "help"
        #expect(content.csv(for: .apps) == "id,name,bundleId,version,supportedOS,isCustomApp,appStoreUrl,websiteUrl\r\n"
                + "1000000006,Example Help Desk,com.example.helpdesk,5.1,SUPPORTED_OS_MACOS; SUPPORTED_OS_IOS,True,,https://www.example.com/helpdesk\r\n")
    }

    /// Each list's CSV has its own columns (`ExportPolicy`), the configurations' no custom setting's profile.
    @Test func eachListExportsItsColumns() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        func header(_ kind: ContentKind) -> String { String(world.content.csv(for: kind).prefix { $0 != "\r\n" }) }
        #expect(header(.apps) == "id,name,bundleId,version,supportedOS,isCustomApp,appStoreUrl,websiteUrl")
        #expect(header(.packages) == "id,name,version,bundleIds,hash,description,createdDateTime,updatedDateTime")
        #expect(header(.blueprints) == "id,name,status,appLicenseDeficient,description,createdDateTime,updatedDateTime")
        #expect(header(.configurations) == "id,name,type,configuredForPlatforms,createdDateTime,updatedDateTime")
        #expect(world.content.csv(for: .configurations).split(separator: "\r\n").count == 9)
        for kind in ContentKind.allCases { #expect(world.content.exportBlocked(for: kind) == nil, "\(kind)") }
    }

    /// The failure-log entry "the screen models had no tests": after a switch nothing of org a's stays, in the lists, a CSV
    /// or the detail, and org b is read at once.
    @Test func aSwitchClearsEveryListAndTheDetailAndReadsTheNewOrg() async throws {
        let world = try await World.make()
        Self.stocked(world)
        let content = world.content
        content.load()
        await Self.settled(world, 4)
        content.selection = "1000000005"
        await Self.detailSettled(world, 1)
        #expect(try Self.detail(world).title == "Example Badge")
        world.gates["b"]!.hold("b", Self.appPages)

        world.orgs.select("b")
        #expect(content.apps.rows.isEmpty && content.packages.rows.isEmpty && content.blueprints.rows.isEmpty && content.configurations.rows.isEmpty)
        #expect(content.selection == nil && content.detail.shown == nil)
        for kind in ContentKind.allCases { #expect(!content.csv(for: kind).contains("Example"), "\(kind)") }
        #expect(content.apps.state == .loading(count: 0), "a switch reads the new org at once: \(content.apps.state)")

        world.gates["b"]!.release("b")
        await Self.settled(world, 8)
        #expect(Self.isLoaded(content.apps.state) && content.apps.rows.isEmpty)
        #expect(content.apps.emptyWords == "No apps in this organization.")
        #expect(content.packages.emptyWords == "No packages in this organization.")
    }

    /// A switch with nothing shown yet reads nothing: the screen reads when it's shown.
    @Test func aSwitchBeforeTheScreenIsShownReadsNothing() async throws {
        let world = try await World.make()
        world.orgs.select("b")
        #expect(world.content.apps.state == .idle && world.content.readsFinished == 0)
        #expect(!world.stubs["b"]!.requests.contains { $0.contains("/v1/apps") })
    }

    /// a's walk, cut off by the switch, hands on its held page: none of it lands on b's screen.
    @Test func aSupersededLoadWritesNothing() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<2500).map(Self.app))
        world.gates["a"]!.hold("later", Self.laterAppPages)
        world.content.load()
        await eventually("a's first page") { world.content.apps.rows.count == 1000 }
        world.gates["b"]!.hold("b", Self.appPages)

        world.orgs.select("b")
        world.gates["a"]!.release("later")
        // a's four reads have returned, and b's apps are still held.
        await Self.settled(world, 7)
        #expect(world.content.apps.state == .loading(count: 0), "\(world.content.apps.state) while org b's apps are held")
        #expect(world.content.apps.rows.isEmpty)
        world.gates["b"]!.release("b")
        await Self.settled(world, 8)
        #expect(Self.isLoaded(world.content.apps.state) && world.content.apps.rows.isEmpty)
    }

    /// A switch stops the old org's reads, a list's walk and the detail's read alike: each held read ends (the gate's wait
    /// is cancellable, as a slow tenant's page is) rather than waiting on, and nothing more is sent for org a.
    @Test func aSwitchStopsTheOldOrgsReads() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.stubs["a"]!.add((0..<1500).map(Self.app))
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAppPages)
        gate.hold("detail", { $0.path() == "/v1/blueprints/demo-blueprint-01" })
        world.content.load()
        await eventually("a's first page") { world.content.apps.rows.count == 1000 }
        world.content.kind = .blueprints
        world.content.selection = "demo-blueprint-01"
        await eventually("the detail's read held") { gate.held == 2 }

        world.orgs.select("b")
        // a's held page and held detail return, cancelled, with the holds still on; b's four lists read.
        await Self.settled(world, 8)
        await Self.detailSettled(world, 1)
        #expect(gate.held == 0 && world.content.detail.shown == nil)
        let sent = world.stubs["a"]!.requests.count
        gate.release("later")
        gate.release("detail")
        try await Task.sleep(for: .milliseconds(100))
        #expect(world.stubs["a"]!.requests.count == sent, "org a's reads went on after the switch")
    }

    /// Refresh during a load cancels it: the old walk's page never mixes into the new one, and the new one is whole.
    @Test func aRefreshCancelsTheRunningLoadAndTheNewOneIsWhole() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<2500).map(Self.app))
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAppPages)
        world.content.load()
        await eventually("a's first page") { world.content.apps.rows.count == 1000 }
        gate.hold("all", Self.appPages)

        world.content.load(force: true)
        gate.release("later")
        await Self.settled(world, 5)
        #expect(world.content.apps.state == .loading(count: 0), "\(world.content.apps.state) while the refresh's first page is held")
        #expect(world.content.apps.rows.isEmpty)
        gate.release("all")
        await Self.settled(world, 8)
        #expect(world.content.apps.rows.count == 2500 && Set(world.content.apps.rows.map(\.id)).count == 2500)
        #expect(Self.isLoaded(world.content.apps.state) && !world.content.apps.truncated)
    }

    /// A page already answered when Refresh is pressed waits in the old walk's buffer, and a cancelled loop can still be
    /// handed it: the check inside the loop drops it.
    @Test func aPageAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<3500).map(Self.app))
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAppPages)
        world.content.load()
        await eventually("a's first page") { world.content.apps.rows.count == 1000 }
        gate.hold("third", { $0.path() == "/v1/apps" && ($0.query() ?? "").contains("cursor=2000") })
        world.buffer("a", release: "later")
        gate.hold("all", Self.appPages)
        world.content.load(force: true)
        await Self.settled(world, 7)
        #expect(world.content.apps.rows.isEmpty, "\(world.content.apps.rows.count) rows of the cancelled read landed in the new one")
        #expect(world.content.apps.state == .loading(count: 0))
        gate.release("third")
        gate.release("all")
        await Self.settled(world, 8)
        #expect(world.content.apps.rows.count == 3500)
    }

    /// The same for a failure: the old walk's error, already on its way, never lands on the new read.
    @Test func aFailureAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<2500).map(Self.app))
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAppPages)
        world.content.load()
        await eventually("a's first page") { world.content.apps.rows.count == 1000 }
        world.stubs["a"]!.failTransport(5)
        world.buffer("a", release: "later", count: 5)
        gate.hold("all", Self.appPages)
        world.content.load(force: true)
        await Self.settled(world, 7)
        #expect(world.content.apps.state == .loading(count: 0), "the cancelled read's failure landed on the new one: \(world.content.apps.state)")
        gate.release("all")
        await Self.settled(world, 8)
        #expect(world.content.apps.rows.count == 2500 && Self.isLoaded(world.content.apps.state))
    }

    /// The page cap stops a list and says so ("showing N of ≥M", the banner); a list cut there still exports, as the
    /// Devices list does, and isn't said to be empty.
    @Test func aListCutAtThePageCapSaysSo() async throws {
        let world = try await World.make(pageCap: 1)
        world.stubs["a"]!.add((0..<1001).map(Self.app))
        world.content.load()
        await Self.settled(world, 4)
        let apps = world.content.apps
        #expect(apps.rows.count == 1000 && apps.truncated && Self.isLoaded(apps.state))
        #expect(apps.emptyWords == nil && world.content.exportBlocked(for: .apps) == nil)
        #expect(!world.content.packages.truncated)
    }

    /// One list the role can't read says so; the others load (load each panel as its own Result).
    @Test func aForbiddenListSaysSoAndTheOthersLoad() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.stubs["a"]!.forbid("/v1/configurations")
        world.content.load()
        await Self.settled(world, 4)
        #expect(world.content.configurations.state == .forbidden)
        #expect(world.content.configurations.emptyWords
                == "Your role can't read configurations. An administrator can change the API account's role in Apple Business.")
        #expect(world.content.apps.rows.count == 12 && Self.isLoaded(world.content.apps.state))
    }

    /// A walk that fails part-way keeps what it read, says it is partial, and doesn't export (a file can't say so).
    @Test func aWalkThatFailsPartWayIsPartialAndDoesNotExport() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<2500).map(Self.app))
        world.stubs["a"]!.queue(400, for: "/v1/apps?cursor=")
        world.content.load()
        await Self.settled(world, 4)
        let apps = world.content.apps
        guard case .failed(let why) = apps.state else { Issue.record("\(apps.state)"); return }
        #expect(why.hasPrefix("Apple refused the request"), "\(why)")
        #expect(apps.rows.count == 1000 && apps.partialCount == 1000 && apps.emptyWords == nil)
        #expect(world.content.exportBlocked(for: .apps) == "The list is partial: 1,000 apps were read before the error. Refresh, then export.")
        world.stubs["a"]!.queue(403, for: "/v1/packages")
        world.content.load(force: true)
        #expect(world.content.exportBlocked(for: .apps) == "The list is still loading.")
        await Self.settled(world, 8)
        #expect(apps.rows.count == 2500 && world.content.exportBlocked(for: .apps) == nil)
        #expect(world.content.packages.state == .forbidden && world.content.packages.partialCount == nil)
    }

    /// Apple School Manager has no content endpoints (plan §2.4): each list says so in words, never an empty table, and
    /// nothing is sent.
    @Test func aSchoolOrgSaysNotInScopeAndSendsNothing() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.content.load()
        await Self.settled(world, 4)
        let lists: [(LoadState, String?, String)] = [
            (world.content.apps.state, world.content.apps.emptyWords, "apps"),
            (world.content.packages.state, world.content.packages.emptyWords, "packages"),
            (world.content.blueprints.state, world.content.blueprints.emptyWords, "blueprints"),
            (world.content.configurations.state, world.content.configurations.emptyWords, "configurations"),
        ]
        for (state, words, noun) in lists {
            let said = "Apple School Manager's API has no \(noun) to read."
            #expect(state == .notInScope(said) && words == said, "\(state)")
        }
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("/v1/apps") || $0.contains("/v1/packages") || $0.contains("/v1/blueprints")
            || $0.contains("/v1/configurations") }, "\(world.stubs["a"]!.requests)")
    }

    /// No org, or one this version can't use: each list says why, never idle or an empty table.
    @Test func anOrgThatCantBeReadSaysWhy() async throws {
        let none = try await World.make(profiles: [])
        none.content.load()
        #expect(none.content.apps.state == .unusable("No organization yet: add an Apple Business or Apple School Manager API account in Settings."))
        #expect(none.content.configurations.emptyWords == "No organization yet: add an Apple Business or Apple School Manager API account in Settings.")
        let district = try await World.make(profiles: [World.unusable])
        district.content.load()
        guard case .unusable(let why) = district.content.blueprints.state else { Issue.record("\(district.content.blueprints.state)"); return }
        #expect(why.hasPrefix("This organization can't be used: "), "\(why)")
        district.content.selection = "B1"
        guard case .failed(let detail) = district.content.detail.item else { Issue.record("\(district.content.detail.item)"); return }
        #expect(detail.hasPrefix("This organization can't be used: "))
    }

    /// A list Apple sent in a shape this version can't read is said, never shown as none.
    @Test func aListThatDidNotReadIsSaid() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Resource(type: "apps", id: "A1", attributes: ["name": .string("Odd"), "supportedOS": .array([.number("1")])]),
                               Resource(type: "apps", id: "A2", attributes: ["name": .string("None"), "supportedOS": .array([])]),
                               Resource(type: "apps", id: "A3", attributes: ["name": .string("Unsaid")]),
                               Resource(type: "apps", id: "A4", attributes: ["name": .string("Future"), "supportedOS": .array([.string("SUPPORTED_OS_GLASSES")])])])
        world.content.load()
        await Self.settled(world, 4)
        let rows = Dictionary(uniqueKeysWithValues: world.content.apps.rows.map { ($0.id, $0.platforms) })
        #expect(rows == ["A1": "Not readable", "A2": "None", "A3": "—", "A4": "SUPPORTED_OS_GLASSES"])
    }

    // MARK: the details

    @Test func anAppsDetailIsItsOwnReadWithItsAddressesAsText() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        world.content.selection = "1000000001"
        #expect(world.content.detail.shown == ContentSelection(kind: .apps, id: "1000000001"))
        await Self.detailSettled(world, 1)
        let detail = try Self.detail(world)
        #expect(detail.title == "Example Field Notes")
        #expect(detail.fields == [
            ContentField("Name", "Example Field Notes"), ContentField("Bundle ID", "com.example.fieldnotes"), ContentField("Version", "4.2.1"),
            ContentField("Platforms", "iOS, iPadOS"), ContentField("Kind", "App Store app"),
            ContentField("App Store", "https://apps.example.com/app/id1000000001"), ContentField("Website", "https://www.example.com/fieldnotes"),
            ContentField("Adam ID", "1000000001"),
        ])
        #expect(detail.attributes.first == ContentField("name", "Example Field Notes"))
        #expect(detail.attributes.contains(ContentField("supportedOS", "SUPPORTED_OS_IOS, SUPPORTED_OS_IPADOS")))
        #expect(detail.attributes.contains(ContentField("isCustomApp", "No")))
        // The same row chosen again (a table sets its selection more than once) reads nothing more.
        world.content.selection = "1000000001"
        #expect(world.content.detail.readsFinished == 1 && world.content.detail.item.isLoaded)
        #expect(world.stubs["a"]!.requests.filter { $0.hasPrefix("GET api-business.apple.com/v1/apps/1000000001") }.count == 1)
    }

    /// Choosing another list clears the selection and the detail; a detail read superseded by another choice writes
    /// nothing, even when it answers last.
    @Test func aSupersededDetailWritesNothing() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        world.gates["a"]!.hold("first", { $0.path() == "/v1/apps/1000000001" })
        world.content.selection = "1000000001"
        world.content.selection = "1000000002"
        await Self.detailSettled(world, 1)
        #expect(try Self.detail(world).title == "Example Timesheets")
        world.gates["a"]!.release("first")
        await Self.detailSettled(world, 2)
        #expect(try Self.detail(world).title == "Example Timesheets")
        #expect(world.content.detail.shown == ContentSelection(kind: .apps, id: "1000000002"))

        world.content.kind = .packages
        #expect(world.content.selection == nil && world.content.detail.shown == nil)
        world.content.selection = "demo-package-01"
        #expect(world.content.detail.shown == ContentSelection(kind: .packages, id: "demo-package-01"))
        await Self.detailSettled(world, 3)
        #expect(try Self.detail(world).title == "Example Printer Driver")
    }

    /// A detail read already answered when another row is chosen waits, unread, to land on the main actor: the checks
    /// drop it, so the inspector never shows one row's detail under another's selection.
    @Test func aDetailAlreadyOnItsWayWhenAnotherIsChosenIsDropped() async throws {
        let world = try await World.make()
        Self.stocked(world)
        let gate = world.gates["a"]!
        gate.hold("first", { $0.path() == "/v1/apps/1000000001" })
        gate.hold("second", { $0.path() == "/v1/apps/1000000002" })
        world.content.selection = "1000000001"
        await eventually("the first read held") { gate.held == 1 }
        world.buffer("a", release: "first")
        world.content.selection = "1000000002"
        await Self.detailSettled(world, 1)
        #expect(world.content.detail.shown == ContentSelection(kind: .apps, id: "1000000002"))
        if case .loaded(let detail) = world.content.detail.item { Issue.record("\(detail.title) landed under the second row's selection") }
        gate.release("second")
        await Self.detailSettled(world, 2)
        #expect(try Self.detail(world).title == "Example Timesheets")
    }

    /// Refresh reads the open detail again too, and a refused detail read says "your role can't read this".
    @Test func aRefreshReadsTheOpenDetailAgain() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        world.content.kind = .packages
        world.content.selection = "demo-package-04"
        await Self.detailSettled(world, 1)
        world.stubs["a"]!.queue(403, for: "/v1/packages/demo-package-04")
        world.content.load(force: true)
        #expect(world.content.selection == "demo-package-04")
        await Self.detailSettled(world, 2)
        guard case .forbidden = world.content.detail.item else { Issue.record("\(world.content.detail.item)"); return }
        await Self.settled(world, 8)
    }

    /// A package's location is shown as text, never fetched, with what could be a credential masked: the user and
    /// password, every query value and the fragment. Its CSV holds no location at all.
    @Test func aPackagesLocationIsShownWithItsCredentialsMasked() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        world.content.kind = .packages
        for (id, shown, secret) in [
            ("demo-package-03", "https://********@packages.example.com/agent/security-agent-3.2.7.pkg", "demo-not-a-password"),
            ("demo-package-02", "https://packages.example.com/vpn/vpn-client-6.1.pkg?expires=********&signature=********", "TESTSIGNATURE0001"),
        ] {
            let before = world.content.detail.readsFinished
            world.content.selection = id
            await Self.detailSettled(world, before + 1)
            let detail = try Self.detail(world)
            #expect(detail.fields.first { $0.label == "Location" }?.value == shown)
            #expect(detail.attributes.first { $0.label == "url" }?.value == shown)
            #expect(detail.notes == ["The location's user, password, query and fragment are masked: they can carry credentials. It is shown here, never opened."])
            let everything = (detail.fields + detail.attributes).map(\.value) + detail.notes + [detail.title, String(describing: detail.fields)]
            #expect(!everything.contains { $0.contains(secret) || $0.contains("deploy") }, "\(everything)")
        }
        world.content.selection = "demo-package-01"
        await Self.detailSettled(world, 3)
        #expect(try Self.detail(world).notes.isEmpty)
        #expect(!world.content.csv(for: .packages).contains("packages.example.com"))
    }

    /// The masking itself: the user and password, each query value and the fragment; the host and path kept; bytes, so a
    /// combining mark can't join a delimiter.
    @Test func aLocationsCredentialsAreMasked() {
        let cases: [(String, String, Bool)] = [
            ("https://packages.example.com/a.pkg", "https://packages.example.com/a.pkg", false),
            ("https://user:pass@packages.example.com/a.pkg", "https://********@packages.example.com/a.pkg", true),
            ("https://token@packages.example.com", "https://********@packages.example.com", true),
            ("https://a@b@packages.example.com/x@y", "https://********@packages.example.com/x@y", true),
            ("https://packages.example.com/a.pkg?X-Amz-Signature=abc&flag&empty=", "https://packages.example.com/a.pkg?X-Amz-Signature=********&********&empty=", true),
            ("https://packages.example.com/a.pkg#access_token=abc", "https://packages.example.com/a.pkg#********", true),
            ("https://u:p@h.example.com?k=v#f", "https://********@h.example.com?k=********#********", true),
            ("packages.example.com/a.pkg?sig=1", "packages.example.com/a.pkg?sig=********", true),
            ("https://u\u{301}:p\u{301}@h.example.com/\u{E9}", "https://********@h.example.com/\u{E9}", true),
            ("https://packages.example.com/a.pkg?", "https://packages.example.com/a.pkg?", false),
            ("", "", false),
        ]
        for (url, shown, masked) in cases {
            let result = ContentWords.location(url)
            #expect(Array(result.text.utf8) == Array(shown.utf8) && result.masked == masked, "\(url) -> \(result)")
        }
    }

    // MARK: blueprints

    static func blueprintDetail(_ world: World, _ id: String) async throws -> ContentDetail {
        world.content.kind = .blueprints
        let before = world.content.detail.readsFinished
        world.content.selection = id
        await Self.detailSettled(world, before + 1)
        return try Self.detail(world)
    }

    /// A blueprint is read with every relationship included, each member named from what Apple included where it can be,
    /// its id always, and each count from `members`.
    @Test func aBlueprintsMembersAreReadWithIt() async throws {
        let world = try await World.make()
        Self.stocked(world)
        let detail = try await Self.blueprintDetail(world, "demo-blueprint-01")
        let read = try #require(world.stubs["a"]!.requests.first { $0.contains("/v1/blueprints/demo-blueprint-01") }?.removingPercentEncoding)
        for relationship in ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"] {
            #expect(read.contains("limit[\(relationship)]=1000") && read.contains(relationship), "\(read)")
        }
        #expect(detail.title == "Example Office Macs" && detail.membersNote == nil)
        #expect(detail.members.map(\.title) == ["Apps", "Packages", "Configurations", "Devices", "Users", "User groups"])
        #expect(detail.members.map(\.summary) == ["5 apps", "3 packages", "4 configurations", "3 devices", "None", "1 user group"])
        #expect(detail.members.map(\.count) == [5, 3, 4, 3, 0, 1])
        let apps = try #require(detail.members.first)
        #expect(apps.members.first == ContentMember(id: "1000000001", name: "Example Field Notes"))
        #expect(detail.members[3].members.first == ContentMember(id: "ADEV0000000", name: "MacBook Air"))
        // DemoPeople's group, by its id; named once DemoPeople is loaded too, as the demo org does (DemoTests).
        #expect(detail.members[5].members.map(\.id) == ["DEMOUG01"])
        #expect(detail.fields.contains(ContentField("Licences", "Enough for its apps")) && detail.fields.contains(ContentField("Status", "Active")))
    }

    /// A relationship cut at the include's limit says "showing N of more than N", never the count as all.
    @Test func aRelationshipCutAtTheIncludesLimitSaysSo() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Resource(type: "blueprints", id: "B1", attributes: ["name": .string("Big")])])
        world.stubs["a"]!.relate("blueprints", "B1", "orgDevices", to: (0..<1001).map { String(format: "TEST%07d", $0) })
        world.stubs["a"]!.relate("blueprints", "B1", "apps", to: ["1"])
        let detail = try await Self.blueprintDetail(world, "B1")
        let devices = try #require(detail.members.first { $0.relationship == .orgDevices })
        #expect(devices.isTruncated && devices.count == 1000 && devices.members.count == 1000)
        #expect(devices.summary == "Showing 1,000 of more than 1,000 devices: Apple lists at most 1,000 of each with the blueprint.")
        #expect(detail.members.first?.summary == "1 app" && detail.members.first?.isTruncated == false)
    }

    /// A relationship Apple didn't list (links only) is said, with no count: never "None".
    @Test func aRelationshipAppleDidNotListIsSaidWithNoCount() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Resource(type: "blueprints", id: "B1", attributes: ["name": .string("Partial")])])
        let base = "https://api-business.apple.com/v1/blueprints/B1"
        func listed(_ name: String, _ ids: [String]) -> String {
            "\"\(name)\":{\"links\":{\"self\":\"\(base)/relationships/\(name)\"},\"data\":[\(ids.map { "{\"type\":\"\(name)\",\"id\":\"\($0)\"}" }.joined(separator: ","))]}"
        }
        let relationships = [listed("apps", ["1", "2"]), listed("packages", []), listed("configurations", []), listed("orgDevices", []),
                             "\"users\":{\"links\":{\"self\":\"\(base)/relationships/users\"}}", listed("userGroups", [])].joined(separator: ",")
        world.stubs["a"]!.queue(200, for: "/v1/blueprints/B1?include=", body: """
            {"data":{"type":"blueprints","id":"B1","attributes":{"name":"Partial"},"relationships":{\(relationships)}},"links":{"self":"\(base)"},"included":[]}
            """)
        let detail = try await Self.blueprintDetail(world, "B1")
        let users = try #require(detail.members.first { $0.relationship == .users })
        #expect(users.count == nil && users.members.isEmpty && users.summary == "Apple didn't list the blueprint's users, so none are shown or counted.")
        #expect(detail.members.first?.summary == "2 apps" && detail.members[1].summary == "None")
    }

    /// A refused include (a 400, or a 403 for a role that can't read users) is said, and nothing is counted: the bare
    /// blueprint still shows (Phase 2a review L5: a refusal read as no members).
    @Test func aRefusedIncludeIsSaidAndCountsNothing() async throws {
        for status in [400, 403] {
            let world = try await World.make()
            Self.stocked(world)
            world.stubs["a"]!.forbid("/v1/users")
            if status == 403 { world.stubs["a"]!.refuseIncludes(with: 403) }
            let detail = try await Self.blueprintDetail(world, "demo-blueprint-02")
            #expect(detail.title == "Example Field iPads" && detail.members.isEmpty, "\(status)")
            let note = try #require(detail.membersNote)
            if status == 403 {
                #expect(note == "Your role can't read this: Apple refused to include the blueprint's members, so none are shown or counted.")
            } else {
                #expect(note.hasPrefix("Apple refused to include the blueprint's members, so none are shown or counted: Apple refused the request"), "\(note)")
            }
            // Read with the include, refused, then read again without it.
            let reads = world.stubs["a"]!.requests.filter { $0.contains("/v1/blueprints/demo-blueprint-02") }
            #expect(reads.count == 2 && reads[0].contains("include=") && !reads[1].contains("include="), "\(reads)")
        }
    }

    // MARK: configurations

    static func configurationDetail(_ world: World, _ id: String) async throws -> ContentDetail {
        world.content.kind = .configurations
        let before = world.content.detail.readsFinished
        world.content.selection = id
        await Self.detailSettled(world, before + 1)
        return try Self.detail(world)
    }

    /// Every text a value can be turned into: its description, its debug description and its dump.
    static func printed(_ value: Any) -> String {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped].joined(separator: "\n")
    }

    /// The demo's Wi-Fi custom setting, through the strict stub and the model: its profile shows masked, and its canary
    /// password is in nothing the model exposes: no row, no field, no attribute, no note, no description or dump of the
    /// detail or its view, no CSV of any list, and no blueprint that holds it (invariant 11; Phase 2a review M2).
    @Test func theDemosCustomSettingReachesNothingTheModelExposesUnmasked() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.content.load()
        await Self.settled(world, 4)
        let detail = try await Self.configurationDetail(world, "demo-config-01")
        #expect(world.stubs["a"]!.requests.contains { $0.hasPrefix("GET api-business.apple.com/v1/configurations/demo-config-01") })
        let profile = try #require(detail.profile)
        #expect(profile.contains("<string>Example Office</string>") && profile.contains(ProfileText.mask) && profile.contains("<key>Password</key>"))
        #expect(detail.profileNote == "1 value masked")
        #expect(detail.fields == [
            ContentField("Name", "Example Office Wi-Fi (profile)"), ContentField("Type", "Custom setting"),
            ContentField("Platforms", "macOS, iOS and iPadOS"),
            ContentField("Created", DemoFleet.reference.addingTimeInterval(-500 * 86_400).formatted(date: .abbreviated, time: .omitted)),
            ContentField("Updated", DemoFleet.reference.addingTimeInterval(-20 * 86_400).formatted(date: .abbreviated, time: .omitted)),
            ContentField("Profile file", "office-wifi.mobileconfig"),
        ])
        #expect(detail.attributes.contains { $0.label == "customSettingsValues" && $0.value.contains(CustomSettingsValues.withheld) })

        let blueprint = try await Self.blueprintDetail(world, "demo-blueprint-01")
        #expect(blueprint.members[2].members.first == ContentMember(id: "demo-config-01", name: "Example Office Wi-Fi (profile)"))

        let content = world.content
        var exposed = [Self.printed(detail), Self.printed(blueprint), Self.printed(content.configurations.rows),
                       Self.printed(content.blueprints.rows), Self.printed(content.detail.item)]
        exposed += (detail.fields + detail.attributes).map { "\($0.label)=\($0.value)" } + detail.notes + [profile, detail.profileNote ?? ""]
        exposed += ContentKind.allCases.map { content.csv(for: $0) }
        for row in content.configurations.rows { exposed += [row.name, row.type, row.platforms, JSONValue.object(row.item.attributes).jsonText] }
        for text in exposed { #expect(!text.contains(DemoContent.canary), "the canary in \(text.prefix(300))") }
        #expect(!content.csv(for: .configurations).contains("customSettingsValues"))
    }

    /// A built-in configuration is shown typed (its type in words, its platforms), with what Apple's API gives of it; a
    /// type this version doesn't know is shown as sent.
    @Test func aBuiltInConfigurationIsShownTyped() async throws {
        let world = try await World.make()
        Self.stocked(world)
        world.stubs["a"]!.add([Resource(type: "configurations", id: "C9", attributes: ["type": .string("HOLOGRAM_POLICY"), "name": .string("Future"),
                                                                                       "configuredForPlatforms": .array([.string("PLATFORM_GLASSES")])])])
        let wifi = try await Self.configurationDetail(world, "demo-config-02")
        #expect(Array(wifi.fields.prefix(3)) == [ContentField("Name", "Example Guest Wi-Fi"), ContentField("Type", "Wi-Fi"),
                                          ContentField("Platforms", "iOS and iPadOS, macOS")])
        #expect(wifi.profile == nil && wifi.profileNote == nil)
        #expect(wifi.notes == ["A built-in configuration: Apple's API gives its name, type and platforms, not its settings."])
        let future = try await Self.configurationDetail(world, "C9")
        #expect(Array(future.fields.prefix(3)) == [ContentField("Name", "Future"), ContentField("Type", "HOLOGRAM_POLICY"), ContentField("Platforms", "PLATFORM_GLASSES")])
        #expect(future.notes == ["A type this version doesn't know, shown as Apple sent it."])
    }

    /// A custom setting whose profile can't be shown says why, never nothing: another shape, none sent, not a property
    /// list, a signed one.
    @Test func aCustomSettingWhoseProfileIsNotShownSaysWhy() async throws {
        let world = try await World.make()
        let signed = Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02] + Array(repeating: 0, count: 64)).base64EncodedString()
        let cases: [(String, JSONValue, String)] = [
            ("C1", .string("not an object"),
             "The profile isn't shown: Apple sent it in a shape this version can't read (custom settings not an object)."),
            ("C2", .object(["configurationProfile": .object(["SSID_STR": .string("Office")])]),
             "The profile isn't shown: Apple sent it in a shape this version can't read (profile not a string)."),
            ("C3", .null, "Apple sent no profile with this custom setting."),
            ("C4", .object(["configurationProfile": .string("plain words"), "filename": .string("x.mobileconfig")]),
             "Not a property list, not shown."),
            ("C5", .object(["configurationProfile": .string("<plist version=\"1.0\"><dict><key>SSID_STR</key><string>Office</string></dict></plist>")]),
             "No value in it looked secret, so nothing is masked."),
        ]
        world.stubs["a"]!.add(cases.map { id, values, _ in
            Resource(type: "configurations", id: id, attributes: ["type": .string("CUSTOM_SETTING"), "name": .string(id), "customSettingsValues": values])
        })
        for (id, _, said) in cases {
            let detail = try await Self.configurationDetail(world, id)
            #expect(detail.profileNote == said, "\(id)")
            #expect((detail.profile != nil) == (id == "C5"), "\(id)")
        }
        world.stubs["a"]!.add([Resource(type: "configurations", id: "C6", attributes: [
            "type": .string("CUSTOM_SETTING"), "customSettingsValues": .object(["configurationProfile": .string(signed)])])])
        let detail = try await Self.configurationDetail(world, "C6")
        #expect(detail.profile == nil && detail.profileNote == "Signed profile, 79 bytes, not shown: its content holds its secrets in the clear.",
                "\(detail.profileNote ?? "nil")")
        #expect(detail.title == "C6")
    }
}

extension Panel {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}
