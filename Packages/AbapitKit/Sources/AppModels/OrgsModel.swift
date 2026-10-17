import AppleBusiness
import Foundation
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

    public init() {}

    /// The editable fields of `profile`, as the editor opens them.
    public init(_ profile: OrgProfile) {
        (name, clientID, keyID, teamID, role) = (profile.name, profile.clientID, profile.keyID, profile.teamID, profile.role)
        scope = profile.scope.known ?? .business
    }

    /// A name, a client ID and a key ID: what an Apple org can't be saved without.
    public var isComplete: Bool {
        [name, clientID, keyID].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
    @ObservationIgnored private var switchHandlers: [@MainActor () -> Void] = []
    /// The ids saves in flight are writing, an Add's new one and an edit's own (one entry per save), and the client
    /// IDs they are writing: two editors open at once never get the same id or both take one client ID (Phase 1b
    /// review, LOW: the second Add replaced the first's key, then its clean-up deleted it), and an Add never takes the
    /// id of an org removed while its edit is saving, which the edit would then have merged onto (verifier round 1).
    @ObservationIgnored private var reservedIDs: [String] = []
    @ObservationIgnored private var reservedClientIDs: [(org: String, client: String)] = []

    public init(storage: Storage, vault: Vault, store: OrgStore? = nil,
                makeClient: @escaping @MainActor (TokenBroker.Account, Double?) -> AppleClient) {
        self.storage = storage
        self.vault = vault
        self.makeClient = makeClient
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
        return profile.problem
            ?? "\(profile.name.isEmpty ? profile.id : profile.name) is a \(profile.provider.rawValue) organization, which this version can't read yet."
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
    /// it, so a probe or a learned rate recorded meanwhile survives; a changed account clears what was learned
    /// about the old one. Its id stays reserved meanwhile, so the profile it merges onto is the org it opened or none.
    /// A save that fails after its key was stored removes the key, and says so if it can't.
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
            if id == nil { try trial.add(Self.merged(draft, onto: opened)) } else { try trial.update(Self.merged(draft, onto: opened)) }
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
        let profile = Self.merged(draft, onto: before ?? opened)
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
        let wasActive = store.active?.id == id
        store.remove(id)
        if wasActive { bump() }
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
        case let error as VaultError: error.guidance
        case let error as OrgStore.Failure: error.message
        case let error as SaveFailure: error.message
        default: "\(error.localizedDescription)"
        }
    }

    /// The editor's fields over `current`. A changed client ID, key ID or scope is another API account: what was
    /// probed and learned belonged to the old one, so its section locks, probe date and rate go (Phase 1b review,
    /// LOW: a changed client ID kept the old account's locks).
    static func merged(_ draft: OrgDraft, onto current: OrgProfile) -> OrgProfile {
        var profile = current
        let otherAccount = isOtherAccount(draft, than: current)
        profile.name = draft.name
        profile.scope = .known(draft.scope)
        profile.clientID = draft.clientID
        profile.keyID = draft.keyID
        profile.teamID = draft.teamID
        profile.role = draft.role
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
