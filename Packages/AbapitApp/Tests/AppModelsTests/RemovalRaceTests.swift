import AppModels
import CryptoKit
import Foundation
import Orgs
import Testing
import TestSupport
import Vault

/// A removal that finishes after a save of the same org (failure-log: "a removal that finished after an edit left the
/// edit's credentials behind"). The review of PR 17 held the other order only: the removal done while the save was
/// still inside its Keychain write (`MosyleOrgReviewTests.anEditRacingARemovalLeavesNoCredentials`). Here the removal
/// is held inside its last Keychain delete, after every kind was removed, while the save runs to its end.
@Suite("Orgs: a removal that finishes after a save")
@MainActor
struct RemovalRaceTests {
    @Test func aRemovalThatFinishesAfterAMosyleEditLeavesNoCredentials() async throws {
        let world = try await World.make(mosyle: true)
        let m = try #require(world.orgs.store["m"])
        #expect(try await world.vault.inventory()["m"] != nil, "m starts with a stored set")
        world.keychain.holdNextDelete(of: .mosyleLogsToken)
        let removal = Task { try await world.orgs.remove("m", deleteSecrets: true) }
        await eventually("the removal inside its last Keychain delete") { world.keychain.deletesWaiting == 1 }
        try await world.orgs.saveMosyle(MosyleOrgTests.newSet(m), editing: "m")
        world.keychain.releaseDeleteHold()
        try await removal.value
        #expect(world.orgs.store["m"] == nil, "the org is removed")
        let left = try await world.vault.inventory()["m"]
        #expect(left == nil, "left under removed id m: \(String(describing: left))")
    }

    @Test func aRemovalThatFinishesAfterAnAppleEditLeavesNoKey() async throws {
        let world = try await World.make()
        var draft = OrgDraft(world.orgs.store["b"]!)
        draft.role = "Device Enrollment Manager"
        world.keychain.holdNextDelete(of: .mosyleLogsToken)
        let removal = Task { try await world.orgs.remove("b", deleteSecrets: true) }
        await eventually("the removal inside its last Keychain delete") { world.keychain.deletesWaiting == 1 }
        try await world.orgs.save(draft, key: try World.imported(P256.Signing.PrivateKey()), editing: "b")
        world.keychain.releaseDeleteHold()
        try await removal.value
        #expect(world.orgs.store["b"] == nil, "the org is removed")
        let left = try await world.vault.inventory()["b"]
        #expect(left == nil, "left under removed id b: \(String(describing: left))")
    }
}
