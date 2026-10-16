import AppleBusiness
import AppModels
import CryptoKit
import Foundation
import Orgs
import Testing
import TestSupport
import Vault

/// The org editor's save path, moved into `OrgsModel` so it can be tested (Phase 1b review M4 and its LOWs):
/// everything is checked before the Keychain, ids are reserved, a failed clean-up is said, and an edit merges onto
/// the profile as it is now.
@MainActor
@Suite("Saving an org", .serialized)
struct SaveTests {
    static func draft(_ name: String, client: String, key: String) -> OrgDraft {
        var draft = OrgDraft()
        (draft.name, draft.clientID, draft.keyID) = (name, client, key)
        return draft
    }

    /// M4: in an edit, the new key was stored (deleting the old one) before a duplicate client ID was found, so the
    /// org kept its IDs with a key that wasn't theirs.
    @Test func aDuplicateClientIDIsRefusedBeforeTheKeychain() async throws {
        let world = try await World.make()
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.clientID = World.clientID("a").lowercased() + " "
        do {
            try await world.orgs.save(draft, key: World.imported(P256.Signing.PrivateKey()), editing: "b")
            Issue.record("a duplicate client ID was saved")
        } catch let failure as OrgsModel.SaveFailure {
            guard case .refused(let why) = failure else {
                Issue.record("\(failure)")
                return
            }
            #expect(why.contains("already uses the client ID"))
        }
        #expect(await world.keyWorks("b"), "org b's own key was replaced before the refusal")
        #expect(world.orgs.store["b"]!.clientID == World.clientID("b"))
    }

    /// The Add path's clean-up was `try?`: a refused removal left an orphan key without a word. Here the org is removed
    /// while its new key is being stored (a Touch ID prompt is that window), so the save can't land.
    @Test func aKeyThatCantBeRemovedAgainIsSaid() async throws {
        let world = try await World.make()
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.role = "Device Enrollment Manager"
        world.store.failNext(.delete, with: errSecInteractionNotAllowed)
        let saving = Task { try await world.orgs.save(draft, key: World.imported(P256.Signing.PrivateKey()), editing: "b") }
        await Task.yield()
        try await world.orgs.remove("b", deleteSecrets: false)
        do {
            _ = try await saving.value
            Issue.record("an edit of a removed org was saved")
        } catch let failure as OrgsModel.SaveFailure {
            guard case .keyLeftBehind(_, let removal) = failure else {
                Issue.record("\(failure)")
                return
            }
            #expect(removal == .keychain(errSecInteractionNotAllowed))
            #expect(failure.keyIsStored)
            #expect(failure.message.contains("couldn't be removed"))
        }
        #expect(try await world.vault.inventory()["b"]?.contains(.appleKey) == true, "the report matches the Keychain")
    }

    /// The same window with the removal allowed: nothing of the org is left behind.
    @Test func aSaveThatCantLandRemovesItsKey() async throws {
        let world = try await World.make()
        let draft = OrgDraft(world.orgs.store["b"]!)
        let saving = Task { try await world.orgs.save(draft, key: World.imported(P256.Signing.PrivateKey()), editing: "b") }
        await Task.yield()
        try await world.orgs.remove("b", deleteSecrets: false)
        do {
            _ = try await saving.value
            Issue.record("an edit of a removed org was saved")
        } catch let failure as OrgsModel.SaveFailure {
            guard case .notSaved = failure else {
                Issue.record("\(failure)")
                return
            }
            #expect(!failure.keyIsStored)
        }
        #expect(try await world.vault.inventory()["b"] == nil)
    }

    /// Two Add editors open at once both got the same new id: the second replaced the first's key, then its
    /// duplicate-id clean-up deleted the key of the org that was saved.
    @Test func addsAtTheSameTimeGetTheirOwnIDs() async throws {
        let world = try await World.make(profiles: [])
        let keys = (0..<5).map { _ in P256.Signing.PrivateKey() }
        let clients = (0..<5).map { "BUSINESSAPI.00000000-0000-4000-8000-00000000010\($0)" }
        for (index, key) in keys.enumerated() {
            world.stubs["a"]!.register(AppleStub.Account(clientID: clients[index], keyID: "k\(index)", publicKey: key.publicKey))
        }
        let saves = try keys.indices.map { index in
            let imported = try World.imported(keys[index])
            return Task { try await world.orgs.save(Self.draft("Acme", client: clients[index], key: "k\(index)"), key: imported, editing: nil) }
        }
        var ids: [String] = []
        for save in saves { ids.append(try await save.value.id) }
        #expect(Set(ids).count == 5, "\(ids)")
        #expect(Set(world.orgs.store.orgs.map(\.id)) == ["acme", "acme-2", "acme-3", "acme-4", "acme-5"])
        // Every org's stored key is its own: each mints a token with the account the stub registered.
        for id in ids { #expect(await world.keyWorks(id), "\(id)'s key isn't the one its account was registered with") }
    }

    /// Two Adds of one API account at once: one is saved, the others are refused before they reach the Keychain,
    /// rather than storing a key and taking it out again.
    @Test func addsOfOneAccountAtTheSameTimeRefuseAllButOne() async throws {
        let world = try await World.make(profiles: [])
        let saves = try (0..<5).map { index in
            let imported = try World.imported(world.keys["a"]!)
            return Task { try await world.orgs.save(Self.draft("Acme \(index)", client: World.clientID("a"), key: World.keyID("a")), key: imported, editing: nil) }
        }
        var saved: [String] = [], refused = 0
        for save in saves {
            do {
                saved.append(try await save.value.id)
            } catch let failure as OrgsModel.SaveFailure {
                if case .refused = failure { refused += 1 } else { Issue.record("not refused before the Keychain: \(failure)") }
            }
        }
        #expect(saved.count == 1 && refused == 4)
        #expect(try await world.vault.inventory().keys.sorted() == (["a", "b"] + saved).sorted())
        #expect(await world.keyWorks(saved[0]))
    }

    /// The editor wrote back the profile as it opened it, so a probe or a learned rate recorded meanwhile was lost.
    @Test func anEditMergesOntoTheProfileAsItIsNow() async throws {
        let world = try await World.make()
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.name = "Org B, renamed"
        let saving = Task { try await world.orgs.save(draft, key: World.imported(world.keys["b"]!), editing: "b") }
        await Task.yield()
        // While the key is being stored: a permissions check and a learned rate land.
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], for: "b")
        world.orgs.record(readsPerMinute: 42, for: "b")
        let saved = try await saving.value
        let profile = world.orgs.store["b"]!
        #expect(saved == profile)
        #expect(profile.name == "Org B, renamed")
        #expect(profile.capabilities == ["devices": ProbeResult.forbidden])
        #expect(!profile.probedAt.isEmpty)
        #expect(profile.learnedReadsPerMinute == 42)
    }

    /// A changed client ID kept the old account's section locks, probe date and learned rate.
    @Test func anotherAccountForgetsWhatWasLearnedAboutTheOldOne() async throws {
        let world = try await World.make()
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], for: "b")
        world.orgs.record(readsPerMinute: 42, for: "b")
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.role = "Administrator"
        try await world.orgs.save(draft, key: nil, editing: "b")
        #expect(world.orgs.store["b"]!.deniedSections == ["devices"], "a role note isn't another account")
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 42)

        draft.clientID = World.clientID("c")
        try await world.orgs.save(draft, key: nil, editing: "b")
        let profile = world.orgs.store["b"]!
        #expect(profile.capabilities.isEmpty)
        #expect(profile.probedAt.isEmpty)
        #expect(profile.learnedReadsPerMinute == 0)
    }

    /// A Keychain refusal on Add saves nothing, and frees the id for the retry.
    @Test func aKeychainRefusalOnAddSavesNothing() async throws {
        let world = try await World.make(profiles: [])
        world.store.failNext(.storeKey, with: errSecUserCanceled)
        let draft = Self.draft("Acme", client: World.clientID("a"), key: World.keyID("a"))
        await #expect(throws: OrgsModel.SaveFailure.keyNotStored(.keychain(errSecUserCanceled), adding: true)) {
            try await world.orgs.save(draft, key: World.imported(world.keys["a"]!), editing: nil)
        }
        #expect(world.orgs.store.orgs.isEmpty)
        let saved = try await world.orgs.save(draft, key: World.imported(world.keys["a"]!), editing: nil)
        #expect(saved.id == "acme")
        #expect(await world.keyWorks("acme"))
    }

    /// An Add needs a key, and every save its three fields; neither reaches the Keychain.
    @Test func anIncompleteDraftIsRefused() async throws {
        let world = try await World.make(profiles: [])
        await #expect(throws: OrgsModel.SaveFailure.self) {
            try await world.orgs.save(Self.draft("Acme", client: World.clientID("a"), key: World.keyID("a")), key: nil, editing: nil)
        }
        await #expect(throws: OrgsModel.SaveFailure.self) {
            try await world.orgs.save(Self.draft(" ", client: World.clientID("a"), key: World.keyID("a")), key: World.imported(world.keys["a"]!), editing: nil)
        }
        #expect(try await world.vault.inventory().keys.sorted() == ["a", "b"])
    }

    /// Editing the active org's account reads it again; a note on its role doesn't.
    @Test func changingTheActiveAccountReloadsItsScreens() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        let generation = world.orgs.generation
        var draft = OrgDraft(world.orgs.store["a"]!)
        draft.role = "Administrator"
        try await world.orgs.save(draft, key: nil, editing: "a")
        #expect(world.orgs.generation == generation)
        #expect(world.devices.rows.count == 3)

        draft.teamID = "TEAM000001"
        try await world.orgs.save(draft, key: nil, editing: "a")
        #expect(world.orgs.generation == generation + 1)
        #expect(world.devices.rows.isEmpty, "the old account's rows stayed")
        #expect(world.devices.state.isLoading)
    }
}
