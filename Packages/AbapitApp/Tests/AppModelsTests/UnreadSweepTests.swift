import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import Testing
import TestSupport

/// A snapshot records which devices each per-device sweep didn't read (`SnapshotStore.Summary.unread`; docs/domains/history.md, "The
/// sweeps"): the same devices the note's "N of M not read" counts, plus the devices whose own coverage list the page cap cut. Ids
/// only, none longer than the list the sweep covers. A sweep that wasn't run has no key; one that ran and missed none has an empty list.
/// The real collector over the strict stub, into a real `SnapshotStore`.
@MainActor
@Suite("Unread devices, recorded", .serialized)
struct UnreadSweepTests {
    /// The N of the note's "N of M devices not read", nil when the note holds none.
    static func noted(_ summary: SnapshotStore.Summary, _ resource: String) -> Int? {
        guard let note = summary.notes[resource], let match = note.firstMatch(of: /(\d+) of \d+ devices? not read/) else { return nil }
        return Int(match.1)
    }

    /// Every sweep's list holds only ids of the list it covers, and no more of them (the bound), never a name or an attribute.
    static func bounded(_ snapshot: SnapshotStore.Snapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        for (resource, ids) in snapshot.summary.unread {
            let covers = resource == "mdm_details" ? "mdm_enrolled" : "devices"
            let listed = Set((snapshot.resources[covers] ?? []).map(\.id))
            #expect(ids.count <= listed.count && Set(ids).isSubset(of: listed), "\(resource): \(ids) of \(listed)", sourceLocation: sourceLocation)
            #expect(ids == ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } && Set(ids).count == ids.count, "\(resource) sorted, once each", sourceLocation: sourceLocation)
        }
    }

    /// A device whose read failed twice: its id is in `unread`, and the count is the note's.
    @Test func aDeviceThatFailedTwiceIsRecorded() async throws {
        let world = try await SweepTests.world()
        let a = world.stubs["a"]!
        for _ in 0..<2 {
            a.queue(500, for: SweepTests.care(3))
            a.queue(500, for: SweepTests.lock(1))
            a.queue(500, for: "/v1/mdmDevices/\(SweepTests.serial(0))/details")
        }
        let snapshot = try await SweepTests.recorded(world)
        let summary = snapshot.summary
        #expect(summary.unread == ["applecare": [SweepTests.serial(3)], "activation_lock": [SweepTests.serial(1)], "mdm_details": [SweepTests.serial(0)]], "\(summary.unread)")
        for resource in ["applecare", "activation_lock", "mdm_details"] {
            #expect(Self.noted(summary, resource) == summary.unread[resource]?.count, "\(resource): \(summary.notes[resource] ?? "")")
        }
        Self.bounded(snapshot)
    }

    /// An id that can't go in a path is never sent, and is recorded as not read: its count is the note's.
    @Test func anUnsendableDeviceIsRecorded() async throws {
        let world = try await SweepTests.world()
        world.stubs["a"]!.add(devices: [Resource(type: "orgDevices", id: "BAD SERIAL/1", attributes: ["serialNumber": .string("BAD SERIAL/1")])])
        let snapshot = try await SweepTests.recorded(world, [.appleCare, .activationLock])
        for resource in ["applecare", "activation_lock"] {
            #expect(snapshot.summary.unread[resource] == ["BAD SERIAL/1"] && Self.noted(snapshot.summary, resource) == 1, "\(resource)")
        }
        Self.bounded(snapshot)
    }

    /// A 403 stops that sweep: every device not asked is recorded, and the count is the note's. The other sweep, whole, has an empty list.
    @Test func devicesNotAskedAfterTheSweepStoppedAreRecorded() async throws {
        let world = try await SweepTests.world(devices: 12)
        for index in 0..<12 { world.stubs["a"]!.queue(403, for: SweepTests.lock(index)) }
        let snapshot = try await SweepTests.recorded(world, [.appleCare, .activationLock])
        let lock = try #require(snapshot.summary.unread["activation_lock"])
        #expect(lock.count == 12 && Self.noted(snapshot.summary, "activation_lock") == 12 && Set(lock) == Set((0..<12).map(SweepTests.serial)), "\(lock)")
        #expect(snapshot.summary.counts["activation_lock"] == nil, "nothing was read, yet the devices are still named")
        // AppleCare ran whole: recorded, none missed.
        #expect(snapshot.summary.unread["applecare"] == [] && snapshot.summary.errors["applecare"] == nil)
        Self.bounded(snapshot)
    }

    /// Failed, unsendable and not asked together: every way a device goes unread, one list, the note's total.
    @Test func everyWayADeviceGoesUnreadCountsTheSame() async throws {
        let world = try await SweepTests.world(devices: 6)
        let a = world.stubs["a"]!
        a.add(devices: [Resource(type: "orgDevices", id: "BAD SERIAL/1", attributes: ["serialNumber": .string("BAD SERIAL/1")])])
        for _ in 0..<2 { a.queue(500, for: SweepTests.lock(2)) }
        let snapshot = try await SweepTests.recorded(world, [.activationLock])
        let summary = snapshot.summary
        #expect(Set(summary.unread["activation_lock"] ?? []) == ["BAD SERIAL/1", SweepTests.serial(2)])
        #expect(Self.noted(summary, "activation_lock") == 2 && summary.notes["activation_lock"] == "2 of 7 devices not read: 1 failed twice (HTTP 500); 1 has an id Apple can't be asked for")
        // Not asked: the 403 case above; a sign-in failure, below, stops the run.
        Self.bounded(snapshot)
    }

    /// A device whose own coverage list the page cap cut was read in part: recorded, and said in the note's other count (the cut one).
    @Test func aDeviceWhoseCoverageWasCutIsRecorded() async throws {
        let world = try await SweepTests.world(pageCap: 1)
        world.stubs["a"]!.setCoverage(SweepTests.serial(0), (0...1000).map { SweepTests.coverage(String(format: "CUT%05d", $0), "AppleCare+", payment: "SUBSCRIPTION") })
        let snapshot = try await SweepTests.recorded(world, [.appleCare])
        #expect(snapshot.summary.unread["applecare"] == [SweepTests.serial(0)])
        #expect(snapshot.summary.notes["applecare"] == "the page limit cut 1 device's records: the rest not read")
        #expect(Self.noted(snapshot.summary, "applecare") == nil, "the cut device isn't in the not-read count: it was read in part")
        Self.bounded(snapshot)
    }

    /// A sweep that wasn't run has no key; one that ran and missed none has an empty list, so "none missed" is told from "not recorded".
    @Test func aSweepNotRunHasNoKeyAndOneThatMissedNoneHasAnEmptyList() async throws {
        let world = try await SweepTests.world()
        let some = try await SweepTests.recorded(world, [.appleCare])
        #expect(some.summary.unread == ["applecare": []], "\(some.summary.unread)")
        let none = try await SweepTests.recorded(world, [])
        #expect(none.summary.unread == [:])
        let all = try await SweepTests.recorded(world)
        #expect(all.summary.unread == ["applecare": [], "activation_lock": [], "mdm_details": []] && all.summary.errors.isEmpty)
    }

    /// A sweep over a list that failed, and one the run's stop kept from asking, asked for no device: no key.
    @Test func aSweepThatNeverAskedForADeviceHasNoKey() async throws {
        let failed = try await SweepTests.world()
        failed.stubs["a"]!.queue(500, for: "/v1/orgDevices?")
        let list = try await SweepTests.recorded(failed, [.appleCare, .activationLock])
        #expect(list.summary.errors["applecare"] == "not read: devices failed" && list.summary.unread == [:])

        let world = try await SweepTests.world(devices: 12)
        let gate = world.gates["a"]!
        gate.hold("care") { $0.path().hasSuffix("/appleCareCoverage") }
        let running = Task { await world.snapshots.run(sweeps: Set(Sweep.allCases)) }
        await eventually("the sweep under way") { gate.held >= 1 }
        world.stubs["a"]!.revokeAccount()
        gate.release("care")
        guard case .recorded(let id) = await running.value else {
            Issue.record("not recorded")
            return
        }
        let summary = try await world.history!.load(id, org: world.orgs.active!).summary
        #expect(summary.errors["activation_lock"] == "not asked after HTTP 401" && summary.unread["activation_lock"] == nil && summary.unread["mdm_details"] == nil)
        // The sweep under way named the devices it hadn't reached.
        let care = try #require(summary.unread["applecare"])
        #expect(Self.noted(summary, "applecare") == care.count && !care.isEmpty)
    }

    /// Ids only: nothing but an id of the snapshot's own list is recorded, and nothing a policy withholds (the details' identifiers, a
    /// device's name) is in the column.
    @Test func onlyIdsAreRecorded() async throws {
        let world = try await SweepTests.world()
        let a = world.stubs["a"]!
        for _ in 0..<2 { a.queue(500, for: "/v1/mdmDevices/\(SweepTests.serial(1))/details") }
        let snapshot = try await SweepTests.recorded(world)
        let text = snapshot.summary.unread.values.joined().joined(separator: " ")
        #expect(!text.contains("KEPTDEVICENAME") && SweepTests.detailCanaries.allSatisfy { !text.contains($0) }, "\(text)")
        #expect(snapshot.summary.unread["mdm_details"] == [SweepTests.serial(1)])
        Self.bounded(snapshot)
    }
}
