import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import HTTPCore
import JSONAPI
import Orgs
import Synchronization
import Testing
import TestSupport

/// The per-device sweeps (plan §3.6; docs/domains/history.md, "The sweeps"): AppleCare coverage, Activation Lock and the
/// Apple MDM details, run by the collector when a run asks for them. Bounded (at most four reads in flight, at the org's
/// rate, one retry pass, a device asked at most twice, cancellable) and never silent (a device not read makes the sweep a part
/// read, never a good copy). Over the strict stub behind its gate, into a real `SnapshotStore`.
@MainActor
@Suite("Per-device sweeps", .serialized)
struct SweepTests {
    // MARK: the fleet

    nonisolated static func serial(_ index: Int) -> String { String(format: "ADEV%07d", index) }

    /// The device-list identifiers the operator left out (2026-11-20), as Apple's MDM details carry them.
    static let detailCanaries = ["CANARYIMEI", "CANARYMEID", "CA:NA:RY:WI:FI:00", "CA:NA:RY:BT:00:00", "CA:NA:RY:ET:00:00"]

    /// Apple's own example's two kinds of record (`get-all-applecare-coverage-for-an-orgdevice`): the limited warranty, whose
    /// id is the serial, and AppleCare+, whose id is its agreement number.
    static func coverage(_ id: String, _ description: String, payment: String) -> Resource {
        Resource(type: "appleCareCoverage", id: id, attributes: [
            "description": .string(description), "status": .string("ACTIVE"), "paymentType": .string(payment), "isRenewable": .bool(false),
            "isCanceled": .bool(false), "startDateTime": .string("2025-02-02T00:00:00Z"), "endDateTime": .string("2026-02-02T00:00:00Z"),
            "agreementNumber": .null, "contractCancelDateTime": .null,
        ])
    }

    static func managed(_ serial: String) -> Resource {
        Resource(type: "mdmDevices", id: serial, attributes: ["serialNumber": .string(serial), "deviceName": .string("KEPTDEVICENAME"),
                                                              "productFamily": .string("Mac")])
    }

    /// An Apple-managed device's details, with every identifier the operator left out.
    static func details(_ serial: String, named: String? = nil) -> Resource {
        Resource(type: "mdmDeviceDetails", id: serial, attributes: [
            "serialNumber": .string(named ?? serial), "deviceName": .string("KEPTDEVICENAME"), "deviceModel": .string("MacBook Air"),
            "osVersion": .string("26.1"), "platform": .string("macOS"), "imei": .array([.string("CANARYIMEI")]), "meid": .array([.string("CANARYMEID")]),
            "wifiMacAddress": .string("CA:NA:RY:WI:FI:00"), "bluetoothMacAddress": .string("CA:NA:RY:BT:00:00"),
            "ethernetMacAddress": .string("CA:NA:RY:ET:00:00"), "lastCheckInDateTime": .string("2026-11-01T00:00:00Z"),
            "isFirewallEnabled": .bool(true), "isFileVaultEnabled": .bool(false), "storageFreeCapacity": .number("100"),
            "storageTotalCapacity": .number("500"),
        ])
    }

    /// Org `a` with `devices` devices, each with an Activation Lock status (the second locked by a person), the first with
    /// two AppleCare records and the others with none; the first two Apple-managed, the first with details and the second
    /// with none on record (Apple's 404). Org `b` has one device.
    static func world(devices: Int = 6, pageCap: Int = AppleClient.defaultPageCap, profiles: [OrgProfile]? = nil,
                      history: Result<SnapshotStore, SnapshotStore.Failure>? = nil) async throws -> World {
        var opener: (@MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>)?
        if let history { opener = { history } }
        let world = try await World.make(devices: ["a": devices, "b": 1], pageCap: pageCap, profiles: profiles, history: opener)
        let a = world.stubs["a"]!
        for index in 0..<devices { a.setLock(serial(index), isLocked: index == 1, lockType: index == 1 ? "USER" : "NONE") }
        if devices > 0 {
            a.setCoverage(serial(0), [coverage(serial(0), "Limited Warranty", payment: "NONE"), coverage("0000000001", "AppleCare+", payment: "SUBSCRIPTION")])
        }
        if devices > 1, profiles?.first?.scope != .known(.school) {
            a.add([managed(serial(0)), managed(serial(1))])
            a.setDetails(serial(0), details(serial(0)))
        }
        return world
    }

    /// Runs a snapshot of the active org with `sweeps` and returns it as the store holds it.
    static func recorded(_ world: World, _ sweeps: Set<Sweep> = Set(Sweep.allCases)) async throws -> SnapshotStore.Snapshot {
        let outcome = await world.snapshots.run(sweeps: sweeps)
        guard case .recorded(let id) = outcome else {
            Issue.record("not recorded: \(outcome)")
            throw CancellationError()
        }
        return try await world.history!.load(id, org: world.orgs.active!)
    }

    /// The requests org `a`'s stub answered whose path holds `part`.
    static func asked(_ world: World, _ part: String) -> [String] { world.stubs["a"]!.requests.filter { $0.contains(part) } }

    static func item(_ snapshot: SnapshotStore.Snapshot, _ resource: String, _ id: String) -> Resource? {
        snapshot.resources[resource]?.first { Array($0.id.utf8) == Array(id.utf8) }
    }

    static func latest(_ world: World, _ resource: String) async throws -> SnapshotStore.Latest? {
        try await world.history!.latest(resource, org: world.orgs.active!)
    }

    nonisolated static let lockPath = "/activationLockStatus"
    nonisolated static func lock(_ index: Int) -> String { "/v1/orgDevices/\(serial(index))/activationLockStatus" }
    nonisolated static func care(_ index: Int) -> String { "/v1/orgDevices/\(serial(index))/appleCareCoverage" }

    // MARK: what is kept

    @Test func eachSweepKeepsWhatThePolicySays() async throws {
        let world = try await Self.world()
        let snapshot = try await Self.recorded(world)
        let summary = snapshot.summary
        #expect(summary.errors.isEmpty, "\(summary.errors)")
        #expect(summary.counts["applecare"] == 2 && summary.counts["activation_lock"] == 6 && summary.counts["mdm_details"] == 1)
        // AppleCare: every record, with the serial it was read for (abapit's shape), under Apple's id.
        let care = snapshot.resources["applecare"] ?? []
        #expect(Set(care.map(\.id)) == [Self.serial(0), "0000000001"])
        for record in care {
            #expect(record.attributes["serialNumber"] == .string(Self.serial(0)), "\(record.id)")
            #expect(record.attributes.keys.sorted() == ["agreementNumber", "contractCancelDateTime", "description", "endDateTime", "isCanceled",
                                                        "isRenewable", "paymentType", "serialNumber", "startDateTime", "status"])
        }
        // Activation Lock: one item per device, keyed by serial.
        #expect(Self.item(snapshot, "activation_lock", Self.serial(1))?.attributes == ["isLocked": .bool(true), "lockType": .string("USER")])
        #expect(Self.item(snapshot, "activation_lock", Self.serial(5))?.attributes == ["isLocked": .bool(false), "lockType": .string("NONE")])
        // The details: the posture and the device's name (the operator's "All three"), never an IMEI, MEID or MAC address;
        // the device Apple answered 404 for is read, with no details, so it has no item and the sweep is whole.
        let detail = try #require(Self.item(snapshot, "mdm_details", Self.serial(0)))
        #expect(detail.attributes.keys.sorted() == ["deviceModel", "deviceName", "isFileVaultEnabled", "isFirewallEnabled", "lastCheckInDateTime",
                                                    "osVersion", "platform", "serialNumber", "storageFreeCapacity", "storageTotalCapacity"])
        #expect(detail.attributes["deviceName"] == .string("KEPTDEVICENAME"))
        #expect(Self.item(snapshot, "mdm_details", Self.serial(1)) == nil)
        // The 404 is said (review M3), and nothing else: IMEI, MEID and MACs are known and left out unsaid.
        #expect(summary.notes["mdm_details"] == "1 answered 404, read as no details on record (Apple's meaning unconfirmed)")
        guard case .read(let copy)? = try await Self.latest(world, "mdm_details") else {
            Issue.record("a whole details sweep isn't read")
            return
        }
        #expect(copy.items.count == 1)
        // Each device asked once; the details once per Apple-managed device.
        #expect(Self.asked(world, Self.lockPath).count == 6 && Self.asked(world, "/appleCareCoverage").count == 6)
        #expect(Self.asked(world, "/details").count == 2)
    }

    /// Opt-in per run: a run that asks for none sends no per-device read and records none, so `latest` passes over it.
    @Test func aRunWithoutSweepsAsksForNone() async throws {
        let world = try await Self.world()
        let first = try await Self.recorded(world, [.activationLock])
        let snapshot = try await Self.recorded(world, [])
        for sweep in ["applecare", "activation_lock", "mdm_details"] {
            #expect(snapshot.summary.counts[sweep] == nil && snapshot.summary.errors[sweep] == nil, "\(sweep)")
        }
        #expect(Self.asked(world, Self.lockPath).count == 6, "only the first run's")
        #expect(Self.asked(world, "/appleCareCoverage").isEmpty && Self.asked(world, "/details").isEmpty)
        guard case .read(let copy)? = try await Self.latest(world, "activation_lock") else {
            Issue.record("the sweep's last copy is lost")
            return
        }
        #expect(copy.summary.id == first.summary.id)
    }

    /// The details' canaries, looked for in every file the history folder holds after a sweep: no IMEI, MEID or MAC address;
    /// the device name kept (the operator's "All three").
    @Test func noIdentifierOfTheDetailsReachesTheFile() async throws {
        let folder = try CollectorTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await Self.world(history: .success(try SnapshotStore(storage: .folder(folder), appVersion: "test")))
        _ = try await Self.recorded(world)
        var bytes = Data()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { bytes += try Data(contentsOf: file) }
        for kept in ["KEPTDEVICENAME", "26.1", "0000000001", "Limited Warranty"] { #expect(bytes.range(of: Data(kept.utf8)) != nil, "\(kept)") }
        for canary in Self.detailCanaries { #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(canary) reached \(folder.path)") }
    }

    // MARK: bounds

    /// At most four reads at once: with every read held, four wait at the gate and a fifth never comes.
    @Test func atMostFourReadsAreInFlight() async throws {
        #expect(Sweep.inFlight == 4)
        let world = try await Self.world(devices: 12)
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("four reads held") { gate.held == 4 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.held == 4, "\(gate.held) in flight")
        #expect(Self.asked(world, Self.lockPath).isEmpty)
        gate.release("locks")
        guard case .recorded = await running.value else {
            Issue.record("not recorded")
            return
        }
        #expect(Self.asked(world, Self.lockPath).count == 12)
    }

    /// One retry pass: a device whose first read failed is asked once more and read; one whose second read failed too is
    /// not read, never asked a third time, and makes the sweep a part read.
    @Test func aFailedReadIsAskedOnceMoreAndNoMore() async throws {
        let world = try await Self.world()
        let a = world.stubs["a"]!
        a.queue(500, for: Self.lock(2))
        for _ in 0..<3 { a.queue(500, for: Self.lock(3)) }
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(Self.asked(world, Self.lock(2)).count == 2 && Self.item(snapshot, "activation_lock", Self.serial(2)) != nil)
        #expect(Self.asked(world, Self.lock(3)).count == 2 && Self.item(snapshot, "activation_lock", Self.serial(3)) == nil)
        #expect(Self.asked(world, Self.lockPath).count == 8)
        #expect(snapshot.summary.counts["activation_lock"] == 5)
        #expect(snapshot.summary.errors["activation_lock"] == "HTTP 500")
        #expect(snapshot.summary.notes["activation_lock"] == "1 of 6 devices not read: 1 failed twice (HTTP 500)")
    }

    /// Every read failing: each device is asked exactly twice, never more (total requests at most twice the serials), and
    /// nothing read is the error alone.
    @Test func everyDeviceIsAskedAtMostTwice() async throws {
        let world = try await Self.world()
        for index in 0..<6 { for _ in 0..<3 { world.stubs["a"]!.queue(503, for: Self.lock(index)) } }
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(Self.asked(world, Self.lockPath).count == 12)
        for index in 0..<6 { #expect(Self.asked(world, Self.lock(index)).count == 2) }
        #expect(snapshot.summary.counts["activation_lock"] == nil && snapshot.summary.errors["activation_lock"] == "HTTP 503")
        #expect(snapshot.summary.notes["activation_lock"] == "6 of 6 devices not read: 6 failed twice (HTTP 503)")
    }

    /// A 429 halves the org's limiter (and its `Retry-After` holds the lane: `HTTPCoreTests`), the read is retried by the
    /// client and the device read; the rate the limiter learned is recorded for the org, for the next estimate.
    @Test func a429SlowsTheLimiterAndTheDeviceIsStillRead() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.queue(429, for: Self.lock(3), headers: ["Retry-After": "7"])
        let client = try #require(world.orgs.appleClient)
        #expect(await client.learnedReadsPerMinute == 600)
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(snapshot.summary.errors.isEmpty && snapshot.summary.counts["activation_lock"] == 6)
        #expect(Self.asked(world, Self.lock(3)).count == 2)
        let learned = await client.learnedReadsPerMinute
        #expect(learned < 600)
        #expect(world.orgs.store["a"]?.learnedReadsPerMinute == learned)
    }

    /// A cancel stops the sweep at once: no read starts after it, and the run writes nothing.
    @Test func cancelStopsFurtherReads() async throws {
        let world = try await Self.world(devices: 12)
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("four reads held") { gate.held == Sweep.inFlight }
        world.snapshots.cancel()
        gate.release("locks")
        #expect(await running.value == .cancelled)
        #expect(Self.asked(world, Self.lockPath).count <= Sweep.inFlight, "\(Self.asked(world, Self.lockPath).count) asked after the cancel")
        #expect(try await world.history!.orgIDs().isEmpty)
        #expect(world.snapshots.sweepProgress == nil && world.snapshots.sweepEstimate == nil)
    }

    /// An org switch mid-sweep stops it: nothing is written, under either org, and nothing more is asked of the old one.
    @Test func anOrgSwitchMidSweepWritesNothing() async throws {
        let world = try await Self.world(devices: 12)
        let gate = world.gates["a"]!
        gate.hold("care") { $0.path().hasSuffix("/appleCareCoverage") }
        let running = Task { await world.snapshots.run(sweeps: Set(Sweep.allCases)) }
        await eventually("the sweep under way") { gate.held == Sweep.inFlight }
        world.orgs.select("b")
        gate.release("care")
        #expect(await running.value == .cancelled)
        #expect(try await world.history!.orgIDs().isEmpty)
        #expect(Self.asked(world, "/appleCareCoverage").count <= Sweep.inFlight && Self.asked(world, Self.lockPath).isEmpty)
        #expect(world.snapshots.lastOutcome == nil)
    }

    // MARK: never silent

    /// A sweep that left a device not read is a part read: its items and an error, so `latest` says it failed and shows the
    /// last good copy; a failure is never "no coverage" or "unlocked".
    @Test func aPartialSweepIsNeverAGoodCopy() async throws {
        let world = try await Self.world()
        let whole = try await Self.recorded(world, [.appleCare, .activationLock])
        let a = world.stubs["a"]!
        for _ in 0..<2 {
            a.queue(500, for: Self.lock(1))
            a.queue(500, for: Self.care(0))
        }
        let part = try await Self.recorded(world, [.appleCare, .activationLock])
        #expect(part.summary.counts["activation_lock"] == 5 && part.summary.errors["activation_lock"] == "HTTP 500")
        #expect(Self.item(part, "activation_lock", Self.serial(1)) == nil, "a failure is never stored as a status")
        // The device with the records failed: the sweep read the others (none on record), and is no answer of "none".
        #expect(part.summary.counts["applecare"] == 0 && part.summary.errors["applecare"] == "HTTP 500")
        for resource in ["activation_lock", "applecare"] {
            guard case .failed(let summary, let error, let newest?)? = try await Self.latest(world, resource) else {
                Issue.record("a part read of \(resource) is taken for a good copy")
                continue
            }
            #expect(summary.id == part.summary.id && error == "HTTP 500" && newest.summary.id == whole.summary.id, "\(resource)")
        }
    }

    /// Apple's 404s, decided per read (docs/domains/history.md, "The sweeps"): AppleCare's coverage is a list, and "none on
    /// record" is an empty list (seen live, `ok, 0 items`), so a 404 is a device Apple couldn't find: not read. Activation
    /// Lock documents a status for every device: a 404 is not read, never "unlocked". The details' 404 is Apple's "no
    /// details": read, nothing kept.
    @Test func a404IsNotReadForCoverageAndLockAndNoDetailsForTheDetails() async throws {
        let world = try await Self.world()
        let a = world.stubs["a"]!
        for _ in 0..<2 { a.queue(404, for: Self.care(0)) }
        a.queue(404, for: Self.lock(0))
        a.queue(404, for: Self.lock(0))
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.errors["applecare"] == "HTTP 404" && snapshot.summary.counts["applecare"] == 0)
        #expect(snapshot.summary.errors["activation_lock"] == "HTTP 404" && Self.item(snapshot, "activation_lock", Self.serial(0)) == nil)
        #expect(snapshot.summary.errors["mdm_details"] == nil && snapshot.summary.counts["mdm_details"] == 1)
        #expect(Self.asked(world, "/v1/mdmDevices/\(Self.serial(1))/details").count == 1, "no details is an answer: not asked again")
    }

    /// An id that can't go in a path is never sent, and the sweep says the device wasn't read.
    @Test func anUnsendableSerialIsNeverSent() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.add(devices: [Resource(type: "orgDevices", id: "BAD SERIAL/1", attributes: ["serialNumber": .string("BAD SERIAL/1")])])
        let snapshot = try await Self.recorded(world, [.appleCare, .activationLock])
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("BAD") })
        #expect(snapshot.summary.counts["devices"] == 7 && snapshot.summary.counts["activation_lock"] == 6)
        for resource in ["applecare", "activation_lock"] {
            #expect(snapshot.summary.errors[resource] == "unsendable id", "\(resource)")
            #expect(snapshot.summary.notes[resource] == "1 of 7 devices not read: 1 has an id Apple can't be asked for", "\(resource)")
        }
    }

    /// A device list the page cap cut: the sweep covers the devices listed, and is a part read, said.
    @Test func aSweepOverACutListIsAPartRead() async throws {
        let world = try await Self.world(devices: 1001, pageCap: 1)
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(Self.asked(world, Self.lockPath).count == 1000)
        #expect(snapshot.summary.counts["activation_lock"] == 1000 && snapshot.summary.errors["activation_lock"] == "page cap")
        #expect(snapshot.summary.notes["activation_lock"] == "covers only the devices listed: devices stopped at the page limit")
    }

    /// A device the list holds twice is asked once (so its records aren't taken for another's with the same id).
    @Test func aDeviceListedTwiceIsAskedOnce() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.add(devices: [World.device("ADEV", 0)])
        let snapshot = try await Self.recorded(world, [.appleCare, .activationLock])
        #expect(Self.asked(world, Self.care(0)).count == 1 && Self.asked(world, Self.lock(0)).count == 1)
        #expect(snapshot.summary.errors.isEmpty && snapshot.summary.counts["applecare"] == 2 && snapshot.summary.counts["activation_lock"] == 6)
    }

    /// A sweep over a list that wasn't read asks nothing and says why.
    @Test func aSweepOverAFailedListAsksNothing() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.queue(500, for: "/v1/orgDevices?")
        let snapshot = try await Self.recorded(world, [.appleCare, .activationLock])
        #expect(snapshot.summary.errors["applecare"] == "not read: devices failed")
        #expect(snapshot.summary.errors["activation_lock"] == "not read: devices failed")
        #expect(Self.asked(world, "/v1/orgDevices/").isEmpty)
    }

    /// A 403 stops that sweep at the first refusal (the role can't read it for any device); the others still run.
    @Test func aRefusalStopsThatSweepOnly() async throws {
        let world = try await Self.world(devices: 12)
        for index in 0..<12 { world.stubs["a"]!.queue(403, for: Self.lock(index)) }
        let snapshot = try await Self.recorded(world, [.appleCare, .activationLock])
        let asked = Self.asked(world, Self.lockPath).count
        #expect(asked <= Sweep.inFlight, "\(asked) asked after a refusal")
        #expect(snapshot.summary.errors["activation_lock"] == "HTTP 403" && snapshot.summary.counts["activation_lock"] == nil)
        #expect(snapshot.summary.notes["activation_lock"] == "12 of 12 devices not read: 12 left when the sweep stopped at HTTP 403")
        #expect(snapshot.summary.errors["applecare"] == nil && snapshot.summary.counts["applecare"] == 2)
    }

    /// A failure of the account stops the run: the sweep under way stops, and the later ones aren't asked.
    @Test func aSignInFailureStopsTheSweeps() async throws {
        let world = try await Self.world(devices: 12)
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
        #expect(summary.errors["applecare"] == "HTTP 401")
        #expect(summary.errors["activation_lock"] == "not asked after HTTP 401" && summary.errors["mdm_details"] == "not asked after HTTP 401")
        #expect(Self.asked(world, Self.lockPath).isEmpty && Self.asked(world, "/details").isEmpty)
    }

    /// Details that name another serial are never kept as this device's: not read.
    @Test func detailsForAnotherSerialAreNotRead() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.setDetails(Self.serial(1), Self.details(Self.serial(1), named: "ZDEV9999999"))
        let snapshot = try await Self.recorded(world, [.mdmDetails])
        #expect(Self.item(snapshot, "mdm_details", Self.serial(1)) == nil)
        #expect(snapshot.summary.errors["mdm_details"] == "another serial")
        #expect(snapshot.summary.notes["mdm_details"] == "1 of 2 devices not read: 1 failed twice (another serial)")
    }

    /// Apple's example keys AppleCare+ by its agreement number, which several devices can share (review M2): every
    /// device's record is kept, as `serial:id`, and the sweep is a good copy; an id one device alone carries keeps Apple's.
    /// The coordinating session's decision, pending the live check.
    @Test func sixDevicesSharingACoverageIdKeepEveryRecord() async throws {
        let world = try await Self.world()
        for index in 1..<6 { world.stubs["a"]!.setCoverage(Self.serial(index), [Self.coverage("0000000001", "AppleCare+", payment: "SUBSCRIPTION")]) }
        let snapshot = try await Self.recorded(world, [.appleCare])
        #expect(snapshot.summary.errors["applecare"] == nil && snapshot.summary.counts["applecare"] == 7)
        #expect(snapshot.summary.notes["applecare"] == "6 records shared an id with another device's: kept as serial:id")
        for index in 0..<6 {
            let record = Self.item(snapshot, "applecare", "\(Self.serial(index)):0000000001")
            #expect(record?.attributes["serialNumber"] == .string(Self.serial(index)), "\(index)")
        }
        #expect(Self.item(snapshot, "applecare", Self.serial(0)) != nil && Self.item(snapshot, "applecare", "0000000001") == nil)
        guard case .read? = try await Self.latest(world, "applecare") else {
            Issue.record("a sweep that lost nothing isn't a good copy")
            return
        }
    }

    /// One device's list holding an id twice: the store would keep one, so the sweep says so and is a part read.
    @Test func anIdTwiceInOneDevicesListIsAPartRead() async throws {
        let world = try await Self.world()
        let twice = Self.coverage("DUP1", "AppleCare+", payment: "SUBSCRIPTION")
        world.stubs["a"]!.setCoverage(Self.serial(2), [twice, twice])
        let snapshot = try await Self.recorded(world, [.appleCare])
        #expect(snapshot.summary.errors["applecare"] == "duplicate id")
        #expect(snapshot.summary.notes["applecare"] == "1 record had the id of another read: the history keeps one of each")
    }

    /// abapit's fallback id when Apple's is empty, as Python's f-string wrote it, so an imported history's keys continue:
    /// `serial:None` for a null description, `serial:` for a missing one, `serial:text` otherwise.
    @Test func anEmptyCoverageIdIsAbapitsFallback() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.setCoverage(Self.serial(2), [
            Resource(type: "appleCareCoverage", id: "", attributes: ["description": .null, "status": .string("ACTIVE")]),
            Resource(type: "appleCareCoverage", id: "", attributes: ["status": .string("EXPIRED")]),
            Resource(type: "appleCareCoverage", id: "", attributes: ["description": .string("AppleCare+"), "status": .string("ACTIVE")]),
        ])
        let snapshot = try await Self.recorded(world, [.appleCare])
        #expect(snapshot.summary.errors["applecare"] == nil)
        for id in ["None", "", "AppleCare+"] { #expect(Self.item(snapshot, "applecare", "\(Self.serial(2)):\(id)") != nil, "\(id)") }
    }

    /// Every details read answering 404 is a whole sweep of "no details on record", and the note says how many and that
    /// Apple's meaning is unconfirmed (review M3), so a reader of the snapshot never takes it for a confirmed absence.
    @Test func everyDetails404IsCountedInTheNote() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.queue(404, for: "/v1/mdmDevices/\(Self.serial(0))/details")
        let snapshot = try await Self.recorded(world, [.mdmDetails])
        #expect(snapshot.summary.errors["mdm_details"] == nil && snapshot.summary.counts["mdm_details"] == 0)
        #expect(snapshot.summary.notes["mdm_details"] == "2 answered 404, read as no details on record (Apple's meaning unconfirmed)")
        #expect(Self.asked(world, "/details").count == 2, "a 404 is an answer: not asked again")
    }

    /// A device's own coverage list cut at the page cap: what came is kept, the sweep is a part read and says so (review L3).
    @Test func aDevicesCoverageCutAtThePageCapIsAPartRead() async throws {
        let world = try await Self.world(pageCap: 1)
        world.stubs["a"]!.setCoverage(Self.serial(0), (0...1000).map { Self.coverage(String(format: "CUT%05d", $0), "AppleCare+", payment: "SUBSCRIPTION") })
        let snapshot = try await Self.recorded(world, [.appleCare])
        #expect(snapshot.summary.counts["applecare"] == 1000 && snapshot.summary.errors["applecare"] == "page cap")
        #expect(snapshot.summary.notes["applecare"] == "the page limit cut 1 device's records: the rest not read")
    }

    /// An Activation Lock status under another device's id is never kept as the device asked for (review L5).
    @Test func aLockForAnotherSerialIsNotRead() async throws {
        let world = try await Self.world()
        let other = #"{"data": {"type": "activationLockStatus", "id": "ZDEV9999999", "attributes": {"isLocked": false, "lockType": "NONE"}}}"#
        for _ in 0..<2 { world.stubs["a"]!.queue(200, for: Self.lock(2), body: other) }
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(Self.item(snapshot, "activation_lock", Self.serial(2)) == nil && snapshot.summary.counts["activation_lock"] == 5)
        #expect(snapshot.summary.errors["activation_lock"] == "another serial")
    }

    /// Offline mid-sweep (review L8): five transport failures in a row stop the sweep, recorded as `transport`, and the sends
    /// are bounded: at most eight reads (five, and three in flight), each sent five times by the client; without the breaker,
    /// twelve devices asked twice would be 120 sends.
    @Test func offlineMidSweepStopsAtTheBreaker() async throws {
        let world = try await Self.world(devices: 12)
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("four reads held") { gate.held == 4 }
        let before = gate.answered
        world.stubs["a"]!.failTransport(10_000)
        gate.release("locks")
        guard case .recorded(let id) = await running.value else {
            Issue.record("not recorded")
            return
        }
        let sent = gate.answered - before
        #expect(sent <= (Sweep.transportBreaker + Sweep.inFlight - 1) * 5, "\(sent) sends")
        let summary = try await world.history!.load(id, org: world.orgs.active!).summary
        #expect(summary.errors["activation_lock"] == "transport")
        #expect(summary.notes["activation_lock"] == "12 of 12 devices not read: 12 left when the sweep stopped at transport")
    }

    /// The breaker counts transport failures in a row, and an answer resets it (the delta review's surviving mutant D6):
    /// across 24 devices, twelve transport failures between answers never trip it. Deterministic: every first ask is
    /// answered 500, so every device is retried, and the retry pass goes a read at a time in the list's order, the odd
    /// devices' second ask dropped (all five of the client's sends) between the even ones' answers.
    @Test func transportFailuresBetweenAnswersNeverTripTheBreaker() async throws {
        let world = try await Self.world(devices: 24)
        let gate = world.gates["a"]!
        for index in 0..<24 { world.stubs["a"]!.queue(500, for: Self.lock(index)) }
        let odd = Set((0..<24).filter { $0 % 2 == 1 }.map(Self.lock)), asks = Mutex<[String: Int]>([:])
        gate.drop("odd retries") { url in
            let path = url.path()
            guard odd.contains(path) else { return false }
            return asks.withLock { asks in
                asks[path, default: 0] += 1
                return asks[path]! > 1
            }
        }
        let snapshot = try await Self.recorded(world, [.activationLock])
        #expect(snapshot.summary.counts["activation_lock"] == 12)
        #expect(snapshot.summary.errors["activation_lock"] == "transport")
        #expect(snapshot.summary.notes["activation_lock"] == "12 of 24 devices not read: 12 failed twice (transport)")
        #expect(Self.asked(world, Self.lockPath).count == 36, "every device asked twice; the dropped sends never reached the stub")
    }

    /// A transport-level failure is coded for what happened (the delta review): no answer is `transport`; an answer past the
    /// body cap and a host this app refused had an answer, or never asked, so they say so, and never the host.
    @Test func aTransportLevelFailureIsCodedForWhatHappened() {
        #expect(SnapshotPolicy.code(HTTPFailure.transport(code: URLError.notConnectedToInternet.rawValue)) == "transport")
        #expect(SnapshotPolicy.code(HTTPFailure.tooLarge(limit: 1 << 25)) == "too large")
        #expect(SnapshotPolicy.code(AppleAPIError.http(.tooLarge(limit: 1 << 25))) == "too large")
        #expect(SnapshotPolicy.code(HTTPFailure.refusedHost("evil.example.com")) == "refused host")
        #expect(SnapshotPolicy.code(AppleAPIError.http(.refusedHost("evil.example.com"))) == "refused host")
    }

    /// A School org has no Apple MDM: its run tries AppleCare and Activation Lock only.
    @Test func aSchoolOrgSweepsNoDetails() async throws {
        let world = try await Self.world(profiles: [World.profile("a", scope: .school), World.profile("b")])
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.counts["applecare"] == 2 && snapshot.summary.counts["activation_lock"] == 6)
        #expect(snapshot.summary.counts["mdm_details"] == nil && snapshot.summary.errors["mdm_details"] == nil)
        #expect(Self.asked(world, "/v1/mdmDevices").isEmpty)
    }

    // MARK: progress and the estimate

    /// The estimate is made before the sweep's first read, and the progress counts the devices answered.
    @Test func progressAndTheEstimateAreObservable() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("last") { $0.path() == Self.lock(5) }
        let running = Task { await world.snapshots.run(sweeps: Set(Sweep.allCases)) }
        await eventually("five of six answered") { gate.held == 1 && world.snapshots.sweepProgress?.done == 5 }
        #expect(world.snapshots.sweepProgress == Sweep.Progress(sweep: .activationLock, done: 5, total: 6))
        #expect(world.snapshots.sweepProgress?.words == "Activation Lock: 5 of 6 devices")
        // Six devices' coverage and lock, two Apple-managed devices' details, at the rate the org's limiter had.
        #expect(world.snapshots.sweepEstimate == Sweep.Estimate(reads: 14, readsPerMinute: 600))
        #expect(world.snapshots.sweepEstimate?.words.contains("An estimate") == true)
        gate.release("last")
        guard case .recorded = await running.value else {
            Issue.record("not recorded")
            return
        }
        #expect(world.snapshots.sweepProgress == nil && world.snapshots.sweepEstimate == nil)
    }

    /// Before any answer the progress is there, nothing done (review mutant M12): a sweep never looks idle while it starts.
    @Test func progressShowsBeforeTheFirstAnswer() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("four reads held") { gate.held == 4 }
        #expect(world.snapshots.sweepProgress == Sweep.Progress(sweep: .activationLock, done: 0, total: 6))
        gate.release("locks")
        _ = await running.value
    }

    /// A device whose first read failed isn't done until its second answers (review mutant M9): while its retry waits, the
    /// progress is five of six, never six, and never seven of six after.
    @Test func progressThroughAFailureNeverClaimsMore() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        world.stubs["a"]!.queue(500, for: Self.lock(2))
        let seen = Mutex(0), path = Self.lock(2)
        // The device's second ask only: its first goes through and fails.
        gate.hold("retry") { url in
            guard url.path() == path else { return false }
            return seen.withLock { count in
                count += 1
                return count > 1
            }
        }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("the retry held") { gate.held == 1 }
        #expect(world.snapshots.sweepProgress == Sweep.Progress(sweep: .activationLock, done: 5, total: 6))
        gate.release("retry")
        guard case .recorded = await running.value else {
            Issue.record("not recorded")
            return
        }
    }

    /// A cancel during the retry pass stops it (the review's P9): six devices fail once, the first retry is held, the
    /// cancel comes; at most seven requests in all, never the other five retries.
    @Test func aCancelDuringTheRetryPassStopsIt() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        for index in 0..<6 { world.stubs["a"]!.queue(500, for: Self.lock(index)) }
        let seen = Mutex(0), path = Self.lock(0)
        gate.hold("retry") { url in
            guard url.path() == path else { return false }
            return seen.withLock { count in
                count += 1
                return count > 1
            }
        }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("the first retry held") { gate.held == 1 }
        world.snapshots.cancel()
        gate.release("retry")
        #expect(await running.value == .cancelled)
        #expect(Self.asked(world, Self.lockPath).count <= 7, "\(Self.asked(world, Self.lockPath).count) asked")
    }

    /// An org switch clears what a run says while it goes (review L6): the stopping run's sweep, progress and estimate are
    /// the old org's.
    @Test func aSwitchClearsTheSweepsWords() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("the sweep under way") { gate.held == 4 && world.snapshots.sweepProgress != nil }
        #expect(world.snapshots.reading == "activation_lock" && world.snapshots.sweepEstimate != nil)
        world.orgs.select("b")
        #expect(world.snapshots.sweepProgress == nil && world.snapshots.sweepEstimate == nil && world.snapshots.reading == nil)
        gate.release("locks")
        #expect(await running.value == .cancelled)
        #expect(world.snapshots.sweepProgress == nil && world.snapshots.sweepEstimate == nil && world.snapshots.reading == nil)
    }

    /// An estimate whose rate read outlived an org switch is the old org's: none (review L7).
    @Test func anEstimateAcrossASwitchIsNone() async throws {
        let world = try await Self.world()
        let client = try #require(world.orgs.appleClient)
        // Stall a's limiter behind another read, so the estimate's rate read waits there.
        world.stall.hold(World.clientID("a"))
        Task.detached { try? await client.ping() }
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while !world.stall.entered, clock.now < end { usleep(500) }
        #expect(world.stall.entered)
        let answer = Task { await world.snapshots.estimate([.activationLock], devices: 6, appleManaged: 0) }
        try await Task.sleep(for: .milliseconds(50))
        world.orgs.select("b")
        world.stall.release()
        #expect(await answer.value == nil)
        #expect(await world.snapshots.estimate([.activationLock], devices: 6, appleManaged: 0) != nil, "b's own is made")
    }

    /// Four reads refused at once are one throttle event (the review's P13, M1): the rate halves once, 600 to 300, and the
    /// run records 300, never 600 halved four times (37.5).
    @Test func fourReadsRefusedAtOnceHalveTheSavedRateOnce() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!, a = world.stubs["a"]!
        gate.hold("locks") { $0.path().hasSuffix(Self.lockPath) }
        let running = Task { await world.snapshots.run(sweeps: [.activationLock]) }
        await eventually("four reads held") { gate.held == 4 }
        for index in 0..<4 { a.queue(429, for: Self.lock(index), headers: ["Retry-After": "7"]) }
        // The four refusals reach the limiter together, as they would within Apple's window: its clock moves only when it
        // sleeps, so hold it until all four are answered, then let them through.
        world.stall.hold(World.clientID("a"))
        let before = gate.answered
        gate.release("locks")
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while !(world.stall.entered && gate.answered >= before + 4), clock.now < end { usleep(500) }
        usleep(100_000)
        world.stall.release()
        guard case .recorded = await running.value else {
            Issue.record("not recorded")
            return
        }
        #expect(Self.asked(world, Self.lockPath).count == 10)
        #expect(world.orgs.store["a"]?.learnedReadsPerMinute == 300)
    }

    /// The estimate holds its rate to 1...600 a minute and says the rate it used (review M11 and nits): below one a minute,
    /// or not a number, is one; no count traps; seconds under a minute say so.
    @Test func theEstimateHoldsItsRateAndNeverTraps() {
        let slow = Sweep.Estimate(reads: 60, readsPerMinute: 0.5)
        #expect(slow.readsPerMinute == 1 && slow.seconds == 3600)
        #expect(slow.words.hasPrefix("About 60 minutes: 60 reads at about 1 a minute"))
        #expect(Sweep.Estimate(reads: 60, readsPerMinute: 0).seconds == 3600 && Sweep.Estimate(reads: 60, readsPerMinute: .nan).seconds == 3600)
        #expect(Sweep.Estimate(reads: 600, readsPerMinute: 1e12).readsPerMinute == 600)
        #expect(Sweep.Estimate(reads: 14, readsPerMinute: 600).words.hasPrefix("Under a minute: 14 reads"))
        #expect(Sweep.Estimate(reads: Int.max, readsPerMinute: 1).words.hasPrefix("About 1000000 hours"))
        #expect(Sweep.Estimate(reads: -3, readsPerMinute: 20).reads == 0)
    }

    /// Before a run, from the counts a screen has, at the org's rate now; said as an estimate.
    @Test func theEstimateBeforeARunIsSaidAsOne() async throws {
        let world = try await Self.world()
        let estimate = try #require(await world.snapshots.estimate(Set(Sweep.allCases), devices: 100, appleManaged: 10))
        #expect(estimate == Sweep.Estimate(reads: 210, readsPerMinute: 600))
        #expect(estimate.words == "Under a minute: 210 reads at about 600 a minute, this organization's rate now. An estimate: "
                + "Apple may slow the reads, and a device whose read fails is asked once more.")
        let slow = Sweep.Estimate(reads: 500, readsPerMinute: 20)
        #expect(slow.seconds == 1500 && slow.words.hasPrefix("About 25 minutes: 500 reads at about 20 a minute"))
        #expect(Sweep.Estimate(reads: 3000, readsPerMinute: 20).words.hasPrefix("About 3 hours"))
        #expect(Sweep.Estimate(reads: 0, readsPerMinute: 20).words == "Nothing to read.")
        #expect(await world.snapshots.estimate([.activationLock], devices: -5, appleManaged: 0)?.reads == 0)
        // A School org has no Apple MDM details to read.
        let school = try await Self.world(profiles: [World.profile("a", scope: .school), World.profile("b")])
        #expect(await school.snapshots.estimate(Set(Sweep.allCases), devices: 100, appleManaged: 10)?.reads == 200)
        let none = try await World.make(profiles: [])
        #expect(await none.snapshots.estimate([.appleCare], devices: 1, appleManaged: 0) == nil)
    }
}
