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

extension MosyleOrgTests {
    static func draft(_ name: String, base: OrgProfile) -> MosyleDraft {
        MosyleDraft(name: name, accessToken: World.mosyleAccount.accessToken, email: World.mosyleAccount.email,
                    password: World.mosyleAccount.password, editing: base)
    }

    static func newSet(_ m: OrgProfile) -> MosyleDraft {
        MosyleDraft(name: m.name, accessToken: "new-token", email: "new@example.com", password: "new-pw", editing: m)
    }
}

/// The credential review of PR 17, each finding held by its probe (P1–P16), each failing on the reviewed code.
@Suite("Mosyle orgs: the credential review")
@MainActor
struct MosyleOrgReviewTests {
    /// M2 (P1): an edit whose org is removed while its credentials are written removes them again, and says so.
    @Test func anEditRacingARemovalLeavesNoCredentials() async throws {
        let world = try await World.make(mosyle: true)
        let m = try #require(world.orgs.store["m"])
        world.keychain.holdNextWrite()
        let save = Task { () -> String in
            do { try await world.orgs.saveMosyle(MosyleOrgTests.newSet(m), editing: "m"); return "saved" } catch { return OrgsModel.message(error) }
        }
        await eventually("the edit inside its Keychain write") { world.keychain.writesWaiting == 1 }
        try await world.orgs.remove("m", deleteSecrets: true)
        world.keychain.releaseWriteHold()
        #expect(await save.value == "The organization was removed while its credentials were being saved, so they were removed again.")
        #expect(try await world.vault.inventory()["m"] == nil)
    }

    /// M3 (P2): a failed write whose clean-up is refused says what stayed, never "nothing was saved".
    @Test func aRefusedCleanUpSaysWhatStayed() async throws {
        let world = try await World.make(mosyle: true)
        world.keychain.failNext(.write, with: errSecInteractionNotAllowed, skipping: 1)
        world.keychain.failNext(.delete, with: errSecInteractionNotAllowed, skipping: 1)
        var message = ""
        do { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil) } catch { message = OrgsModel.message(error) }
        let inventory = try await world.vault.inventory()
        let orphans = Set(inventory.keys).subtracting(world.orgs.store.orgs.map(\.id))
        #expect(!orphans.isEmpty, "the test reaches a refused clean-up")
        #expect(!message.contains("Nothing was saved") && message.contains("stayed in the Keychain") && message.contains("wasn't added"), "\(message)")
        let names: [VaultItem.Kind: String] = [.mosyleAccessToken: "the access token", .mosyleEmail: "the admin's email", .mosylePassword: "the password"]
        for org in orphans { for kind in inventory[org] ?? [] { #expect(message.contains(names[kind] ?? "?"), "\(kind) unsaid: \(message)") } }
    }

    /// M1 (P3): a refused edit removes the stored set with the new one (a set is whole or absent), says so in words, reads
    /// every screen again, and Settings' Test then logs in afresh and fails, never "Connected" on a login kept in memory.
    @Test func aRefusedEditSaysTheStoredCredentialsWentAndReadsAgain() async throws {
        let world = try await World.make(mosyle: true)
        try await #require(world.orgs.mosyleClient).ping()
        let m = try #require(world.orgs.store["m"])
        let generation = world.orgs.generation
        world.keychain.failNext(.write, with: errSecUserCanceled)
        var message = ""
        do { try await world.orgs.saveMosyle(MosyleOrgTests.newSet(m), editing: "m") } catch { message = OrgsModel.message(error) }
        #expect(message.hasPrefix("The new credentials couldn't be stored: ") && message.contains("The ones stored before were removed with them"), "\(message)")
        #expect(message.hasSuffix("Enter them all again before this organization can be read."))
        #expect(try await world.vault.inventory()["m"] == nil)
        #expect(world.orgs.generation == generation + 1, "the screens read again")
        let test = try #require(world.orgs.mosyleClient(for: m))
        await #expect(throws: (any Error).self, "Test logs in afresh, with nothing stored") { try await test.ping() }
    }

    /// Settings' Test logs in afresh, even for the org on screen whose login is kept in memory: it proves what is stored.
    @Test func testLogsInAfreshEvenForTheOrgOnScreen() async throws {
        let world = try await World.make(mosyle: true)
        try await #require(world.orgs.mosyleClient).ping()
        #expect(world.mosyleStub.logins == 1)
        let shown = try #require(world.orgs.mosyleOrg)
        try await #require(world.orgs.mosyleClient(for: shown)).ping()
        #expect(world.mosyleStub.logins == 2)
    }

    /// P4: the first org added, a Mosyle one, is read on screen at once.
    @Test func theFirstOrgAddedIsReadOnScreen() async throws {
        let world = try await World.make(profiles: [])
        world.mosyle.load()
        #expect(world.mosyle.devices.unavailable != nil)
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil)
        #expect(world.orgs.active?.id == added.id && world.orgs.generation == 1)
        #expect(world.mosyle.devices.unavailable == nil && world.mosyle.devices.state.isLoading)
    }

    /// A Mosyle org added while the active client has one is a client of its own: it never replaces what a client reads.
    @Test func aSecondMosyleOrgIsAClientOfItsOwn() async throws {
        let world = try await World.make(mosyle: true)
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil)
        #expect(world.orgs.mosyleOrg?.id == "m" && world.orgs.store.client(of: added.id)?.orgs == [added.id])
    }

    /// P6: a draft is saved only onto the org it was opened for: an edit's never as an Add, an Add's never as an edit.
    @Test func aDraftIsSavedOnlyOntoTheOrgItOpened() async throws {
        let world = try await World.make(mosyle: true)
        let m = try #require(world.orgs.store["m"])
        let refused = OrgsModel.SaveFailure.refused("This editor was opened for another organization: close it and open it again.")
        await #expect(throws: refused) { try await world.orgs.saveMosyle(MosyleDraft(name: "Ghost", editing: m), editing: nil) }
        await #expect(throws: refused) { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: "m") }
        #expect(world.orgs.store.orgs.count == 3)
    }

    /// P7: two Adds of one name, the second inside the first's Keychain write: two ids, each with its whole set.
    @Test func twoAddsAtOnceKeepEachSet() async throws {
        let world = try await World.make(mosyle: true)
        world.keychain.holdNextWrite()
        let first = Task { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil) }
        await eventually("the first Add inside its Keychain write") { world.keychain.writesWaiting == 1 }
        let second = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil)
        world.keychain.releaseWriteHold()
        let firstProfile = try await first.value
        let inventory = try await world.vault.inventory()
        #expect(firstProfile.id != second.id)
        #expect(inventory[firstProfile.id]?.count == 3 && inventory[second.id]?.count == 3, "\(inventory)")
    }

    /// P8: removing a Mosyle org deletes its Logs Stream token too.
    @Test func removalDeletesTheLogsStreamToken() async throws {
        let world = try await World.make()
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet", logs: "logs"), editing: nil)
        #expect(try await world.vault.inventory()[added.id]?.contains(.mosyleLogsToken) == true)
        try await world.orgs.remove(added.id, deleteSecrets: true)
        #expect(try await world.vault.inventory()[added.id] == nil)
    }

    /// P9: an Add never takes the id of a removed org whose credentials stayed in the Keychain.
    @Test func anAddSkipsAnIdTheKeychainHolds() async throws {
        let world = try await World.make(mosyle: true)
        try await world.orgs.remove("m", deleteSecrets: false)
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("m"), editing: nil)
        #expect(added.id != "m")
    }

    /// P10: a rename keeps the stored credentials: a fresh login after it works.
    @Test func aRenameKeepsTheCredentials() async throws {
        let world = try await World.make(mosyle: true)
        try await world.orgs.saveMosyle(MosyleDraft(name: "Renamed", editing: try #require(world.orgs.store["m"])), editing: "m")
        let m = try #require(world.orgs.store["m"])
        try await #require(world.orgs.mosyleClient(for: m)).ping()
    }

    /// P11: an edit giving a set with no Logs Stream token removes the stored one (defect 14).
    @Test func anEditClearsAStoredLogsStreamToken() async throws {
        let world = try await World.make()
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet", logs: "logs"), editing: nil)
        try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet", base: added), editing: added.id)
        #expect(try await world.vault.inventory()[added.id] == [.mosyleAccessToken, .mosyleEmail, .mosylePassword])
    }

    /// P12: a password is stored as typed, its surrounding spaces kept.
    @Test func aPasswordIsKeptAsTyped() async throws {
        let world = try await World.make()
        world.mosyleStub.register(MosyleStub.Account(accessToken: "t2", email: "e2@example.com", password: " pw "))
        let added = try await world.orgs.saveMosyle(MosyleDraft(name: "Fleet", accessToken: "t2", email: "e2@example.com", password: " pw "), editing: nil)
        try await #require(world.orgs.mosyleClient(for: added)).ping()
    }

    /// P13: an Add whose Keychain inventory can't be read is refused before any write.
    @Test func anUnreadableInventoryRefusesTheAdd() async throws {
        let world = try await World.make(mosyle: true)
        world.keychain.failNext(.inventory, with: errSecInteractionNotAllowed)
        await #expect(throws: OrgsModel.SaveFailure.self) { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil) }
        let stored = Set(try await world.vault.inventory().keys)
        #expect(world.orgs.store.orgs.count == 3 && stored == ["a", "b", "m"])
    }

    /// P14: an edit typing only a Logs Stream token is refused, never saved as a rename that drops it.
    @Test func aLogsStreamTokenAloneIsRefused() async throws {
        let world = try await World.make(mosyle: true)
        let draft = MosyleDraft(name: "Mosyle m", logsToken: "logs", editing: try #require(world.orgs.store["m"]))
        await #expect(throws: OrgsModel.SaveFailure.refused(
            "To change the credentials, enter the access token, the admin's email and the password again, together.")) {
            try await world.orgs.saveMosyle(draft, editing: "m")
        }
    }

    /// P15: new credentials for an org not on screen read nothing again.
    @Test func anOffScreenEditDoesntSwitch() async throws {
        let world = try await World.make(mosyle: true)
        let other = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other"), editing: nil)
        let generation = world.orgs.generation
        try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other", base: other), editing: other.id)
        #expect(world.orgs.generation == generation)
    }

    /// P16: two sheets on one org: the later credentials-only save keeps the earlier rename.
    @Test func aLaterSheetKeepsAnEarlierRename() async throws {
        let world = try await World.make(mosyle: true)
        let opened = try #require(world.orgs.store["m"])
        try await world.orgs.saveMosyle(MosyleDraft(name: "Renamed", editing: opened), editing: "m")
        try await world.orgs.saveMosyle(MosyleOrgTests.draft(opened.name, base: opened), editing: "m")
        #expect(world.orgs.store["m"]?.name == "Renamed")
    }
}
