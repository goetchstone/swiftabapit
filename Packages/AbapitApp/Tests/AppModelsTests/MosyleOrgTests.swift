import AppModels
import Foundation
import Mosyle
import Orgs
import Testing
import TestSupport
import Vault

/// Adding and editing a Mosyle Business org (plan §4, defects 10 and 14): its credentials go to the Vault as one set, only
/// after everything that can refuse was checked, and the client reads with them.
@Suite("Mosyle orgs")
@MainActor
struct MosyleOrgTests {
    static func draft(_ name: String = "Fleet", logs: String = "") -> MosyleDraft {
        var draft = MosyleDraft()
        draft.name = name
        (draft.accessToken, draft.email, draft.password, draft.logsToken) = (World.mosyleAccount.accessToken, World.mosyleAccount.email,
                                                                             World.mosyleAccount.password, logs)
        return draft
    }

    @Test func anAddedOrgsCredentialsAreInTheVaultAndItsClientReads() async throws {
        let world = try await World.make()
        let profile = try await world.orgs.saveMosyle(Self.draft(logs: " logs-token "), editing: nil)
        #expect(profile.provider == .known(.mosyle) && profile.name == "Fleet" && world.orgs.store[profile.id] != nil)
        let stored = try await world.vault.inventory()[profile.id]
        #expect(stored == [.mosyleAccessToken, .mosyleEmail, .mosylePassword, .mosyleLogsToken])
        let client = try #require(world.orgs.mosyleClient(for: profile))
        try await client.ping()
        #expect(world.mosyleStub.logins == 1)
        #expect(world.orgs.mosyleClient(for: World.profile("a")) == nil, "an Apple org has no Mosyle client")
    }

    /// Refused before any Keychain write: a missing name or credential, and an edit giving only some credentials.
    @Test func anIncompleteDraftWritesNothing() async throws {
        let world = try await World.make(mosyle: true)
        var noName = Self.draft()
        noName.name = " "
        var noPassword = Self.draft()
        noPassword.password = ""
        for (draft, why) in [(noName, "A name is needed."),
                             (noPassword, "The access token, the admin's email and the password are all needed.")] {
            await #expect(throws: OrgsModel.SaveFailure.refused(why)) { try await world.orgs.saveMosyle(draft, editing: nil) }
        }
        var partial = MosyleDraft(try #require(world.orgs.store["m"]))
        partial.accessToken = "only-the-token"
        await #expect(throws: OrgsModel.SaveFailure.refused(
            "To change the credentials, enter the access token, the admin's email and the password again, together.")) {
            try await world.orgs.saveMosyle(partial, editing: "m")
        }
        #expect(Set(try await world.vault.inventory().keys) == ["a", "b", "m"])
        await #expect(throws: OrgsModel.SaveFailure.refused("Org a isn't a Mosyle Business organization.")) {
            try await world.orgs.saveMosyle(MosyleDraft(World.profile("a")), editing: "a")
        }
    }

    /// An edit of the name keeps the credentials; a new set replaces the old one whole, an empty Logs Stream token clearing a
    /// stored one, and the org on screen reads again with it.
    @Test func anEditKeepsOrReplacesTheWholeSet() async throws {
        let world = try await World.make(mosyle: true)
        var rename = MosyleDraft(try #require(world.orgs.store["m"]))
        rename.name = "Renamed"
        let generation = world.orgs.generation
        try await world.orgs.saveMosyle(rename, editing: "m")
        #expect(world.orgs.store["m"]?.name == "Renamed" && world.orgs.generation == generation)
        #expect(try await world.vault.inventory()["m"] == [.mosyleAccessToken, .mosyleEmail, .mosylePassword])
        var replace = MosyleDraft(try #require(world.orgs.store["m"]))
        (replace.accessToken, replace.email, replace.password) = ("new-token", "new@example.com", "new-pw")
        try await world.orgs.saveMosyle(replace, editing: "m")
        #expect(world.orgs.generation == generation + 1, "the org on screen reads again with its new credentials")
        world.mosyleStub.register(MosyleStub.Account(accessToken: "new-token", email: "new@example.com", password: "new-pw"))
        try await #require(world.orgs.mosyleClient).ping()
    }

    /// Two Adds of one name get two ids, and an Add never takes an id the Keychain still holds items under.
    @Test func anAddNeverTakesAnIdInUse() async throws {
        let world = try await World.make(mosyle: true)
        let first = try await world.orgs.saveMosyle(Self.draft("m"), editing: nil)
        let second = try await world.orgs.saveMosyle(Self.draft("m"), editing: nil)
        #expect(first.id != "m" && second.id != first.id && second.id != "m")
    }
}
