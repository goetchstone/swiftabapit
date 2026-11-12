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

    /// The Mosyle Business org the Mosyle screens read: the active org when it is one, else the org the active Apple org is
    /// paired with (plan §2.3 defect 17: chosen by the operator, never the first one found), when that is a Mosyle org.
    public var mosyleOrg: OrgProfile? {
        guard let active else { return nil }
        if active.provider == .known(.mosyle) { return active }
        guard active.provider == .known(.apple), let paired = store[active.pairedOrg], paired.provider == .known(.mosyle) else { return nil }
        return paired
    }

    /// The Apple org reconciled against `mosyleOrg`: the active org, when it is an Apple org paired with a Mosyle one.
    /// Reconciliation reads the Apple org's devices through the Devices screen's read, which is the active org's.
    public var reconciles: Bool { active?.provider == .known(.apple) && mosyleOrg != nil }

    /// Why nothing can be read from Mosyle, in words, and whether it is that this org has no Mosyle in scope (`notInScope`:
    /// an Apple org with no Mosyle org paired) or can't be used at all; nil when `mosyleOrg` can be read.
    public var mosyleUnavailable: (why: String, notInScope: Bool)? {
        guard let active else {
            return ("No organization yet: add an Apple Business or Mosyle Business organization in Settings.", false)
        }
        if mosyleOrg != nil { return makeMosyleClient == nil ? ("This build reads no Mosyle Business organization.", false) : nil }
        guard active.provider == .known(.apple) else { return (unusableReason ?? "This organization can't be used.", false) }
        let name = Self.title(active)
        if active.pairedOrg.isEmpty {
            return ("Mosyle Business isn't in scope for \(name): no Mosyle Business organization is paired with it. Pair one in Settings.", true)
        }
        guard let paired = store[active.pairedOrg] else {
            return ("The organization paired with \(name) has been removed. Pair another in Settings.", true)
        }
        return ("\(name) is paired with \(Self.title(paired)), which isn't a Mosyle Business organization. Pair a Mosyle Business one in Settings.", true)
    }

    /// `mosyleOrg`'s client, made once per org and generation; nil when there is none.
    public var mosyleClient: MosyleClient? {
        guard let org = mosyleOrg, let makeMosyleClient else { return nil }
        if let cachedMosyle, cachedMosyle.org == org.id, cachedMosyle.generation == generation { return cachedMosyle.client }
        let client = makeMosyleClient(org.id)
        cachedMosyle = (org.id, generation, client)
        return client
    }

    /// A client for any Mosyle org (Settings → Test on an org not on screen); the one on screen's is shared.
    public func mosyleClient(for profile: OrgProfile) -> MosyleClient? {
        guard profile.provider == .known(.mosyle), let makeMosyleClient else { return nil }
        if profile.id == mosyleOrg?.id { return mosyleClient }
        return makeMosyleClient(profile.id)
    }

    /// Adds a Mosyle Business org (`editing` nil) or applies the editor's fields to one. Everything that can refuse is
    /// checked before any Keychain write; an Add's id is chosen past every id the Keychain still holds items under (a new org
    /// never inherits another's secrets) and reserved while its credentials are written, as `save` does for an Apple org. The
    /// credentials go in as one set (`Vault.replaceSet`: a failure part-way removes the set, never leaves it mixed); an Add
    /// whose profile then can't be saved removes them again. An edit writes only the name it changed, onto the profile as it
    /// is after the Keychain write, and a new set of credentials for the org on screen makes every screen read again.
    @discardableResult
    public func saveMosyle(_ draft: MosyleDraft, editing id: String?) async throws(SaveFailure) -> OrgProfile {
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
            orgID = store.uniqueID(for: draft.name, avoiding: stored.union(reservedIDs))
            var trial = store
            do {
                try trial.add(OrgProfile(id: orgID, name: draft.name, provider: .mosyle))
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
                throw .notSaved("The credentials couldn't be stored: \(Self.message(error)) Nothing was saved\(id == nil ? "" : "; enter them again")")
            }
        }

        let profile: OrgProfile
        do {
            if id == nil {
                profile = OrgProfile(id: orgID, name: draft.name, provider: .mosyle)
                try store.add(profile)
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
                let removal = (error as? VaultError)?.guidance ?? Self.message(error)
                throw .notSaved("\(why) Its credentials were stored and couldn't be removed again (\(removal)) They stay in the Keychain, "
                                + "under an id no new organization will reuse.")
            }
            throw .notSaved(why)
        }
        if id != nil, draft.givesCredentials, store.active?.id == orgID || mosyleOrg?.id == orgID { bump() }
        save()
        return profile
    }

    /// The orgs `id` may be paired with: those of the other provider (an Apple org with a Mosyle one, and back).
    public func pairable(with id: String) -> [OrgProfile] {
        guard let profile = store[id] else { return [] }
        let other: Provider? = switch profile.provider {
        case .known(.apple): .mosyle
        case .known(.mosyle): .apple
        default: nil
        }
        return store.orgs.filter { other != nil && $0.provider == .known(other!) }
    }

    /// Pairs `id` with `other` (nil: unpairs), remembered in `id`'s profile (defect 17). Only an org of the other provider
    /// may be chosen. When it changes the active org's pair, every screen reads again, as an org switch does, so nothing of
    /// the old pair's Mosyle stays on screen.
    public func pair(_ id: String, with other: String?) throws(SaveFailure) {
        guard var profile = store[id] else { throw .refused(OrgStore.Failure.unknownOrg(id).message) }
        if let other, !pairable(with: id).contains(where: { $0.id == other }) {
            throw .refused("\(Self.title(profile)) can be paired only with an organization of the other provider.")
        }
        guard profile.pairedOrg != (other ?? "") else { return }
        profile.pairedOrg = other ?? ""
        do {
            try store.update(profile)
        } catch {
            throw .refused(Self.message(error))
        }
        if store.active?.id == id { bump() }
        save()
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
    /// key was stored removes the key, and says so if it can't.
    @discardableResult
    public func save(_ draft: OrgDraft, key: ImportedKey?, editing id: String?) async throws(SaveFailure) -> OrgProfile {
        guard draft.isComplete else { throw .refused("A name, a client ID and a key ID are needed.") }
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
        var trial = store
        do {
            let tried = Self.merged(draft, onto: opened, withKey: key != nil)
            if id == nil { try trial.add(tried) } else { try trial.update(tried) }
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
                try store.add(profile)
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
