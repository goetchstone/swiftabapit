import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
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
        #expect(summary.notes["mdm_details"] == nil, "IMEI, MEID and MACs are known and left out unsaid")
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

    /// Two records with one id (abapit's id rule: Apple's id): the store keeps one, so the sweep says so and is a part read.
    @Test func aCoverageIdSeenTwiceIsAPartRead() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.setCoverage(Self.serial(2), [Self.coverage("0000000001", "AppleCare+", payment: "SUBSCRIPTION")])
        let snapshot = try await Self.recorded(world, [.appleCare])
        #expect(snapshot.summary.errors["applecare"] == "duplicate id")
        #expect(snapshot.summary.notes["applecare"] == "1 record had the id of another read: the history keeps one of each")
        #expect(Self.item(snapshot, "applecare", "0000000001")?.attributes["serialNumber"] == .string(Self.serial(2)), "the last, in the list's order")
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

    /// Before a run, from the counts a screen has, at the org's rate now; said as an estimate.
    @Test func theEstimateBeforeARunIsSaidAsOne() async throws {
        let world = try await Self.world()
        let estimate = try #require(await world.snapshots.estimate(Set(Sweep.allCases), devices: 100, appleManaged: 10))
        #expect(estimate == Sweep.Estimate(reads: 210, readsPerMinute: 600))
        #expect(estimate.words == "About a minute: 210 reads at about 600 a minute, this organization's rate now. An estimate: "
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
