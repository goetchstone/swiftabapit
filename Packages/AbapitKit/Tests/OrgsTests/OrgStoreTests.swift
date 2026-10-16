import Foundation
import JSONAPI
import Testing
@testable import Orgs

@Suite("Org store")
struct OrgStoreTests {
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftabapit-orgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func apple(_ store: OrgStore, _ name: String, client: String) -> OrgProfile {
        var profile = OrgProfile(id: store.uniqueID(for: name), name: name, provider: .apple)
        profile.clientID = client
        profile.keyID = "key-\(client)"
        return profile
    }

    /// abapit's `slugify`, outputs taken from Python at the pin.
    @Test(arguments: [("Acme Corp", "acme-corp"), ("  Acme  ", "acme"), ("Caf\u{E9} \u{DC}n\u{EF}code", "caf-n-code"), ("---", "org"),
                      ("", "org"), ("ACME-2", "acme-2"), ("a__b..c", "a-b-c"), ("Example School (K-12)", "example-school-k-12"),
                      ("\u{130}stanbul", "i-stanbul")])
    func idsFollowAbapitsSlugRules(name: String, slug: String) {
        #expect(OrgStore().uniqueID(for: name) == slug)
    }

    @Test func idsAreUniqueAndShortEnoughForTheKeychain() throws {
        var store = OrgStore()
        try store.add(Self.apple(store, "Acme", client: "BUSINESSAPI.1"))
        #expect(store.uniqueID(for: "ACME") == "acme-2")
        #expect(store.uniqueID(for: String(repeating: "x", count: 200)).count == 48)
    }

    @Test func aClientIDIsUsedOnce() throws {
        var store = OrgStore()
        try store.add(Self.apple(store, "One", client: "BUSINESSAPI.1"))
        #expect(throws: OrgStore.Failure.duplicateClientID("BUSINESSAPI.1")) { try store.add(Self.apple(store, "Two", client: "BUSINESSAPI.1")) }
        var two = Self.apple(store, "Two", client: "BUSINESSAPI.2")
        try store.add(two)
        two.clientID = "BUSINESSAPI.1"
        #expect(throws: OrgStore.Failure.duplicateClientID("BUSINESSAPI.1")) { try store.update(two) }
    }

    @Test func everyFieldClearsAndTheFirstOrgIsActive() throws {
        var store = OrgStore()
        var profile = Self.apple(store, "Acme", client: "BUSINESSAPI.1")
        profile.teamID = "TEAM1"
        #expect(profile.issuer == "TEAM1")
        profile.teamID = "  "
        #expect(profile.raw["team_id"] == nil)
        #expect(profile.issuer == "BUSINESSAPI.1")
        try store.add(profile)
        #expect(store.active?.id == "acme")
    }

    @Test func aNewerFieldSurvivesAnEditAndASave() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"{"version": 1, "active": "acme", "orgs": [{"id": "acme", "name": "Acme", "provider": "apple", "scope": "business", "client_id": "BUSINESSAPI.1", "key_id": "k", "future_field": {"x": [1, 2]}}, {"id": "next", "name": "Next", "provider": "jamf"}]}"#
        try Data(text.utf8).write(to: dir.appending(path: OrgStore.fileName))
        var store = try OrgStore.load(from: dir)
        #expect(store.orgs.count == 2)
        #expect(store["next"]?.problem?.contains("jamf") == true)
        var acme = try #require(store["acme"])
        acme.name = "Acme Inc"
        try store.update(acme)
        try store.save(to: dir)
        let again = try OrgStore.load(from: dir)
        #expect(again["acme"]?.name == "Acme Inc")
        #expect(again["acme"]?.raw["future_field"]?["x"] == .array([.number("1"), .number("2")]))
        #expect(again["next"]?.provider == .unknown("jamf"))
    }

    /// Review findings on the store: each one a load, an edit or a save that lost or mixed something.
    @Test func anIDIsUsedOnceAndAStoredOrgsIDIsNotReused() throws {
        var store = OrgStore()
        try store.add(Self.apple(store, "Acme", client: "BUSINESSAPI.1"))
        let twin = OrgProfile(id: "acme", name: "Acme again", provider: .mosyle)
        #expect(throws: OrgStore.Failure.duplicateID("acme")) { try store.add(twin) }
        // "acme-2" was removed from the file but its Keychain items are still there: a new org doesn't inherit them.
        #expect(store.uniqueID(for: "Acme", avoiding: ["acme-2", "acme-3"]) == "acme-4")
        #expect(store.uniqueID(for: "Acme", avoiding: ["acme-2"]) == "acme-3")
    }

    @Test func clientIDsCompareTrimmedAndCaseInsensitive() throws {
        var store = OrgStore()
        try store.add(Self.apple(store, "One", client: "BUSINESSAPI.abc"))
        for spelling in ["businessapi.ABC", " BUSINESSAPI.abc\n", "BUSINESSAPI.ABC"] {
            let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(throws: OrgStore.Failure.duplicateClientID(trimmed)) { try store.add(Self.apple(store, "Two", client: spelling)) }
        }
        var mosyle = OrgProfile(id: "m", name: "M", provider: .mosyle)
        mosyle.clientID = "BUSINESSAPI.abc"
        try store.add(mosyle)
    }

    @Test func whatThisVersionCantReadSurvivesASave() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"{"version": 1, "active": "acme", "sync": {"every": 5}, "orgs": [{"id": "acme", "name": "Acme", "provider": "apple"}, {"name": "no id"}, 7]}"#
        try Data(text.utf8).write(to: dir.appending(path: OrgStore.fileName))
        var store = try OrgStore.load(from: dir)
        #expect(store.orgs.map(\.id) == ["acme"])
        try store.add(Self.apple(store, "Beta", client: "BUSINESSAPI.2"))
        try store.save(to: dir)
        let saved = try #require(JSONValue.parse(String(contentsOf: dir.appending(path: OrgStore.fileName), encoding: .utf8))?.object)
        #expect(saved["sync"] == .object(["every": .number("5")]))
        let orgs = try #require(saved["orgs"]?.array)
        #expect(orgs.contains(.object(["name": .string("no id")])))
        #expect(orgs.contains(.number("7")))
        #expect(try OrgStore.load(from: dir).orgs.map(\.id) == ["acme", "beta"])
    }

    @Test func aLearnedRateIsAlwaysAFiniteNumber() {
        var profile = OrgProfile(id: "a", name: "A", provider: .apple)
        for rate in [Double.nan, .infinity, -.infinity, -3, 0] {
            profile.learnedReadsPerMinute = rate
            #expect(profile.raw["learned_reads_per_minute"] == nil, "\(rate)")
            #expect(profile.learnedReadsPerMinute == 0)
        }
        profile.learnedReadsPerMinute = 42.5
        #expect(profile.learnedReadsPerMinute == 42.5)
    }

    @Test func aFileFromANewerVersionIsNeverWrittenOver() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"version": 2, "orgs": []}"#.utf8).write(to: dir.appending(path: OrgStore.fileName))
        let store = try OrgStore.load(from: dir)
        #expect(throws: OrgStore.Failure.newerVersion(2)) { try store.save(to: dir) }
    }

    @Test func theFileIsPrivateAndNeverWrittenThroughALink() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = OrgStore()
        try store.add(Self.apple(store, "Acme", client: "BUSINESSAPI.1"))
        try store.save(to: dir)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: OrgStore.fileName).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // A link planted at the name: the save replaces the link itself, and the outside file is untouched.
        let outside = dir.appending(path: "outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.removeItem(at: dir.appending(path: OrgStore.fileName))
        try FileManager.default.createSymbolicLink(at: dir.appending(path: OrgStore.fileName), withDestinationURL: outside)
        #expect(throws: OrgStore.Failure.self) { try OrgStore.load(from: dir) }
        try store.save(to: dir)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(try OrgStore.load(from: dir).orgs.count == 1)
    }

    @Test func notAnOrgFileIsLeftAlone() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appending(path: OrgStore.fileName))
        #expect(throws: OrgStore.Failure.notAnOrgFile) { try OrgStore.load(from: dir) }
        #expect(try OrgStore.load(from: dir.appending(path: "missing")).orgs.isEmpty)
    }

    @Test func removingAnOrgClearsItsPairingAndTheActiveOrg() throws {
        var store = OrgStore()
        try store.add(Self.apple(store, "Acme", client: "BUSINESSAPI.1"))
        var mosyle = OrgProfile(id: store.uniqueID(for: "Acme Mosyle"), name: "Acme Mosyle", provider: .mosyle)
        mosyle.pairedOrg = "acme"
        try store.add(mosyle)
        store.remove("acme")
        #expect(store.activeID == "acme-mosyle")
        #expect(store["acme-mosyle"]?.pairedOrg == "")
    }
}
