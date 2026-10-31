import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// Content's four lists (Appendix B: `/apps`, `/packages`, `/blueprints`, `/configurations`), in the order the screen
/// offers them.
public enum ContentKind: String, CaseIterable, Identifiable, Sendable {
    case apps, packages, blueprints, configurations

    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    /// The list inside a sentence: "No apps in this organization."
    public var noun: String { rawValue }
}

/// One row of a Content table: the item with the text its columns sort and search on, made once per page so sorting
/// doesn't re-read attributes.
public protocol ContentRow: Identifiable, Sendable where ID == String {
    associatedtype Item: ResourceView
    static var kind: ContentKind { get }
    /// What the list's CSV holds: its documented attributes, never a profile or a package's location (invariant 11).
    static var columns: ExportPolicy.Columns { get }
    var item: Item { get }
    var name: String { get }
    /// What the search matches.
    var searched: [String] { get }
    /// The row as its CSV holds it: the item's attributes, a package's with its addresses masked.
    var exported: CSV.Item { get }
    init(_ item: Item)
}

extension ContentRow {
    public var id: String { item.id }
    public var exported: CSV.Item { CSV.Item(item.resource) }
}

public struct AppRow: ContentRow {
    public static let kind = ContentKind.apps
    public static var columns: ExportPolicy.Columns { ExportPolicy.apps }
    public let item: ContentApp
    public let name: String
    public let bundleID: String
    public let version: String
    public let platforms: String
    /// "Custom" (the organization's own) or "App Store".
    public let source: String
    public var searched: [String] { [name, bundleID, item.id] }

    public init(_ app: ContentApp) {
        item = app
        name = app.name ?? app.id
        bundleID = app.bundleID ?? ""
        version = app.version ?? ""
        platforms = ContentWords.list(app.supportedOS?.map { $0.known?.title ?? $0.rawValue }, misread: app.misreadLists.contains("supportedOS"))
        source = app.isCustomApp.map { $0 ? "Custom" : "App Store" } ?? "—"
    }
}

public struct PackageRow: ContentRow {
    public static let kind = ContentKind.packages
    public static var columns: ExportPolicy.Columns { ExportPolicy.packages }
    public let item: ContentPackage
    public let name: String
    public let version: String
    public let bundleIDs: String
    /// Sorts undated packages first, as a missing date reads oldest.
    public let updated: Date
    public var searched: [String] { [name, bundleIDs, item.id] }
    public var exported: CSV.Item { ContentWords.exported(item) }

    /// Each text with its addresses masked (`ContentWords.shown`), as the detail's attributes are.
    public init(_ package: ContentPackage) {
        item = package
        name = ContentWords.shown(package.name) ?? package.id
        version = ContentWords.shown(package.version) ?? ""
        bundleIDs = ContentWords.list(package.bundleIDs?.map(ContentWords.addresses(in:)), misread: package.misreadLists.contains("bundleIds"))
        updated = package.updated?.date ?? .distantPast
    }
}

public struct BlueprintRow: ContentRow {
    public static let kind = ContentKind.blueprints
    public static var columns: ExportPolicy.Columns { ExportPolicy.blueprints }
    public let item: Blueprint
    public let name: String
    public let status: String
    /// Apple's `appLicenseDeficient`: "Too few" when the blueprint's apps are short of licences.
    public let licences: String
    public let updated: Date
    public var searched: [String] { [name, item.summary ?? "", item.id] }

    public init(_ blueprint: Blueprint) {
        item = blueprint
        name = blueprint.name ?? blueprint.id
        status = blueprint.status.map { $0.known?.title ?? $0.rawValue } ?? "—"
        licences = blueprint.appLicenseDeficient.map { $0 ? "Too few" : "Enough" } ?? "—"
        updated = blueprint.updated?.date ?? .distantPast
    }
}

public struct ConfigurationRow: ContentRow {
    public static let kind = ContentKind.configurations
    public static var columns: ExportPolicy.Columns { ExportPolicy.configurations }
    /// The configuration as the list sends it: a custom setting's profile is null there, and withheld in any case.
    public let item: Configuration
    public let name: String
    public let type: String
    public let platforms: String
    public let updated: Date
    public var searched: [String] { [name, type, item.id] }

    public init(_ configuration: Configuration) {
        item = configuration
        name = configuration.name ?? configuration.id
        type = configuration.type.map { $0.known?.title ?? $0.rawValue } ?? "—"
        platforms = ContentWords.list(configuration.platforms?.map { $0.known?.title ?? $0.rawValue },
                                      misread: configuration.misreadLists.contains("configuredForPlatforms"))
        updated = configuration.updated?.date ?? .distantPast
    }
}

/// One of Content's lists, read page by page, with its own state: a role that can't read configurations still sees its
/// apps (SwiftGamGui failure-log 2026-10-13, "load each panel as its own Result"). Its read has a token: one that was
/// refreshed, superseded or cancelled writes nothing (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Observable
public final class ContentList<Row: ContentRow> {
    public private(set) var rows: [Row] = []
    public private(set) var state: LoadState = .idle
    /// The page cap stopped the list with more to come: "showing N of ≥M".
    public private(set) var truncated = false
    public private(set) var total: Int?
    public var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.name, comparator: String.StandardComparator.localizedStandard)]

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    /// Reads that have returned, superseded ones included: what tests wait on instead of the clock.
    @ObservationIgnored package private(set) var readsFinished = 0

    init() {}

    /// The rows the table shows: those whose name, identifier or other searched text holds `search` as Finder matches
    /// (`localizedStandardContains`), sorted. A search only picks rows; it decides nothing that leaves the app but which
    /// rows a CSV holds, and its columns are the list's own.
    public func shown(matching search: String) -> [Row] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? rows : rows.filter { row in row.searched.contains { $0.localizedStandardContains(query) } }
        return found.sorted(using: sortOrder)
    }

    /// The rows a walk read before it failed or was refused: shown, and said to be partial.
    public var partialCount: Int? {
        switch state {
        case .failed, .forbidden: rows.isEmpty ? nil : rows.count
        default: nil
        }
    }

    /// What stands in place of the table when there is no row to show, in words: none in the organization, the role
    /// can't read them, the read failed, the org can't be used, or its scope has no such list (never an empty table,
    /// invariant 8). Nil while it loads or once there are rows.
    public var emptyWords: String? {
        guard rows.isEmpty else { return nil }
        switch state {
        case .idle, .loading: return nil
        case .loaded: return "No \(Row.kind.noun) in this organization."
        case .forbidden: return "Your role can't read \(Row.kind.noun). An administrator can change the API account's role in Apple Business."
        case .failed(let why), .unusable(let why), .notInScope(let why): return why
        }
    }

    /// Why Export is off for the rows `search` shows, in words; nil when they are a whole read: every screen's rule
    /// (`ScreenWords.exportBlocked`). A partial list is never exported as if whole: the file couldn't say so. A list the
    /// page cap stopped exports, as the banner says "showing N of ≥M".
    public func exportBlocked(matching search: String) -> String? {
        ScreenWords.exportBlocked(state, read: partialCount ?? 0, shown: shown(matching: search).count, noun: Row.kind.noun)
    }

    /// The CSV of what the table shows, with the list's columns only (invariant 11).
    public func csv(matching search: String) -> String {
        CSV.text(shown(matching: search).map(\.exported), columns: Row.columns)
    }

    /// Cancels the running read, retires its token, drops what it read and stands at `state`.
    func reset(to state: LoadState) {
        task?.cancel()
        task = nil
        token += 1
        rows = []
        truncated = false
        total = nil
        self.state = state
    }

    /// Reads `pages` in place of whatever was read or reading.
    func read(_ pages: AsyncThrowingStream<Page<Row.Item>, any Error>) {
        reset(to: .loading(count: 0))
        let token = token
        task = Task { [weak self] in await self?.walk(pages, token: token) }
    }

    /// Whether the read holding `token` may still write: checked after every page and every await, because a cancelled
    /// `for try await` loop ends without throwing and can still be handed a page from its buffer.
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func walk(_ pages: AsyncThrowingStream<Page<Row.Item>, any Error>, token: Int) async {
        defer { readsFinished += 1 }
        do {
            for try await page in pages {
                guard current(token) else { return }
                rows += page.items.map(Row.init)
                truncated = page.truncated
                total = page.total
                state = .loading(count: rows.count)
            }
            guard current(token) else { return }
            state = .loaded(at: Date())
        } catch {
            guard current(token) else { return }
            state = LoadState(after: error)
        }
    }
}

/// Content (plan §8 Phase 2; Appendix B: `/apps`, `/packages`, `/blueprints`, `/configurations`): the four lists, read
/// side by side when the screen shows, and the detail of the row chosen in the list on screen. Business only: a School
/// org's lists each say not in scope, in words (`LoadState.notInScope`). An org switch empties every list and the
/// detail at once and reads again; Refresh reads the lists and the open detail again.
@MainActor
@Observable
public final class ContentModel {
    public let apps: ContentList<AppRow>
    public let packages: ContentList<PackageRow>
    public let blueprints: ContentList<BlueprintRow>
    public let configurations: ContentList<ConfigurationRow>
    /// The chosen row's detail, read on its own.
    public let detail: ContentDetailModel

    /// The list on screen. Choosing another clears the selection: an id is one list's.
    public var kind = ContentKind.apps {
        didSet { if kind != oldValue { selection = nil } }
    }

    /// The id of the row chosen in the list on screen; the detail reads it.
    public var selection: String? {
        didSet { if selection != oldValue { detail.show(selection.map { ContentSelection(kind: kind, id: $0) }) } }
    }

    /// The search field's text, for whichever list is on screen.
    public var search = ""

    private let orgs: OrgsModel
    @ObservationIgnored private var loadedGeneration = -1

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        apps = ContentList()
        packages = ContentList()
        blueprints = ContentList()
        configurations = ContentList()
        detail = ContentDetailModel(orgs: orgs)
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    /// The four lists' reads that have returned, superseded ones too: what tests wait on.
    package var readsFinished: Int { apps.readsFinished + packages.readsFinished + blueprints.readsFinished + configurations.readsFinished }

    /// Loads unless the active org's lists are already here; `force` reads again (Refresh, ⌘R), cancelling a read still
    /// running, and reads the open detail again too.
    public func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || apps.state == .idle else { return }
        loadedGeneration = generation
        guard let client = orgs.appleClient else {
            resetAll(to: .unusable(ScreenWords.unusable(orgs)))
            return
        }
        apps.read(client.apps())
        packages.read(client.packages())
        blueprints.read(client.blueprints())
        configurations.read(client.configurations())
        if force, let selection { detail.show(ContentSelection(kind: kind, id: selection)) }
    }

    /// The CSV of what `kind`'s table shows, with that list's columns.
    public func csv(for kind: ContentKind) -> String {
        switch kind {
        case .apps: apps.csv(matching: search)
        case .packages: packages.csv(matching: search)
        case .blueprints: blueprints.csv(matching: search)
        case .configurations: configurations.csv(matching: search)
        }
    }

    /// Why `kind`'s Export is off, in words; nil when it may export.
    public func exportBlocked(for kind: ContentKind) -> String? {
        switch kind {
        case .apps: apps.exportBlocked(matching: search)
        case .packages: packages.exportBlocked(matching: search)
        case .blueprints: blueprints.exportBlocked(matching: search)
        case .configurations: configurations.exportBlocked(matching: search)
        }
    }

    /// The org changed: nothing of the old one stays, in a list, a CSV or the detail, and if anything was showing, the
    /// new org is read at once.
    private func orgChanged() {
        let wasShowing = apps.state != .idle
        // Its `didSet` retires the detail's read.
        selection = nil
        resetAll(to: .idle)
        loadedGeneration = -1
        if wasShowing { load() }
    }

    private func resetAll(to state: LoadState) {
        apps.reset(to: state)
        packages.reset(to: state)
        blueprints.reset(to: state)
        configurations.reset(to: state)
    }
}

/// A row chosen in one of Content's lists.
public struct ContentSelection: Hashable, Sendable {
    public let kind: ContentKind
    public let id: String

    public init(kind: ContentKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// The detail of the row chosen (plan Phase 2: app, package, blueprint and configuration detail): the item read alone,
/// for a blueprint with every relationship included, for a configuration the only read that carries a custom setting's
/// profile. A choice made after it, or an org switch, retires its read.
@MainActor
@Observable
public final class ContentDetailModel {
    public private(set) var shown: ContentSelection?
    public private(set) var item: Panel<ContentDetail> = .loading

    private let orgs: OrgsModel
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The current read's token: a read for a row shown before, even the same one, never lands.
    @ObservationIgnored private var token = 0
    /// Detail reads that have returned, superseded ones included: what tests wait on.
    @ObservationIgnored package private(set) var readsFinished = 0

    init(orgs: OrgsModel) {
        self.orgs = orgs
    }

    func show(_ selection: ContentSelection?) {
        task?.cancel()
        task = nil
        token += 1
        shown = selection
        item = .loading
        guard let selection else { return }
        guard let client = orgs.appleClient else {
            // Never a spinner that can't end: why, in words (invariant 8).
            item = .failed(ScreenWords.unusable(orgs))
            return
        }
        // An id that can't go in a path is never sent: the client would call it "no such item", which isn't so of an item
        // Apple has just listed (Phase 2b review L1).
        guard AppleRead.isPathSafe(selection.id) else {
            item = .failed(ScreenWords.unsendableID)
            return
        }
        let token = token
        task = Task { [weak self] in
            defer { self?.readsFinished += 1 }
            let result: Panel<ContentDetail>
            do {
                result = .loaded(try await Self.read(selection, from: client))
            } catch is CancellationError {
                return
            } catch {
                // Through the shared mapping, as every screen model's errors are (Phase 2b review L10).
                result = Panel(after: error)
            }
            guard let self, self.token == token, !Task.isCancelled else { return }
            self.item = result
        }
    }

    private static func read(_ selection: ContentSelection, from client: AppleClient) async throws -> ContentDetail {
        switch selection.kind {
        case .apps: ContentDetail(app: try await client.app(selection.id))
        case .packages: ContentDetail(package: try await client.package(selection.id))
        case .blueprints: ContentDetail(blueprint: try await client.blueprint(selection.id, include: Set(Blueprint.Relationship.allCases)))
        case .configurations: ContentDetail(configuration: try await client.configuration(selection.id))
        }
    }
}

/// A label and its text, as the inspector lists it.
public struct ContentField: Sendable, Equatable, CustomStringConvertible {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var description: String { "\(label): \(value)" }
}

/// One member of a blueprint relationship: its id, and its name when Apple included it.
public struct ContentMember: Sendable, Equatable {
    public let id: String
    public let name: String?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }
}

/// One of a blueprint's relationships as the read with `include` said it: its members, how many, and that in words.
public struct ContentMemberGroup: Identifiable, Sendable, Equatable {
    public let relationship: Blueprint.Relationship
    public let title: String
    public let members: [ContentMember]
    /// How many members Apple listed; nil when it didn't list them, never a zero nobody counted.
    public let count: Int?
    /// The include's limit cut the list: there are more than `count`.
    public let isTruncated: Bool
    public let summary: String

    public var id: String { relationship.rawValue }
}

/// What the inspector shows of one row: every word decided here, so the view only lays it out. Package, App Store and
/// website addresses are text, never opened or fetched (invariant 4); a package's location has what could be a
/// credential masked (`ContentWords.location`); a custom setting's profile is only ever `profileText`, masked
/// (invariant 11), and the configuration's attributes are its withheld copy.
public struct ContentDetail: Sendable {
    public let title: String
    public let fields: [ContentField]
    /// Sentences under the fields: a masked location, a configuration's type.
    public let notes: [String]
    /// A blueprint's relationships, in `Blueprint.Relationship` order; empty when the include was refused.
    public let members: [ContentMemberGroup]
    /// Why a blueprint's members aren't shown: Apple refused the include (Phase 2a review L5: never "no members").
    public let membersNote: String?
    /// A custom setting's profile, pretty-printed with every secret masked.
    public let profile: String?
    /// What was masked in it, or why it isn't shown.
    public let profileNote: String?
    /// Every attribute Apple sent, as text, in Apple's order: what this version doesn't read is shown raw (invariant 10).
    public let attributes: [ContentField]

    init(title: String, fields: [ContentField], notes: [String] = [], members: [ContentMemberGroup] = [],
         membersNote: String? = nil, profile: String? = nil, profileNote: String? = nil, attributes: [ContentField]) {
        self.title = title
        self.fields = fields
        self.notes = notes
        self.members = members
        self.membersNote = membersNote
        self.profile = profile
        self.profileNote = profileNote
        self.attributes = attributes
    }

    init(app: ContentApp) {
        self.init(title: app.name ?? app.id, fields: [
            ContentField("Name", app.name ?? "—"), ContentField("Bundle ID", app.bundleID ?? "—"), ContentField("Version", app.version ?? "—"),
            ContentField("Platforms", AppRow(app).platforms),
            ContentField("Kind", app.isCustomApp.map { $0 ? "Custom app" : "App Store app" } ?? "—"),
            ContentField("App Store", app.appStoreURL ?? "—"), ContentField("Website", app.websiteURL ?? "—"), ContentField("Adam ID", app.id),
        ], attributes: ContentWords.attributes(of: app))
    }

    /// A package's location is masked as `ContentWords.location` says, and every other place an address could be shown with
    /// a credential in it, the title, the name, version, bundle ids, hash and description fields and every string of every
    /// attribute, through `ContentWords.addresses(in:)` (Phase 2b verifier round 1: the Description field showed in clear
    /// what its attribute masked; round 2: so did the other four and the title). A url Apple sent in a shape this version
    /// can't read is said, never a dash that reads as no location; a url Apple sent as null is none, a dash.
    init(package: ContentPackage) {
        let location = package.url.map(ContentWords.location)
        let misread = location == nil && package.attributes["url"].map { $0.jsonText != "null" } == true
        var notes: [String] = []
        if location?.masked == true { notes.append(ContentWords.maskedLocation) }
        if misread { notes.append(ContentWords.misreadLocation) }
        let name = ContentWords.shown(package.name)
        self.init(title: name ?? package.id, fields: [
            ContentField("Name", name ?? "—"), ContentField("Version", ContentWords.shown(package.version) ?? "—"),
            ContentField("Bundle IDs", PackageRow(package).bundleIDs),
            ContentField("Location", location?.text ?? (misread ? "Not readable" : "—")),
            ContentField("Hash", ContentWords.shown(package.hash) ?? "—"), ContentField("Description", ContentWords.shown(package.summary) ?? "—"),
            ContentField("Created", ScreenWords.day(package.created?.date)), ContentField("Updated", ScreenWords.day(package.updated?.date)),
        ], notes: notes, attributes: ContentWords.packageAttributes(package))
    }

    init(blueprint read: BlueprintRead) {
        let blueprint = read.blueprint
        var groups: [ContentMemberGroup] = [], refusal: String?
        switch read.members {
        case .refused(let error):
            refusal = ContentWords.refusal(error)
        case .read(let related, let included):
            groups = Blueprint.Relationship.allCases.map { relationship in
                guard let listed = related[relationship] else {
                    return ContentMemberGroup(relationship: relationship, title: relationship.title, members: [], count: nil, isTruncated: false,
                                              summary: "Apple didn't list the blueprint's \(relationship.noun(2)), so none are shown or counted.")
                }
                // Each member's name from what Apple included, matched by its id's bytes: a device's model, a person's name
                // or Managed Apple Account, anything else's name.
                var names: [[UInt8]: String] = [:]
                for resource in blueprint.included(relationship, from: included) {
                    let key = Array(resource.id.utf8)
                    let name: String? = switch relationship {
                    case .apps: ContentApp(resource: resource).name
                    case .packages: ContentPackage(resource: resource).name
                    case .configurations: Configuration(resource: resource).name
                    case .orgDevices: OrgDevice(resource: resource).deviceModel
                    case .users: User(resource: resource).fullName ?? User(resource: resource).managedAppleAccount
                    case .userGroups: UserGroup(resource: resource).name
                    }
                    if names[key] == nil, let name { names[key] = name }
                }
                let members = listed.linkages.map { ContentMember(id: $0.id, name: names[Array($0.id.utf8)]) }
                return ContentMemberGroup(relationship: relationship, title: relationship.title, members: members, count: members.count,
                                          isTruncated: listed.isTruncated, summary: ContentWords.members(members.count, relationship, truncated: listed.isTruncated))
            }
        }
        self.init(title: blueprint.name ?? blueprint.id, fields: [
            ContentField("Name", blueprint.name ?? "—"), ContentField("Description", blueprint.summary ?? "—"),
            ContentField("Status", BlueprintRow(blueprint).status),
            ContentField("Licences", blueprint.appLicenseDeficient.map { $0 ? "Too few for its apps" : "Enough for its apps" } ?? "—"),
            ContentField("Created", ScreenWords.day(blueprint.created?.date)), ContentField("Updated", ScreenWords.day(blueprint.updated?.date)),
        ], members: groups, membersNote: refusal, attributes: ContentWords.attributes(of: blueprint))
    }

    init(configuration: Configuration) {
        let row = ConfigurationRow(configuration)
        let settings = configuration.customSettings
        var fields = [ContentField("Name", configuration.name ?? "—"), ContentField("Type", row.type), ContentField("Platforms", row.platforms),
                      ContentField("Created", ScreenWords.day(configuration.created?.date)),
                      ContentField("Updated", ScreenWords.day(configuration.updated?.date))]
        if let filename = settings?.filename { fields.append(ContentField("Profile file", filename)) }
        var notes: [String] = []
        switch configuration.type {
        case .known(.customSetting)?: break
        case .known?: notes.append("A built-in configuration: Apple's API gives its name, type and platforms, not its settings.")
        case .unknown?: notes.append("A type this version doesn't know, shown as Apple sent it.")
        case nil: break
        }
        let (profile, profileNote) = ContentWords.profile(configuration)
        self.init(title: configuration.name ?? configuration.id, fields: fields, notes: notes,
                  profile: profile, profileNote: profileNote, attributes: ContentWords.attributes(of: configuration))
    }
}

/// The words Content decides, as pure functions the tests hold.
package enum ContentWords {
    /// What stands where a value is masked: `ProfileText`'s mask, so the screen masks one way.
    static let mask = ProfileText.mask

    static let maskedLocation = "The location's user, password, query, path parameters and fragment are masked: they can carry credentials. "
        + "It is shown here, never opened."

    static let misreadLocation = "Apple sent the location in a shape this version can't read: its url attribute below is shown with every "
        + "address in it masked."

    /// A list's items, joined: "Not readable" when Apple sent it in a shape this version can't read (never shown as
    /// none), a dash when it sent none, "None" for an empty list.
    static func list(_ items: [String]?, misread: Bool) -> String {
        if misread { return "Not readable" }
        guard let items else { return "—" }
        return items.isEmpty ? "None" : items.joined(separator: ", ")
    }

    /// A package's location as the detail shows it: the user and password (everything before the authority's last `@`),
    /// every query value, every path parameter's value (`;jsessionid=`) and the fragment masked, since a signed address or a
    /// basic-auth one carries its credential there; the scheme, host and path kept. A scheme is only a leading
    /// `[A-Za-z][A-Za-z0-9+.-]*:`, an authority follows `//` (`//user:pw@host` too), and with no `//` an `@` ahead of the path
    /// still ends a user and password (`user:pw@host`, whose `user:` reads as a scheme): Phase 2b review L2, where the first
    /// `://` anywhere was taken for the scheme's, so one only in the query copied the query before it raw. After a scheme,
    /// any run of slashes starts an authority (`https:/host`, which a browser reads as `https://host`); text or an outer
    /// scheme glued before an address's `://` (`url=https://…`, `jar:https://…`, `Mirror:https://…`) is kept as it came and
    /// the address masked from its own scheme on (Phase 2b verifier round 1: a leading `jar:` was read as the scheme, and the
    /// address after it copied as a path, its user and password in clear); and so is an address inside the path, a proxy's
    /// or an archive's (`https://proxy/fetch/https://user:pw@origin/…`) or one joined by `,` or `;` (Phase 2b verifier round
    /// 2: the outer path was copied as it came, the inner user and password with it). A blank ends an address, so a second
    /// one after an unencoded space is masked as its own, except inside the first one's user and password: a client sends a
    /// password a blank splits (a browser encodes a space there and drops a tab or a newline), so that authority runs past
    /// blanks to its last `@` (`https://deploy:my pw@host`, whose `deploy:my` showed as a host, verifier round 2). Read as
    /// UTF-8 bytes, so a combining mark can't join a delimiter into another character. Never opened or fetched (invariant 4).
    /// Not caught: an unencoded `/`, `?` or `#` inside a password, which isn't a valid address: what comes before it shows as
    /// the host, and after it as the path, or masked as the query or the fragment; and an address percent-encoded inside a
    /// path segment (`/https%3A%2F%2Fuser%3Apw%40origin%2Fa.pkg`), which is a segment's text until the server it names
    /// decodes it, and would take a decoder for each layer of encoding (`%253A` too).
    package static func location(_ url: String) -> (text: String, masked: Bool) {
        masking(url, joiningUserinfo: true) { _ in true }
    }

    /// `text` with every address in it masked as `location` masks one, the rest as it came: a package's description and the
    /// strings of its other attributes, where Apple could add an address. A run of text between blanks is an address when it
    /// starts with a scheme and goes on, starts with `//`, holds a `://`, or has a user before an `@` ahead of a path; a word,
    /// a version, a bundle id, a hash or an email address (`it@example.com`, no path) is none of these and shows unchanged.
    /// Masking errs toward hiding: `Requires:macOS;iOS` reads as a scheme and a path parameter and loses its tail, and an
    /// email address after a scheme or a label (`mailto:it@example.com`, `Contact:it@example.com`) or before a path
    /// (`Team@HQ/West`) reads as a user and password and loses its name. Not caught: an address with no scheme, no `//` and
    /// no user (`host/a.pkg?sig=…`) inside other text, the second half of one an unencoded space split, a password a blank
    /// splits (in other text a blank ends a word, so what came before it shows: the Location joins it, `location`), and a
    /// user with no password and no path (`token@host`), which is an email address's shape; the package's own `url` is
    /// always read as one (`packageAttributes`).
    package static func addresses(in text: String) -> String {
        masking(text, isAddress).text
    }

    /// A package's name, version, bundle ids, hash and description, its row's and its detail's and its CSV's, each through
    /// `addresses(in:)` as its attribute is among the detail's attributes (Phase 2b verifier round 2: the detail masked an
    /// address in the description attribute, then showed the same address raw in the Name, Version, Bundle IDs and Hash
    /// fields and the title, and the CSV wrote all five raw: a file that leaves the app was less careful than the screen,
    /// invariant 11). Nil when Apple sent none.
    static func shown(_ text: String?) -> String? { text.map(addresses(in:)) }

    /// A package as its CSV holds it: every string of every attribute through `addresses(in:)`, at any depth. The `url`
    /// isn't on the column list at all (`ExportPolicy.packages`).
    static func exported(_ package: ContentPackage) -> CSV.Item {
        var attributes = package.attributes
        for key in attributes.keys { attributes[key] = attributes[key]?.mappingStrings(addresses(in:)) }
        return CSV.Item(id: package.id, attributes: attributes)
    }

    /// Every attribute of a package, an attribute Apple adds included: each string at any depth through `addresses(in:)`,
    /// and every string of its `url` as the Location (`location`), whatever its shape (Phase 2b verifier round 1: a url that
    /// wasn't a string, an object holding `host/a.pkg?sig=…`, had its strings read only as other text, and its query shown).
    static func packageAttributes(_ package: ContentPackage) -> [ContentField] {
        let asLocation = attributes(of: package) { location($0).text }
        return zip(attributes(of: package, addresses(in:)), asLocation).map { other, location in
            other.label.utf8.elementsEqual("url".utf8) ? location : other
        }
    }

    private static let slash = UInt8(ascii: "/"), question = UInt8(ascii: "?"), hash = UInt8(ascii: "#"), at = UInt8(ascii: "@")
    private static let semicolon = UInt8(ascii: ";"), equals = UInt8(ascii: "="), ampersand = UInt8(ascii: "&")
    private static let slashes = Array("//".utf8), schemeSlashes = Array("://".utf8)
    /// ASCII blanks: an address holds none, so they split `text` into runs, and are kept as they came.
    private static let blanks: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]

    private static func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (0x30...0x39).contains(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    /// Where a leading scheme's `:` ends (RFC 3986: a letter, then letters, digits, `+`, `-` or `.`); nil when `run` has none.
    private static func schemeEnd(_ run: ArraySlice<UInt8>) -> Int? {
        guard let first = run.first, isLetter(first) else { return nil }
        guard let colon = run.dropFirst().firstIndex(where: { !isSchemeByte($0) }), run[colon] == UInt8(ascii: ":") else { return nil }
        return colon + 1
    }

    /// The end of the authority or of the user part: the first `/`, `?` or `#` from `start`, else the run's end.
    private static func pathStart(_ run: ArraySlice<UInt8>, from start: Int) -> Int {
        run[start...].firstIndex { $0 == slash || $0 == question || $0 == hash } ?? run.endIndex
    }

    private static func isAddress(_ run: ArraySlice<UInt8>) -> Bool {
        if let end = schemeEnd(run), end < run.endIndex { return true }
        if run.starts(with: slashes) || run.firstRange(of: schemeSlashes) != nil { return true }
        // A user before an `@` ahead of a path (`deploy@host/a.pkg`; a password's `:` is a scheme above). With nothing after
        // the host it is an email address (`it@example.com`, `ask it@example.com?`), shown as it came (Phase 2b verifier
        // round 1: an email in a description lost its name).
        let path = pathStart(run, from: run.startIndex)
        guard let user = run[..<path].firstIndex(of: at), user > run.startIndex else { return false }
        return path + 1 < run.endIndex
    }

    /// `text` with each run between blanks that `isAddress` passes masked as an address (`address`); blanks as they came.
    /// `joiningUserinfo` (a Location, one address): the first run's authority, or its user part with no `//`, runs past
    /// blanks to the last `@` ahead of the path (`userinfoEnd`).
    private static func masking(_ text: String, joiningUserinfo: Bool = false,
                                _ isAddress: (ArraySlice<UInt8>) -> Bool) -> (text: String, masked: Bool) {
        let bytes = Array(text.utf8)
        var out: [UInt8] = [], masked = false, start = 0, first = joiningUserinfo
        while start < bytes.endIndex {
            guard !blanks.contains(bytes[start]) else {
                out.append(bytes[start])
                start += 1
                continue
            }
            var end = bytes[start...].firstIndex(where: blanks.contains) ?? bytes.endIndex
            if first {
                first = false
                end = userinfoEnd(bytes, run: start..<end) ?? end
            }
            let run = bytes[start..<end]
            if isAddress(run) {
                let shown = address(run)
                out += shown.bytes
                masked = masked || shown.masked
            } else {
                out += run
            }
            start = end
        }
        return (String(decoding: out, as: UTF8.self), masked)
    }

    /// Where a run that a blank cut inside its user and password really ends: when its authority (after its first `//`, else
    /// from its start) has reached the blank with no `/`, `?` or `#`, and an `@` follows across blanks before any, the run
    /// goes on to the blank after the last such `@`. Nil when the run is whole.
    private static func userinfoEnd(_ bytes: [UInt8], run: Range<Int>) -> Int? {
        let text = bytes[run]
        let authority = text.firstRange(of: slashes)?.upperBound ?? run.lowerBound
        guard !text[authority...].contains(where: { $0 == slash || $0 == question || $0 == hash }) else { return nil }
        let ahead = bytes[run.upperBound...].firstIndex { $0 == slash || $0 == question || $0 == hash } ?? bytes.endIndex
        guard let last = bytes[run.upperBound..<ahead].lastIndex(of: at) else { return nil }
        return bytes[last...].firstIndex(where: blanks.contains) ?? bytes.endIndex
    }

    /// One address, its credentials masked (`location` says which parts).
    private static func address(_ run: ArraySlice<UInt8>) -> (bytes: [UInt8], masked: Bool) {
        let mask = Array(Self.mask.utf8)
        // An address glued to the text before it (`url=https://…`), or to a label or an outer scheme (`Mirror:https://…`,
        // `jar:https://…`): that text as it came, from the address's own scheme on an address. After a leading scheme only
        // when the `://` comes before any `/`, `?`, `#` or `@`, so one in a query stays the query's (review L2) and a user
        // before an `@` is still masked. The address starts after the text (`start > run.startIndex`), so this ends.
        if !run.starts(with: slashes), let found = run.firstRange(of: schemeSlashes),
           schemeEnd(run) == nil || !run[..<found.lowerBound].contains(where: { $0 == slash || $0 == question || $0 == hash || $0 == at }) {
            var start = found.lowerBound
            while start > run.startIndex, isSchemeByte(run[start - 1]) { start -= 1 }
            while start < found.lowerBound, !isLetter(run[start]) { start += 1 }
            if start > run.startIndex, start < found.lowerBound {
                let rest = address(run[start...])
                return (Array(run[..<start]) + rest.bytes, rest.masked)
            }
        }
        var out: [UInt8] = [], masked = false
        let afterScheme = schemeEnd(run) ?? run.startIndex
        let leadingSlashes = run[afterScheme...].prefix { $0 == slash }.count
        var index: Int
        if leadingSlashes >= 2 || (leadingSlashes == 1 && afterScheme > run.startIndex) {
            // An authority, after `//` or a scheme's slashes: everything before its last `@` is a user and password.
            let authority = afterScheme + leadingSlashes
            out += run[..<authority]
            if let last = run[authority..<pathStart(run, from: authority)].lastIndex(of: at) {
                out += mask
                masked = true
                index = last
            } else {
                index = authority
            }
        } else if let last = run[..<pathStart(run, from: run.startIndex)].lastIndex(of: at) {
            // No authority, and an `@` ahead of the path: what comes before it is a user and password, a `user:` read as a
            // scheme included.
            out += mask
            masked = true
            index = last
        } else {
            out += run[..<afterScheme]
            index = afterScheme
        }
        let queryStart = run[index...].firstIndex(of: question) ?? run.endIndex
        let fragmentStart = run[index...].firstIndex(of: hash) ?? run.endIndex
        var pathEnd = min(queryStart, fragmentStart)
        // An address inside the path, a proxy's or an archive's (`https://proxy/fetch/https://user:pw@origin/…`) or one
        // joined by `,` or `;`: the path up to its scheme, then that address masked as one from its scheme on, its own user
        // and password, query and fragment included (Phase 2b verifier round 2: the outer path was copied as it came, the
        // inner user and password with it). It starts after the run's start, so this ends; a digit, `-`, `+` or `.` it
        // starts with is its own glued split's text before a scheme.
        var inner: Int?
        if let found = run[index..<pathEnd].firstRange(of: schemeSlashes) {
            var start = found.lowerBound
            while start > index, isSchemeByte(run[start - 1]) { start -= 1 }
            if start > run.startIndex, start < found.lowerBound {
                inner = start
                pathEnd = start
            }
        }
        // The path, each `;name=value` parameter's value masked.
        var position = index
        while position < pathEnd {
            guard let parameter = run[position..<pathEnd].firstIndex(of: semicolon) else {
                out += run[position..<pathEnd]
                break
            }
            out += run[position...parameter]
            let end = run[(parameter + 1)..<pathEnd].firstIndex { $0 == slash || $0 == semicolon } ?? pathEnd
            let part = run[(parameter + 1)..<end]
            if let sign = part.firstIndex(of: equals) {
                out += part[...sign]
                if sign + 1 < end {
                    out += mask
                    masked = true
                }
            } else if !part.isEmpty {
                out += mask
                masked = true
            }
            position = end
        }
        if let inner {
            let rest = address(run[inner...])
            return (out + rest.bytes, masked || rest.masked)
        }
        if queryStart < fragmentStart {
            out.append(question)
            let query = run[(queryStart + 1)..<fragmentStart].split(separator: ampersand, omittingEmptySubsequences: false)
            for (number, part) in query.enumerated() {
                if number > 0 { out.append(ampersand) }
                if let sign = part.firstIndex(of: equals) {
                    out += part[...sign]
                    if sign + 1 < part.endIndex {
                        out += mask
                        masked = true
                    }
                } else if !part.isEmpty {
                    out += mask
                    masked = true
                }
            }
        }
        if fragmentStart < run.endIndex {
            out.append(hash)
            if fragmentStart + 1 < run.endIndex {
                out += mask
                masked = true
            }
        }
        return (out, masked)
    }

    /// A relationship's count in words: "5 apps", "1 user group", "None", or "showing N of more than N" when the
    /// include's limit cut it (invariant 8).
    static func members(_ count: Int, _ relationship: Blueprint.Relationship, truncated: Bool) -> String {
        if truncated {
            return "Showing \(count.formatted()) of more than \(count.formatted()) \(relationship.noun(2)): "
                + "Apple lists at most \(AppleRead.pageLimit.formatted()) of each with the blueprint."
        }
        return count == 0 ? "None" : "\(count.formatted()) \(relationship.noun(count))"
    }

    /// Why a blueprint's members aren't shown: Apple refused the include, and the blueprint was read without it.
    static func refusal(_ error: AppleAPIError) -> String {
        let said = "Apple refused to include the blueprint's members, so none are shown or counted"
        if case .forbidden = error { return "Your role can't read this: \(said)." }
        return "\(said): \(error.message)"
    }

    /// A custom setting's profile and what to say under it: masked text and how much was masked, or why it isn't shown.
    /// Only `profileText` is read: the raw profile is AbapitKit's alone (invariant 11). A shape this version can't read is
    /// said (`profileProblems`), never shown as no profile.
    static func profile(_ configuration: Configuration) -> (text: String?, note: String?) {
        if let problem = configuration.profileProblems.first {
            return (nil, "The profile isn't shown: Apple sent it in a shape this version can't read (\(problem.rawValue)).")
        }
        switch configuration.customSettings?.profileText {
        case .plist(let text, _, _)?:
            return (text, configuration.customSettings?.profileText?.note ?? "No value in it looked secret, so nothing is masked.")
        case .signed(let bytes)?:
            return (nil, sentence(ProfileText.signed(bytes: bytes).text) + ": its content holds its secrets in the clear.")
        case .notShown(let why)?:
            return (nil, sentence(why) + ".")
        case nil:
            return (nil, configuration.type?.known == .customSetting ? "Apple sent no profile with this custom setting." : nil)
        }
    }

    /// `text` with its first letter capitalized: the profile's reasons are written to follow a colon.
    static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// Every attribute of `view` as text, in Apple's order, each string first through `shown` (a package's addresses)
    /// wherever it sits: in a list, an object, a list of objects (Phase 2b review L2: only a top-level string and a list's
    /// strings went through it, so an address in an object showed raw).
    static func attributes<View: ResourceView>(of view: View, _ shown: (String) -> String = { $0 }) -> [ContentField] {
        view.attributes.keys.map { key in
            let value = view.attributes[key]
            let text: String
            if let string = value?.string {
                text = string.isEmpty ? "—" : shown(string)
            } else if let flag = value?.bool {
                text = flag ? "Yes" : "No"
            } else if let items = value?.array {
                text = items.map { $0.string.map(shown) ?? $0.mappingStrings(shown).jsonText }.joined(separator: ", ")
            } else if let value, value.jsonText != "null" {
                text = value.mappingStrings(shown).jsonText
            } else {
                text = "—"
            }
            return ContentField(key, text)
        }
    }
}

// MARK: Apple's values in words

extension Blueprint.Relationship {
    fileprivate var title: String {
        switch self {
        case .apps: "Apps"
        case .packages: "Packages"
        case .configurations: "Configurations"
        case .orgDevices: "Devices"
        case .users: "Users"
        case .userGroups: "User groups"
        }
    }

    /// The members' noun for `count` of them.
    fileprivate func noun(_ count: Int) -> String {
        let one: String = switch self {
        case .apps: "app"
        case .packages: "package"
        case .configurations: "configuration"
        case .orgDevices: "device"
        case .users: "user"
        case .userGroups: "user group"
        }
        return count == 1 ? one : one + "s"
    }
}

extension SupportedOS {
    fileprivate var title: String {
        switch self {
        case .unspecified: "Unspecified"
        case .iPadOS: "iPadOS"
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        case .visionOS: "visionOS"
        }
    }
}

extension ConfigurationPlatform {
    /// `PLATFORM_IOS` covers iPadOS too (Apple's contract).
    fileprivate var title: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS and iPadOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        }
    }
}

extension BlueprintStatus {
    fileprivate var title: String {
        switch self {
        case .active: "Active"
        case .toBeDeleted: "To be deleted"
        }
    }
}

extension ConfigurationType {
    fileprivate var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .airPrint: "AirPrint"
        case .appAccess: "App access"
        case .appleIntelligenceSiri: "Apple Intelligence and Siri"
        case .applicationLayerFirewall: "Application firewall"
        case .authenticationScreenLock: "Authentication and screen lock"
        case .certificate: "Certificate"
        case .conferenceRoomDisplay: "Conference room display"
        case .contentCaching: "Content caching"
        case .customProfile: "Custom profile"
        case .customSetting: "Custom setting"
        case .dataManagement: "Data management"
        case .energySaver: "Energy saver"
        case .fileVault: "FileVault"
        case .gateKeeper: "Gatekeeper"
        case .iCloud: "iCloud"
        case .loginWindow: "Login window"
        case .mediaManagement: "Media management"
        case .softwareUpdate: "Software update"
        case .vpn: "VPN"
        case .webClip: "Web clip"
        case .webFilter: "Web filter"
        case .wifi: "Wi-Fi"
        }
    }
}
