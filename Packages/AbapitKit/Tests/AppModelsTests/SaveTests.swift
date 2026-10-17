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

    /// Starts `save` and returns once it is inside its Keychain write, held there until `world.keychain.release()`:
    /// the window an org can be removed, probed or added in while an editor saves. (Storing a key doesn't prompt; the
    /// window is the Keychain call, an await.)
    static func saveHeldAtTheKeychain(_ world: World, _ draft: OrgDraft, key: ImportedKey, editing id: String?) async -> Task<OrgProfile, any Error> {
        world.keychain.holdNextKey()
        let saving = Task { try await world.orgs.save(draft, key: key, editing: id) as OrgProfile }
        await eventually("the save at the Keychain") { world.keychain.waiting == 1 }
        return saving
    }

    /// The Add path's clean-up was `try?`: a refused removal left an orphan key without a word. Here the org is removed
    /// while its new key is being stored, so the save can't land.
    @Test func aKeyThatCantBeRemovedAgainIsSaid() async throws {
        let world = try await World.make()
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.role = "Device Enrollment Manager"
        world.store.failNext(.delete, with: errSecInteractionNotAllowed)
        let saving = await Self.saveHeldAtTheKeychain(world, draft, key: try World.imported(P256.Signing.PrivateKey()), editing: "b")
        try await world.orgs.remove("b", deleteSecrets: false)
        world.keychain.release()
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
        let saving = await Self.saveHeldAtTheKeychain(world, draft, key: try World.imported(P256.Signing.PrivateKey()), editing: "b")
        try await world.orgs.remove("b", deleteSecrets: false)
        world.keychain.release()
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
        let saving = await Self.saveHeldAtTheKeychain(world, draft, key: try World.imported(world.keys["b"]!), editing: "b")
        // While the key is being stored: a permissions check and a learned rate land.
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: world.orgs.store["b"]!)
        world.orgs.record(readsPerMinute: 42, for: "b")
        world.keychain.release()
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
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: world.orgs.store["b"]!)
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

    /// A permissions check still running when its org was edited to another account recorded the old account's
    /// results onto the new one, putting back the locks the edit had just cleared (the first fix's open item).
    @Test func aProbeOfTheOldAccountIsNotKept() async throws {
        let world = try await World.make()
        let probed = world.orgs.store["b"]!
        var draft = OrgDraft(probed)
        draft.clientID = World.clientID("c")
        try await world.orgs.save(draft, key: nil, editing: "b")
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: probed)
        #expect(world.orgs.store["b"]!.capabilities.isEmpty, "the old account's locks landed on the new account")
        #expect(world.orgs.store["b"]!.probedAt.isEmpty)

        // The same account's probe is kept across a rename and a client ID retyped in another case.
        let before = world.orgs.store["b"]!
        draft.name = "Org B, renamed"
        draft.clientID = draft.clientID.lowercased()
        try await world.orgs.save(draft, key: nil, editing: "b")
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: before)
        #expect(world.orgs.store["b"]!.deniedSections == ["devices"])
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

    // MARK: verifier round 1

    /// An edit didn't reserve its id: with the org removed while the edit's key was stored, an Add whose name gave the
    /// same id took it, and the edit then merged its fields onto the Add's org, both reporting success.
    @Test func anAddNeverTakesTheIDOfAnOrgRemovedWhileItsEditSaves() async throws {
        let world = try await World.make()
        let key = P256.Signing.PrivateKey(), client = "BUSINESSAPI.00000000-0000-4000-8000-000000000999"
        world.stubs["a"]!.register(AppleStub.Account(clientID: client, keyID: "k9", publicKey: key.publicKey))
        var edit = OrgDraft(world.orgs.store["b"]!)
        edit.role = "Administrator"
        let editing = await Self.saveHeldAtTheKeychain(world, edit, key: try World.imported(P256.Signing.PrivateKey()), editing: "b")
        try await world.orgs.remove("b", deleteSecrets: true)
        let added = try await world.orgs.save(Self.draft("B", client: client, key: "k9"), key: World.imported(key), editing: nil)
        #expect(added.id != "b", "the Add took the id of an org whose edit is still saving")
        world.keychain.release()
        do {
            _ = try await editing.value
            Issue.record("the edit of a removed org was saved")
        } catch let failure as OrgsModel.SaveFailure {
            if case .notSaved = failure {} else { Issue.record("\(failure)") }
        }
        #expect(world.orgs.store["b"] == nil)
        #expect(world.orgs.store[added.id]?.clientID == client && world.orgs.store[added.id]?.role == "")
        #expect(await world.keyWorks(added.id), "the Add's key was replaced or removed")
        #expect(try await world.vault.inventory()["b"] == nil, "the failed edit left its key behind")
    }

    /// A changed key ID is another API account too: its locks, probe date and rate go.
    @Test func anotherKeyIDForgetsTheOldLocks() async throws {
        let world = try await World.make()
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: world.orgs.store["b"]!)
        world.orgs.record(readsPerMinute: 42, for: "b")
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.keyID = "00000000-0000-4000-8000-0000000000f2"
        try await world.orgs.save(draft, key: nil, editing: "b")
        #expect(world.orgs.store["b"]!.capabilities.isEmpty)
        #expect(world.orgs.store["b"]!.probedAt.isEmpty)
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 0)
    }

    /// So is a changed scope, even with a client ID that compares equal.
    @Test func anotherScopeForgetsTheOldLocks() async throws {
        let world = try await World.make()
        world.orgs.record(readsPerMinute: 42, for: "b")
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.scope = .school
        try await world.orgs.save(draft, key: nil, editing: "b")
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 0)
    }

    /// A client ID retyped in another case, or with a stray space, is the same account: what was learned stays.
    @Test func aRetypedClientIDIsTheSameAccount() async throws {
        let world = try await World.make()
        world.orgs.record([ProbeResult(section: .devices, status: ProbeResult.forbidden)], probed: world.orgs.store["b"]!)
        world.orgs.record(readsPerMinute: 42, for: "b")
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.clientID = World.clientID("b").lowercased() + " "
        try await world.orgs.save(draft, key: nil, editing: "b")
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 42)
        #expect(world.orgs.store["b"]!.deniedSections == ["devices"])
    }

    /// An Add never takes an id the Keychain still holds items under (an org removed without its secrets): a new org
    /// never inherits another's secrets.
    @Test func anAddAvoidsIdsTheKeychainHolds() async throws {
        let world = try await World.make(profiles: [])
        // The Keychain holds keys for "a" and "b"; orgs.json has neither.
        let key = P256.Signing.PrivateKey()
        world.stubs["a"]!.register(AppleStub.Account(clientID: World.clientID("c"), keyID: World.keyID("c"), publicKey: key.publicKey))
        let saved = try await world.orgs.save(Self.draft("A", client: World.clientID("c"), key: World.keyID("c")), key: World.imported(key), editing: nil)
        #expect(saved.id != "a", "a new org took org a's Keychain items")
        #expect(await world.keyWorks(saved.id))
    }

    /// An Add with another org's client ID is refused before the Keychain is touched.
    @Test func anAddWithATakenClientIDNeverReachesTheKeychain() async throws {
        let world = try await World.make()
        // Were the Keychain reached, this would be the failure.
        world.store.failNext(.storeKey, with: errSecUserCanceled)
        do {
            try await world.orgs.save(Self.draft("Other", client: World.clientID("a"), key: "k"), key: World.imported(world.keys["a"]!), editing: nil)
            Issue.record("a duplicate client ID was saved")
        } catch let failure as OrgsModel.SaveFailure {
            guard case .refused(let why) = failure else {
                Issue.record("not refused before the Keychain: \(failure)")
                return
            }
            #expect(why.contains("already uses the client ID"))
        }
    }

    /// An edit whose new key the Keychain refused says the old key may be gone; an Add's doesn't.
    @Test func anEditsKeychainRefusalSaysTheOldKeyMayBeGone() async throws {
        let world = try await World.make()
        world.store.failNext(.storeKey, with: errSecUserCanceled)
        let draft = OrgDraft(world.orgs.store["b"]!)
        do {
            try await world.orgs.save(draft, key: World.imported(P256.Signing.PrivateKey()), editing: "b")
            Issue.record("saved")
        } catch let failure as OrgsModel.SaveFailure {
            #expect(failure == .keyNotStored(.keychain(errSecUserCanceled), adding: false))
            #expect(failure.message.contains("settings weren't changed"))
        }
    }

    /// A new key for the active org, its IDs unchanged, reads again with that key.
    @Test func aNewKeyForTheActiveOrgReloads() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        let generation = world.orgs.generation
        try await world.orgs.save(OrgDraft(world.orgs.store["a"]!), key: World.imported(world.keys["a"]!), editing: "a")
        #expect(world.orgs.generation == generation + 1)
        #expect(world.devices.rows.isEmpty && world.devices.state.isLoading)
        await world.settled(4)
    }

    /// A client ID is free again once the save that used it is over and its org is gone.
    @Test func aClientIDIsFreeOnceItsOrgIsGone() async throws {
        let world = try await World.make(profiles: [])
        let first = try await world.orgs.save(Self.draft("One", client: World.clientID("c"), key: "k1"), key: World.imported(world.keys["a"]!), editing: nil)
        try await world.orgs.remove(first.id, deleteSecrets: true)
        let second = try await world.orgs.save(Self.draft("Two", client: World.clientID("c"), key: "k2"), key: World.imported(world.keys["a"]!), editing: nil)
        #expect(second.id == "two")
    }

    // MARK: verifier round 2

    /// Two sheets open on one org: each save writes only what its operator changed, so the later one never puts the
    /// earlier one's old fields back (the later save wrote all six fields as its sheet had opened them, and both said
    /// they had succeeded). The editor's role is saved (X14).
    @Test func twoSheetsOnOneOrgKeepEachOthersChanges() async throws {
        let world = try await World.make()
        var rename = OrgDraft(world.orgs.store["b"]!), role = OrgDraft(world.orgs.store["b"]!)
        rename.name = "Org B, renamed"
        role.role = "Administrator"
        try await world.orgs.save(rename, key: nil, editing: "b")
        try await world.orgs.save(role, key: nil, editing: "b")
        #expect(world.orgs.store["b"]!.name == "Org B, renamed", "the second sheet wrote back the name it opened with")
        #expect(world.orgs.store["b"]!.role == "Administrator")

        // An account edit, then a rename from a sheet opened before it: the rename keeps the new account.
        var account = OrgDraft(world.orgs.store["b"]!), again = OrgDraft(world.orgs.store["b"]!)
        account.clientID = World.clientID("c")
        account.teamID = "TEAM000001"
        again.name = "Org B"
        try await world.orgs.save(account, key: nil, editing: "b")
        try await world.orgs.save(again, key: nil, editing: "b")
        let profile = world.orgs.store["b"]!
        #expect(profile.clientID == World.clientID("c") && profile.teamID == "TEAM000001", "a rename put the old account back")
        #expect(profile.name == "Org B" && profile.role == "Administrator")
    }

    /// The same, inside a save's Keychain window: an account edit held in its key write while a rename of the org
    /// lands keeps the rename (the behaviour verifier's atk08).
    @Test func anEditHeldAtTheKeychainKeepsARenameThatLandedMeanwhile() async throws {
        let world = try await World.make()
        let key = P256.Signing.PrivateKey()
        world.stubs["b"]!.register(AppleStub.Account(clientID: World.clientID("c"), keyID: World.keyID("c"), publicKey: key.publicKey))
        var account = OrgDraft(world.orgs.store["b"]!)
        (account.clientID, account.keyID) = (World.clientID("c"), World.keyID("c"))
        let saving = await Self.saveHeldAtTheKeychain(world, account, key: try World.imported(key), editing: "b")
        var rename = OrgDraft(world.orgs.store["b"]!)
        rename.name = "Renamed"
        try await world.orgs.save(rename, key: nil, editing: "b")
        world.keychain.release()
        _ = try await saving.value
        let profile = world.orgs.store["b"]!
        #expect(profile.name == "Renamed", "the held edit wrote back the name it opened with")
        #expect(profile.clientID == World.clientID("c") && profile.keyID == World.keyID("c"))
        #expect(await world.keyWorks("b"))
    }

    /// A picked key goes with the IDs its sheet holds, even when another sheet changed them meanwhile: a key under
    /// another account's IDs would mint nothing.
    @Test func aPickedKeyKeepsTheIDsItWasPickedWith() async throws {
        let world = try await World.make()
        var other = OrgDraft(world.orgs.store["b"]!)
        let rekey = OrgDraft(world.orgs.store["b"]!)
        other.clientID = World.clientID("c")
        try await world.orgs.save(other, key: nil, editing: "b")
        try await world.orgs.save(rekey, key: World.imported(world.keys["b"]!), editing: "b")
        #expect(world.orgs.store["b"]!.clientID == World.clientID("b"))
        #expect(await world.keyWorks("b"))
    }

    /// And the trial before the Keychain checks those IDs: a key picked for a client ID another org has taken since is
    /// refused there, before it replaces the org's key.
    @Test func aPickedKeyWhoseIDsAreTakenIsRefusedBeforeTheKeychain() async throws {
        let world = try await World.make()
        let rekey = OrgDraft(world.orgs.store["b"]!)
        var move = OrgDraft(world.orgs.store["b"]!)
        move.clientID = World.clientID("c")
        try await world.orgs.save(move, key: nil, editing: "b")
        let key = P256.Signing.PrivateKey()
        world.stubs["a"]!.register(AppleStub.Account(clientID: World.clientID("b"), keyID: "k9", publicKey: key.publicKey))
        let taker = try await world.orgs.save(Self.draft("Taker", client: World.clientID("b"), key: "k9"), key: World.imported(key), editing: nil)
        // Were the Keychain reached, this would be the failure.
        world.store.failNext(.storeKey, with: errSecUserCanceled)
        do {
            try await world.orgs.save(rekey, key: World.imported(world.keys["b"]!), editing: "b")
            Issue.record("two orgs hold one client ID")
        } catch let failure as OrgsModel.SaveFailure {
            guard case .refused(let why) = failure else {
                Issue.record("not refused before the Keychain: \(failure)")
                return
            }
            #expect(why.contains("already uses the client ID"))
        }
        #expect(world.orgs.store["b"]!.clientID == World.clientID("c"))
        #expect(await world.keyWorks(taker.id))
    }

    /// Two edits of one org at once share its client ID: the second isn't refused as a duplicate (X17), and neither
    /// undoes the other.
    @Test func twoEditsOfOneOrgAtOnceAreNoDuplicate() async throws {
        let world = try await World.make()
        var rename = OrgDraft(world.orgs.store["b"]!)
        rename.name = "Org B, renamed"
        let saving = await Self.saveHeldAtTheKeychain(world, rename, key: try World.imported(world.keys["b"]!), editing: "b")
        var role = OrgDraft(world.orgs.store["b"]!)
        role.role = "Administrator"
        do {
            try await world.orgs.save(role, key: nil, editing: "b")
        } catch {
            Issue.record("the second edit was refused: \(error)")
        }
        world.keychain.release()
        _ = try await saving.value
        let profile = world.orgs.store["b"]!
        #expect(profile.name == "Org B, renamed" && profile.role == "Administrator", "\(profile.name), \(profile.role)")
    }

    /// Settings → Test and Check Permissions on an org that isn't active use that org's own account, never the active
    /// one's (X20: `client(for:)` handing back the active org's client passed every test, and would have recorded the
    /// active org's locks as the other's).
    @Test func aClientForAnotherOrgIsThatOrgs() async throws {
        let world = try await World.make()
        let before = (a: world.stubs["a"]!.requests.count, b: world.stubs["b"]!.requests.count)
        let client = try #require(world.orgs.client(for: world.orgs.store["b"]!))
        try await client.ping()
        #expect(world.stubs["a"]!.requests.count == before.a, "org b's Test went to org a's account")
        #expect(world.stubs["b"]!.requests.count > before.b)
        // With b's key replaced by one its account doesn't know, b's Test fails, whatever a's key does.
        try await world.vault.storeKey(World.imported(P256.Signing.PrivateKey()), as: VaultItem(org: "b", kind: .appleKey)!)
        #expect(await world.keyWorks("a"))
        #expect(await !world.keyWorks("b"), "org b was tested with org a's account")
    }

    /// A Keychain that refuses to remove an org's items keeps its profile, so the secrets stay reachable to remove
    /// (defect 14; X13: a `try?` there passed every test).
    @Test func aRefusedKeychainRemovalKeepsTheOrg() async throws {
        let world = try await World.make()
        world.store.failNext(.delete, with: errSecInteractionNotAllowed)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) { try await world.orgs.remove("b", deleteSecrets: true) }
        #expect(world.orgs.store["b"] != nil, "the profile went and its key stayed")
        #expect(try await world.vault.inventory()["b"]?.contains(.appleKey) == true)
    }
}
