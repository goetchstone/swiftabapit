import AppleBusiness
import AppModels
import CryptoKit
import Foundation
import Orgs
import Testing
import TestSupport
import Vault

/// A change that can't be saved isn't made: nothing is written over a file that wasn't read, and nothing reaches or leaves
/// the Keychain for an organization the file can't hold (failure-log 2026-11-12 held this at launch only).
@Suite("The organizations file guards its saves")
@MainActor
struct StoreGuardTests {
    /// A file cut off part-way: not one this app can read.
    static let cut = #"{"version": 2, "active": "acme", "orgs": [{"id": "acme", "name": "Acme", "provider": "apple"}, {"id": "beta", "na"#
    /// A newer version's file with one Mosyle org in it.
    static let newer = #"{"version": 3, "active": "acme", "orgs": [{"id": "acme", "name": "Acme", "provider": "mosyle"}], "clients": [{"id": "c1", "name": "Acme", "mdm": "acme"}]}"#
    /// A readable version-2 file holding one customer with an Apple org and its Mosyle org.
    static let paired = #"{"version": 2, "active": "a", "orgs": [{"id": "a", "name": "A", "provider": "apple"}, {"id": "m", "name": "M", "provider": "mosyle"}], "clients": [{"id": "c1", "name": "A", "apple": "a", "mdm": "m"}]}"#
    static let refusal = OrgsModel.SaveFailure.refused(OrgStore.Failure.newerVersion(3).message)

    static func folder(holding text: String, settings: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "store-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: OrgStore.fileName))
        if let settings { try Data(settings.utf8).write(to: folder.appending(path: LocalSettings.fileName)) }
        return folder
    }

    static func model(_ folder: URL, _ vault: Vault) -> OrgsModel {
        OrgsModel(storage: .folder(folder), vault: vault, history: { World.history() }) { account, _ in
            AppleClient(account: account, vault: vault, transport: AppleStub())
        }
    }

    static func text(_ folder: URL, _ name: String = OrgStore.fileName) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    static let mosyleDraft = MosyleDraft(name: "New org", accessToken: "a", email: "b@example.com", password: "c")

    static var appleDraft: OrgDraft {
        var draft = OrgDraft()
        (draft.name, draft.clientID, draft.keyID) = ("New org", World.clientID("c"), World.keyID("c"))
        return draft
    }

    /// A file that couldn't be read is never written over, at launch or by a later Add, and nothing reaches the Keychain.
    @Test func anUnreadableFileIsNeverWrittenOver() async throws {
        let folder = try Self.folder(holding: Self.cut)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        let orgs = Self.model(folder, vault)
        #expect(orgs.problem == OrgStore.Failure.notAnOrgFile.message)
        await #expect(throws: OrgsModel.SaveFailure.self) { try await orgs.saveMosyle(Self.mosyleDraft, editing: nil) }
        #expect(try Self.text(folder) == Self.cut)
        #expect(try await vault.inventory().isEmpty, "nothing was stored for an organization that can't be saved")
        #expect(orgs.store.orgs.isEmpty && orgs.problem == OrgStore.Failure.notAnOrgFile.message)
        // A save no refusal stands in front of (dismissing the notes saves) writes nothing either.
        orgs.dismissMigrationNotes()
        #expect(try Self.text(folder) == Self.cut)
    }

    /// The refusal says why in words, and what to do: the Add sheet shows it.
    @Test func theRefusalOverAnUnreadableFileSaysWhyAndWhatToDo() async throws {
        let folder = try Self.folder(holding: Self.cut)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orgs = Self.model(folder, Vault(store: MemoryStore()))
        do {
            _ = try await orgs.saveMosyle(Self.mosyleDraft, editing: nil)
            Issue.record("the Add was accepted")
        } catch {
            #expect(error.message.contains(OrgStore.Failure.notAnOrgFile.message))
            #expect(error.message.contains("Move or repair that file"))
        }
    }

    /// An Apple Add over an unreadable file stores no key either.
    @Test func anUnreadableFileRefusesAnAppleAddBeforeTheKeychain() async throws {
        let folder = try Self.folder(holding: Self.cut)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        let orgs = Self.model(folder, vault)
        let key = try World.imported(P256.Signing.PrivateKey())
        await #expect(throws: OrgsModel.SaveFailure.self) { try await orgs.save(Self.appleDraft, key: key, editing: nil) }
        #expect(try await vault.inventory().isEmpty)
        #expect(try Self.text(folder) == Self.cut)
    }

    /// A file a newer version wrote refuses a Mosyle Add before its credentials are stored.
    @Test func aNewerVersionsFileRefusesAnAddBeforeTheKeychain() async throws {
        let folder = try Self.folder(holding: Self.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        let orgs = Self.model(folder, vault)
        await #expect(throws: Self.refusal) { try await orgs.saveMosyle(Self.mosyleDraft, editing: nil) }
        #expect(try Self.text(folder) == Self.newer)
        #expect(try await vault.inventory().isEmpty && orgs.store.orgs.map(\.id) == ["acme"])
    }

    /// And an Apple Add before its key is stored.
    @Test func aNewerVersionsFileRefusesAnAppleAddBeforeTheKeychain() async throws {
        let folder = try Self.folder(holding: Self.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        let orgs = Self.model(folder, vault)
        let key = try World.imported(P256.Signing.PrivateKey())
        await #expect(throws: Self.refusal) { try await orgs.save(Self.appleDraft, key: key, editing: nil) }
        #expect(try await vault.inventory().isEmpty && orgs.store.orgs.map(\.id) == ["acme"])
    }

    /// An edit of an org the file holds is refused too, before its credentials are replaced.
    @Test func aNewerVersionsFileRefusesAnEditBeforeTheKeychain() async throws {
        let folder = try Self.folder(holding: Self.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        let orgs = Self.model(folder, vault)
        let base = try #require(orgs.store["acme"])
        let draft = MosyleDraft(name: "Renamed", accessToken: "a", email: "b@example.com", password: "c", editing: base)
        await #expect(throws: Self.refusal) { try await orgs.saveMosyle(draft, editing: "acme") }
        #expect(try await vault.inventory().isEmpty)
    }

    /// A removal this version can't save would delete the secrets and bring the organization back at the next launch.
    @Test func aNewerVersionsFileRefusesARemovalBeforeTheKeychain() async throws {
        let folder = try Self.folder(holding: Self.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: MemoryStore())
        try await vault.store(Secret("t"), as: try #require(VaultItem(org: "acme", kind: .mosyleAccessToken)))
        let orgs = Self.model(folder, vault)
        await #expect(throws: Self.refusal) { try await orgs.remove("acme", deleteSecrets: true) }
        #expect(try await vault.inventory() == ["acme": [.mosyleAccessToken]])
        #expect(orgs.store["acme"] != nil)
        #expect(try Self.text(folder) == Self.newer)
    }

    /// A move or a rename this version can't save isn't made.
    @Test func aNewerVersionsFileRefusesAMoveAndARename() throws {
        let folder = try Self.folder(holding: Self.newer)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orgs = Self.model(folder, Vault(store: MemoryStore()))
        let client = try #require(orgs.store.client(of: "acme"))
        #expect(throws: Self.refusal) { try orgs.move("acme", toClient: nil) }
        #expect(throws: Self.refusal) { try orgs.renameClient(client.id, to: "Other") }
        #expect(orgs.store.client(of: "acme")?.name == client.name)
    }

    /// `settings.json` has its own guard: a file that can't be read is never written over by a change, and the screen is told.
    @Test func anUnreadableSettingsFileIsNeverWrittenOver() throws {
        let junk = "not a settings file"
        let folder = try Self.folder(holding: Self.paired, settings: junk)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orgs = Self.model(folder, Vault(store: MemoryStore()))
        #expect(throws: LocalSettings.Failure.self) {
            try orgs.changeSettings { (settings: inout LocalSettings) throws(LocalSettings.Failure) in
                settings.dropMosyleService(for: "c1")
            }
        }
        #expect(try Self.text(folder, LocalSettings.fileName) == junk)
        #expect(orgs.settings.blocked != nil)
    }

    /// A move that drops a client's service setting over an unreadable `settings.json` writes nothing, and says so.
    @Test func aMoveOverAnUnreadableSettingsFileLeavesItAndSaysWhy() throws {
        let junk = "not a settings file"
        let folder = try Self.folder(holding: Self.paired, settings: junk)
        defer { try? FileManager.default.removeItem(at: folder) }
        let orgs = Self.model(folder, Vault(store: MemoryStore()))
        try orgs.move("m", toClient: nil)
        #expect(try OrgStore.load(from: folder).client(of: "m")?.id != "c1", "the move itself was made and saved")
        #expect(try Self.text(folder, LocalSettings.fileName) == junk)
        #expect(orgs.settingsProblem != nil)
    }
}
