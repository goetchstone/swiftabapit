import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import Testing
import TestSupport

/// abapit's history store, held to `Tests/Fixtures/parity/history.json` through the import (invariant 6): a fake abapit database
/// is made from the golden's own schema and seed, imported (org A as the active client, then org B), and abapit's reads
/// (`list_snapshots`, `latest_resource`, `snapshot_resource`) are asked of this app's store and compared with what abapit
/// answered. The differences are the import's, each listed here and in docs/domains/history.md:
///
/// 1. **Ids.** The store gives its own ids, so a case's snapshot is found by its `taken_at` (unique in the seed).
/// 2. **The snapshot policy.** An attribute off the allowlist isn't stored: the seed's `flag`, `tags` and `note` (a device) and
///    `name` (a user). Expected items are abapit's, their attributes cut to the policy's list for the resource.
/// 3. **Error text.** abapit's `errors` hold text; the store holds the code `abapit error`. Keys are compared, values aren't.
/// 4. **`org_name` and `abapit_version`**: the store's snapshot carries the org's name here, not the name abapit saw then
///    (`Demo Org A (renamed)`), and `abapit 0.2.0` where abapit has `0.2.0`.
/// 5. **`limit` -1**: abapit's SQLite reads it as no limit; the store's `snapshots(org:limit:)` clamps a negative limit to none
///    returned (PR #30), so that one case is not wired and `aNegativeLimitIsTheStoresClamp` says what the store does.
/// 6. **A client ID no org has** (`DEMO-ORG-NONE`, empty): this app asks by org, so there is no call to make; the golden's answer
///    (nothing) is checked to be what no org here has.
/// 7. **Snapshot ids that don't exist** (4 and 7): no snapshot to ask; abapit's answer (nothing) is checked against the seed.
///
/// Plan defect 13 (`latest_resource` showing an older copy as current when the newest snapshot failed) shows in none of the
/// golden's cases, since an imported snapshot's `counts` hold only resources with items; `HistoryTransferTests.
/// aFailureAtTheNewestSnapshotIsNotHiddenByAnOlderCopy` holds the deviation itself.
@MainActor
@Suite("History import parity", .serialized)
struct HistoryImportParityTests {
    let golden: JSONValue
    let world: World
    let folder: URL

    /// Attributes the seed carries that the snapshot policy leaves out, as the listed difference 2 says.
    static let leftOutBySeed: Set<String> = ["flag", "tags", "note", "name"]

    init() async throws {
        golden = try Fixtures.parityValue("history")
        folder = try CollectorTests.folder()
        var a = World.profile("a"), b = World.profile("b")
        a.clientID = "DEMO-ORG-A"
        b.clientID = "DEMO-ORG-B"
        world = try await World.make(profiles: [a, b])
        let seed = try req(golden["seed"]?.object)
        var rows: [HistoryTransferTests.Row] = []
        for snapshot in try req(seed["snapshots"]?.array).compactMap(\.object) {
            let id = Int64(try req(snapshot["id"]?.int))
            var row = HistoryTransferTests.Row(id: id, takenAt: try req(snapshot["taken_at"]?.string), client: try req(snapshot["org_client_id"]?.string),
                                               name: try req(snapshot["org_name"]?.string), scope: try req(snapshot["org_scope"]?.string),
                                               version: try req(snapshot["abapit_version"]?.string), errors: try req(snapshot["errors"]?.string))
            for item in try req(seed["items"]?.array).compactMap(\.object) where item["snapshot_id"]?.int == Int(id) {
                row.items.append((try req(item["resource"]?.string), try req(item["item_id"]?.string), try req(item["attributes"]?.object)))
            }
            rows.append(row)
        }
        let path = try HistoryTransferTests.abapitFile(rows, in: folder)
        let transfer = world.screens.historyTransfer
        for client in ["a", "b"] {
            world.orgs.selectClient(try req(world.orgs.store.client(of: client)).id)
            guard case .imported = await transfer.importHistory(from: URL(filePath: path)) else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    func cases(_ call: String) throws -> [JSONObject] {
        try req(golden["cases"]?.array).compactMap(\.object).filter { $0["call"]?.string == call }
    }

    func org(_ clientID: String) -> OrgProfile? { world.orgs.store.orgs.first { $0.clientID == clientID } }

    /// abapit's seed snapshot with this id.
    func seeded(_ id: Int) throws -> JSONObject {
        try req(try req(golden["seed"]?["snapshots"]?.array).compactMap(\.object).first { $0["id"]?.int == id })
    }

    /// The store's snapshot for abapit's snapshot `id` (found by its time, in its org).
    func imported(_ id: Int) async throws -> SnapshotStore.Summary {
        let seed = try seeded(id)
        let profile = try req(org(try req(seed["org_client_id"]?.string)))
        let found = try await world.history!.snapshots(org: profile).filter { $0.takenAt == seed["taken_at"]?.string }
        return try req(found.count == 1 ? found.first : nil)
    }

    /// An abapit item as the policy keeps it: its attributes cut to the resource's list, by bytes.
    func kept(_ resource: String, _ attributes: JSONObject, dropped: inout Set<String>) throws -> String {
        let rule = try req(SnapshotPolicy.all.first { Array($0.name.utf8) == Array(resource.utf8) })
        let allowed = Set(rule.kept.map { Array($0.utf8) })
        var out = JSONObject()
        for member in attributes.members {
            if allowed.contains(Array(member.key.utf8)) { out[member.key] = member.value } else { dropped.insert(member.key) }
        }
        return JSONValue.object(out).jsonText
    }

    func expectedItems(_ value: JSONValue?, dropped: inout Set<String>) throws -> [[String]] {
        try req(value?.array).compactMap(\.object).map {
            [try req($0["id"]?.string), try kept(try req($0["type"]?.string), try req($0["attributes"]?.object), dropped: &dropped)]
        }
    }

    func actualItems(_ items: [Resource]) -> [[String]] { items.map { [$0.id, JSONValue.object($0.attributes).jsonText] } }

    // MARK: the reads

    @Test func listSnapshotsMatchesWhereTheImportCanAnswer() async throws {
        var wired = 0
        for item in try cases("list_snapshots") {
            let args = try req(item["args"]?.object), client = try req(args["org_client_id"]?.string)
            let limit = args["limit"]?.int
            let expected = try req(item["expected"]?["ok"]?.array).compactMap(\.object)
            guard let profile = org(client) else {
                #expect(expected.isEmpty, "difference 6: no org here has \(client)")
                continue
            }
            if let limit, limit < 0 { continue }  // difference 5
            let found = try await world.history!.snapshots(org: profile, limit: limit ?? 100)
            #expect(found.count == expected.count, "\(args)")
            for (summary, row) in zip(found, expected) {
                #expect(Array(summary.takenAt.utf8) == Array((row["taken_at"]?.string ?? "").utf8), "\(args)")
                #expect(summary.clientID == row["org_client_id"]?.string && summary.orgScope == row["org_scope"]?.string)
                #expect(summary.deviceCount == row["device_count"]?.int, "\(args)")
                // difference 3: the keys of abapit's errors, each a code now.
                let keys = (try req(JSONValue.parse(try req(row["errors"]?.string))?.object)).keys.sorted()
                #expect(summary.errors.keys.sorted() == keys && summary.errors.values.allSatisfy { $0 == "abapit error" }, "\(args)")
                // difference 4
                let version = try req(try seeded(try req(row["id"]?.int))["abapit_version"]?.string)
                #expect(summary.orgName == profile.name && summary.writtenBy == "abapit " + version)
            }
            wired += 1
        }
        #expect(wired == 5, "A: nil, 1, 2, 0; B: nil")
    }

    /// Difference 5.
    @Test func aNegativeLimitIsTheStoresClamp() async throws {
        let item = try req(try cases("list_snapshots").first { $0["args"]?["limit"]?.int == -1 })
        #expect((try req(item["expected"]?["ok"]?.array)).count == 4, "abapit: no limit")
        #expect(try await world.history!.snapshots(org: try req(org("DEMO-ORG-A")), limit: -1).isEmpty, "the store: none")
    }

    @Test func latestResourceMatchesAbapit() async throws {
        var dropped: Set<String> = []
        for item in try cases("latest_resource") {
            let args = try req(item["args"]?.object)
            let client = try req(args["org_client_id"]?.string), resource = try req(args["resource"]?.string)
            let expected = try req(item["expected"]?["ok"])
            guard let profile = org(client) else {
                #expect(expected == .null, "difference 6: no org here has \(client)")
                continue
            }
            let latest = try await world.history!.latest(resource, org: profile)
            if expected == .null {
                #expect(latest == nil, "\(args)")
                continue
            }
            guard case .read(let copy)? = latest else { Issue.record("\(args): \(String(describing: latest))"); continue }
            let parts = try req(expected.array)
            let seed = try seeded(try req(parts[0].int))
            #expect(copy.summary.takenAt == parts[1].string && copy.summary.takenAt == seed["taken_at"]?.string, "\(args)")
            #expect(actualItems(copy.items) == (try expectedItems(parts[2], dropped: &dropped)), "\(args)")
        }
        #expect(dropped.isSubset(of: Self.leftOutBySeed), "\(dropped)")
    }

    @Test func snapshotResourceMatchesAbapit() async throws {
        var dropped: Set<String> = [], wired = 0
        for item in try cases("snapshot_resource") {
            let args = try req(item["args"]?.object)
            let id = try req(args["snapshot_id"]?.int), resource = try req(args["resource"]?.string)
            let expected = try req(item["expected"]?["ok"])
            guard (try? seeded(id)) != nil else {
                #expect(expected.array?.isEmpty == true, "difference 7: abapit has no snapshot \(id)")
                continue
            }
            let summary = try await imported(id)
            let profile = try req(org(summary.clientID))
            let snapshot = try await world.history!.load(summary.id, org: profile)
            #expect(actualItems(snapshot.resources[resource] ?? []) == (try expectedItems(expected, dropped: &dropped)), "\(args)")
            wired += 1
        }
        #expect(wired == 8 && dropped.isSubset(of: Self.leftOutBySeed) && !dropped.isEmpty, "\(dropped)")
    }

    /// Every attribute the policy left out of the seed is one difference 2 lists, and nothing else of the seed was lost.
    @Test func onlyTheListedAttributesAreLeftOut() async throws {
        var dropped: Set<String> = []
        for item in try req(golden["seed"]?["items"]?.array).compactMap(\.object) {
            _ = try kept(try req(item["resource"]?.string), try req(item["attributes"]?.object), dropped: &dropped)
        }
        #expect(dropped == Self.leftOutBySeed)
    }
}

/// An optional that must be there, without `#require`'s macro (which can't nest).
func req<T>(_ value: T?, _ line: UInt = #line) throws -> T {
    guard let value else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "missing at line \(line)"]) }
    return value
}
