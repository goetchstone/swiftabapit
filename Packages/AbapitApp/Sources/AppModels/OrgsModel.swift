import AppleBusiness
import Foundation
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

    public let vault: Vault
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

    public init(storage: Storage, vault: Vault, store: OrgStore? = nil,
                makeClient: @escaping @MainActor (TokenBroker.Account, Double?) -> AppleClient,
                makeMosyleClient: (@MainActor (String) -> MosyleClient)? = nil) {
        self.storage = storage
        self.vault = vault
        self.makeClient = makeClient
        self.makeMosyleClient = makeMosyleClient
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
            } catch {
                self.store = OrgStore()
                problem = error.message
            }
        } else {
            self.store = OrgStore()
        }
    }

    public var active: OrgProfile? { store.active }

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
        let before = (activeClient?.id, mosyleOrg?.id)
        do {
            try store.move(org, to: target)
        } catch {
            throw .refused(error.message)
        }
        // Only when what the screens read changed: the active client, or the Mosyle org it reads (a move into the client the
        // org is in already changes nothing, and clears nothing).
        if before.0 != activeClient?.id || before.1 != mosyleOrg?.id { bump() }
        save()
    }

    /// The add sheet's question for a new org of `slot`'s kind, or nil when no client has room for one, and it is a client
    /// of its own (the operator, 2026-11-12, "lets do it right"; the details are the parent session's proposal). The options
    /// are each client with room, by name, and a new one. With one client the app shows no client anywhere, so the question
    /// names the org it would join instead.
    public func clientQuestion(adding slot: Client.Slot) -> ClientQuestion? {
        let room = store.clients(withRoomFor: slot)
        guard let first = room.first else { return nil }
        if showsClients {
            return ClientQuestion(title: "Client", prompt: "Which client is this organization for?",
                                  options: room.map { .init(choice: .join($0.id), label: $0.name) } + [.init(choice: .new, label: "A new client")])
        }
        return ClientQuestion(title: "Customer", prompt: "Which customer is this organization for?",
                              options: [.init(choice: .join(first.id), label: "The same customer as \(names(first.orgs))"),
                                        .init(choice: .new, label: "A different customer")])
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
        guard draft.base?.id == id else { throw .refused("This editor was opened for another organization: close it and open it again.") }
        guard id == nil || choice == nil else { throw .refused(Self.editMoves) }
        if let why = draft.problem { throw .refused(why) }
        let orgID: String
        if let id {
            guard let current = store[id] else { throw .refused(OrgStore.Failure.unknownOrg(id).message) }
            guard current.provider == .known(.mosyle) else { throw .refused("\(Self.title(current)) isn't a Mosyle Business organization.") }
            orgID = current.id
        } else {
            let stored: Set<String>
            do {
                stored = Set(try await vault.inventory().keys)
            } catch {
                throw .refused(Self.message(error))
            }
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
        guard draft.isComplete else { throw .refused("A name, a client ID and a key ID are needed.") }
        guard id == nil || choice == nil else { throw .refused(Self.editMoves) }
        let orgID: String
        let opened: OrgProfile
        if let id {
            guard let current = store[id] else { throw .refused(OrgStore.Failure.unknownOrg(id).message) }
            (orgID, opened) = (id, current)
        } else {
            guard key != nil else { throw .refused("Choose the key file Apple gave you for this API account.") }
            // Ids an org removed from orgs.json still holds Keychain items under are taken too: a new org never
            // inherits another's secrets. The inventory is names only: no prompt.
            let stored: Set<String>
            do {
                stored = Set(try await vault.inventory().keys)
            } catch {
                throw .refused(Self.message(error))
            }
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

    /// Removes the org's profile, and with `deleteSecrets` its Keychain items first (defect 14: abapit left
    /// them orphaned). A refused Keychain removal keeps the profile, so the secret stays reachable to remove.
    public func remove(_ id: String, deleteSecrets: Bool) async throws {
        if deleteSecrets { try await vault.remove(org: id) }
        // The Mosyle org the active Apple org is paired with is on screen too: removing it clears what was read from it.
        let wasShown = store.active?.id == id || mosyleOrg?.id == id
        store.remove(id)
        if wasShown { bump() }
        save()
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

    /// An error in the operator's words.
    public static func message(_ error: any Error) -> String {
        switch error {
        case let error as AppleAPIError: error.message
        case let error as MosyleAPIError: error.message
        case let error as VaultError: error.guidance
        case let error as OrgStore.Failure: error.message
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
        guard case .folder(let folder) = storage else { return }
        do {
            try store.save(to: folder)
            problem = nil
        } catch {
            problem = error.message
        }
    }
}
