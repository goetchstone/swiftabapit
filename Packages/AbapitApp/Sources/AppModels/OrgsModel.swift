import AppleBusiness
import Foundation
import History
import Mosyle
import Observation
import Orgs
import Vault

/// What the org editor collects (plan §3.4.1); `OrgsModel.save` applies it. Plain text only: the key travels
/// beside it as an `ImportedKey` and goes straight to the Keychain.
public struct OrgDraft: Sendable, Equatable {
    public var name = ""
    public var scope = Scope.business
    public var clientID = ""
    public var keyID = ""
    public var teamID = ""
    public var role = ""
    /// The profile as the editor opened it: `save` writes only the fields changed from it. Nil for an Add.
    let base: OrgProfile?

    public init() { base = nil }

    /// The editable fields of `profile`, as the editor opens them.
    public init(_ profile: OrgProfile) {
        (name, clientID, keyID, teamID, role) = (profile.name, profile.clientID, profile.keyID, profile.teamID, profile.role)
        scope = profile.scope.known ?? .business
        base = profile
    }

    /// A name, a client ID and a key ID: what an Apple org can't be saved without.
    public var isComplete: Bool {
        [name, clientID, keyID].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// What the Mosyle Business org editor collects (plan §4: a name, the access token, the admin's email and password, and the
/// optional Logs Stream token). The credentials are `Secret`s from the moment the editor makes the draft: they never print,
/// dump or mirror (invariant 3), as nothing in the screen models may reflect to hide them (`BoundaryTests`). They are a set
/// (`Vault.replaceSet`): an Add gives the first three, an edit gives all of them again or none, so a stored set is never
/// half old and half new; an empty Logs Stream token in a set given is none, which clears one stored (defect 14: abapit's
/// couldn't be cleared).
public struct MosyleDraft: Sendable, Equatable {
    public let name: String
    public let accessToken: Secret
    public let email: Secret
    public let password: Secret
    public let logsToken: Secret
    /// The profile the editor opened; nil for an Add.
    let base: OrgProfile?

    /// The editor's fields as typed. The token, the email and the Logs Stream token lose surrounding whitespace (a paste's);
    /// a password is kept as typed, unless it is only whitespace, which is none.
    public init(name: String, accessToken: String = "", email: String = "", password: String = "", logsToken: String = "",
                editing base: OrgProfile? = nil) {
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.name = name
        self.accessToken = Secret(trimmed(accessToken))
        self.email = Secret(trimmed(email))
        self.password = Secret(trimmed(password).isEmpty ? "" : password)
        self.logsToken = Secret(trimmed(logsToken))
        self.base = base
    }

    /// Whether any credential was typed.
    public var givesCredentials: Bool { [accessToken, email, password, logsToken].contains { !$0.isEmpty } }

    /// Why it can't be saved yet, in words; nil when it can. An Add needs the three credentials; an edit needs all three
    /// or none.
    public var problem: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A name is needed." }
        let missing = [accessToken, email, password].contains(where: \.isEmpty)
        if base == nil, missing { return "The access token, the admin's email and the password are all needed." }
        if base != nil, givesCredentials, missing {
            return "To change the credentials, enter the access token, the admin's email and the password again, together."
        }
        return nil
    }
}

/// Which client a new org joins: the operator's answer to the add sheet's question (plan §8.0, "Clients").
public enum ClientChoice: Sendable, Hashable {
    /// A client of its own, named after it.
    case new
    /// The client with this id, which must have no org of the new one's kind.
    case join(String)
}

/// The add sheet's question: which customer a new org is for. Asked whenever some client has room for an org of its kind;
/// nothing is chosen until the operator answers (`OrgsModel.clientQuestion`).
public struct ClientQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public let choice: ClientChoice
        public let label: String
        public var id: ClientChoice { choice }
    }

    /// The section's title.
    public let title: String
    /// The question, as the picker's label.
    public let prompt: String
    public let options: [Option]
    /// Why the answer given can't stand, when it no longer can: its client was filled or removed while the sheet was open.
    public var note: String?

    /// Whether `choice` answers the question: one of its options, never none.
    public func accepts(_ choice: ClientChoice?) -> Bool { options.contains { $0.choice == choice } }
}

/// The organizations, which one is active, and its client (plan §3.7). Switching org, or changing the active
/// org's account or key, bumps `generation` and tells every screen model at once (`onSwitch`): each drops what
/// it read for the old org and reads again, and every load checks its own token before it shows a result, so
/// nothing read for one org lands on another's screen (Phase 1b review H2).
@MainActor
@Observable
public final class OrgsModel {
    public enum Storage: Sendable {
        case folder(URL)
        /// The demo: nothing is ever written (plan §4: demo never touches the real config).
        case memory
    }

    /// Why a save didn't happen, and how far it got: the editor keeps the picked key unless it is stored.
    public enum SaveFailure: Error, Equatable {
        /// Refused before anything was written: the Keychain wasn't touched.
        case refused(String)
        /// The Keychain didn't store the key. Adding: nothing was saved. Editing: the settings weren't changed,
        /// but the old key may be gone (a key item is replaced by deleting it first).
        case keyNotStored(VaultError, adding: Bool)
        /// The org couldn't be saved after its key was stored; that key was removed again.
        case notSaved(String)
        /// The org couldn't be saved after its key was stored, and removing that key was refused too: it is still
        /// in the Keychain. Said, never swallowed (Phase 1b review M4: a `try?` clean-up hid it).
        case keyLeftBehind(why: String, removal: VaultError)

        public var message: String {
            switch self {
            case .refused(let why): why
            case .keyNotStored(let error, let adding):
                adding ? error.guidance
                    : "\(error.guidance) The organization's settings weren't changed; choose the key file again so it has a key."
            case .notSaved(let why): why
            case .keyLeftBehind(let why, let removal):
                "\(why) Its key was stored and couldn't be removed again (\(removal.guidance)) It stays in the Keychain, "
                    + "under an id no new organization will reuse."
            }
        }

        /// The key reached the Keychain and stayed there: the editor has no reason to hold its copy.
        public var keyIsStored: Bool { if case .keyLeftBehind = self { true } else { false } }
    }

    public private(set) var store: OrgStore
    public private(set) var generation = 0
    /// Why `orgs.json` couldn't be read or saved, in words; shown in Settings.
    public private(set) var problem: String?
    /// This Mac's settings (`settings.json`, beside `orgs.json`): the Needs-attention thresholds and each client's Mosyle service.
    /// In memory for the demo and the tests, which write nothing. Changed only through `changeSettings`.
    public private(set) var settings = LocalSettings()
    /// Why a client's Mosyle service setting couldn't be dropped when the client lost an org, in words; shown in Settings.
    public private(set) var settingsProblem: String?

    public let vault: Vault
    /// The snapshot history (plan Phase 3), or why it couldn't be opened. A new org's id avoids every id it holds
    /// snapshots or findings under (`takenIDs`), and the snapshot collector records into it. One that failed is opened again
    /// when it is next needed (`openHistory`).
    public private(set) var history: Result<SnapshotStore, SnapshotStore.Failure>
    private let opensHistory: @MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>
    private let storage: Storage
    private let makeClient: @MainActor (TokenBroker.Account, Double?) -> AppleClient
    @ObservationIgnored private var cached: (account: TokenBroker.Account, generation: Int, client: AppleClient)?
    /// Makes a Mosyle Business org's client from its id (its secrets are in the Vault under it); nil where nothing reads Mosyle.
    private let makeMosyleClient: (@MainActor (String) -> MosyleClient)?
    @ObservationIgnored private var cachedMosyle: (org: String, generation: Int, client: MosyleClient)?
    @ObservationIgnored private var switchHandlers: [@MainActor () -> Void] = []
    /// The ids saves in flight are writing, an Add's new one and an edit's own (one entry per save), and the client
    /// IDs they are writing: two editors open at once never get the same id or both take one client ID (Phase 1b
    /// review, LOW: the second Add replaced the first's key, then its clean-up deleted it), and an Add never takes the
    /// id of an org removed while its edit is saving, which the edit would then have merged onto (verifier round 1).
    @ObservationIgnored private var reservedIDs: [String] = []
    @ObservationIgnored private var reservedClientIDs: [(org: String, client: String)] = []
    /// How many Keychain writes saves have finished for each org id, stored or refused. `remove` reads it before and after
    /// its own Keychain removal: a save that finished one meanwhile may have written after its kind was removed, so the
    /// removal runs again (failure-log: "a removal that finished after an edit left the edit's credentials behind").
    @ObservationIgnored private var credentialWrites: [String: Int] = [:]
    /// Why `orgs.json` couldn't be read at launch, when it was there and couldn't: nothing is saved over a file that wasn't
    /// read, and no organization is added, changed or removed until it is moved or repaired. The words are also in `problem`.
    @ObservationIgnored private var unreadable: String?

    /// `history` opens the snapshot history: called once now, and again whenever it is needed while the last try failed.
    public init(storage: Storage, vault: Vault, store: OrgStore? = nil, history: @escaping @MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>,
                makeClient: @escaping @MainActor (TokenBroker.Account, Double?) -> AppleClient,
                makeMosyleClient: (@MainActor (String) -> MosyleClient)? = nil) {
        self.storage = storage
        self.vault = vault
        opensHistory = history
        self.history = history()
        self.makeClient = makeClient
        self.makeMosyleClient = makeMosyleClient
        if case .folder(let folder) = storage { settings = LocalSettings.load(from: folder) }
        if let store {
            self.store = store
        } else if case .folder(let folder) = storage {
            do {
                self.store = try OrgStore.load(from: folder)
                // A version-1 file grouped into clients is saved once, as version 2, atomically: a save that fails leaves the
                // old file as it was, to be grouped the same way next time, and says why in Settings. Only a file that was
                // read: one that couldn't be is never written over (the review of PR 18: one guard stood between an
                // unreadable file and an empty store saved over it).
                if self.store.migrated { save() }
                // A file a newer version wrote is read, never saved: said from launch, not at the first change. A selection
                // made over it is kept in memory only, and its failed save repeats this.
                if self.store.fileVersion > OrgStore.version { problem = OrgStore.Failure.newerVersion(self.store.fileVersion).message }
            } catch {
                self.store = OrgStore()
                problem = error.message
                unreadable = error.message
            }
        } else {
            self.store = OrgStore()
        }
    }

    public var active: OrgProfile? { store.active }

    /// Why nothing can be saved now, asked before any Keychain write: the file wasn't read at launch, or a newer version of the
    /// app wrote it. A change that can't be saved isn't made: its Keychain items would outlive it, under no organization.
    /// Only for a folder: the demo and the tests keep the store in memory.
    var cannotPersist: String? {
        guard case .folder = storage else { return nil }
        if let unreadable { return "\(unreadable) Move or repair that file, then reopen abapit: nothing is saved over a file it couldn't read." }
        if store.fileVersion > OrgStore.version { return OrgStore.Failure.newerVersion(store.fileVersion).message }
        return nil
    }

    /// The folder `orgs.json` lives in, where this Mac's other settings live too (`settings.json`); nil for the demo and the
    /// tests, which keep them in memory and write nothing.
    var folder: URL? { if case .folder(let folder) = storage { folder } else { nil } }

    /// Reads `settings.json` again (a screen about to judge by it), so a hand edit, or a file that can no longer be read, is seen.
    public func reloadSettings() {
        if let folder { settings = LocalSettings.load(from: folder) }
    }

    /// Changes one setting without losing another: the file is read again, so a hand edit since the last read is kept; `change`
    /// is made to that; it is saved, and what was saved is read back and adopted. A file that can't be read is never written over
    /// (its state is adopted, so a screen says why) and a change that is refused changes nothing. In memory for the demo and the
    /// tests, checked as a save would check it. A change that changes nothing writes nothing.
    public func changeSettings(_ change: (inout LocalSettings) throws(LocalSettings.Failure) -> Void) throws(LocalSettings.Failure) {
        guard let folder else {
            var changed = settings
            try change(&changed)
            try changed.check()
            settings = changed
            return
        }
        var fresh = LocalSettings.load(from: folder)
        if let blocked = fresh.blocked {
            settings = fresh
            throw blocked
        }
        let before = fresh
        try change(&fresh)
        if fresh != before { try fresh.save(to: folder) }
        settings = LocalSettings.load(from: folder)
    }

    /// A client lost an org (removed, or moved out of it), was made by a move, or had its Mosyle org's credentials replaced (new
    /// credentials may be another tenant's under the same org id): its Mosyle service setting, made for the client as it was, is
    /// dropped (the coordinating session's decisions). An org added into an existing client drops nothing: that client couldn't have
    /// had a usable entry (it had no org of that kind), and a leftover one names another Mosyle org, so it reads as stale. It runs
    /// after the org change, which is whole or not at all on its own, and only when that change was made. A settings file that can't
    /// be written keeps the entry, said here; an entry left that names another Mosyle org still reads as stale on the
    /// Needs-attention screen, and one whose service Apple no longer lists, too.
    private func dropMosyleServices(of clients: [String]) {
        let clients = clients.filter { !$0.isEmpty }
        guard !clients.isEmpty else { return }
        do {
            try changeSettings { (settings: inout LocalSettings) throws(LocalSettings.Failure) in
                for client in clients { settings.dropMosyleService(for: client) }
            }
            settingsProblem = nil
        } catch {
            settingsProblem = "The Mosyle service setting of the customer whose organizations changed couldn't be removed: \(error.message)"
        }
    }

    /// The active org's Apple client, made once per account and generation; nil for a profile that can't be used.
    /// Keyed by the account itself, so an edited team ID or client ID never reuses the old account's client.
    public var appleClient: AppleClient? {
        guard let profile = active, let account = TokenBroker.Account(profile) else { return nil }
        if let cached, cached.account == account, cached.generation == generation { return cached.client }
        let client = makeClient(account, profile.learnedReadsPerMinute > 0 ? profile.learnedReadsPerMinute : nil)
        cached = (account, generation, client)
        return client
    }

    /// Why the active org can't be read, in words; nil when it can, or when there's no org.
    public var unusableReason: String? {
        guard let profile = active, TokenBroker.Account(profile) == nil else { return nil }
        if profile.provider == .known(.mosyle) {
            return "\(Self.title(profile)) is a Mosyle Business organization: Apple Business's and Apple School Manager's screens don't read it."
        }
        return profile.problem
            ?? "\(Self.title(profile)) is a \(profile.provider.rawValue) organization, which this version can't read yet."
    }

    /// An org's name in a sentence: its name, else its id.
    static func title(_ profile: OrgProfile) -> String { profile.name.isEmpty ? profile.id : profile.name }

    // MARK: Mosyle Business

    /// The Mosyle Business org the Mosyle screens read: the active org when it is one, else the active client's MDM org, when
    /// that is a Mosyle org (plan §8.0, "Clients": an Apple org and its MDM org belong to one client; the operator, 2026-11-12).
    public var mosyleOrg: OrgProfile? {
        guard let active else { return nil }
        if active.provider == .known(.mosyle) { return active }
        guard active.provider == .known(.apple), let mdm = store.client(of: active.id)?.mdm, let org = store[mdm],
              org.provider == .known(.mosyle) else { return nil }
        return org
    }

    /// The Apple org reconciled against `mosyleOrg`: the active org, when it is an Apple org whose client has a Mosyle org.
    /// Reconciliation reads the Apple org's devices through the Devices screen's read, which is the active org's.
    public var reconciles: Bool { active?.provider == .known(.apple) && mosyleOrg != nil }

    /// Why nothing can be read from Mosyle, in words, and whether it is that this org has no Mosyle in scope (`notInScope`:
    /// an Apple org whose client has no Mosyle org) or can't be used at all; nil when `mosyleOrg` can be read.
    public var mosyleUnavailable: (why: String, notInScope: Bool)? {
        guard let active else {
            return ("No organization yet: add an Apple Business or Mosyle Business organization in Settings.", false)
        }
        if mosyleOrg != nil { return makeMosyleClient == nil ? ("This build reads no Mosyle Business organization.", false) : nil }
        guard active.provider == .known(.apple) else { return (unusableReason ?? "This organization can't be used.", false) }
        let name = Self.title(active)
        if let mdm = store.client(of: active.id)?.mdm, let org = store[mdm] {
            return ("\(name)'s MDM organization, \(Self.title(org)), isn't a Mosyle Business organization this version reads.", true)
        }
        return ("Mosyle Business isn't in scope for \(name): no Mosyle Business organization is set up with it. Add one in Settings.", true)
    }

    // MARK: Clients

    /// The clients, in the store's order (plan §8.0, "Clients"). With one, nothing on screen says so: the app looks as it did.
    public var clients: [Client] { store.clients }

    /// Whether the app shows clients at all: only with two or more (the operator, 2026-11-12).
    public var showsClients: Bool { store.clients.count >= 2 }

    /// The active org's client.
    public var activeClient: Client? { store.activeClient }

    /// The active client's orgs, its Apple org first: what the organization picker offers. Every screen reads one client.
    public var clientOrgs: [OrgProfile] { activeClient.map { $0.orgs.compactMap { store[$0] } } ?? store.orgs }

    /// The client an export is named for: the active client's name when the app shows clients, else nil (one client, no
    /// client anywhere on screen). No export holds more than one client's data.
    public var exportClient: String? { showsClients ? activeClient?.name : nil }

    /// Switches to the client `id`: its Apple org, else its MDM org, becomes active, and every screen, selection and read is
    /// cleared and read again, as an org switch does.
    public func selectClient(_ id: String) {
        // The client on screen already: nothing changes (a picker that sends its current value again clears nothing).
        guard id != activeClient?.id, let client = store[client: id], let org = client.apple ?? client.mdm else { return }
        select(org)
    }

    /// Moves an org to another client (nil: a client of its own). When it changes what the screens read, they read again.
    public func move(_ org: String, toClient target: String?) throws(SaveFailure) {
        if let why = cannotPersist { throw .refused(why) }
        let before = (activeClient?.id, mosyleOrg?.id)
        let from = store.client(of: org)?.id
        do {
            try store.move(org, to: target)
        } catch {
            throw .refused(error.message)
        }
        // Only when what the screens read changed: the active client, or the Mosyle org it reads (a move into the client the
        // org is in already changes nothing, and clears nothing).
        if before.0 != activeClient?.id || before.1 != mosyleOrg?.id { bump() }
        save()
        // The client it left and the one it is in now (joined, or made for it, on an id that may have been another's) each changed:
        // their Mosyle service settings go.
        let to = store.client(of: org)?.id
        if from != to { dropMosyleServices(of: [from, to].compactMap { $0 }) }
    }

    /// The add sheet's question for a new org of `slot`'s kind, given the sheet's `answer` so far; nil when no client has room
    /// for one and none was chosen: then it is a client of its own (the operator, 2026-11-12, "lets do it right"; the details
    /// are the parent session's proposal). The options are each client with room, by name, and a new one. With one client the
    /// app shows no client anywhere, so the question names the org it would join instead, and never says "client".
    ///
    /// An answer whose client was filled or removed while the sheet was open is never taken for another (the review of PR 19:
    /// the sheet sent it as no answer, and the org became a different customer's, the opposite of what was chosen). The
    /// question stays, with a note, and Add waits until the operator chooses again.
    public func clientQuestion(adding slot: Client.Slot, answer: ClientChoice? = nil) -> ClientQuestion? {
        let room = store.clients(withRoomFor: slot)
        var stale = false
        if case .join? = answer { stale = !room.contains { ClientChoice.join($0.id) == answer } }
        guard !room.isEmpty || stale else { return nil }
        var question: ClientQuestion
        if showsClients {
            question = ClientQuestion(title: "Client", prompt: "Which client is this organization for?",
                                      options: room.map { .init(choice: .join($0.id), label: $0.name) } + [.init(choice: .new, label: "A new client")])
        } else {
            question = ClientQuestion(title: "Customer", prompt: "Which customer is this organization for?",
                                      options: room.prefix(1).map { .init(choice: .join($0.id), label: "The same customer as \(names($0.orgs))") }
                                          + [.init(choice: .new, label: "A different customer")])
        }
        if stale { question.note = "The \(showsClients ? "client" : "customer") you chose can't take this organization any more: choose again." }
        return question
    }

    /// The other orgs in `org`'s client, in words ("Grouped with …"), or nil when it is alone in its client. Settings says it
    /// with one client too, so a join can always be seen and undone (`move(_:toClient:)` with nil).
    public func grouping(of org: String) -> String? {
        guard let client = store.client(of: org) else { return nil }
        let others = client.orgs.filter { $0 != org }
        return others.isEmpty ? nil : "Grouped with \(names(others))"
    }

    /// Orgs' names in a sentence, in the order given.
    private func names(_ ids: [String]) -> String {
        ids.compactMap { store[$0] }.map(Self.title).joined(separator: " and ")
    }

    /// The client an Add joins (nil: a client of its own), from the sheet's answer. No answer while some client has room for
    /// the org is refused, never taken for "a new client": the sheet asks then, and an org is never placed unasked.
    private func target(_ choice: ClientChoice?, adding slot: Client.Slot) throws(SaveFailure) -> String? {
        switch choice {
        case .join(let id)?: return id
        case .new?: return nil
        case nil:
            guard store.clients(withRoomFor: slot).isEmpty else { throw .refused(Self.unanswered) }
            return nil
        }
    }

    static let unanswered = "Choose which customer this organization is for."

    /// An edit never moves an org: Settings does (the draft and the call must agree, as an Add's must).
    static let editMoves = "An edit doesn't change which customer an organization is for: change that in Settings."

    public func renameClient(_ id: String, to name: String) throws(SaveFailure) {
        if let why = cannotPersist { throw .refused(why) }
        do {
            try store.renameClient(id, to: name)
        } catch {
            throw .refused(error.message)
        }
        save()
    }

    /// The note a School org's screens carry until a school has tested them (`ScreenWords.schoolUnverified`); nil otherwise.
    public var unverifiedNote: String? {
        active?.provider == .known(.apple) && active?.scope == .known(.school) ? ScreenWords.schoolUnverified : nil
    }

    /// What grouping the old file into clients changed, to be said once (Settings).
    public var migrationNotes: [String] { store.migrationNotes }

    /// The notes have been read: they go, with the old pairings they spoke of.
    public func dismissMigrationNotes() {
        store.dismissMigrationNotes()
        save()
    }

    /// `mosyleOrg`'s client, made once per org and generation; nil when there is none.
    public var mosyleClient: MosyleClient? {
        guard let org = mosyleOrg, let makeMosyleClient else { return nil }
        if let cachedMosyle, cachedMosyle.org == org.id, cachedMosyle.generation == generation { return cachedMosyle.client }
        let client = makeMosyleClient(org.id)
        cachedMosyle = (org.id, generation, client)
        return client
    }

    /// A new client for a Mosyle org, never the one on screen's: Settings' Test logs in afresh with what the Keychain holds, so
    /// it proves the stored credentials, not a login kept in memory (the review of PR 17: after a refused edit had removed the
    /// credentials, Test on the org on screen still said "Connected", with no login).
    public func mosyleClient(for profile: OrgProfile) -> MosyleClient? {
        guard profile.provider == .known(.mosyle), let makeMosyleClient else { return nil }
        return makeMosyleClient(profile.id)
    }

    /// Adds a Mosyle Business org (`editing` nil) or applies the editor's fields to one (plan §4, defects 10 and 14).
    ///
    /// - Everything that can refuse is checked before any Keychain write, the draft's own org among it: an edit's draft is
    ///   saved only onto the org it opened, an Add's only as an Add (the review: an edit's draft saved as an Add skipped the
    ///   Add's credential rule).
    /// - An Add's id is past every id the Keychain still holds items under and every save in flight; it stays reserved
    ///   while its credentials are written, as `save` does for an Apple org. It joins the client `choice` names, or is a
    ///   client of its own; with no answer while some client has room for it, it is refused (`clientQuestion`). The answer
    ///   is checked before the Keychain write and again when the org is added, so a client filled or removed meanwhile
    ///   refuses it, and its credentials go again.
    /// - The credentials go in as one set (`Vault.replaceSet`), whole or absent: a write that fails part-way removes the set,
    ///   the credentials stored before an edit included, rather than leave old and new mixed. What the Keychain then holds is
    ///   read back (names only, no prompt) and said, never "nothing was saved" over what stayed (the review's M1 and M3), and
    ///   an edit of the org on screen reads every screen again, so nothing goes on reading with the old login.
    /// - An edit whose org was removed while its credentials were written removes them again (the review's M2: they stayed
    ///   under an id no org has); an Add whose profile can't be saved does the same.
    /// - An edit writes only the name it changed, onto the profile as it is after the Keychain write.
    /// - An org on screen reads again: an Add that becomes the active org, or an edit with new credentials.
    @discardableResult
    public func saveMosyle(_ draft: MosyleDraft, editing id: String?, client choice: ClientChoice? = nil) async throws(SaveFailure) -> OrgProfile {
        if let why = cannotPersist { throw .refused(why) }
        guard draft.base?.id == id else { throw .refused("This editor was opened for another organization: close it and open it again.") }
        guard id == nil || choice == nil else { throw .refused(Self.editMoves) }
        if let why = draft.problem { throw .refused(why) }
        let orgID: String
        if let id {
            guard let current = store[id] else { throw .refused(OrgStore.Failure.unknownOrg(id).message) }
            guard current.provider == .known(.mosyle) else { throw .refused("\(Self.title(current)) isn't a Mosyle Business organization.") }
            orgID = current.id
        } else {
            let stored = try await takenIDs()
            // No await between choosing the id and reserving it below: two Adds can't both take it.
            orgID = store.uniqueID(for: draft.name, avoiding: stored.union(reservedIDs))
            let joining = try target(choice, adding: .mdm)
            var trial = store
            do {
                try trial.add(OrgProfile(id: orgID, name: draft.name, provider: .mosyle), to: joining)
            } catch {
                throw .refused(Self.message(error))
            }
        }
        guard VaultItem(org: orgID, kind: .mosyleAccessToken) != nil else { throw .refused("That name can't be used.") }
        reservedIDs.append(orgID)
        defer { if let index = reservedIDs.firstIndex(of: orgID) { reservedIDs.remove(at: index) } }

        if draft.givesCredentials {
            do {
                defer { credentialWrites[orgID, default: 0] += 1 }
                try await vault.replaceSet([
                    .mosyleAccessToken: draft.accessToken, .mosyleEmail: draft.email, .mosylePassword: draft.password,
                    .mosyleLogsToken: draft.logsToken.isEmpty ? nil : draft.logsToken,
                ], for: orgID)
            } catch {
                let failure = await credentialsNotStored(error, org: orgID, adding: id == nil)
                if id != nil, store.active?.id == orgID || mosyleOrg?.id == orgID { bump() }
                throw failure
            }
        }

        // Removed while its credentials were written: they go again, so none stays under an id no org has.
        if id != nil, store[orgID] == nil {
            guard draft.givesCredentials else { throw .notSaved(OrgStore.Failure.unknownOrg(orgID).message) }
            do {
                try await vault.remove(org: orgID)
            } catch {
                throw .notSaved("The organization was removed while its credentials were being saved, and removing them again was refused "
                                + "(\(Self.message(error))) They stay in the Keychain, under an id no new organization will reuse.")
            }
            throw .notSaved("The organization was removed while its credentials were being saved, so they were removed again.")
        }

        let profile: OrgProfile
        do {
            if id == nil {
                profile = OrgProfile(id: orgID, name: draft.name, provider: .mosyle)
                try store.add(profile, to: try target(choice, adding: .mdm))
            } else {
                guard var current = store[orgID] else { throw OrgStore.Failure.unknownOrg(orgID) }
                if draft.base?.name != draft.name { current.name = draft.name }
                try store.update(current)
                profile = current
            }
        } catch {
            let why = Self.message(error)
            guard id == nil else { throw .notSaved(why) }
            do {
                try await vault.remove(org: orgID)
            } catch {
                throw .notSaved("\(why) Its credentials were stored and couldn't be removed again (\(Self.message(error))) They stay in "
                                + "the Keychain, under an id no new organization will reuse.")
            }
            throw .notSaved(why)
        }
        let shown = store.active?.id == orgID || mosyleOrg?.id == orgID
        if shown, id == nil || draft.givesCredentials { bump() }
        save()
        // New credentials may be another tenant's under the same org id: its client's Mosyle service setting goes (the coordinating
        // session's decision), as the other drops do, after the change.
        if id != nil, draft.givesCredentials, let client = store.client(of: orgID)?.id { dropMosyleServices(of: [client]) }
        return profile
    }

    /// Why a set of credentials wasn't stored, and what the Keychain holds for the org now, read back by name (no prompt).
    private func credentialsNotStored(_ error: any Error, org: String, adding: Bool) async -> SaveFailure {
        let why = Self.message(error)
        let left: Set<VaultItem.Kind>?
        do {
            left = try await vault.inventory()[org] ?? []
        } catch {
            left = nil
        }
        let names: [VaultItem.Kind: String] = [.mosyleAccessToken: "the access token", .mosyleEmail: "the admin's email",
                                               .mosylePassword: "the password", .mosyleLogsToken: "the Logs Stream token"]
        let stayed = left.map { $0.sorted().compactMap { names[$0] }.joined(separator: ", ") }
        if adding {
            switch stayed {
            case ""?: return .notSaved("The credentials couldn't be stored: \(why) Nothing was saved.")
            case let stayed?:
                return .notSaved("The credentials couldn't be stored: \(why) Removing them again was refused, so \(stayed) stayed in the "
                                 + "Keychain, under an id no new organization will reuse. The organization wasn't added.")
            case nil:
                return .notSaved("The credentials couldn't be stored: \(why) What stayed in the Keychain couldn't be read; anything there is "
                                 + "under an id no new organization will reuse. The organization wasn't added.")
            }
        }
        switch stayed {
        case ""?:
            return .notSaved("The new credentials couldn't be stored: \(why) The ones stored before were removed with them, as a set is "
                             + "never left half old and half new. Enter them all again before this organization can be read.")
        case let stayed?:
            return .notSaved("The new credentials couldn't be stored: \(why) Removing them all was refused, so \(stayed) stayed, old or new. "
                             + "Enter them all again before this organization can be read.")
        case nil:
            return .notSaved("The new credentials couldn't be stored: \(why) What stayed in the Keychain couldn't be read. Enter them all "
                             + "again before this organization can be read.")
        }
    }

    /// A client for any org (Settings → Test and Permissions on an org that isn't active); the active org's is shared.
    public func client(for profile: OrgProfile) -> AppleClient? {
        if profile.id == active?.id { return appleClient }
        guard let account = TokenBroker.Account(profile) else { return nil }
        return makeClient(account, nil)
    }

    /// Runs `handler` whenever `generation` changes, before the call that changed it returns: the screen models
    /// clear and reload there, so no view has to remember to (Phase 1b review H2).
    public func onSwitch(_ handler: @escaping @MainActor () -> Void) {
        switchHandlers.append(handler)
    }

    public func select(_ id: String) {
        guard store[id] != nil, store.active?.id != id else { return }
        store.activeID = id
        bump()
        save()
    }

    /// Adds an org (`editing` nil) or applies the editor's fields to one, storing `key` as its Apple key.
    ///
    /// Everything that can refuse is checked before any Keychain write: the fields, the id, the client ID against
    /// every org and every save in flight (Phase 1b review M4: a duplicate client ID was found only after the old
    /// key was deleted). An edit merges onto the profile as it is once the key is stored, not as the editor opened
    /// it, and writes only the fields the operator changed (`merged`), so a probe, a learned rate or another sheet's
    /// save that landed meanwhile survives; a changed account clears what was learned about the old one. Its id stays
    /// reserved meanwhile, so the profile it merges onto is the org it opened or none. A save that fails after its
    /// key was stored removes the key, and says so if it can't. An Add joins the client `choice` names, as `saveMosyle`'s
    /// does, and is refused with no answer while some client has room for an Apple org.
    @discardableResult
    public func save(_ draft: OrgDraft, key: ImportedKey?, editing id: String?, client choice: ClientChoice? = nil) async throws(SaveFailure) -> OrgProfile {
        if let why = cannotPersist { throw .refused(why) }
        guard draft.isComplete else { throw .refused("A name, a client ID and a key ID are needed.") }
        guard id == nil || choice == nil else { throw .refused(Self.editMoves) }
        let orgID: String
        let opened: OrgProfile
        if let id {
            guard let current = store[id] else { throw .refused(OrgStore.Failure.unknownOrg(id).message) }
            (orgID, opened) = (id, current)
        } else {
            guard key != nil else { throw .refused("Choose the key file Apple gave you for this API account.") }
            let stored = try await takenIDs()
            // No await between choosing the id and reserving it below: two Adds can't both take it.
            orgID = store.uniqueID(for: draft.name, avoiding: stored.union(reservedIDs))
            opened = OrgProfile(id: orgID, name: draft.name, provider: .apple)
        }
        guard let item = VaultItem(org: orgID, kind: .appleKey) else { throw .refused("That name can't be used.") }
        let client = Self.clientKey(draft.clientID)
        if reservedClientIDs.contains(where: { $0.client == client && $0.org != orgID }) {
            throw .refused(OrgStore.Failure.duplicateClientID(draft.clientID).message)
        }
        let joining = try id == nil ? target(choice, adding: .apple) : nil
        var trial = store
        do {
            let tried = Self.merged(draft, onto: opened, withKey: key != nil)
            if id == nil { try trial.add(tried, to: joining) } else { try trial.update(tried) }
        } catch {
            throw .refused(Self.message(error))
        }
        reservedIDs.append(orgID)
        reservedClientIDs.append((orgID, client))
        defer {
            if let index = reservedIDs.firstIndex(of: orgID) { reservedIDs.remove(at: index) }
            if let index = reservedClientIDs.firstIndex(where: { $0.org == orgID && $0.client == client }) { reservedClientIDs.remove(at: index) }
        }

        if let key {
            do {
                defer { credentialWrites[orgID, default: 0] += 1 }
                try await vault.storeKey(key, as: item)
            } catch {
                throw .keyNotStored(error as? VaultError ?? .keyNotUsable, adding: id == nil)
            }
        }

        // The profile as it is now: storing the key was an await, and a probe or a learned rate may have landed meanwhile.
        let before = id.flatMap { store[$0] }
        let profile = Self.merged(draft, onto: before ?? opened, withKey: key != nil)
        do {
            if id == nil {
                try store.add(profile, to: try target(choice, adding: .apple))
            } else {
                guard before != nil else { throw OrgStore.Failure.unknownOrg(orgID) }
                try store.update(profile)
            }
        } catch {
            let why = Self.message(error)
            guard key != nil else { throw .notSaved(why) }
            guard id == nil || store[orgID] == nil else {
                // The reservations make this unreachable; were it reached, the mismatch is said, not left silent.
                throw .notSaved("\(why) The new key was stored but the settings weren't: edit the organization again so they match.")
            }
            // Whole or absent: an org that couldn't be saved leaves no key behind.
            do {
                try await vault.remove(org: orgID)
            } catch {
                throw .keyLeftBehind(why: why, removal: error as? VaultError ?? .keyNotUsable)
            }
            throw .notSaved(why)
        }
        let accountChanged = before.map { TokenBroker.Account($0) != TokenBroker.Account(profile) } ?? true
        if store.active?.id == orgID, accountChanged || key != nil { bump() }
        save()
        return profile
    }

    /// The ids a new org can't take besides the store's own: every id an org removed from orgs.json still holds Keychain
    /// items under (a new org never inherits another's secrets; the inventory is names only, no prompt), and every id the
    /// snapshot history holds snapshots or findings under, since ids are slugs of names and come round again: a new org never
    /// inherits a removed org's history, which could be another customer's (docs/domains/history.md). The history is opened
    /// again here if it failed before, so a failure at launch doesn't hold for the session; one that still can't be opened
    /// refuses the Add, saying why and what to do: its ids can't be checked.
    private func takenIDs() async throws(SaveFailure) -> Set<String> {
        let stored: Set<String>
        do {
            stored = Set(try await vault.inventory().keys)
        } catch {
            throw .refused(Self.message(error))
        }
        switch openHistory() {
        case .failure(let failure):
            throw .refused(Self.historyUnopened(failure))
        case .success(let snapshots):
            do {
                return stored.union(try await snapshots.orgIDs())
            } catch {
                throw .refused(error.message)
            }
        }
    }

    /// The snapshot history, opened again if the last try failed (the file moved aside or fixed since).
    public func openHistory() -> Result<SnapshotStore, SnapshotStore.Failure> {
        if case .failure = history { history = opensHistory() }
        return history
    }

    /// Why an Add was refused when the history can't be opened, with what to do.
    static func historyUnopened(_ failure: SnapshotStore.Failure) -> String {
        "A new organization's id can't be checked against the snapshot history, which couldn't be opened: \(failure.message) "
            + "Fix what that names, or move history.sqlite out of the app's Application Support folder, then add the organization again: "
            + "the history is opened again at each Add."
    }

    /// Removes the org's profile, and with `deleteSecrets` its Keychain items first (defect 14: abapit left
    /// them orphaned). A refused Keychain removal keeps the profile, so the secret stays reachable to remove. Its snapshot
    /// history stays, and its id with it (no new org takes it, `takenIDs`), unless `deleteHistory` is set: the operator's
    /// yes to "delete its history too" (`removeAll(org:)`, which can't be undone). The history goes first, so one that
    /// can't be deleted (a file a newer version wrote, one that won't open) refuses the removal and leaves the org, its key
    /// and its history as they were.
    public func remove(_ id: String, deleteSecrets: Bool, deleteHistory: Bool = false) async throws {
        // First: the history's deletion can't be undone either.
        if let why = cannotPersist { throw SaveFailure.refused(why) }
        // A write for this history in flight (a snapshot past its last check, an import into another org of the client) could land
        // after the deletion: refused, in words. Removing the org and keeping its history stays allowed.
        if deleteHistory, let why = historyDeletionBlocked { throw SaveFailure.refused(why) }
        if deleteHistory, let profile = store[id] {
            switch openHistory() {
            case .success(let opened): try await opened.removeAll(org: profile)
            case .failure(let failure): throw failure
            }
        }
        if deleteSecrets {
            // A save that finished a Keychain write while these were being removed wrote after its kind was removed: remove
            // again until none landed meanwhile, so nothing stays under an id no org has. A save still inside its write
            // finds the org gone afterwards and removes its own (`saveMosyle`, `save`). No await between the last
            // comparison and `store.remove` below.
            var seen: Int
            repeat {
                seen = credentialWrites[id, default: 0]
                try await vault.remove(org: id)
            } while credentialWrites[id, default: 0] != seen
        }
        // The Mosyle org the active Apple org is paired with is on screen too: removing it clears what was read from it.
        let wasShown = store.active?.id == id || mosyleOrg?.id == id
        let client = store.client(of: id)?.id
        store.remove(id)
        if wasShown { bump() }
        save()
        // The client lost an org, or is gone: its Mosyle service setting goes with it.
        dropMosyleServices(of: [client].compactMap { $0 })
    }

    /// What Settings' removal says of the org's snapshot history: that it is kept unless the operator deletes it too, and that
    /// deleting it can't be undone. `snapshots` is `historySnapshots(of:)`'s answer.
    public static func removalHistoryNote(snapshots: Int?) -> String {
        switch snapshots {
        case nil: "Its snapshot history couldn't be read, so it is kept."
        case 0?: "It has no snapshots in this Mac's history."
        case let count?:
            "Its \(count.formatted()) snapshot\(count == 1 ? "" : "s") in this Mac's history stay unless you delete them too, with its Needs-attention findings. Deleting them can't be undone: no copy is kept."
        }
    }

    /// Why the history can't be deleted now: a snapshot is being taken, or an import or export is running (the screens' models set
    /// `historyBusy`). Nil when nothing is writing to it.
    public var historyDeletionBlocked: String? { historyBusy?() }

    /// Set by `ScreenModels`: the words for a write to the history in flight, nil when none is.
    @ObservationIgnored public var historyBusy: (@MainActor () -> String?)?

    /// How many snapshots the org's history holds, for the question Settings asks when it is removed; nil when the history
    /// can't be read (the question then says so and offers no deletion).
    public func historySnapshots(of id: String) async -> Int? {
        guard let profile = store[id], case .success(let opened) = openHistory() else { return nil }
        return try? await opened.count(org: profile)
    }

    /// What Settings → Permissions found, kept so sections show locked without probing again. `probed` is the
    /// profile as the probe started: if the org was edited to another account while the probe ran, the results
    /// are the old account's and are dropped, so they never put back the locks that edit cleared (the first fix's
    /// open item).
    public func record(_ results: [ProbeResult], probed: OrgProfile, at date: Date = Date()) {
        guard var profile = store[probed.id], !Self.isOtherAccount(OrgDraft(probed), than: profile) else { return }
        profile.capabilities = Dictionary(uniqueKeysWithValues: results.map { ($0.section.rawValue, $0.status) })
        profile.probedAt = ISO8601DateFormatter().string(from: date)
        try? store.update(profile)
        save()
    }

    /// The rate the limiter learned, so the next launch starts there.
    public func record(readsPerMinute: Double, for id: String) {
        guard var profile = store[id], readsPerMinute.isFinite, abs(profile.learnedReadsPerMinute - readsPerMinute) >= 1 else { return }
        profile.learnedReadsPerMinute = readsPerMinute
        try? store.update(profile)
        save()
    }

    /// Settings' Test of a Mosyle org, in words: a login and the first page of Macs with `client` (a fresh one,
    /// `mosyleClient(for:)`), and which device columns Mosyle refused and which it took, after a failure too: the live check
    /// of 2026-11-19 showed only "400".
    public static func testMosyle(_ client: MosyleClient) async -> String {
        do {
            try await client.ping()
            let columns = await client.columns
            return "Connected: the token, the admin account and the network work. " + (columns?.words ?? MosyleColumns.allTaken)
        } catch {
            let columns = await client.columns
            return [message(error), columns?.words].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// An error in the operator's words.
    public static func message(_ error: any Error) -> String {
        switch error {
        case let error as AppleAPIError: error.message
        case let error as MosyleAPIError: error.message
        case let error as VaultError: error.guidance
        case let error as OrgStore.Failure: error.message
        case let error as SnapshotStore.Failure: error.message
        case let error as SaveFailure: error.message
        default: "\(error.localizedDescription)"
        }
    }

    /// The editor's changes over `current`: only what the operator changed from the profile the sheet opened with
    /// (`draft.base`; an Add writes everything), so a sheet opened before another's save never writes that save's
    /// fields back (verifier round 2: two sheets on one org, and the later save put the earlier one's old name back).
    /// The account's four fields go together, and always with a picked key, which belongs to the IDs it was picked
    /// with. A changed client ID, key ID or scope is another API account: what was probed and learned belonged to
    /// the old one, so its section locks, probe date and rate go (Phase 1b review, LOW: a changed client ID kept the
    /// old account's locks).
    static func merged(_ draft: OrgDraft, onto current: OrgProfile, withKey: Bool) -> OrgProfile {
        var profile = current
        let base = draft.base?.id == current.id ? draft.base : nil
        if base?.name != draft.name { profile.name = draft.name }
        if base?.role != draft.role { profile.role = draft.role }
        let accountEdited = base.map {
            $0.scope != .known(draft.scope) || $0.clientID != draft.clientID || $0.keyID != draft.keyID || $0.teamID != draft.teamID
        } ?? true
        guard withKey || accountEdited else { return profile }
        let otherAccount = isOtherAccount(draft, than: current)
        profile.scope = .known(draft.scope)
        profile.clientID = draft.clientID
        profile.keyID = draft.keyID
        profile.teamID = draft.teamID
        if otherAccount {
            if !profile.capabilities.isEmpty { profile.capabilities = [:] }
            profile.probedAt = ""
            profile.learnedReadsPerMinute = 0
        }
        return profile
    }

    /// Whether `draft` names another API account than `profile`: a changed client ID, key ID or scope.
    static func isOtherAccount(_ draft: OrgDraft, than profile: OrgProfile) -> Bool {
        clientKey(profile.clientID) != clientKey(draft.clientID)
            || profile.keyID.trimmingCharacters(in: .whitespacesAndNewlines) != draft.keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            || profile.scope != .known(draft.scope)
    }

    /// Client IDs compare as `OrgStore` compares them: trimmed, case-insensitive.
    static func clientKey(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func bump() {
        generation += 1
        cached = nil
        cachedMosyle = nil
        for handler in switchHandlers { handler() }
    }

    private func save() {
        // Never over a file that wasn't read: what the load said stays in `problem`.
        guard case .folder(let folder) = storage, unreadable == nil else { return }
        do {
            try store.save(to: folder)
            problem = nil
        } catch {
            problem = error.message
        }
    }
}
