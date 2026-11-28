import AppModels
import CryptoKit
import Foundation
import Orgs
import Testing
import TestSupport
import Vault

/// Keychain items under an id no organization has (a clean-up the Keychain refused, a lost `orgs.json`): listed by name,
/// removable, and never an organization's own or a save in flight's.
@MainActor
@Suite("Orphaned credentials", .serialized)
struct OrphanedCredentialsTests {
    /// `World.make(profiles: [])`: the Keychain holds keys for "a" and "b", and no organization has either id.
    @Test func idsNoOrganizationHasAreListedWithWhatTheyHold() async throws {
        let world = try await World.make(profiles: [])
        #expect(try await world.orgs.orphanedCredentials() == ["a": [.appleKey], "b": [.appleKey]])
    }

    @Test func anOrganizationsOwnCredentialsAreNeverListed() async throws {
        let world = try await World.make()
        #expect(try await world.orgs.orphanedCredentials().isEmpty)
        try await world.orgs.remove("b", deleteSecrets: false)
        #expect(try await world.orgs.orphanedCredentials() == ["b": [.appleKey]])
    }

    @Test func removingDeletesOnlyThatIdsItems() async throws {
        let world = try await World.make(profiles: [])
        try await world.orgs.removeOrphanedCredentials("a")
        #expect(try await world.vault.inventory()["a"] == nil)
        #expect(try await world.orgs.orphanedCredentials() == ["b": [.appleKey]])
    }

    @Test func anOrganizationsOwnIdIsRefusedBeforeTheKeychain() async throws {
        let world = try await World.make()
        await #expect(throws: OrgsModel.SaveFailure.self) { try await world.orgs.removeOrphanedCredentials("a") }
        #expect(try await world.vault.inventory()["a"] == [.appleKey])
        #expect(await world.keyWorks("a"))
    }

    @Test func aRefusedRemovalIsThrownAndTheIdStaysListed() async throws {
        let world = try await World.make(profiles: [])
        world.store.failNext(.delete, with: errSecInteractionNotAllowed)
        await #expect(throws: VaultError.keychain(errSecInteractionNotAllowed)) { try await world.orgs.removeOrphanedCredentials("a") }
        #expect(try await world.orgs.orphanedCredentials()["a"] == [.appleKey])
    }

    /// An edit of "b" is held at the Keychain while "b" is removed with its key kept: the id is in the Keychain, in no
    /// organization, and reserved by the save in flight, so it is neither listed nor removable until that save ends.
    @Test func anIdASaveInFlightIsWritingIsNeitherListedNorRemoved() async throws {
        let world = try await World.make()
        var edit = OrgDraft(world.orgs.store["b"]!)
        edit.role = "Administrator"
        let saving = await SaveTests.saveHeldAtTheKeychain(world, edit, key: try World.imported(P256.Signing.PrivateKey()), editing: "b")
        try await world.orgs.remove("b", deleteSecrets: false)
        #expect(try await world.vault.inventory()["b"] == [.appleKey])
        #expect(try await world.orgs.orphanedCredentials().isEmpty)
        await #expect(throws: OrgsModel.SaveFailure.self) { try await world.orgs.removeOrphanedCredentials("b") }
        #expect(try await world.vault.inventory()["b"] == [.appleKey])
        world.keychain.releaseKeyHold()
        _ = try? await saving.value
    }

    /// A vault holding a key for "stray", which neither file below names.
    private static func vaultHoldingAStrayKey() async throws -> Vault {
        let vault = Vault(store: MemoryStore())
        try await vault.storeKey(KeyImport.parse(Secret(P256.Signing.PrivateKey().pemRepresentation)), as: VaultItem(org: "stray", kind: .appleKey)!)
        return vault
    }

    /// A file that couldn't be read leaves the store empty: every stored id would look left over. Nothing is listed, and
    /// nothing is deleted (an organization's credentials among them).
    @Test func nothingIsListedOrDeletedWhileTheFileWasNotRead() async throws {
        let folder = try StoreGuardTests.folder(holding: StoreGuardTests.cut)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = try await Self.vaultHoldingAStrayKey()
        let orgs = StoreGuardTests.model(folder, vault)
        #expect(try await orgs.orphanedCredentials().isEmpty)
        await #expect(throws: OrgsModel.SaveFailure.self) { try await orgs.removeOrphanedCredentials("stray") }
        #expect(try await vault.inventory()["stray"] == [.appleKey])
    }

    /// A file a newer version wrote is read but not the whole truth: the same.
    @Test func nothingIsListedOrDeletedWhileANewerVersionWroteTheFile() async throws {
        let folder = try StoreGuardTests.folder(holding: StoreGuardTests.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = try await Self.vaultHoldingAStrayKey()
        let orgs = StoreGuardTests.model(folder, vault)
        #expect(try await orgs.orphanedCredentials().isEmpty)
        await #expect(throws: StoreGuardTests.refusal) { try await orgs.removeOrphanedCredentials("stray") }
        #expect(try await vault.inventory()["stray"] == [.appleKey])
    }
}
