import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// People (plan §8 Phase 2; Appendix B: `/users`, `/user-groups[/{id}]`, `/org-units[/{id}]`): users with every attribute
/// and a user's detail, user groups and org units with their members. The three lists load side by side, each with its
/// own state, so a role that can't read one still sees the others (SwiftGamGui failure-log 2026-10-13); a selected group's
/// or org unit's members are read on their own and resolved to the users read, an id not among them shown as its id.
/// Business only: a School org's reads throw `.notInScope`, said as `LoadState.notInScope` in each panel, never an empty
/// table. Each load has a token, as `DevicesModel`'s: a load that was refreshed, superseded or cancelled writes nothing,
/// and an org switch clears everything at once and reads again (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Observable
public final class PeopleModel {
    /// The screen's three lists, chosen by a segmented control: an inner sidebar wouldn't fit beside the sidebar and the
    /// inspector in the smallest window (`ColumnWidths`).
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case users, groups, units

        public var id: Self { self }

        public var title: String {
            switch self {
            case .users: "Users"
            case .groups: "Groups"
            case .units: "Org units"
            }
        }

        /// The search field's prompt: what the list's search looks in.
        public var prompt: String {
            switch self {
            case .users: "Name, Managed Apple Account, email, department…"
            case .groups: "Group or org unit name"
            case .units: "Org unit name or description"
            }
        }

        /// abapit's export names (`/export/users.csv`, `user-groups`, `org-units`).
        public var filename: String {
            switch self {
            case .users: "users.csv"
            case .groups: "user-groups.csv"
            case .units: "org-units.csv"
            }
        }

        /// One item and the list, inside a sentence.
        var noun: (one: String, many: String) {
            switch self {
            case .users: ("user", "users")
            case .groups: ("group", "user groups")
            case .units: ("org unit", "org units")
            }
        }
    }

    /// One list as far as it has been read: its rows, where its read stands, and whether the page cap cut it.
    public struct Listing<Row: Sendable>: Sendable {
        public fileprivate(set) var rows: [Row] = []
        public fileprivate(set) var state: LoadState = .idle
        /// The page cap stopped the list with more to come: "showing N of ≥M".
        public fileprivate(set) var truncated = false
        /// Apple's own total, when it gives one.
        public fileprivate(set) var total: Int?

        /// The rows a failed or refused walk read before it stopped: shown, and said to be partial.
        public var partialCount: Int? {
            switch state {
            case .failed, .forbidden: rows.isEmpty ? nil : rows.count
            default: nil
            }
        }

        /// The sentence that takes the table's place when there is nothing such a list could hold: an org that can't be
        /// read, or a scope with no such list (invariant 8: never an empty table for "not in scope"); nil to show the table.
        public var unavailable: String? {
            switch state {
            case .notInScope(let why), .unusable(let why): why
            default: nil
            }
        }
    }

    /// A user as the Users table shows it, made once per page so sorting and searching don't re-read attributes. A value
    /// Apple didn't send is a dash; a status in words, one Apple adds later as sent (invariant 10).
    public struct UserRow: Identifiable, Sendable {
        public let user: User
        public let name: String
        public let account: String
        public let email: String
        public let status: String
        public let external: String
        public let department: String
        public let jobTitle: String
        public let started: Date?

        public var id: String { user.id }
        /// Sorts undated users first, as a missing date reads oldest.
        public var startedSort: Date { started ?? .distantPast }

        init(_ user: User) {
            self.user = user
            name = user.fullName ?? "—"
            account = PeopleModel.text(user.managedAppleAccount)
            email = PeopleModel.text(user.email)
            status = PeopleModel.words(user.status?.known, raw: user.status?.rawValue)
            external = user.isExternalUser.map { $0 ? "Yes" : "No" } ?? "—"
            department = PeopleModel.text(user.department)
            jobTitle = PeopleModel.text(user.jobTitle)
            started = user.startDate?.date
        }
    }

    /// A user group as the Groups table shows it. Made when shown, not per page: its org unit's name comes from the org
    /// units read, which may arrive after the groups.
    public struct GroupRow: Identifiable, Sendable {
        public let group: UserGroup
        public let name: String
        public let type: String
        public let status: String
        /// The org unit's name once read, else its id: never blank.
        public let unit: String
        /// Apple's `totalMemberCount`, which no page cap cuts; nil (a dash) when Apple sent none, never 0.
        public let members: Int?

        public var id: String { group.id }
        public var membersSort: Int { members ?? -1 }
        public var membersText: String { members.map { $0.formatted() } ?? "—" }

        init(_ group: UserGroup, unit: String) {
            self.group = group
            name = PeopleModel.text(group.name)
            type = PeopleModel.words(group.type?.known, raw: group.type?.rawValue)
            status = PeopleModel.words(group.status?.known, raw: group.status?.rawValue)
            self.unit = unit
            members = group.totalMemberCount
        }
    }

    public struct UnitRow: Identifiable, Sendable {
        public let unit: OrganizationalUnit
        public let name: String
        public let summary: String
        public let updated: Date?

        public var id: String { unit.id }
        public var updatedSort: Date { updated ?? .distantPast }

        init(_ unit: OrganizationalUnit) {
            self.unit = unit
            name = PeopleModel.text(unit.name)
            summary = PeopleModel.text(unit.summary)
            updated = unit.updated?.date
        }
    }

    /// One member of a group or an org unit: the user, when the users read holds the id, else the id itself.
    public struct MemberRow: Identifiable, Sendable {
        public let id: String
        public let user: UserRow?

        public var isUser: Bool { user != nil }
        public var name: String { user.map { $0.user.fullName ?? $0.user.managedAppleAccount ?? id } ?? id }
        public var detail: String { user?.account ?? "Not among the users read" }
    }

    /// A label and its value as the inspector shows them.
    public struct Field: Equatable, Sendable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The lists inside a user that `User` reads as typed objects.
    public enum UserList: String, Sendable {
        case phoneNumbers, roleOuList
    }

    public var tab: Tab = .users
    /// One search, applied to the list on screen.
    public var search = ""
    public var userOrder = [KeyPathComparator(\UserRow.name)]
    public var groupOrder = [KeyPathComparator(\GroupRow.name)]
    public var unitOrder = [KeyPathComparator(\UnitRow.name)]

    public private(set) var users = Listing<UserRow>()
    public private(set) var groups = Listing<UserGroup>()
    public private(set) var units = Listing<UnitRow>()

    /// Each tab's own selection, here so an org switch clears it. Choosing a group or an org unit reads its members.
    public var selectedUser: String?
    public var selectedGroup: String? {
        didSet { if !Self.same(selectedGroup, oldValue) { groupMembers.show(selectedGroup) } }
    }
    public var selectedUnit: String? {
        didSet { if !Self.same(selectedUnit, oldValue) { unitMembers.show(selectedUnit) } }
    }

    /// The selected group's members, and the selected org unit's.
    public let groupMembers: Members
    public let unitMembers: Members

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current load's token: every write checks it, so a superseded load never lands.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    /// List reads (users, groups, org units) that have returned, superseded ones included: what tests wait on instead of
    /// the clock. `package`: the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        groupMembers = Members(.group, orgs: orgs)
        unitMembers = Members(.unit, orgs: orgs)
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    // MARK: what the tables show

    /// The users the table shows: searched, then sorted. The search folds case and accents, as Finder's does: a person
    /// typing "ines" is looking for Inés.
    public var shownUsers: [UserRow] {
        let query = Self.query(search)
        let rows = query.isEmpty ? users.rows : users.rows.filter { row in
            [row.name, row.account, row.email, row.department, row.jobTitle].contains { $0.localizedStandardContains(query) }
        }
        return rows.sorted(using: userOrder)
    }

    /// The groups the table shows, each with its org unit's name: searched by the group's name or its unit's, then sorted.
    public var shownGroups: [GroupRow] {
        let names = unitNames(), query = Self.query(search)
        let rows = groups.rows.map { GroupRow($0, unit: Self.unitName($0.ouID, in: names)) }
        let found = query.isEmpty ? rows : rows.filter { $0.name.localizedStandardContains(query) || $0.unit.localizedStandardContains(query) }
        return found.sorted(using: groupOrder)
    }

    public var shownUnits: [UnitRow] {
        let query = Self.query(search)
        let rows = query.isEmpty ? units.rows : units.rows.filter { $0.name.localizedStandardContains(query) || $0.summary.localizedStandardContains(query) }
        return rows.sorted(using: unitOrder)
    }

    /// An org unit's name as a group or a role shows it: the unit's name once read, else its id; a dash for none.
    public func unitName(_ id: String?) -> String { Self.unitName(id, in: unitNames()) }

    // MARK: the selection and the inspector

    public var user: UserRow? { selectedUser.flatMap { id in users.rows.first { Self.same($0.id, id) } } }

    public var group: GroupRow? {
        guard let id = selectedGroup, let group = groups.rows.first(where: { Self.same($0.id, id) }) else { return nil }
        return GroupRow(group, unit: unitName(group.ouID))
    }

    public var unit: UnitRow? { selectedUnit.flatMap { id in units.rows.first { Self.same($0.id, id) } } }

    /// Whether the tab on screen has a selection: the inspector shows it.
    public var hasSelection: Bool {
        switch tab {
        case .users: selectedUser != nil
        case .groups: selectedGroup != nil
        case .units: selectedUnit != nil
        }
    }

    /// Closes the inspector: clears the selection of the tab on screen only.
    public func clearSelection() {
        switch tab {
        case .users: selectedUser = nil
        case .groups: selectedGroup = nil
        case .units: selectedUnit = nil
        }
    }

    /// Why the inspector has nothing to show for the selection: its list is still being read (a Refresh), or Apple's list
    /// doesn't hold it; nil when it shows the selection or nothing is selected.
    public var selectionNote: String? {
        let (selected, found, state): (Bool, Bool, LoadState) = switch tab {
        case .users: (selectedUser != nil, user != nil, users.state)
        case .groups: (selectedGroup != nil, group != nil, groups.state)
        case .units: (selectedUnit != nil, unit != nil, units.state)
        }
        guard selected, !found else { return nil }
        switch state {
        case .idle, .loading: return "Reading the \(tab.noun.many)…"
        case .loaded: return "This \(tab.noun.one) isn't in the list Apple sent."
        default: return "This \(tab.noun.one) couldn't be read."
        }
    }

    /// `list`'s members, in Apple's order: each the user the users read holds, else its id.
    public func members(_ list: Members) -> [MemberRow] {
        // By bytes: `String` keys would make canonically equivalent ids one (failure-log 2026-10-16, "Swift matched
        // Characters where Python reads code points").
        let index = Dictionary(users.rows.map { (Array($0.id.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        return list.ids.map { MemberRow(id: $0, user: index[Array($0.utf8)]) }
    }

    /// Why some of `list`'s members show as their ids, with how many; nil when every member is a user read.
    public func memberNote(_ list: Members) -> String? {
        let known = Set(users.rows.map { Array($0.id.utf8) })
        let count = list.ids.filter { !known.contains(Array($0.utf8)) }.count
        return Self.byID(count, ("member", "members"), in: users, named: "users")
    }

    /// Why some of the org units `ids` names (a user's roles, a group's unit) show as their ids; nil when each is read.
    public func unitNote(for ids: [String?]) -> String? {
        let known = Set(units.rows.map { Array($0.id.utf8) })
        let count = ids.compactMap { $0 }.filter { !$0.isEmpty && !known.contains(Array($0.utf8)) }.count
        return Self.byID(count, ("org unit", "org units"), in: units, named: "org units")
    }

    /// The Users inspector's typed attributes, in the order a person reads them. Every attribute Apple sent follows them,
    /// raw.
    public nonisolated static func fields(of row: UserRow) -> [Field] {
        let user = row.user
        return [
            Field("Name", row.name), Field("Status", row.status), Field("Managed Apple Account", row.account), Field("Email", row.email),
            Field("External", row.external), Field("Employee number", text(user.employeeNumber)), Field("Department", row.department),
            Field("Job title", row.jobTitle), Field("Division", text(user.division)), Field("Cost center", text(user.costCenter)),
            Field("Start date", ScreenWords.day(row.started)), Field("Created", ScreenWords.day(user.created?.date)),
            Field("Updated", ScreenWords.day(user.updated?.date)),
        ]
    }

    public nonisolated static func fields(of row: GroupRow) -> [Field] {
        [
            Field("Name", row.name), Field("Type", row.type), Field("Status", row.status),
            Field("Members, Apple's count", row.membersText), Field("Org unit", row.unit),
            Field("Created", ScreenWords.day(row.group.created?.date)), Field("Updated", ScreenWords.day(row.group.updated?.date)),
        ]
    }

    public nonisolated static func fields(of row: UnitRow) -> [Field] {
        [Field("Name", row.name), Field("Description", row.summary), Field("Created", ScreenWords.day(row.unit.created?.date)),
         Field("Updated", ScreenWords.day(row.updated))]
    }

    /// A user's phone numbers, each with its type in words (one Apple adds later as sent; "Phone" when it sent none).
    public nonisolated static func phones(of user: User) -> [Field] {
        (user.phoneNumbers ?? []).map { Field(words($0.type?.known, raw: $0.type?.rawValue), text($0.phoneNumber)) }
    }

    /// A user's roles, each with the org unit it is held in (`unitName`).
    public func roles(of user: User) -> [Field] {
        let names = unitNames()
        return (user.roleOuList ?? []).map { Field(Self.text($0.roleName), Self.unitName($0.ouID, in: names)) }
    }

    /// What the detail says of one of a user's lists when it has nothing to show: "None.", or that Apple sent it in a shape
    /// this version can't read, which is never shown as none (RULE-FEEDBACK 2026-10-31: a stricter read's nil is said). Nil
    /// when the list has items.
    public nonisolated static func listNote(_ user: User, _ list: UserList) -> String? {
        if user.misreadLists.contains(where: { $0.utf8.elementsEqual(list.rawValue.utf8) }) {
            return "Apple sent these in a form this version can't read: they're under Every attribute."
        }
        let count = switch list {
        case .phoneNumbers: user.phoneNumbers?.count
        case .roleOuList: user.roleOuList?.count
        }
        return (count ?? 0) == 0 ? "None." : nil
    }

    // MARK: export

    /// The CSV of what the tab's table shows, with that list's columns only (invariant 11: `ExportPolicy`).
    public func csv(_ tab: Tab) -> String {
        switch tab {
        case .users: CSV.text(shownUsers.map { CSV.Item($0.user.resource) }, columns: ExportPolicy.users)
        case .groups: CSV.text(shownGroups.map { CSV.Item($0.group.resource) }, columns: ExportPolicy.userGroups)
        case .units: CSV.text(shownUnits.map { CSV.Item($0.unit.resource) }, columns: ExportPolicy.organizationalUnits)
        }
    }

    /// Why the tab's Export is off, in words; nil when it exports: every screen's rule (`ScreenWords.exportBlocked`). A list
    /// still loading or left partial by an error isn't exported as if whole, and one the page cap stopped exports, as the
    /// banner says it was cut.
    public func exportBlocked(_ tab: Tab) -> String? {
        let (state, read, shown): (LoadState, Int, Int) = switch tab {
        case .users: (users.state, users.partialCount ?? 0, shownUsers.count)
        case .groups: (groups.state, groups.partialCount ?? 0, shownGroups.count)
        case .units: (units.state, units.partialCount ?? 0, shownUnits.count)
        }
        return ScreenWords.exportBlocked(state, read: read, shown: shown, noun: tab.noun.many)
    }

    // MARK: loading

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R), cancelling a load still
    /// running, and reads the selected group's and org unit's members again too.
    public func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || users.state == .idle else { return }
        reset()
        loadedGeneration = generation
        defer {
            groupMembers.show(selectedGroup)
            unitMembers.show(selectedUnit)
        }
        guard let client = orgs.appleClient else {
            let why = ScreenWords.unusable(orgs)
            (users.state, groups.state, units.state) = (.unusable(why), .unusable(why), .unusable(why))
            return
        }
        let token = token
        (users.state, groups.state, units.state) = (.loading(count: 0), .loading(count: 0), .loading(count: 0))
        tasks = [
            Task { [weak self] in await self?.read(client.users(), into: \.users, token: token, UserRow.init) },
            Task { [weak self] in await self?.read(client.userGroups(), into: \.groups, token: token) { $0 } },
            Task { [weak self] in await self?.read(client.organizationalUnits(), into: \.units, token: token, UnitRow.init) },
        ]
    }

    /// The org changed: nothing of the old one stays on screen, selected, in a member list or in a CSV, and if anything
    /// was showing, the new org is read at once.
    private func orgChanged() {
        let wasShowing = users.state != .idle
        reset()
        loadedGeneration = -1
        // Each selection's `didSet` empties its member list, cancelling a read on its way.
        (selectedUser, selectedGroup, selectedUnit) = (nil, nil, nil)
        if wasShowing { load() }
    }

    /// Cancels the running load, retires its token, and drops what it read.
    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        (users, groups, units) = (Listing(), Listing(), Listing())
    }

    /// Whether the load holding `token` may still write: checked after every await and every page, because a cancelled
    /// `AsyncThrowingStream` loop ends without throwing and can still be handed a page in its buffer (Phase 1b review H2).
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func read<Item: Sendable, Row: Sendable>(_ pages: AsyncThrowingStream<Page<Item>, any Error>,
                                                     into list: ReferenceWritableKeyPath<PeopleModel, Listing<Row>>, token: Int,
                                                     _ row: (Item) -> Row) async {
        defer { readsFinished += 1 }
        do {
            for try await page in pages {
                guard current(token) else { return }
                var listing = self[keyPath: list]
                listing.rows += page.items.map(row)
                listing.truncated = page.truncated
                listing.total = page.total
                listing.state = .loading(count: listing.rows.count)
                self[keyPath: list] = listing
            }
            guard current(token) else { return }
            self[keyPath: list].state = .loaded(at: Date())
        } catch {
            guard current(token) else { return }
            self[keyPath: list].state = LoadState(after: error)
        }
    }

    // MARK: words

    /// Apple's text, or a dash for none.
    nonisolated static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    public nonisolated static func words(_ status: UserStatus?, raw: String?) -> String {
        switch status {
        case .new?: "New"
        case .released?: "Released"
        case .active?: "Active"
        case .deactivated?: "Deactivated"
        case .locked?: "Locked"
        case .lockedForSharedIPad?: "Locked for Shared iPad"
        case nil: text(raw)
        }
    }

    public nonisolated static func words(_ type: UserGroupType?, raw: String?) -> String {
        switch type {
        case .standard?: "Standard"
        case .smart?: "Smart"
        case nil: text(raw)
        }
    }

    public nonisolated static func words(_ status: UserGroupStatus?, raw: String?) -> String {
        switch status {
        case .active?: "Active"
        case nil: text(raw)
        }
    }

    public nonisolated static func words(_ type: UserPhoneNumberType?, raw: String?) -> String {
        switch type {
        case .work?: "Work"
        case .home?: "Home"
        case .mobile?: "Mobile"
        case nil: raw.flatMap { $0.isEmpty ? nil : $0 } ?? "Phone"
        }
    }

    /// "N members shown by id: why", for the ids `list` doesn't hold; nil for none.
    static func byID<Row>(_ count: Int, _ noun: (one: String, many: String), in list: Listing<Row>, named name: String) -> String? {
        guard count > 0 else { return nil }
        let reason: String
        switch list.state {
        case .loaded:
            reason = list.truncated ? "the \(name) list stopped at the page limit"
                : "\(count == 1 ? "it isn't" : "they aren't") in the \(name) list Apple sent"
        case .idle, .loading: reason = "the \(name) are still being read"
        case .forbidden: reason = "your role can't read \(name)"
        case .failed: reason = "the \(name) couldn't be read"
        case .unusable(let why), .notInScope(let why): return why
        }
        return "\(count.formatted()) \(count == 1 ? noun.one : noun.many) shown by id: \(reason)."
    }

    private func unitNames() -> [[UInt8]: String] {
        Dictionary(units.rows.map { (Array($0.id.utf8), $0.unit.name ?? $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func unitName(_ id: String?, in names: [[UInt8]: String]) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return names[Array(id.utf8)] ?? id
    }

    nonisolated static func query(_ search: String) -> String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Ids compared by their bytes, as Apple's text is compared everywhere here.
    nonisolated static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.utf8.elementsEqual(b.utf8)
        default: false
        }
    }
}

extension PeopleModel {
    /// A group's or an org unit's members, as `users` linkages, read page by page with their own token: choosing another
    /// group, Refresh or an org switch cancels the read, and what it was still handed lands nowhere.
    @MainActor
    @Observable
    public final class Members {
        public enum Kind: Sendable {
            case group, unit

            var noun: String { self == .group ? "group" : "org unit" }
        }

        public let kind: Kind
        /// The group or org unit whose members these are.
        public private(set) var owner: String?
        public private(set) var ids: [String] = []
        public private(set) var state: LoadState = .idle
        /// The page cap stopped the member list with more to come.
        public private(set) var truncated = false

        private let orgs: OrgsModel
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var token = 0
        /// Member reads that have returned, superseded ones included (tests).
        @ObservationIgnored package private(set) var readsFinished = 0

        init(_ kind: Kind, orgs: OrgsModel) {
            self.kind = kind
            self.orgs = orgs
        }

        /// Where the member list stands, in words (invariant 8): reading, how many beside Apple's own count when it sends
        /// one (both, when the page cap cut the list), refused, failed and how many were read before; nil when nothing is
        /// selected.
        public func line(appleCount: Int?) -> String? {
            let count = ids.count, plural = count == 1 ? "" : "s"
            let partial = count == 0 ? "" : " Partial: \(count.formatted()) read before the \(state == .forbidden ? "refusal" : "error")."
            switch state {
            case .idle: return nil
            case .loading: return count == 0 ? "Reading the members…" : "Reading the members… \(count.formatted()) so far"
            case .loaded:
                if truncated {
                    return "Showing \(count.formatted()) of \(appleCount.map { "\($0.formatted()), Apple's count" } ?? "more than \(count.formatted())"): "
                        + "the member list stopped at the page limit."
                }
                guard let appleCount, appleCount != count else { return count == 0 ? "No members." : "\(count.formatted()) member\(plural)." }
                return count == 0 ? "No members listed; Apple counts \(appleCount.formatted())."
                    : "\(count.formatted()) member\(plural); Apple counts \(appleCount.formatted())."
            case .forbidden: return "Your role can't read this \(kind.noun)'s members." + partial
            case .failed(let why): return "The members couldn't be read: \(why)" + partial
            case .unusable(let why), .notInScope(let why): return why
            }
        }

        /// Reads `id`'s members, or with nil empties the list; either way the read before it lands nowhere.
        fileprivate func show(_ id: String?) {
            task?.cancel()
            task = nil
            token += 1
            (owner, ids, truncated, state) = (id, [], false, .idle)
            guard let id else { return }
            guard let client = orgs.appleClient else {
                // Never a spinner that can't end: why, in words (invariant 8).
                state = .unusable(ScreenWords.unusable(orgs))
                return
            }
            // An id that can't go in a path is never sent: the client would call it "no such item", which isn't so of a
            // group or an org unit Apple has just listed (Phase 2b review L1).
            guard AppleRead.isPathSafe(id) else {
                state = .failed(ScreenWords.unsendableID)
                return
            }
            let token = token, kind = kind
            state = .loading(count: 0)
            task = Task { [weak self] in
                await self?.read(kind == .group ? client.userGroupMemberIDs(id) : client.organizationalUnitMemberIDs(id), token: token)
            }
        }

        private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

        private func read(_ pages: AsyncThrowingStream<Page<String>, any Error>, token: Int) async {
            defer { readsFinished += 1 }
            do {
                for try await page in pages {
                    guard current(token) else { return }
                    ids += page.items
                    truncated = page.truncated
                    state = .loading(count: ids.count)
                }
                guard current(token) else { return }
                state = .loaded(at: Date())
            } catch {
                guard current(token) else { return }
                state = LoadState(after: error)
            }
        }
    }
}
