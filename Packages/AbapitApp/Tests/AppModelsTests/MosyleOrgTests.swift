import AppModels
import Foundation
import Mosyle
import Orgs
import OSLog
import Security
import Testing
import TestSupport
import Vault

/// Adding and editing a Mosyle Business org (plan §4, defects 10 and 14): its credentials go to the Vault as one set, only
/// after everything that can refuse was checked, and the client reads with them.
@Suite("Mosyle orgs")
@MainActor
struct MosyleOrgTests {
    static func draft(_ name: String = "Fleet", logs: String = "") -> MosyleDraft {
        MosyleDraft(name: name, accessToken: World.mosyleAccount.accessToken, email: World.mosyleAccount.email,
                    password: World.mosyleAccount.password, logsToken: logs)
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
        let noName = Self.draft(" ")
        let noPassword = MosyleDraft(name: "Fleet", accessToken: "t", email: "admin@example.com", password: "   ")
        for (draft, why) in [(noName, "A name is needed."),
                             (noPassword, "The access token, the admin's email and the password are all needed.")] {
            await #expect(throws: OrgsModel.SaveFailure.refused(why)) { try await world.orgs.saveMosyle(draft, editing: nil) }
        }
        let partial = MosyleDraft(name: "Mosyle m", accessToken: "only-the-token", editing: try #require(world.orgs.store["m"]))
        await #expect(throws: OrgsModel.SaveFailure.refused(
            "To change the credentials, enter the access token, the admin's email and the password again, together.")) {
            try await world.orgs.saveMosyle(partial, editing: "m")
        }
        #expect(Set(try await world.vault.inventory().keys) == ["a", "b", "m"])
        await #expect(throws: OrgsModel.SaveFailure.refused("Org a isn't a Mosyle Business organization.")) {
            try await world.orgs.saveMosyle(MosyleDraft(name: "Org a", editing: World.profile("a")), editing: "a")
        }
    }

    /// An edit of the name keeps the credentials; a new set replaces the old one whole, an empty Logs Stream token clearing a
    /// stored one, and the org on screen reads again with it.
    @Test func anEditKeepsOrReplacesTheWholeSet() async throws {
        let world = try await World.make(mosyle: true)
        let rename = MosyleDraft(name: "Renamed", editing: try #require(world.orgs.store["m"]))
        let generation = world.orgs.generation
        try await world.orgs.saveMosyle(rename, editing: "m")
        #expect(world.orgs.store["m"]?.name == "Renamed" && world.orgs.generation == generation)
        #expect(try await world.vault.inventory()["m"] == [.mosyleAccessToken, .mosyleEmail, .mosylePassword])
        let replace = MosyleDraft(name: "Renamed", accessToken: " new-token\n", email: "new@example.com ", password: "new-pw",
                                  editing: try #require(world.orgs.store["m"]))
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

/// The editor's credentials never leave the Keychain path (invariant 3; plan defect 10): not through the draft's own
/// printouts, an error's message, the process's log or Settings' Test. Each held by a canary.
@Suite("Mosyle credentials stay secret")
@MainActor
struct MosyleCredentialTests {
    static let canary = "CANARY-7F3A-SECRET"

    static func draft(password: String = canary) -> MosyleDraft {
        MosyleDraft(name: "Fleet", accessToken: "TOKEN-" + canary, email: "EMAIL-" + canary + "@example.com", password: password,
                    logsToken: "LOGS-" + canary)
    }

    @Test func aDraftNeverPrintsItsCredentials() {
        let draft = Self.draft()
        var dumped = ""
        dump(draft, to: &dumped)
        let shown = [String(describing: draft), String(reflecting: draft), "\(draft)", dumped,
                     Mirror(reflecting: draft).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", ")]
        for text in shown {
            #expect(!text.contains(Self.canary), "\(text)")
            #expect(text.contains("Fleet"))
        }
        #expect(draft.givesCredentials && !MosyleDraft(name: "Fleet").givesCredentials)
    }

    /// Every way a save or a Test can fail says why in words that hold no credential, and nothing this process logged holds
    /// one either (a refused Keychain write, an incomplete edit, refused credentials at Mosyle's login).
    @Test func noCredentialReachesAnErrorOrTheLog() async throws {
        let since = Date().addingTimeInterval(-1)
        let world = try await World.make(mosyle: true)
        var messages: [String] = []
        world.keychain.failNext(.write, with: errSecAuthFailed)
        do { try await world.orgs.saveMosyle(Self.draft(), editing: nil) } catch { messages.append(OrgsModel.message(error)) }
        let partial = MosyleDraft(name: "Mosyle m", password: Self.canary, editing: try #require(world.orgs.store["m"]))
        do { try await world.orgs.saveMosyle(partial, editing: "m") } catch { messages.append(OrgsModel.message(error)) }
        // Credentials Mosyle refuses: Settings' Test says so, in Mosyle's words.
        let refused = try await world.orgs.saveMosyle(Self.draft(), editing: nil)
        do { try await #require(world.orgs.mosyleClient(for: refused)).ping() } catch { messages.append(OrgsModel.message(error)) }
        #expect(messages.count == 3, "\(messages)")
        #expect(messages.allSatisfy { !$0.contains(Self.canary) && !$0.contains("TOKEN-") }, "\(messages)")
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let logged = try store.getEntries(at: store.position(date: since)).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
        #expect(!logged.contains { $0.contains(Self.canary) }, "a log line holds a credential")
    }

    /// Removing a Mosyle org deletes its credentials with it (defect 14: abapit left them orphaned).
    @Test func removingAMosyleOrgDeletesItsCredentials() async throws {
        let world = try await World.make(mosyle: true)
        #expect(try await world.vault.inventory()["m"] != nil)
        try await world.orgs.remove("m", deleteSecrets: true)
        #expect(try await world.vault.inventory()["m"] == nil && world.orgs.store["m"] == nil)
    }
}

/// Mosyle stays optional: with no pair, an Apple org reads its devices as before, and Mosyle says it isn't in scope.
@Suite("Mosyle is optional")
@MainActor
struct MosyleOptionalTests {
    @Test func anAppleOrgWithNoPairStillReadsApple() async throws {
        let world = try await World.make()
        world.devices.load()
        world.mosyle.load()
        await world.settled(2)
        #expect(world.devices.devicesReadWhole && world.devices.rows.count == 3)
        #expect(world.mosyle.devices.state == .notInScope(MosyleScreenTests.notPaired))
    }
}
