import AppleBusiness
import Foundation
import Observation
import Orgs
import Vault

/// The organizations, which one is active, and its client (plan §3.7). Switching org, or changing the active
/// org's account, bumps `generation`: every screen's load compares it before showing a result, so nothing
/// read for one org lands on another's screen.
@Observable
final class OrgsModel {
    enum Storage {
        case folder(URL)
        /// The demo: nothing is ever written (plan §4: demo never touches the real config).
        case memory
    }

    private(set) var store: OrgStore
    private(set) var generation = 0
    /// Why `orgs.json` couldn't be read or saved, in words; shown in Settings.
    private(set) var problem: String?

    let vault: Vault
    private let storage: Storage
    private let makeClient: (TokenBroker.Account, Double?) -> AppleClient
    private var cached: (key: String, client: AppleClient)?

    init(storage: Storage, vault: Vault, store: OrgStore? = nil,
         makeClient: @escaping (TokenBroker.Account, Double?) -> AppleClient) {
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

    var active: OrgProfile? { store.active }

    /// The active org's Apple client, made once per org and generation; nil for a profile that can't be used.
    var appleClient: AppleClient? {
        guard let profile = active, let account = TokenBroker.Account(profile) else { return nil }
        let key = "\(profile.id)#\(generation)"
        if let cached, cached.key == key { return cached.client }
        let client = makeClient(account, profile.learnedReadsPerMinute > 0 ? profile.learnedReadsPerMinute : nil)
        cached = (key, client)
        return client
    }

    /// A client for any org (Settings → Test and Permissions on an org that isn't active); the active org's is shared.
    func client(for profile: OrgProfile) -> AppleClient? {
        if profile.id == active?.id { return appleClient }
        guard let account = TokenBroker.Account(profile) else { return nil }
        return makeClient(account, nil)
    }

    /// An id for a new org: unused in `orgs.json` and by every org whose Keychain items are still stored, so a
    /// new org never inherits a removed one's secrets, and a failed add's clean-up never removes another's.
    /// The inventory is names only: no prompt.
    func newID(for name: String) async throws -> String {
        try await store.uniqueID(for: name, avoiding: Set(vault.inventory().keys))
    }

    func select(_ id: String) {
        guard store[id] != nil, store.active?.id != id else { return }
        store.activeID = id
        bump()
        save()
    }

    func add(_ profile: OrgProfile) throws(OrgStore.Failure) {
        try store.add(profile)
        if store.active?.id == profile.id { bump() }
        save()
    }

    func update(_ profile: OrgProfile) throws(OrgStore.Failure) {
        try store.update(profile)
        if store.active?.id == profile.id { bump() }
        save()
    }

    /// Removes the org's profile, and with `deleteSecrets` its Keychain items first (defect 14: abapit left
    /// them orphaned). A refused Keychain removal keeps the profile, so the secret stays reachable to remove.
    func remove(_ id: String, deleteSecrets: Bool) async throws {
        if deleteSecrets { try await vault.remove(org: id) }
        let wasActive = store.active?.id == id
        store.remove(id)
        if wasActive { bump() }
        save()
    }

    /// What Settings → Permissions found, kept so sections show locked without probing again.
    func record(_ results: [ProbeResult], for id: String, at date: Date = Date()) {
        guard var profile = store[id] else { return }
        profile.capabilities = Dictionary(uniqueKeysWithValues: results.map { ($0.section.rawValue, $0.status) })
        profile.probedAt = ISO8601DateFormatter().string(from: date)
        try? store.update(profile)
        save()
    }

    /// The rate the limiter learned, so the next launch starts there.
    func record(readsPerMinute: Double, for id: String) {
        guard var profile = store[id], readsPerMinute.isFinite, abs(profile.learnedReadsPerMinute - readsPerMinute) >= 1 else { return }
        profile.learnedReadsPerMinute = readsPerMinute
        try? store.update(profile)
        save()
    }

    private func bump() {
        generation += 1
        cached = nil
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
