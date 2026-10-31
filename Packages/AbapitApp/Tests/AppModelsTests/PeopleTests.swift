import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Orgs
import Reports
import Testing
import TestSupport

/// The People screen's model (plan §8 Phase 2, Appendix B): users, user groups and org units as three panels, each with
/// its own state, a group's or an org unit's members resolved to the users read, and invariant 8's states said for each.
/// Over the strict stub, as the Devices tests are (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Suite("People", .serialized)
struct PeopleTests {
    typealias Model = PeopleModel

    static func user(_ id: String, _ first: String?, _ last: String?, status: String? = "ACTIVE", department: String? = nil,
                     external: Bool? = false, extra: JSONObject = [:]) -> Resource {
        var attributes: JSONObject = ["managedAppleAccount": .string("\(id)@appleid.example.com"), "email": .string("\(id)@example.com")]
        if let first { attributes["firstName"] = .string(first) }
        if let last { attributes["lastName"] = .string(last) }
        if let status { attributes["status"] = .string(status) }
        if let department { attributes["department"] = .string(department) }
        if let external { attributes["isExternalUser"] = .bool(external) }
        for (key, value) in extra { attributes[key] = value }
        return Resource(type: "users", id: id, attributes: attributes)
    }

    static func group(_ id: String, _ name: String, unit: String? = nil, count: Int? = nil, type: String = "STANDARD") -> Resource {
        var attributes: JSONObject = ["name": .string(name), "type": .string(type), "status": .string("ACTIVE")]
        if let unit { attributes["ouId"] = .string(unit) }
        if let count { attributes["totalMemberCount"] = .number(String(count)) }
        return Resource(type: "userGroups", id: id, attributes: attributes)
    }

    static func unit(_ id: String, _ name: String) -> Resource {
        Resource(type: "organizationalUnits", id: id, attributes: ["name": .string(name), "description": .string("\(name) unit")])
    }

    static func users(_ count: Int, prefix: String = "u") -> [Resource] {
        (0..<count).map { user(String(format: "\(prefix)%05d", $0), "First\($0)", "Last\($0)") }
    }

    /// A world whose org a holds `users`, two groups and two org units, and org b one user of its own.
    static func world(users: [Resource] = [user("u1", "Ada", "Fernhill", department: "Operations"), user("u2", "Bram", "Castellane")],
                      pageCap: Int = AppleClient.defaultPageCap) async throws -> World {
        let world = try await World.make(devices: ["a": 0, "b": 0], pageCap: pageCap)
        let a = world.stubs["a"]!
        a.add(users)
        a.add([group("G1", "Everyone", unit: "OU1", count: 3), group("G2", "Designers", unit: "OU9", type: "SMART")])
        a.add([unit("OU1", "Head Office"), unit("OU2", "Field")])
        a.relate("userGroups", "G1", "users", to: ["u1", "u2", "u404"])
        a.relate("userGroups", "G2", "users", to: ["u2"])
        a.relate("organizationalUnits", "OU1", "users", to: ["u1"])
        world.stubs["b"]!.add([user("b1", "Cleo", "Varga")])
        return world
    }

    func settled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) people reads, \(world.people.readsFinished) so far") { world.people.readsFinished >= reads }
    }

    func members(_ list: Model.Members, _ reads: Int) async {
        await eventually("\(reads) member reads, \(list.readsFinished) so far") { list.readsFinished >= reads }
    }

    static func isLoaded(_ state: LoadState) -> Bool { if case .loaded = state { true } else { false } }

    static let userPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/users" }
    static let laterUserPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/users" && ($0.query() ?? "").contains("cursor=") }

    // MARK: reading

    @Test func aBusinessOrgReadsUsersGroupsAndUnitsSideBySide() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let people = world.people
        #expect(Self.isLoaded(people.users.state) && Self.isLoaded(people.groups.state) && Self.isLoaded(people.units.state))
        #expect(people.shownUsers.map(\.name) == ["Ada Fernhill", "Bram Castellane"])
        let ada = try #require(people.shownUsers.first)
        #expect(ada.account == "u1@appleid.example.com" && ada.email == "u1@example.com" && ada.status == "Active")
        #expect(ada.department == "Operations" && ada.jobTitle == "—" && ada.external == "No" && ada.started == nil)
        #expect(people.shownGroups.map(\.name) == ["Designers", "Everyone"])
        // A group's unit is the unit's name once read, else its id: never blank.
        #expect(people.shownGroups.map(\.unit) == ["OU9", "Head Office"])
        #expect(people.shownGroups.map(\.type) == ["Smart", "Standard"])
        // Apple's count, or none: a group Apple sent no count for is a dash, never 0.
        #expect(people.shownGroups.map(\.members) == [nil, 3] && people.shownGroups.map(\.membersText) == ["—", "3"])
        #expect(people.shownUnits.map(\.name) == ["Field", "Head Office"])
        let paths = world.stubs["a"]!.requests.map { $0.split(separator: "?")[0] }
        #expect(Set(paths) == ["POST account.apple.com/auth/oauth2/token", "GET api-business.apple.com/v1/users",
                               "GET api-business.apple.com/v1/userGroups", "GET api-business.apple.com/v1/organizationalUnits"], "\(paths)")
    }

    /// The view's `.task` asks on every appearance: only Refresh reads again.
    @Test func anUnforcedLoadReadsOnlyOnce() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let sent = world.stubs["a"]!.requests.count
        world.people.load()
        #expect(world.people.readsFinished == 3 && Self.isLoaded(world.people.users.state))
        #expect(world.stubs["a"]!.requests.count == sent)
        world.people.load(force: true)
        #expect(world.people.users.state.isLoading && world.people.users.rows.isEmpty)
        await settled(world, 6)
        #expect(world.people.users.rows.count == 2)
    }

    /// Statuses and types in words; one Apple adds later is shown as sent (invariant 10); a missing one is a dash.
    @Test func valuesAreSaidInWordsAndUnknownOnesRaw() async throws {
        let world = try await Self.world(users: [
            Self.user("u1", "A", "One", status: "LOCKED_FOR_SHARED_IPAD", external: true), Self.user("u2", "B", "Two", status: "SUSPENDED", external: nil),
            Self.user("u3", "C", "Three", status: nil), Self.user("u4", nil, nil, status: "NEW"),
        ])
        world.stubs["a"]!.add([Self.group("G3", "Later", type: "DYNAMIC")])
        world.people.load()
        await settled(world, 3)
        let by = Dictionary(uniqueKeysWithValues: world.people.users.rows.map { ($0.id, $0) })
        #expect(by["u1"]?.status == "Locked for Shared iPad" && by["u1"]?.external == "Yes")
        #expect(by["u2"]?.status == "SUSPENDED" && by["u2"]?.external == "—")
        #expect(by["u3"]?.status == "—")
        #expect(by["u4"]?.status == "New" && by["u4"]?.name == "—")
        #expect(world.people.shownGroups.first { $0.id == "G3" }?.type == "DYNAMIC")
        #expect(UserStatus.allCases.map { Model.words($0, raw: $0.rawValue) } == ["New", "Released", "Active", "Deactivated", "Locked", "Locked for Shared iPad"])
    }

    // MARK: invariant 8: forbidden, not in scope, unusable, truncated, partial

    /// A role that can't read users still sees its groups and org units, and a group's members show as their ids,
    /// saying why (each panel its own state: SwiftGamGui failure-log 2026-10-13).
    @Test func aRoleThatCantReadUsersStillSeesGroupsAndUnits() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/users")
        world.people.load()
        await settled(world, 3)
        #expect(world.people.users.state == .forbidden)
        #expect(Self.isLoaded(world.people.groups.state) && Self.isLoaded(world.people.units.state))
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.members(world.people.groupMembers).map(\.name) == ["u2"])
        #expect(world.people.members(world.people.groupMembers).map(\.isUser) == [false])
        #expect(world.people.memberNote(world.people.groupMembers) == "1 member shown by id: your role can't read users.")
    }

    @Test func aRoleThatCantReadGroupsSaysSoInThatPanel() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/userGroups")
        world.stubs["a"]!.forbid("/v1/organizationalUnits")
        world.people.load()
        await settled(world, 3)
        #expect(world.people.groups.state == .forbidden && world.people.units.state == .forbidden)
        #expect(Self.isLoaded(world.people.users.state) && world.people.users.rows.count == 2)
        // A group's unit, or a role's, shows as its id, and says why.
        #expect(world.people.unitName("OU1") == "OU1")
        #expect(world.people.unitNote(for: ["OU1"]) == "1 org unit shown by id: your role can't read org units.")
    }

    /// Apple School Manager has no people endpoints (plan §2.4): each panel says so in words, nothing is sent, and the
    /// table gives way to the sentence (never an empty table).
    @Test func aSchoolOrgSaysNotInScopeAndSendsNothing() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0], profiles: [World.profile("a", scope: .school)])
        world.people.load()
        await settled(world, 3)
        let people = world.people
        #expect(people.users.state == .notInScope("Apple School Manager's API has no users to read."))
        #expect(people.groups.state == .notInScope("Apple School Manager's API has no user groups to read."))
        #expect(people.units.state == .notInScope("Apple School Manager's API has no org units to read."))
        #expect(people.users.unavailable == "Apple School Manager's API has no users to read.")
        #expect(people.groups.unavailable != nil && people.units.unavailable != nil)
        for tab in Model.Tab.allCases { #expect(people.exportBlocked(tab) != nil, "\(tab)") }
        people.selectedGroup = "G1"
        await members(people.groupMembers, 1)
        #expect(people.groupMembers.state == .notInScope("Apple School Manager's API has no user groups to read."))
        #expect(people.groupMembers.line(appleCount: nil) == "Apple School Manager's API has no user groups to read.")
        #expect(world.stubs["a"]!.requests.allSatisfy { !$0.contains("/v1/user") && !$0.contains("/v1/organizationalUnits") },
                "\(world.stubs["a"]!.requests)")
    }

    @Test func noOrgOrAnUnusableOneSaysWhy() async throws {
        let none = try await World.make(profiles: [])
        none.people.load()
        #expect(none.people.users.state == .unusable("No organization yet: add an Apple Business or Apple School Manager API account in Settings."))
        #expect(none.people.groups.state == none.people.users.state && none.people.units.state == none.people.users.state)
        #expect(none.people.users.unavailable?.hasPrefix("No organization yet") == true)
        let unusable = try await World.make(profiles: [World.unusable])
        unusable.people.load()
        guard case .unusable(let why) = unusable.people.units.state else { Issue.record("\(unusable.people.units.state)"); return }
        #expect(why.hasPrefix("This organization can't be used: "))
        unusable.people.selectedUnit = "OU1"
        #expect(unusable.people.unitMembers.state == .unusable(why), "a spinner that can't end: \(unusable.people.unitMembers.state)")
    }

    /// The page cap stops the list and says so ("showing N of ≥M"); it still exports, as the banner says it's cut.
    @Test func aListCutAtThePageCapSaysSo() async throws {
        let world = try await Self.world(users: Self.users(1_500), pageCap: 1)
        world.stubs["a"]!.reportTotals()
        world.people.load()
        await settled(world, 3)
        #expect(world.people.users.rows.count == 1_000 && world.people.users.truncated && world.people.users.total == 1_500)
        #expect(Self.isLoaded(world.people.users.state) && !world.people.groups.truncated)
        #expect(world.people.exportBlocked(.users) == nil)
    }

    /// A walk that failed part-way keeps what it read, says it's partial, and doesn't export it as if whole.
    @Test func aPartialListIsSaidAndNotExported() async throws {
        let world = try await Self.world(users: Self.users(1_500))
        world.stubs["a"]!.queue(400, for: "/v1/users?cursor=")
        world.people.load()
        await settled(world, 3)
        guard case .failed = world.people.users.state else { Issue.record("\(world.people.users.state)"); return }
        #expect(world.people.users.partialCount == 1_000)
        #expect(world.people.exportBlocked(.users) == "The list is partial: \(1_000.formatted()) users were read before the error. Refresh, then export.")
        #expect(world.people.users.unavailable == nil, "a partial list is shown, said to be partial")
        #expect(world.people.groups.partialCount == nil && world.people.exportBlocked(.groups) == nil)
    }

    @Test func exportWaitsForTheListAndForRows() async throws {
        let world = try await Self.world()
        world.gates["a"]!.hold("users", Self.userPages)
        world.people.load()
        await settled(world, 2)
        #expect(world.people.exportBlocked(.users) == "The list is still loading.")
        #expect(world.people.exportBlocked(.groups) == nil)
        world.people.search = "nobody matches this"
        #expect(world.people.exportBlocked(.groups) == "There's nothing to export.")
        world.gates["a"]!.release("users")
        await settled(world, 3)
    }

    // MARK: org switches, superseded loads, Refresh

    @Test func aSwitchClearsThePeopleAndReadsTheNewOrg() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        world.people.selectedUser = "u1"
        world.people.selectedGroup = "G1"
        world.people.selectedUnit = "OU1"
        await members(world.people.groupMembers, 1)
        await members(world.people.unitMembers, 1)
        world.gates["b"]!.hold("users", Self.userPages)

        world.orgs.select("b")
        // At once, before anything of b's has arrived.
        let people = world.people
        #expect(people.users.rows.isEmpty && people.groups.rows.isEmpty && people.units.rows.isEmpty)
        #expect(people.selectedUser == nil && people.selectedGroup == nil && people.selectedUnit == nil)
        #expect(people.user == nil && people.group == nil && people.unit == nil)
        #expect(people.groupMembers.owner == nil && people.groupMembers.ids.isEmpty && people.groupMembers.state == .idle)
        #expect(people.unitMembers.owner == nil && people.unitMembers.ids.isEmpty && people.unitMembers.state == .idle)
        for tab in Model.Tab.allCases { #expect(!people.csv(tab).contains("u1"), "\(tab)") }
        #expect(people.users.state.isLoading, "a switch reads the new org: \(people.users.state)")

        world.gates["b"]!.release("users")
        await settled(world, 6)
        #expect(people.users.rows.map(\.id) == ["b1"])
        #expect(Self.isLoaded(people.users.state))
    }

    /// A screen nobody opened isn't read on a switch.
    @Test func aSwitchReadsNothingForPeopleNobodyOpened() async throws {
        let world = try await Self.world()
        world.orgs.select("b")
        #expect(world.people.users.state == .idle)
        #expect(world.stubs["b"]!.requests.isEmpty)
    }

    /// Org a's users walk is cancelled by the switch; its loop ends without throwing, and must not say "loaded" over
    /// org b's users, which are still being read (Phase 1b review H2).
    @Test func aSupersededLoadSaysNothingOnTheNewOrg() async throws {
        let world = try await Self.world(users: Self.users(2_500))
        world.gates["a"]!.hold("later", Self.laterUserPages)
        world.people.load()
        await eventually("a's first page") { world.people.users.rows.count == 1_000 }
        world.gates["b"]!.hold("users", Self.userPages)
        world.orgs.select("b")
        world.gates["a"]!.release("later")
        // a's three reads and b's groups and units.
        await settled(world, 5)
        #expect(world.people.users.state == .loading(count: 0), "\(world.people.users.state) while b's users are held")
        #expect(world.people.users.rows.isEmpty)
        world.gates["b"]!.release("users")
        await settled(world, 6)
        #expect(world.people.users.rows.map(\.id) == ["b1"])
    }

    /// A page already answered when the org switches waits in the stream's buffer; the cancelled loop can still be
    /// handed it, and the check inside the loop drops it.
    @Test func aPageAlreadyOnItsWayAtASwitchIsDropped() async throws {
        let world = try await Self.world(users: Self.users(2_500))
        world.gates["a"]!.hold("later", Self.laterUserPages)
        world.people.load()
        await eventually("a's first page") { world.people.users.rows.count == 1_000 }
        world.gates["b"]!.hold("users", Self.userPages)
        world.buffer("a", release: "later", count: 2)
        world.orgs.select("b")
        await settled(world, 5)
        #expect(world.people.users.rows.isEmpty, "\(world.people.users.rows.count) of org a's users landed on org b")
        #expect(world.people.users.state == .loading(count: 0))
        world.gates["b"]!.release("users")
        await settled(world, 6)
        #expect(world.people.users.rows.map(\.id) == ["b1"])
    }

    /// Refresh during a load cancels it; the new read is whole, with none of the old one's rows mixed in.
    @Test func aRefreshCancelsTheRunningLoadAndTheNewOneIsWhole() async throws {
        let world = try await Self.world(users: Self.users(2_500))
        world.gates["a"]!.hold("later", Self.laterUserPages)
        world.people.load()
        await eventually("a's first page") { world.people.users.rows.count == 1_000 }
        world.gates["a"]!.hold("all", Self.userPages)
        world.people.load(force: true)
        world.gates["a"]!.release("later")
        await settled(world, 5)
        #expect(world.people.users.state == .loading(count: 0), "\(world.people.users.state)")
        #expect(world.people.users.rows.isEmpty)
        world.gates["a"]!.release("all")
        await settled(world, 6)
        #expect(world.people.users.rows.count == 2_500)
        #expect(Set(world.people.users.rows.map(\.id)).count == 2_500, "the old load's rows were mixed in")
        #expect(!world.people.users.truncated && Self.isLoaded(world.people.users.state))
    }

    /// A failure already on its way when Refresh is pressed doesn't land on the new read.
    @Test func aFailureAlreadyOnItsWayAtARefreshIsDropped() async throws {
        let world = try await Self.world(users: Self.users(2_500))
        world.gates["a"]!.hold("later", Self.laterUserPages)
        world.people.load()
        await eventually("a's first page") { world.people.users.rows.count == 1_000 }
        world.stubs["a"]!.queue(400, for: "/v1/users?cursor=")
        world.buffer("a", release: "later")
        world.gates["a"]!.hold("all", Self.userPages)
        world.people.load(force: true)
        await settled(world, 5)
        #expect(world.people.users.state == .loading(count: 0), "the cancelled read's failure landed: \(world.people.users.state)")
        world.gates["a"]!.release("all")
        await settled(world, 6)
        #expect(world.people.users.rows.count == 2_500)
    }

    // MARK: members

    /// A group's members are the users read; an id Apple lists that the users read lacks shows as its id, and the
    /// count of those is said (abapit's "N member id(s) not in the cached user list").
    @Test func aGroupsMembersResolveToTheUsersRead() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G1"
        await members(world.people.groupMembers, 1)
        let list = world.people.groupMembers
        #expect(list.owner == "G1" && list.ids == ["u1", "u2", "u404"] && Self.isLoaded(list.state))
        let rows = world.people.members(list)
        #expect(rows.map(\.name) == ["Ada Fernhill", "Bram Castellane", "u404"])
        #expect(rows.map(\.isUser) == [true, true, false])
        #expect(rows.map(\.detail) == ["u1@appleid.example.com", "u2@appleid.example.com", "Not among the users read"])
        #expect(world.people.memberNote(list) == "1 member shown by id: it isn't in the users list Apple sent.")
        #expect(list.line(appleCount: world.people.group?.members) == "3 members.")
        // The table sets its selection again on a redraw: the same group isn't read again.
        world.people.selectedGroup = "G1"
        #expect(list.readsFinished == 1 && Self.isLoaded(list.state) && list.ids.count == 3)
        #expect(world.people.group.map(Model.fields(of:)) == [
            Model.Field("Name", "Everyone"), Model.Field("Type", "Standard"), Model.Field("Status", "Active"), Model.Field("Members, Apple's count", "3"),
            Model.Field("Org unit", "Head Office"), Model.Field("Created", "—"), Model.Field("Updated", "—"),
        ])
        // An org unit's members, the same way, read on their own.
        world.people.selectedUnit = "OU1"
        await members(world.people.unitMembers, 1)
        #expect(world.people.members(world.people.unitMembers).map(\.name) == ["Ada Fernhill"])
        #expect(world.people.memberNote(world.people.unitMembers) == nil)
        #expect(world.people.unitMembers.line(appleCount: nil) == "1 member.")
        #expect(world.stubs["a"]!.requests.contains { $0.hasPrefix("GET api-business.apple.com/v1/organizationalUnits/OU1/relationships/users?") })
    }

    /// A member with no name on record is shown by their Managed Apple Account, never as a dash.
    @Test func aMemberWithNoNameShowsTheirAccount() async throws {
        let world = try await Self.world(users: [Self.user("u2", nil, nil)])
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.members(world.people.groupMembers).map(\.name) == ["u2@appleid.example.com"])
    }

    /// Members not found among users still being read say so; once the users arrive they resolve.
    @Test func membersReadBeforeTheUsersSayTheyAreStillBeingRead() async throws {
        let world = try await Self.world()
        world.gates["a"]!.hold("users", Self.userPages)
        world.people.load()
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.members(world.people.groupMembers).map(\.name) == ["u2"])
        #expect(world.people.memberNote(world.people.groupMembers) == "1 member shown by id: the users are still being read.")
        world.gates["a"]!.release("users")
        await settled(world, 3)
        #expect(world.people.members(world.people.groupMembers).map(\.name) == ["Bram Castellane"])
        #expect(world.people.memberNote(world.people.groupMembers) == nil)
    }

    /// Several members not found are counted as several, and a users list cut at the cap says that is why.
    @Test func aCountOfUnfoundMembersAndACutUsersList() async throws {
        let world = try await Self.world(users: Self.users(1_500), pageCap: 1)
        world.stubs["a"]!.relate("userGroups", "G2", "users", to: ["u00001", "u01200", "u01300"])
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.members(world.people.groupMembers).map(\.isUser) == [true, false, false])
        #expect(world.people.memberNote(world.people.groupMembers) == "2 members shown by id: the users list stopped at the page limit.")
    }

    /// A member list cut at the page cap says so, beside Apple's own count when it sends one.
    @Test func aMemberListCutAtThePageCapShowsBothCounts() async throws {
        let world = try await Self.world(pageCap: 1)
        let ids = (0..<1_500).map { String(format: "m%05d", $0) }
        world.stubs["a"]!.relate("userGroups", "G1", "users", to: ids)
        world.stubs["a"]!.relate("userGroups", "G2", "users", to: ids)
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G1"
        await members(world.people.groupMembers, 1)
        let list = world.people.groupMembers
        #expect(list.ids.count == 1_000 && list.truncated)
        #expect(list.line(appleCount: 1_500) == "Showing \(1_000.formatted()) of \(1_500.formatted()), Apple's count: the member list stopped at the page limit.")
        world.people.selectedGroup = "G2"
        await members(list, 2)
        #expect(list.line(appleCount: nil) == "Showing \(1_000.formatted()) of more than \(1_000.formatted()): the member list stopped at the page limit.")
    }

    /// The other member lines: none, a count beside Apple's that differs, loading, refused, failed part-way.
    @Test func eachMemberLineSaysWhereTheListStands() async throws {
        let world = try await Self.world()
        let stub = world.stubs["a"]!
        stub.add([Self.group("G3", "Empty", count: 0), Self.group("G4", "Odd", count: 9)])
        stub.relate("userGroups", "G4", "users", to: ["u1", "u2"])
        world.people.load()
        await settled(world, 3)
        let list = world.people.groupMembers
        #expect(list.line(appleCount: 5) == nil, "nothing selected")
        world.people.selectedGroup = "G3"
        await members(list, 1)
        #expect(list.line(appleCount: 0) == "No members.")
        #expect(list.line(appleCount: 4) == "No members listed; Apple counts 4.")
        world.people.selectedGroup = "G4"
        await members(list, 2)
        #expect(list.line(appleCount: 9) == "2 members; Apple counts 9.")
        world.gates["a"]!.hold("members", { $0.path().hasPrefix("/v1/userGroups/G1/") })
        world.people.selectedGroup = "G1"
        #expect(list.line(appleCount: 3) == "Reading the members…")
        world.gates["a"]!.release("members")
        await members(list, 3)
        stub.forbid("/v1/userGroups/G2/")
        world.people.selectedGroup = "G2"
        await members(list, 4)
        #expect(list.state == .forbidden)
        #expect(list.line(appleCount: nil) == "Your role can't read this group's members.")
        stub.forbid("/v1/organizationalUnits/OU1/")
        world.people.selectedUnit = "OU1"
        await members(world.people.unitMembers, 1)
        #expect(world.people.unitMembers.line(appleCount: nil) == "Your role can't read this org unit's members.")
        // A walk that failed after a page keeps what it read and says it's partial.
        let many = (0..<1_200).map { String(format: "m%05d", $0) }
        stub.relate("userGroups", "G1", "users", to: many)
        stub.queue(400, for: "/v1/userGroups/G1/relationships/users?cursor=")
        world.people.selectedGroup = "G3"
        world.people.selectedGroup = "G1"
        await members(list, 6)
        guard case .failed(let why) = list.state else { Issue.record("\(list.state)"); return }
        #expect(list.line(appleCount: nil) == "The members couldn't be read: \(why) Partial: \(1_000.formatted()) read before the error.")
    }

    /// Choosing another group while the first's members are on their way: the first's never land on the second.
    @Test func aSupersededMemberReadWritesNothing() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let gate = world.gates["a"]!
        gate.hold("G1", { $0.path().hasPrefix("/v1/userGroups/G1/") })
        world.people.selectedGroup = "G1"
        gate.hold("G2", { $0.path().hasPrefix("/v1/userGroups/G2/") })
        // G1's request must be at the gate before the main actor is held, or nothing is answered to buffer.
        await eventually("G1's members at the gate") { gate.held == 1 }
        world.buffer("a", release: "G1")
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.groupMembers.ids.isEmpty, "G1's members landed on G2: \(world.people.groupMembers.ids)")
        #expect(world.people.groupMembers.owner == "G2" && world.people.groupMembers.state == .loading(count: 0))
        gate.release("G2")
        await members(world.people.groupMembers, 2)
        #expect(world.people.groupMembers.ids == ["u2"] && Self.isLoaded(world.people.groupMembers.state))
    }

    /// A member read cancelled while its first page is still on its way: its loop ends without throwing, and it must not
    /// say "loaded" over the next group's list, which is still being read.
    @Test func aMemberReadCancelledBeforeItsPageSaysNothing() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let gate = world.gates["a"]!
        gate.hold("G1", { $0.path().hasPrefix("/v1/userGroups/G1/") })
        gate.hold("G2", { $0.path().hasPrefix("/v1/userGroups/G2/") })
        world.people.selectedGroup = "G1"
        await eventually("G1's members at the gate") { gate.held == 1 }
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.groupMembers.state == .loading(count: 0), "G1's cancelled read said: \(world.people.groupMembers.state)")
        gate.release("G1")
        gate.release("G2")
        await members(world.people.groupMembers, 2)
        #expect(world.people.groupMembers.ids == ["u2"])
    }

    /// The same for a failure: a member read that failed just before another group was chosen hands its error to a loop
    /// already cancelled, and it mustn't land on the new group.
    @Test func aSupersededMemberFailureLandsNowhere() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let gate = world.gates["a"]!
        world.stubs["a"]!.queue(400, for: "/v1/userGroups/G1/")
        gate.hold("G1", { $0.path().hasPrefix("/v1/userGroups/G1/") })
        world.people.selectedGroup = "G1"
        await eventually("G1's members at the gate") { gate.held == 1 }
        gate.hold("G2", { $0.path().hasPrefix("/v1/userGroups/G2/") })
        world.buffer("a", release: "G1")
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.groupMembers.state == .loading(count: 0), "G1's failure landed on G2: \(world.people.groupMembers.state)")
        gate.release("G2")
        await members(world.people.groupMembers, 2)
        #expect(world.people.groupMembers.ids == ["u2"])
    }

    /// Ids are matched by their bytes, as Apple's text is everywhere here: an id spelled with a combining accent isn't the
    /// same member, or the same selection, as one spelled precomposed, though `String ==` calls them equal.
    @Test func idsAreMatchedByTheirBytes() async throws {
        let world = try await Self.world(users: [Self.user("e\u{301}", "Ada", "Fernhill"), Self.user("u2", "Bram", "Castellane")])
        world.stubs["a"]!.relate("userGroups", "G2", "users", to: ["\u{E9}", "u2"])
        world.stubs["a"]!.add([Self.unit("\u{C5}U", "Nordic"), Self.group("\u{C5}G", "Nordic team")])
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G2"
        await members(world.people.groupMembers, 1)
        #expect(world.people.members(world.people.groupMembers).map(\.isUser) == [false, true])
        #expect(world.people.memberNote(world.people.groupMembers) == "1 member shown by id: it isn't in the users list Apple sent.")
        world.people.selectedUser = "\u{E9}"
        #expect(world.people.user == nil)
        world.people.selectedUser = "e\u{301}"
        #expect(world.people.user?.name == "Ada Fernhill")
        // A unit's id the same way: U+00C5 is A and U+030A composed.
        #expect(world.people.unitName("\u{C5}U") == "Nordic" && world.people.unitName("A\u{30A}U") == "A\u{30A}U")
        // And choosing the other spelling of a selected group is choosing another group: its members are read.
        world.people.selectedGroup = "\u{C5}G"
        await members(world.people.groupMembers, 2)
        world.people.selectedGroup = "A\u{30A}G"
        await members(world.people.groupMembers, 3)
        #expect(world.people.groupMembers.owner.map { Array($0.utf8) } == Array("A\u{30A}G".utf8))
    }

    /// An org switch while a group's members are on their way: they never land, and the panel is idle.
    @Test func aSwitchDropsMembersOnTheirWay() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        world.gates["a"]!.hold("G1", { $0.path().hasPrefix("/v1/userGroups/G1/") })
        world.people.selectedGroup = "G1"
        await eventually("G1's members at the gate") { world.gates["a"]!.held == 1 }
        world.buffer("a", release: "G1")
        world.orgs.select("b")
        await members(world.people.groupMembers, 1)
        #expect(world.people.groupMembers.ids.isEmpty && world.people.groupMembers.state == .idle && world.people.groupMembers.owner == nil)
    }

    /// Refresh reads the section on screen again: the lists, and the members of what is selected.
    @Test func aRefreshReadsTheSelectedMembersAgain() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        world.people.selectedGroup = "G2"
        world.people.selectedUnit = "OU1"
        await members(world.people.groupMembers, 1)
        await members(world.people.unitMembers, 1)
        world.stubs["a"]!.relate("userGroups", "G2", "users", to: ["u2", "u1"])
        world.stubs["a"]!.relate("organizationalUnits", "OU1", "users", to: [])
        world.people.load(force: true)
        await members(world.people.groupMembers, 2)
        await members(world.people.unitMembers, 2)
        #expect(world.people.groupMembers.ids == ["u2", "u1"])
        #expect(world.people.unitMembers.ids.isEmpty && Self.isLoaded(world.people.unitMembers.state))
        #expect(world.people.selectedGroup == "G2", "Refresh keeps the selection")
        await settled(world, 6)
    }

    // MARK: the user detail

    /// Every attribute, typed where `User` types it: phone numbers with their type, roles with their org unit's name.
    @Test func aUsersDetailTypesPhonesAndRoles() async throws {
        let detailed = Self.user("u1", "Ada", "Fernhill", department: "Operations", extra: [
            "middleName": .string("J"), "jobTitle": .string("Lead"), "employeeNumber": .string("E1"), "startDateTime": .string("2024-02-01T09:00:00Z"),
            "division": .string("North"), "costCenter": .string("CC-7"),
            "phoneNumbers": .array([.object(["phoneNumber": .string("+1 555-0100"), "type": .string("WORK")]),
                                    .object(["phoneNumber": .string("+1 555-0101"), "type": .string("PAGER")]),
                                    .object(["phoneNumber": .string("+1 555-0102")])]),
            "roleOuList": .array([.object(["roleName": .string("Manager"), "ouId": .string("OU1")]),
                                  .object(["roleName": .string("Staff"), "ouId": .string("OU7")])]),
        ])
        let world = try await Self.world(users: [detailed])
        world.people.load()
        await settled(world, 3)
        world.people.selectedUser = "u1"
        let row = try #require(world.people.user)
        #expect(row.name == "Ada J Fernhill")
        let day = try #require(ISO8601DateFormatter().date(from: "2024-02-01T09:00:00Z")).formatted(date: .abbreviated, time: .omitted)
        #expect(Model.day(row.started) == day)
        let fields = Model.fields(of: row)
        #expect(fields.map(\.label) == ["Name", "Status", "Managed Apple Account", "Email", "External", "Employee number", "Department",
                                        "Job title", "Division", "Cost center", "Start date", "Created", "Updated"])
        #expect(fields.map(\.value) == ["Ada J Fernhill", "Active", "u1@appleid.example.com", "u1@example.com", "No", "E1", "Operations", "Lead",
                                        "North", "CC-7", day, "—", "—"])
        #expect(Model.phones(of: row.user) == [Model.Field("Work", "+1 555-0100"), Model.Field("PAGER", "+1 555-0101"),
                                                      Model.Field("Phone", "+1 555-0102")])
        #expect(world.people.roles(of: row.user) == [Model.Field("Manager", "Head Office"), Model.Field("Staff", "OU7")])
        #expect(world.people.unitNote(for: row.user.roleOuList?.map(\.ouID) ?? []) == "1 org unit shown by id: it isn't in the org units list Apple sent.")
        #expect(Model.listNote(row.user, .phoneNumbers) == nil && Model.listNote(row.user, .roleOuList) == nil)
    }

    /// A list Apple sent that this version can't read is said, never shown as none (RULE-FEEDBACK 2026-10-31).
    @Test func aListTheDetailCantReadIsSaidNotNone() async throws {
        let odd = Self.user("u1", "Ada", "Fernhill", extra: ["phoneNumbers": .array([.string("+1 555-0100")]), "roleOuList": .object([:])])
        let plain = Self.user("u2", "Bram", "Castellane", extra: ["phoneNumbers": .null])
        let world = try await Self.world(users: [odd, plain])
        world.people.load()
        await settled(world, 3)
        world.people.selectedUser = "u1"
        let user = try #require(world.people.user).user
        #expect(Model.phones(of: user).isEmpty && world.people.roles(of: user).isEmpty)
        #expect(Model.listNote(user, .phoneNumbers) == "Apple sent these in a form this version can't read: they're under Every attribute.")
        #expect(Model.listNote(user, .roleOuList) == "Apple sent these in a form this version can't read: they're under Every attribute.")
        world.people.selectedUser = "u2"
        let none = try #require(world.people.user).user
        #expect(Model.listNote(none, .phoneNumbers) == "None.")
        #expect(Model.listNote(none, .roleOuList) == "None.")
    }

    /// The inspector follows the tab: each tab keeps its own selection, and closing it clears only that one.
    @Test func eachTabKeepsItsOwnSelection() async throws {
        let world = try await Self.world()
        world.people.load()
        await settled(world, 3)
        let people = world.people
        #expect(!people.hasSelection)
        people.selectedUser = "u2"
        #expect(people.hasSelection && people.user?.name == "Bram Castellane")
        people.tab = .groups
        #expect(!people.hasSelection)
        people.selectedGroup = "G1"
        #expect(people.hasSelection)
        people.clearSelection()
        #expect(people.selectedGroup == nil && people.selectedUser == "u2")
        people.tab = .units
        people.selectedUnit = "OU2"
        #expect(people.unit?.name == "Field" && people.unit?.summary == "Field unit")
        // A selection the list doesn't hold (yet) says why.
        people.selectedUnit = "OU404"
        #expect(people.unit == nil && people.selectionNote == "This org unit isn't in the list Apple sent.")
        people.tab = .users
        people.selectedUser = "u404"
        #expect(people.selectionNote == "This user isn't in the list Apple sent.")
        world.gates["a"]!.hold("users", Self.userPages)
        people.load(force: true)
        #expect(people.selectionNote == "Reading the users…")
        world.gates["a"]!.release("users")
        await settled(world, 6)
    }

    // MARK: search, sort, CSV

    @Test func searchFindsByNameAccountEmailAndDepartment() async throws {
        let world = try await Self.world(users: [
            Self.user("u1", "In\u{E9}s", "Duarte", department: "Studio"), Self.user("u2", "Bram", "Castellane", department: "Field"),
            Self.user("u3", "Cleo", "Varga", department: "Field"),
        ])
        world.people.load()
        await settled(world, 3)
        let people = world.people
        people.search = "ines"
        #expect(people.shownUsers.map(\.id) == ["u1"], "case and accents fold, as Finder's search does")
        people.search = "u2@"
        #expect(people.shownUsers.map(\.id) == ["u2"])
        people.search = "  field "
        #expect(people.shownUsers.map(\.id) == ["u2", "u3"])
        people.search = "everyone"
        #expect(people.shownGroups.map(\.id) == ["G1"])
        people.search = "head"
        #expect(people.shownGroups.map(\.id) == ["G1"], "a group is found by its unit's name too")
        #expect(people.shownUnits.map(\.id) == ["OU1"])
        people.search = ""
        #expect(people.shownUsers.count == 3)
    }

    @Test func eachListSortsByItsOrder() async throws {
        let world = try await Self.world(users: [Self.user("u1", "Cleo", "Varga"), Self.user("u2", "Ada", "Fernhill"), Self.user("u3", "Bram", "Castellane")])
        world.people.load()
        await settled(world, 3)
        let people = world.people
        #expect(people.shownUsers.map(\.id) == ["u2", "u3", "u1"])
        people.userOrder = [KeyPathComparator(\Model.UserRow.name, order: .reverse)]
        #expect(people.shownUsers.map(\.id) == ["u1", "u3", "u2"])
        // By name at first, which isn't Apple's order (G1, G2; OU1, OU2), then each order the table asks for.
        #expect(people.shownGroups.map(\.id) == ["G2", "G1"] && people.shownUnits.map(\.id) == ["OU2", "OU1"])
        people.groupOrder = [KeyPathComparator(\Model.GroupRow.membersSort, order: .reverse)]
        #expect(people.shownGroups.map(\.id) == ["G1", "G2"])
        people.unitOrder = [KeyPathComparator(\Model.UnitRow.name, order: .reverse)]
        #expect(people.shownUnits.map(\.id) == ["OU1", "OU2"])
    }

    /// Each list exports what its table shows (searched and sorted), with its own columns only (invariant 11).
    @Test func eachListExportsWhatItShowsWithItsColumns() async throws {
        let world = try await Self.world(users: [
            Self.user("u1", "Ada", "Fernhill", extra: ["accessToken": .string("SECRET-THAT-MUST-NOT-LEAVE"), "futureField": .string("not yet")]),
            Self.user("u2", "Bram", "Castellane"),
        ])
        world.people.load()
        await settled(world, 3)
        let people = world.people
        let users = people.csv(.users)
        #expect(users.hasPrefix((["id"] + ExportPolicy.users.names).joined(separator: ",") + "\r\n"))
        #expect(!users.contains("SECRET-THAT-MUST-NOT-LEAVE") && !users.contains("not yet") && !users.contains("accessToken"))
        #expect(users.split(separator: "\r\n").dropFirst().map { $0.split(separator: ",")[0] } == ["u1", "u2"])
        people.search = "bram"
        #expect(people.csv(.users).split(separator: "\r\n").dropFirst().map { $0.split(separator: ",")[0] } == ["u2"])
        people.search = ""
        #expect(people.csv(.groups).hasPrefix((["id"] + ExportPolicy.userGroups.names).joined(separator: ",") + "\r\nG2,"))
        #expect(people.csv(.units).hasPrefix((["id"] + ExportPolicy.organizationalUnits.names).joined(separator: ",") + "\r\nOU2,"))
        #expect(Model.Tab.allCases.map(\.filename) == ["users.csv", "user-groups.csv", "org-units.csv"])
    }

    // MARK: the demo org

    /// The demo's people (plan §4, demo mode): about 25 users with a mix of statuses, phone numbers and roles in two org
    /// units, four groups with members, three org units with members; invented, at example.com.
    @Test func theDemoOrgHasPeople() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        DemoPeople.load(into: world.stubs["a"]!)
        world.people.load()
        await settled(world, 3)
        let people = world.people
        #expect(people.users.rows.count == 25 && people.groups.rows.count == 4 && people.units.rows.count == 3)
        #expect(Set(people.users.rows.map(\.status)).count >= 4, "\(Set(people.users.rows.map(\.status)))")
        #expect(people.users.rows.contains { $0.external == "Yes" })
        #expect(people.users.rows.allSatisfy { $0.email.hasSuffix("@example.com") && $0.account.hasSuffix("@appleid.example.com") })
        #expect(people.users.rows.filter { !Model.phones(of: $0.user).isEmpty }.count >= 20)
        let roleUnits = Set(people.users.rows.flatMap { $0.user.roleOuList?.compactMap(\.ouID) ?? [] })
        #expect(roleUnits.count >= 2 && roleUnits.isSubset(of: Set(people.units.rows.map(\.id))))
        #expect(people.users.rows.contains { ($0.user.roleOuList?.count ?? 0) >= 2 }, "someone holds roles in two org units")
        for group in people.groups.rows {
            people.selectedGroup = group.id
            await eventually("\(group.id)'s members") { Self.isLoaded(people.groupMembers.state) && people.groupMembers.owner == group.id }
            #expect(!people.groupMembers.ids.isEmpty, "\(group.id)")
            #expect(people.groupMembers.ids.count == group.totalMemberCount, "\(group.id)")
        }
        for unit in people.units.rows {
            people.selectedUnit = unit.id
            await eventually("\(unit.id)'s members") { Self.isLoaded(people.unitMembers.state) && people.unitMembers.owner == unit.id }
            #expect(!people.unitMembers.ids.isEmpty, "\(unit.id)")
            #expect(people.memberNote(people.unitMembers) == nil, "\(unit.id)")
        }
    }
}
