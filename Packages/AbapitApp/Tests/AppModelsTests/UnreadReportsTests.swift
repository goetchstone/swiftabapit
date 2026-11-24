import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import Reports
import Testing
import TestSupport

/// A snapshot that records which devices a sweep didn't read (`SnapshotStore.Summary.unread`) lets a report over a part-read sweep tell "no
/// record" from "not reached" (docs/domains/history.md, "The Reports screen"). Without it (an older snapshot, an imported one, a sweep with
/// no key) the conservative rule holds: a device with no record counts as not read. Never another snapshot's list.
@MainActor
@Suite("Reports over unread devices", .serialized)
struct UnreadReportsTests {
    typealias R = ReportsTests

    @discardableResult
    static func record(_ world: World, days: Double, _ resources: [String: [Resource]], errors: [String: String] = [:], notes: [String: String] = [:],
                       unread: [String: [String]] = [:]) async throws -> Int64 {
        try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Date(timeIntervalSince1970: R.base + days * R.day), resources: resources,
                                        errors: errors, notes: notes, unread: unread)
    }

    static let part = ["applecare": "HTTP 500"], partNote = ["applecare": "1 of 4 devices not read: 1 failed twice (HTTP 500)"]

    static func groups(_ output: ReportsModel.Output) -> [String: String] { Dictionary(uniqueKeysWithValues: output.lines.map { ($0.title, $0.group ?? "") }) }

    static func fleet(_ ids: [String]) -> [String: [Resource]] { ["devices": ids.map { R.device($0) }] }

    // MARK: AppleCare

    /// A part read that says which device it missed: the device is not read, every other is judged, a device with no record has none.
    @Test func aPartReadWithUnreadJudgesTheRest() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2", "D3", "D4"])
        resources["applecare"] = [R.care("D1")]
        try await Self.record(world, days: 0, resources, errors: Self.part, notes: Self.partNote, unread: ["applecare": ["D3"]])
        let model = await R.model(world)

        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty) == ["D1": "active", "D2": "no-record", "D3": "not-read", "D4": "no-record"], "\(warranty.lines)")
        #expect(warranty.lines.first { $0.title == "D3" }?.detail.contains("didn't read this device") == true)
        #expect(warranty.summary[0].contains("; the devices it missed count as not read, and the rest are judged"), "\(warranty.summary)")
        #expect(!R.text(warranty).contains("doesn't record which devices it missed"))
        // Still marked part, and the source says what is judged.
        #expect(warranty.summary[0].hasPrefix("Read in part: the AppleCare coverage read was cut: HTTP 500"))
        #expect(warranty.source.contains { $0.contains("It records which devices it missed: the 1 device it missed counts as not read, and the rest are judged (a device with no record is shown as having none).") }, "\(warranty.source)")

        let coverage = model.build(.coverage, tokens: ["days": "90"])
        #expect(coverage.summary.contains { $0.contains("1 devices have ACTIVE coverage; 2 have none among the records read; 1 had their coverage unread") }, "\(coverage.summary)")
        let age = model.build(.fleetAge, tokens: ["years": "1"])
        #expect(age.lines.first { $0.title == "D2" }?.detail.contains("AppleCare: none active") == true && age.lines.first { $0.title == "D3" }?.detail.contains("AppleCare: not read") == true, "\(age.lines)")
    }

    /// The same snapshot with no `unread` (an older one): the conservative rule, and the words say why.
    @Test func withoutUnreadTheConservativeRuleHolds() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2", "D3", "D4"])
        resources["applecare"] = [R.care("D1")]
        try await Self.record(world, days: 0, resources, errors: Self.part, notes: Self.partNote)
        let model = await R.model(world)
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty) == ["D1": "active", "D2": "not-read", "D3": "not-read", "D4": "not-read"], "\(warranty.lines)")
        #expect(warranty.summary[0].contains("in a part read a device with no record counts as not read: this snapshot doesn't record which devices it missed"), "\(warranty.summary)")
        #expect(warranty.source.contains { $0.contains("since this snapshot doesn't record which devices it missed") }, "\(warranty.source)")
        let coverage = model.build(.coverage, tokens: ["days": "90"])
        #expect(coverage.summary.contains { $0.contains("1 devices have ACTIVE coverage; 0 have none among the records read; 3 had their coverage unread") }, "\(coverage.summary)")
    }

    /// An imported abapit snapshot records `{}`: the conservative rule. A snapshot that records another sweep's list, not this one's, is the
    /// same ("not recorded" for this sweep, never "every device was read").
    @Test func notRecordedIsNeverEveryDeviceRead() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2"])
        resources["applecare"] = [R.care("D1")]
        try await world.history!.recordImported(org: world.orgs.store["a"]!, takenAt: Date(timeIntervalSince1970: R.base), writtenBy: "abapit 0.2.0",
                                                resources: resources, errors: Self.part)
        let imported = await R.model(world).build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(imported) == ["D1": "active", "D2": "not-read"], "\(imported.lines)")

        let other = try await World.make()
        try await Self.record(other, days: 0, resources, errors: Self.part, unread: ["activation_lock": []])
        let mismatched = await R.model(other).build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(mismatched) == ["D1": "active", "D2": "not-read"], "\(mismatched.lines)")
    }

    /// A part read that missed none (an empty list; the page cap cut a device list, say) judges every device of its list.
    @Test func anEmptyListJudgesEveryDevice() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2"])
        resources["applecare"] = [R.care("D1")]
        try await Self.record(world, days: 0, resources, errors: ["applecare": "page cap"], unread: ["applecare": []])
        let warranty = await R.model(world).build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty) == ["D1": "active", "D2": "no-record"], "\(warranty.lines)")
        #expect(warranty.source.contains { $0.contains("It records which devices it missed: none, so every device in its list was read and is judged") }, "\(warranty.source)")
    }

    /// A device the snapshot names as missed is not read even when it has records (its own list was cut): never "active" from a part.
    @Test func aMissedDeviceWithRecordsIsNotRead() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2"])
        resources["applecare"] = [R.care("D1"), R.care("D2")]
        try await Self.record(world, days: 0, resources, errors: ["applecare": "page cap"], unread: ["applecare": ["D2"]])
        let model = await R.model(world)
        #expect(Self.groups(model.build(.outOfWarranty, tokens: [:])) == ["D1": "active", "D2": "not-read"])
        #expect(R.titles(model.build(.coverage, tokens: ["days": "90"])) == ["D1"])
    }

    // MARK: Activation Lock

    /// Activation Lock with `unread`: the missed device is not read; a device with no item that isn't named is still not read (a device the
    /// sweep read always has a status), never unlocked.
    @Test func activationLockWithUnreadNeverTakesNoItemForUnlocked() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["L1", "L2", "L3", "L4"])
        resources["activation_lock"] = [R.lock("L1", locked: true, type: "USER"), R.lock("L2", locked: false, type: nil)]
        try await Self.record(world, days: 0, resources, errors: ["activation_lock": "HTTP 404"],
                              notes: ["activation_lock": "1 of 4 devices not read: 1 failed twice (HTTP 404)"], unread: ["activation_lock": ["L3"]])
        let lock = await R.model(world).build(.activationLock, tokens: [:])
        #expect(Self.groups(lock)["L3"] == "not-read" && Self.groups(lock)["L4"] == "not-read" && Self.groups(lock)["L2"] != "not-read" && Self.groups(lock)["L1"] != "not-read", "\(lock.lines)")
        #expect(lock.summary[0].hasPrefix("Read in part: the Activation Lock read was cut: HTTP 404"), "\(lock.summary)")
        #expect(lock.source.contains { $0.contains("It records which devices it missed: the 1 device it missed counts as not read, and the rest are judged.") }, "\(lock.source)")
    }

    // MARK: bounds, and one snapshot only

    /// A list that names a device not in the snapshot's own device list: the stray is ignored for judging, counted and said.
    @Test func anIdOutsideTheSnapshotsDeviceListIsIgnoredCountedAndSaid() async throws {
        let world = try await World.make()
        var resources = Self.fleet(["D1", "D2"])
        resources["applecare"] = [R.care("D1")]
        try await Self.record(world, days: 0, resources, errors: ["applecare": "HTTP 500"], unread: ["applecare": ["D2", "GHOST1", "GHOST2", "GHOST2"]])
        let model = await R.model(world)
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty) == ["D1": "active", "D2": "not-read"] && !R.text(warranty).contains("GHOST"), "\(warranty.lines)")
        #expect(warranty.source.contains { $0.contains("That snapshot lists 2 ids as not read that aren't in its own device list: left out, never matched to a device.") }, "\(warranty.source)")
        #expect(warranty.source.contains { $0.contains("the 1 device it missed counts as not read") }, "the stray isn't counted among the missed: \(warranty.source)")
    }

    /// Never mixed: the newest attempt read none (it names every device missed) so the older part read is used with its own list and its own
    /// `unread`, never the newer one's.
    @Test func unreadComesFromTheSnapshotUsed() async throws {
        let world = try await World.make()
        var older = Self.fleet(["D1", "D2", "D3"])
        older["applecare"] = [R.care("D1")]
        try await Self.record(world, days: 0, older, errors: ["applecare": "HTTP 500"], unread: ["applecare": ["D2"]])
        // Newer: AppleCare not read at all (the run stopped), so it names every device and has no counts for it.
        try await Self.record(world, days: 5, Self.fleet(["D1", "D2", "D3", "D9"]), errors: ["applecare": "not asked after HTTP 401"],
                              unread: ["applecare": ["D1", "D2", "D3", "D9"]])
        let model = await R.model(world)
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty) == ["D1": "active", "D2": "not-read", "D3": "no-record"], "\(warranty.lines)")
        #expect(warranty.source[0].hasPrefix("From the snapshot of Sep 21, 2026"), "\(warranty.source)")
    }

    /// Through the real collector and the strict stub: a part AppleCare read judges the devices it read and says which it missed.
    @Test func aRealCollectorsPartReadNamesTheDeviceItMissed() async throws {
        let world = try await SweepTests.world(devices: 6)
        let a = world.stubs["a"]!
        for _ in 0..<2 { a.queue(500, for: SweepTests.care(3)) }
        let snapshot = try await SweepTests.recorded(world, [.appleCare])
        #expect(snapshot.summary.unread == ["applecare": [SweepTests.serial(3)]])
        let model = world.screens.reports
        await model.load()
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.groups(warranty)[SweepTests.serial(3)] == "not-read" && Self.groups(warranty)[SweepTests.serial(0)] == "active", "\(warranty.lines)")
        #expect(Self.groups(warranty).filter { $0.value == "no-record" }.count == 4, "\(warranty.lines)")
        #expect(model.csv(of: warranty).contains("the devices it missed count as not read, and the rest are judged"))
    }
}
