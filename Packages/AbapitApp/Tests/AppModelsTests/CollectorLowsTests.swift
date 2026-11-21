import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import Testing
import TestSupport

/// What the review of the collector (PR #34) left open, held after PRs #36 and #37: a refusal that outlived its run (L), a secret
/// nested in a kept attribute (R2), a list that failed part-way (R3), assignments counted as none when every list failed (R6),
/// and the removal question Settings asks about an org's history (plan: "removing an org offers to delete its history").
@MainActor
@Suite("Collector lows and org removal", .serialized)
struct CollectorLowsTests {
    // MARK: the refusal

    /// A refusal is about the run that was going: it ends with that run, and a new run clears it as it starts.
    @Test func aRefusalEndsWithTheRunItWasAbout() async throws {
        let world = try await CollectorTests.world()
        let gate = world.gates["a"]!
        gate.hold("users") { $0.path() == "/v1/users" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the users") { gate.held == 1 }
        #expect(await world.snapshots.run() == .notRun("A snapshot is already being taken."))
        #expect(world.snapshots.refusal == "A snapshot is already being taken.")
        gate.release("users")
        guard case .recorded = await running.value else {
            Issue.record("the first run didn't record")
            return
        }
        #expect(world.snapshots.refusal == nil, "the run it was about has ended")
        #expect(!world.snapshots.isRunning && !world.snapshots.isRunningForActiveOrg)
    }

    // MARK: R2

    /// R2, invariant 11 at depth: a secret-named key nested in a kept attribute (a package's `bundleIds`, a custom setting's values)
    /// never reaches the store: a nested object under a kept name is left out and counted, and a custom setting keeps its two inner keys.
    @Test func aSecretNestedInAKeptAttributeNeverReachesTheStore() async throws {
        let folder = try CollectorTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await CollectorTests.world(history: .success(try SnapshotStore(storage: .folder(folder), appVersion: "test")))
        let stub = world.stubs["a"]!
        stub.add([
            Resource(type: "packages", id: "P9", attributes: [
                "name": .string("Tool"),
                "bundleIds": .array([.string("com.example.tool"), .object(["password": .string("CANARYNESTEDPW"), "token": .string("CANARYNESTEDTOKEN")])]),
                "version": .object(["activation_bypass_code": .string("CANARYBYPASS")]),
            ]),
            Resource(type: "configurations", id: "C9", attributes: [
                "type": .string("CUSTOM_SETTING"), "name": .string("VPN"),
                "customSettingsValues": .object(["configurationProfile": .string("<plist/>"), "filename": .string("vpn.mobileconfig"),
                                                 "sharedSecret": .string("CANARYSHARED"), "nested": .object(["password": .string("CANARYDEEP")])]),
            ]),
        ])
        let snapshot = try await CollectorTests.recorded(world)
        let package = try #require(snapshot.resources["packages"]?.first { $0.id == "P9" })
        #expect(package.attributes["bundleIds"] == nil && package.attributes["version"] == nil && package.attributes["name"]?.string == "Tool",
                "a list holding an object, and an object under a kept name, are left out")
        #expect(snapshot.summary.notes["packages"]?.contains("left out 2 attributes") == true, "\(snapshot.summary.notes)")
        let setting = try #require(snapshot.resources["configurations"]?.first { $0.id == "C9" })
        #expect(setting.attributes["customSettingsValues"] == .null, "the list sends the profile as null: nothing nested is kept")
        // And the policy itself, for any caller (the import's too): only the two listed inner keys of a custom setting's values.
        let kept = SnapshotPolicy.keep(Resource(type: "configurations", id: "C", attributes: [
            "customSettingsValues": .object(["configurationProfile": .string("<plist/>"), "filename": .string("f"), "password": .string("CANARYSHARED")]),
        ]), SnapshotPolicy.configurations)
        #expect(kept.item.attributes["customSettingsValues"]?.object?.keys.sorted() == ["configurationProfile", "filename"] || kept.item.attributes["customSettingsValues"] == .null)
        var bytes = Data()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { bytes += try Data(contentsOf: file) }
        for canary in ["CANARYNESTEDPW", "CANARYNESTEDTOKEN", "CANARYBYPASS", "CANARYSHARED", "CANARYDEEP"] {
            #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(canary) reached the file")
        }
    }

    // MARK: R3 and R6

    /// R3: a list that failed part-way keeps what it read with its error (never a good copy), and what is built from it says "not
    /// read" rather than inventing: the assignments of a services list that failed part-way.
    @Test func aServicesListThatFailedPartWayIsKeptAndAssignmentsAreNotRead() async throws {
        let world = try await CollectorTests.world()
        world.stubs["a"]!.add(services: (3...1001).map { World.service(String(format: "S%04d", $0), name: "Service \($0)") })
        world.stubs["a"]!.queue(403, for: "/v1/mdmServers?cursor=")
        let snapshot = try await CollectorTests.recorded(world)
        #expect(snapshot.summary.counts["mdm_servers"] == 1000 && snapshot.summary.errors["mdm_servers"] == "HTTP 403")
        #expect(snapshot.resources["mdm_servers"]?.count == 1000, "what it read is kept")
        #expect(snapshot.summary.errors["assignments"] == "not read: mdm_servers failed" && snapshot.summary.counts["assignments"] == nil)
        guard case .failed(_, "HTTP 403", nil)? = try await world.history!.latest("mdm_servers", org: world.orgs.active!) else {
            Issue.record("a part read is a good copy")
            return
        }
    }

    /// R6: assignments are not read (never none) when every list failed, and when one failed and the rest were empty.
    @Test func assignmentsAreNeverCountedAsNoneWhenAListFailed() async throws {
        let every = try await CollectorTests.world()
        every.stubs["a"]!.forbid("/v1/mdmServers/S1/relationships")
        every.stubs["a"]!.forbid("/v1/mdmServers/S2/relationships")
        let none = try await CollectorTests.recorded(every)
        #expect(none.summary.counts["assignments"] == nil && none.summary.errors["assignments"] == "HTTP 403 FORBIDDEN_ERROR")
        #expect(none.resources["assignments"] == nil)

        // One list failed and the other has no device: still a failed read, with no count of zero.
        let one = try await CollectorTests.world(devices: ["a": 0, "b": 0])
        one.stubs["a"]!.assign("ADEV0000000", to: nil)
        one.stubs["a"]!.assign("ADEV0000001", to: nil)
        one.stubs["a"]!.forbid("/v1/mdmServers/S2/relationships")
        let part = try await CollectorTests.recorded(one)
        #expect(part.summary.counts["assignments"] == nil && part.summary.errors["assignments"] != nil, "\(part.summary.counts)")
    }

    // MARK: removing an org

    static func record(_ world: World, _ org: String, _ count: Int) async throws {
        for index in 0..<count {
            try await world.history!.record(org: world.orgs.store[org]!, takenAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 86_400),
                                            resources: ["devices": [ChangesTests.device("D\(index)")]])
        }
    }

    /// The question's words say what is deleted and that it can't be undone, and how many snapshots.
    @Test func theRemovalQuestionSaysWhatIsDeleted() {
        #expect(OrgsModel.removalHistoryNote(snapshots: 3)
                == "Its 3 snapshots in this Mac's history stay unless you delete them too, with its Needs-attention findings. Deleting them can't be undone: no copy is kept.")
        #expect(OrgsModel.removalHistoryNote(snapshots: 1).hasPrefix("Its 1 snapshot in this Mac's history stay unless you delete them too, with its"))
        #expect(OrgsModel.removalHistoryNote(snapshots: 0) == "It has no snapshots in this Mac's history.")
        #expect(OrgsModel.removalHistoryNote(snapshots: nil) == "Its snapshot history couldn't be read, so it is kept.")
    }

    /// Removing an org keeps its history unless the operator says yes to deleting it: then it, and only it, goes.
    @Test func removingAnOrgDeletesItsHistoryOnlyOnAYes() async throws {
        let world = try await World.make()
        try await Self.record(world, "a", 3)
        try await Self.record(world, "b", 2)
        let a = try #require(world.orgs.store["a"]), b = try #require(world.orgs.store["b"])
        let counts = [await world.orgs.historySnapshots(of: "a"), await world.orgs.historySnapshots(of: "b"), await world.orgs.historySnapshots(of: "nobody")]
        #expect(counts == [3, 2, nil])
        // No: the profile and its key go, its history stays (and its id with it).
        try await world.orgs.remove("b", deleteSecrets: true, deleteHistory: false)
        #expect(world.orgs.store["b"] == nil)
        #expect(try await world.history!.snapshots(org: b).count == 2, "kept without a yes")
        #expect(try await world.history!.orgIDs() == ["a", "b"])
        // The default is no.
        try await world.orgs.remove("a", deleteSecrets: true)
        #expect(try await world.history!.snapshots(org: a).count == 3)
        // Yes: another org's history stays, this one's goes.
        let again = try await World.make()
        try await Self.record(again, "a", 3)
        try await Self.record(again, "b", 2)
        try await again.orgs.remove("a", deleteSecrets: true, deleteHistory: true)
        #expect(again.orgs.store["a"] == nil)
        #expect(try await again.history!.snapshots(org: a).isEmpty, "deleted on a yes")
        let others = try await again.history!.snapshots(org: b).count, ids = try await again.history!.orgIDs()
        #expect(others == 2 && ids == ["b"], "another org's history stays")
    }

    /// The history deleted is the removed org's, not the active org's, and the count is a count, not a list.
    @Test func removingANonActiveOrgDeletesItsHistoryAndNotTheActiveOnes() async throws {
        let world = try await World.make()
        #expect(world.orgs.active?.id == "a")
        try await Self.record(world, "a", 3)
        try await Self.record(world, "b", 105)
        let counted = await world.orgs.historySnapshots(of: "b")
        #expect(counted == 105, "every snapshot is counted, not the first hundred")
        let a = try #require(world.orgs.store["a"]), b = try #require(world.orgs.store["b"])
        try await world.orgs.remove("b", deleteSecrets: true, deleteHistory: true)
        let underA = try await world.history!.snapshots(org: a).count, underB = try await world.history!.snapshots(org: b).count
        let ids = try await world.history!.orgIDs()
        #expect(underA == 3 && underB == 0 && ids == ["a"], "a's history stays, b's is gone")
        #expect(world.orgs.active?.id == "a")
    }

    /// A history that can't be deleted refuses the removal and leaves the org, its key and its history as they were.
    @Test func aHistoryThatCantBeDeletedKeepsTheOrg() async throws {
        let failure = SnapshotStore.Failure.readOnly(version: 9)
        let world = try await World.make(history: { .failure(failure) })
        await #expect(throws: SnapshotStore.Failure.self) { try await world.orgs.remove("b", deleteSecrets: true, deleteHistory: true) }
        #expect(world.orgs.store["b"] != nil, "the org stays")
        #expect(await world.keyWorks("b"), "and its key")
        #expect(await world.orgs.historySnapshots(of: "b") == nil)
        // Without a yes the history isn't asked for, so the removal goes through.
        try await world.orgs.remove("b", deleteSecrets: true)
        #expect(world.orgs.store["b"] == nil)
    }
}
