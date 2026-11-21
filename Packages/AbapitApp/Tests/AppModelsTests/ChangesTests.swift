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

/// Activity › Changes (plan Phase 3; docs/domains/history.md, "The Changes screen"): the active org's snapshots, two compared
/// with `SnapshotDiff`, and a side that wasn't read never shown as a removal; "Snapshot now" with opt-in sweeps, their estimates
/// before the run, progress and Cancel; nothing of one org's run under another; a Mosyle org said to have no collector; the
/// comparison as a CSV that names its client only with several; the question asked when an org is removed. Over the strict stub,
/// into a real `SnapshotStore`.
@MainActor
@Suite("Changes screen", .serialized)
struct ChangesTests {
    static let base: TimeInterval = 1_790_000_000
    static let day: TimeInterval = 86_400

    static func device(_ id: String, status: String = "ASSIGNED", model: String = "MacBook Air") -> Resource {
        Resource(type: "devices", id: id, attributes: ["serialNumber": .string(id), "deviceModel": .string(model), "status": .string(status)])
    }

    static func person(_ id: String) -> Resource {
        Resource(type: "users", id: id, attributes: ["managedAppleAccount": .string("\(id.lowercased())@example.com"), "status": .string("ACTIVE")])
    }

    /// Records a snapshot of org `org` `days` days after `base`.
    @discardableResult
    static func record(_ world: World, _ org: String = "a", days: Double, _ resources: [String: [Resource]], errors: [String: String] = [:],
                       notes: [String: String] = [:]) async throws -> Int64 {
        try await world.history!.record(org: world.orgs.store[org]!, takenAt: Date(timeIntervalSince1970: base + days * day), resources: resources,
                                        errors: errors, notes: notes)
    }

    /// A model over a world whose org `a` has `older` then `newer` recorded, loaded, comparing them.
    static func compared(older: [String: [Resource]], newer: [String: [Resource]], olderErrors: [String: String] = [:],
                         newerErrors: [String: String] = [:], world: World? = nil) async throws -> (world: World, model: ChangesModel) {
        let world = try await (world == nil ? World.make() : world!)
        try await record(world, days: 0, older, errors: olderErrors)
        try await record(world, days: 14, newer, errors: newerErrors)
        let model = world.screens.changes
        await model.load()
        return (world, model)
    }

    static func change(_ model: ChangesModel, _ resource: String) -> ChangesModel.ResourceChange? {
        model.comparison?.changes.first { $0.resource == resource }
    }

    // MARK: the list and the diff

    /// The newest and the one before are compared by default, and what is shown per resource is `SnapshotDiff`'s.
    @Test func theDiffShownPerResourceMatchesSnapshotDiff() async throws {
        let older: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2"), Self.device("D3")], "users": [Self.person("U1")]]
        let newer: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2", status: "UNASSIGNED"), Self.device("D4", model: "iPhone 16")],
                                           "users": [Self.person("U1")]]
        let (_, model) = try await Self.compared(older: older, newer: newer)
        #expect(model.rows.count == 2 && model.rows[0].id == model.newerID && model.rows[1].id == model.olderID, "newest first; the pair is the last two")
        let comparison = try #require(model.comparison)
        func snapshot(_ resources: [String: [Resource]]) -> SnapshotDiff.Snapshot {
            SnapshotDiff.Snapshot(rows: resources.flatMap { name, items in items.map { (resource: name, id: $0.id, attributes: $0.attributes) } })
        }
        #expect(comparison.deltas == SnapshotDiff.diff(old: snapshot(older), new: snapshot(newer)))
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.added.map(\.id) == ["D4"] && devices.added.first?.label == "iPhone 16")
        #expect(devices.removed.map(\.id) == ["D3"] && devices.removed.first?.label == "MacBook Air")
        #expect(devices.changed.map(\.id) == ["D2"] && devices.changed.first?.fields.map { "\($0.field)|\($0.old)|\($0.new)" } == ["status|ASSIGNED|UNASSIGNED"])
        #expect(!devices.partial && devices.counts == "1 added, 1 removed, 1 changed")
        #expect(comparison.unchanged == ["People"], "a resource read in full on both sides with nothing different is said so")
        #expect(comparison.skipped.isEmpty)
    }

    /// Picking two snapshots: either order, and the same one twice is said.
    @Test func twoSnapshotsAreChosenInEitherOrder() async throws {
        let world = try await World.make()
        let first = try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        let second = try await Self.record(world, days: 7, ["devices": [Self.device("D1"), Self.device("D2")]])
        let third = try await Self.record(world, days: 14, ["devices": [Self.device("D1"), Self.device("D2"), Self.device("D3")]])
        let model = world.screens.changes
        await model.load()
        #expect(model.newerID == third && model.olderID == second)
        await model.choose(older: third, newer: first)
        #expect(model.olderID == first && model.newerID == third, "the older of the two is the older")
        #expect(Self.change(model, "devices")?.added.map(\.id) == ["D2", "D3"])
        await model.choose(older: first, newer: first)
        #expect(model.comparison == nil && model.comparisonProblem == "Choose two different snapshots.")
        #expect(model.exportBlocked == "Choose two different snapshots.")
    }

    @Test func anEmptyHistorySaysSoAndOffersSnapshotNow() async throws {
        let world = try await World.make()
        let model = world.screens.changes
        await model.load()
        guard case .loaded = model.state else {
            Issue.record("\(model.state)")
            return
        }
        #expect(model.rows.isEmpty && model.comparison == nil && model.comparisonProblem == "Take a second snapshot to compare: a comparison needs two.")
        #expect(model.startBlocked == nil && !model.isMosyle, "Snapshot now is offered")
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        await model.load()
        #expect(model.rows.count == 1 && model.comparison == nil && model.comparisonProblem == "Take a second snapshot to compare: a comparison needs two.")
    }

    /// Changes is local history: a School org reads it too, and it asks Apple for nothing.
    @Test func aSchoolOrgReadsItsHistoryAndAsksAppleForNothing() async throws {
        let school = World.profile("a", scope: .school)
        let world = try await World.make(profiles: [school])
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        try await Self.record(world, days: 1, ["devices": [Self.device("D1"), Self.device("D2")]])
        let model = world.screens.changes
        await model.load()
        #expect(Self.change(model, "devices")?.added.map(\.id) == ["D2"])
        #expect(world.stubs["a"]!.requests.isEmpty, "\(world.stubs["a"]!.requests)")
        #expect(model.availableSweeps == [.appleCare, .activationLock], "Apple MDM's details are Business-only")
    }

    // MARK: a side that wasn't read

    /// A resource not read on the newer side (it failed before any item) is no removal: it is left out, in words naming the side.
    @Test func aNotReadNewerSideShowsNoRemovalsAndSaysSo() async throws {
        let older: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2")], "users": [Self.person("U1")]]
        let (_, model) = try await Self.compared(older: older, newer: ["users": [Self.person("U1"), Self.person("U2")]], newerErrors: ["devices": "HTTP 403"])
        #expect(Self.change(model, "devices") == nil, "no devices section: nothing was removed, it wasn't read")
        let skipped = try #require(model.comparison?.skipped.first { $0.resource == "devices" })
        #expect(skipped.why == "not read in the newer snapshot (HTTP 403), so no change is shown.")
        #expect(model.comparison?.deltas.flatMap(\.removed).isEmpty == true)
        #expect(Self.change(model, "users")?.added.map(\.id) == ["U2"], "what was read on both sides is still compared")
        #expect(model.csv().contains("not compared,devices"), "the file says it too")
        #expect(!model.csv().contains(",removed,"))
    }

    /// The older side not read: nothing is "added" either.
    @Test func aNotReadOlderSideShowsNoAdditions() async throws {
        let (_, model) = try await Self.compared(older: ["users": [Self.person("U1")]], newer: ["devices": [Self.device("D1")], "users": [Self.person("U1")]])
        #expect(Self.change(model, "devices") == nil)
        let skipped = try #require(model.comparison?.skipped.first { $0.resource == "devices" })
        #expect(skipped.why == "not read in the older snapshot, so no change is shown.", "\(skipped.why)")
    }

    /// A resource neither snapshot has a word about isn't listed; one both failed is said, never a change.
    @Test func aResourceBothSnapshotsFailedIsSaid() async throws {
        let (_, model) = try await Self.compared(older: ["devices": [Self.device("D1")]], newer: ["devices": [Self.device("D1")]])
        #expect(model.comparison?.changes.isEmpty == true && model.comparison?.hasChanges == false && model.comparison?.skipped.isEmpty == true)
        #expect(model.comparison?.unchanged == ["Devices"])
        // Both sides failed the same resource.
        let both = try await Self.compared(older: ["devices": [Self.device("D1")]], newer: ["devices": [Self.device("D1")]],
                                           olderErrors: ["users": "HTTP 403"], newerErrors: ["users": "HTTP 403"])
        let users = try #require(both.model.comparison?.skipped.first { $0.resource == "users" })
        #expect(users.why == "not read in either snapshot, so no change is shown.")
    }

    /// The newer side read in part (a page cap, a failure part-way): marked partial; what the older has and it lacks is held back, not
    /// removed; a change in what both read is shown.
    @Test func aPartReadNewerSideIsMarkedPartialAndNeverShowsRemovals() async throws {
        let older: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2"), Self.device("D3")]]
        let newer: [String: [Resource]] = ["devices": [Self.device("D1", status: "UNASSIGNED")]]
        let (_, model) = try await Self.compared(older: older, newer: newer, newerErrors: ["devices": "page cap"])
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.partial && devices.removed.isEmpty, "D2 and D3 may only not have been read")
        #expect(devices.changed.map(\.id) == ["D1"])
        #expect(devices.withheld == ["2 items in the older snapshot aren't in the newer, which was read in part (page cap): not shown as removed, since it may only not have been read."])
        #expect(model.comparison?.deltas.flatMap(\.removed).isEmpty == true)
        #expect(model.rows[0].marks == ["partial: Devices (page cap)"], "\(model.rows[0].marks)")
        #expect(model.csv().contains("not compared,devices") && !model.csv().contains(",removed,"))
    }

    /// The older side read in part: what the newer has and it lacks is held back, not added.
    @Test func aPartReadOlderSideShowsNoAdditions() async throws {
        let older: [String: [Resource]] = ["devices": [Self.device("D1")]]
        let newer: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2")]]
        let (_, model) = try await Self.compared(older: older, newer: newer, olderErrors: ["devices": "HTTP 403"])
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.partial && devices.added.isEmpty)
        #expect(devices.withheld.count == 1 && devices.withheld[0].hasPrefix("1 item in the newer snapshot isn't in the older, which was read in part (HTTP 403)"))
    }

    /// Two part reads with no difference among what was read still show, marked partial, never as "no change".
    @Test func aPartReadWithNoDifferenceIsStillShownPartial() async throws {
        let same: [String: [Resource]] = ["devices": [Self.device("D1")]]
        let (_, model) = try await Self.compared(older: same, newer: same, newerErrors: ["devices": "page cap"])
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.partial && devices.isEmpty && devices.counts == "no change among the items read")
        #expect(model.comparison?.unchanged.isEmpty == true)
    }

    /// Each snapshot's notes and marks are shown: counts of attributes left out, the sweeps' not-read counts, what was read in part.
    @Test func aSnapshotsNotesAndMarksAreShown() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]], errors: ["devices": "page cap", "users": "HTTP 403"],
                              notes: ["devices": "stopped at the page limit: 1 of 9 read, more not read",
                                      "activation_lock": "2 of 6 devices not read: 2 failed twice (HTTP 500)"])
        let model = world.screens.changes
        await model.load()
        let row = try #require(model.rows.first)
        #expect(row.marks == ["partial: Devices (page cap)", "not read: People (HTTP 403)"])
        #expect(row.notes == ["Activation Lock: 2 of 6 devices not read: 2 failed twice (HTTP 500)", "Devices: stopped at the page limit: 1 of 9 read, more not read"])
        #expect(row.devices == 1 && row.writtenBy.hasPrefix("swiftabapit"))
    }

    // MARK: Snapshot now

    /// Snapshot now records the active org's snapshot, shows how it ended and reloads the list.
    @Test func snapshotNowRecordsAndShowsIt() async throws {
        let world = try await CollectorTests.world()
        let model = world.screens.changes
        await model.load()
        #expect(model.rows.isEmpty)
        let outcome = await model.snapshotNow()
        guard case .recorded(let id)? = outcome else {
            Issue.record("\(String(describing: outcome))")
            return
        }
        #expect(model.result == "Snapshot taken." && model.rows.map(\.id) == [id] && model.rows.first?.devices == 3)
        #expect(!model.isRunning && model.reading == nil && model.progress == nil)
    }

    /// The sweeps are opt-in, per run: none unless chosen, only those chosen, and none again for the run after.
    @Test func theSweepsAreOptInPerRun() async throws {
        let world = try await SweepTests.world(devices: 3)
        let model = world.screens.changes
        await model.load()
        #expect(model.sweeps.isEmpty && model.availableSweeps == [.appleCare, .activationLock, .mdmDetails])
        await model.snapshotNow()
        #expect(SweepTests.asked(world, "/activationLockStatus").isEmpty && SweepTests.asked(world, "/appleCareCoverage").isEmpty
                && SweepTests.asked(world, "/details").isEmpty, "nothing is swept unless asked")
        model.set(.activationLock, on: true)
        #expect(model.sweeps == [.activationLock])
        await model.snapshotNow()
        #expect(SweepTests.asked(world, "/activationLockStatus").count == 3 && SweepTests.asked(world, "/appleCareCoverage").isEmpty
                && SweepTests.asked(world, "/details").isEmpty, "only the one chosen")
        #expect(model.sweeps.isEmpty, "each run asks again")
        await model.snapshotNow()
        #expect(SweepTests.asked(world, "/activationLockStatus").count == 3, "the third run swept nothing")
        let newest = try await world.history!.snapshots(org: world.orgs.active!)
        #expect(newest.count == 3 && newest[1].counts["activation_lock"] == 3 && newest[0].counts["activation_lock"] == nil && newest[2].counts["activation_lock"] == nil)
    }

    /// The estimate is shown before the run, and says it is one; with no snapshot there is no device count and it says so.
    @Test func theEstimateIsShownBeforeTheRunAndSaysItIsOne() async throws {
        let world = try await SweepTests.world(devices: 3)
        let model = world.screens.changes
        await model.load()
        #expect(model.estimateLine(.appleCare) == "AppleCare coverage: the time can't be estimated yet. It needs a device count, which the first snapshot's device list gives.")
        #expect(model.estimateBasis == nil)
        await model.snapshotNow()
        for sweep in model.availableSweeps {
            let line = model.estimateLine(sweep)
            #expect(line.hasPrefix("\(sweep.title): ") && line.contains("An estimate"), "\(line)")
        }
        #expect(model.estimateLine(.appleCare).contains("3 reads") && model.estimateLine(.mdmDetails).contains("2 reads"), "managed devices only for the details")
        #expect(model.estimateBasis == "Counted from the newest snapshot: 3 devices, 2 managed by Apple MDM.")
    }

    /// Progress shows done of total, the run's own estimate shows, and Cancel stops it and writes nothing.
    @Test func progressShowsAndCancelWritesNothing() async throws {
        let world = try await SweepTests.world(devices: 3)
        let model = world.screens.changes
        await model.load()
        model.set(.activationLock, on: true)
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(SweepTests.lockPath) }
        let running = Task { await model.snapshotNow() }
        await eventually("the sweep's first read held") { gate.held >= 1 }
        #expect(model.isRunning && model.startBlocked == "A snapshot is being taken.")
        #expect(model.reading == "Activation Lock" && model.progress == "Activation Lock: 0 of 3 devices", "\(String(describing: model.progress))")
        #expect(model.runEstimate?.contains("An estimate") == true)
        model.cancel()
        gate.release("locks")
        #expect(await running.value == .cancelled)
        #expect(model.result == "Cancelled: nothing was written." && !model.isRunning && model.progress == nil && model.runEstimate == nil)
        #expect(try await world.history!.snapshots(org: world.orgs.active!).isEmpty, "a cancelled run writes nothing")
        #expect(model.rows.isEmpty)
    }

    /// A refusal is the collector's words while the run it was about goes, and ends with that run.
    @Test func aRefusalEndsWithTheRunItWasAbout() async throws {
        let world = try await CollectorTests.world()
        let model = world.screens.changes
        let gate = world.gates["a"]!
        gate.hold("users") { $0.path() == "/v1/users" }
        let running = Task { await model.snapshotNow() }
        await eventually("the run at the users") { gate.held == 1 }
        let refused = await model.snapshotNow()
        #expect(refused == .notRun("A snapshot is already being taken.") && model.refusal == "A snapshot is already being taken.")
        #expect(model.result == nil, "a refusal is said once, by the collector, and isn't kept by the screen")
        gate.release("users")
        _ = await running.value
        #expect(model.refusal == nil, "the refusal doesn't outlive the run")
        #expect(model.result == "Snapshot taken.")
    }

    /// A refusal or an error is shown as the collector reports it: no org's history, a store that wouldn't record.
    @Test func anErrorIsShownAsTheCollectorReportsIt() async throws {
        let world = try await World.make(profiles: [World.unusable])
        let model = world.screens.changes
        await model.load()
        let outcome = await model.snapshotNow()
        guard case .notRun(let why)? = outcome else {
            Issue.record("\(String(describing: outcome))")
            return
        }
        #expect(model.result == "No snapshot was taken: \(why)" && why.hasPrefix("This organization can't be used:"))
        let none = try await World.make(profiles: [])
        let noOrg = none.screens.changes
        await noOrg.load()
        #expect(noOrg.state == .unusable(ScreenWords.noOrganization) && noOrg.startBlocked == ScreenWords.noOrganization)
        #expect(await noOrg.snapshotNow() == nil && noOrg.result == ScreenWords.noOrganization)
    }

    /// A history that won't open is said, and Snapshot now's run says why too (the collector's words).
    @Test func aHistoryThatWontOpenIsSaid() async throws {
        let failure = SnapshotStore.Failure.readOnly(version: 9)
        let world = try await World.make(history: { .failure(failure) })
        let model = world.screens.changes
        await model.load()
        #expect(model.state == .failed(failure.message) && model.rows.isEmpty)
        #expect(model.exportBlocked != nil)
        await model.snapshotNow()
        #expect(model.result == "No snapshot was taken: \(failure.message)")
    }

    // MARK: Mosyle

    /// A Mosyle org has no collector yet: Snapshot now says so in words, reads nothing and doesn't crash (abapit's defect 6); its
    /// history is still read, and has nothing.
    @Test func aMosyleOrgSaysItHasNoCollectorYet() async throws {
        let world = try await World.make(mosyle: true)
        world.orgs.select("m")
        let model = world.screens.changes
        await model.load()
        guard case .loaded = model.state else {
            Issue.record("\(model.state)")
            return
        }
        #expect(model.isMosyle && model.rows.isEmpty && model.availableSweeps.isEmpty)
        #expect(model.startBlocked == ChangesModel.mosyleWords)
        #expect(await model.snapshotNow() == nil)
        #expect(model.result == ChangesModel.mosyleWords && ChangesModel.mosyleWords.contains("aren't built yet") && !model.isRunning)
        #expect(world.stubs["a"]!.requests.isEmpty && world.mosyleStub.requests.isEmpty, "nothing was read")
        #expect(try await world.history!.orgIDs().isEmpty)
        // The collector itself refuses the same org in words, without running.
        guard case .notRun(let why) = await world.snapshots.run() else {
            Issue.record("a Mosyle org ran")
            return
        }
        #expect(why.contains("Mosyle Business organization"))
    }

    // MARK: one org at a time

    /// Nothing of org A's run is shown under org B: not that it runs, what it reads, its progress, its estimate, a refusal, its
    /// result or its snapshots, though the collector's own run is still stopping.
    @Test func aSwitchMidRunShowsNothingOfTheOldOrg() async throws {
        let world = try await SweepTests.world(devices: 3)
        try await Self.record(world, "a", days: 0, ["devices": [Self.device("D1")]])
        let model = world.screens.changes
        await model.load()
        #expect(model.rows.count == 1)
        model.set(.activationLock, on: true)
        let gate = world.gates["a"]!
        gate.hold("locks") { $0.path().hasSuffix(SweepTests.lockPath) }
        let running = Task { await model.snapshotNow() }
        await eventually("the sweep's first read held") { gate.held >= 1 }
        // A refusal for the run A has going.
        _ = await model.snapshotNow()
        #expect(model.isRunning && model.reading != nil && model.progress != nil && model.runEstimate != nil && model.refusal != nil)
        world.orgs.select("b")
        // The collector's run is still stopping, and the screen says nothing of it as a run.
        #expect(world.snapshots.isRunning, "the stopped run hasn't returned")
        #expect(!model.isRunning && model.reading == nil && model.progress == nil && model.runEstimate == nil && model.refusal == nil)
        #expect(model.result == nil && model.rows.isEmpty && model.comparison == nil && model.sweeps.isEmpty && model.estimates.isEmpty)
        #expect(world.snapshots.sweepProgress == nil && world.snapshots.sweepEstimate == nil && world.snapshots.reading == nil)
        #expect(model.startBlocked == "A snapshot of the previous organization is still stopping. Try again in a moment.")
        gate.release("locks")
        #expect(await running.value == .cancelled)
        await eventually("the new org's history read") { if case .loaded = model.state { true } else { false } }
        #expect(model.result == nil && model.refusal == nil && model.rows.isEmpty && !model.isRunning && model.startBlocked == nil)
        let bProfile = try #require(world.orgs.store["b"])
        let underB = try await world.history!.snapshots(org: bProfile), underA = try await world.history!.snapshots(org: world.orgs.store["a"]!)
        #expect(underB.isEmpty && underA.count == 1, "the stopped run wrote nothing under either org")
    }

    /// How a run ended is org a's: a switch clears it, with the list and the sweeps chosen.
    @Test func aSwitchClearsHowTheLastRunEnded() async throws {
        let world = try await CollectorTests.world()
        let model = world.screens.changes
        await model.snapshotNow()
        model.set(.appleCare, on: true)
        #expect(model.result == "Snapshot taken." && model.rows.count == 1 && model.sweeps == [.appleCare])
        world.orgs.select("b")
        #expect(model.result == nil && model.rows.isEmpty && model.sweeps.isEmpty && model.estimates.isEmpty && model.estimateBasis == nil)
        await eventually("org b's history read") { if case .loaded = model.state { true } else { false } }
        #expect(model.result == nil && model.rows.isEmpty)
    }

    /// The list and the comparison are the active org's, and a load that returns after a switch is dropped.
    @Test func anotherOrgsSnapshotsAreNeverShown() async throws {
        let world = try await World.make()
        try await Self.record(world, "a", days: 0, ["devices": [Self.device("A1")]])
        try await Self.record(world, "a", days: 1, ["devices": [Self.device("A1"), Self.device("A2")]])
        try await Self.record(world, "b", days: 0, ["devices": [Self.device("B1")]])
        let model = world.screens.changes
        await model.load()
        #expect(model.rows.count == 2 && Self.change(model, "devices")?.added.map(\.id) == ["A2"])
        world.orgs.select("b")
        #expect(model.rows.isEmpty && model.comparison == nil, "cleared at once")
        await eventually("org b's history read") { model.rows.count == 1 }
        #expect(model.comparison == nil && model.comparisonProblem == "Take a second snapshot to compare: a comparison needs two.")
        // A load started for a, answered after the switch to b.
        world.orgs.select("a")
        await eventually("org a's history read") { model.rows.count == 2 }
        let stale = Task { await model.load() }
        world.orgs.select("b")
        await stale.value
        await eventually("org b's history read") { model.rows.count == 1 && model.rows.first?.devices == 1 }
        #expect(model.rows.count == 1)
    }

    // MARK: the CSV

    /// One client: the file is named without one, and its words say none. Several: the client's name leads the file's name.
    @Test func theCSVNamesTheClientOnlyWithSeveral() async throws {
        let older: [String: [Resource]] = ["devices": [Self.device("D1"), Self.device("D2")]]
        let newer: [String: [Resource]] = ["devices": [Self.device("D1", status: "UNASSIGNED")]]
        let one = try await World.make(profiles: [World.profile("a")], mosyle: true)
        let single = try await Self.compared(older: older, newer: newer, world: one).model
        let pair = try #require(single.comparison)
        let stamps = pair.older.takenAt.filter { $0 != "-" && $0 != ":" } + " to " + pair.newer.takenAt.filter { $0 != "-" && $0 != ":" }
        #expect(!one.orgs.showsClients && single.exportFileName == "changes \(stamps).csv", "\(single.exportFileName)")
        #expect(!single.exportWords.contains("client"), "\(single.exportWords)")

        let two = try await World.make()
        let several = try await Self.compared(older: older, newer: newer, world: two).model
        #expect(two.orgs.showsClients && several.exportFileName == "Org a - changes \(stamps).csv", "\(several.exportFileName)")
        #expect(several.exportWords.contains("client \"Org a\"'s data only"), "\(several.exportWords)")
        // Its words say what the file holds.
        #expect(several.exportWords.hasPrefix("Saves what differs between two snapshots of \"Org a\" taken ") && several.exportWords.contains("A value under a secret's name is withheld."))
        // Another client's file is named for that client.
        two.orgs.selectClient(try #require(two.orgs.store.client(of: "b")).id)
        #expect(several.exportFileName.hasPrefix("Org b - "), "\(several.exportFileName)")
    }

    /// The file holds the comparison, one row each, and never a secret-named attribute: the store left it out, and the export
    /// would withhold it.
    @Test func theCSVHoldsTheDifferencesAndNoSecret() async throws {
        func device(_ id: String, status: String, bypass: String) -> Resource {
            Resource(type: "devices", id: id, attributes: ["serialNumber": .string(id), "deviceModel": .string("MacBook Air"), "status": .string(status),
                                                            "activation_bypass_code": .string(bypass)])
        }
        let (_, model) = try await Self.compared(older: ["devices": [device("D1", status: "ASSIGNED", bypass: "CANARYBYPASSOLD"), Self.device("D2")]],
                                                 newer: ["devices": [device("D1", status: "UNASSIGNED", bypass: "CANARYBYPASSNEW"), Self.device("D3")]])
        let csv = model.csv()
        let lines = csv.split(separator: "\r\n").map(String.init)
        #expect(lines[0] == "id,older,newer,change,resource,label,field,old,new,note", "\(lines[0])")
        let older = try #require(model.comparison).older.takenAt, newer = try #require(model.comparison).newer.takenAt
        #expect(Array(lines.dropFirst()) == ["D3,\(older),\(newer),added,devices,MacBook Air,,,,", "D2,\(older),\(newer),removed,devices,MacBook Air,,,,",
                                             "D1,\(older),\(newer),changed,devices,MacBook Air,status,ASSIGNED,UNASSIGNED,"], "\(lines)")
        #expect(!csv.contains("CANARYBYPASS") && !csv.contains("activation_bypass"))
    }

    /// Nothing to say is one row, never a bare header.
    @Test func aComparisonWithNothingToSayIsOneRow() async throws {
        let same: [String: [Resource]] = ["devices": [Self.device("D1")]]
        let (_, model) = try await Self.compared(older: same, newer: same)
        let lines = model.csv().split(separator: "\r\n")
        #expect(lines.count == 2 && lines[1].contains("no differences"), "\(lines)")
    }

    // MARK: the demo

    /// The demo org's fake snapshots draw a real-looking diff: a partial resource, a change, a resource not read, and a removal
    /// that is held back, never shown.
    @Test func theDemoHistoryDrawsARealisticDiff() async throws {
        let world = try await World.make()
        await DemoHistory.seed(world.history!, org: world.orgs.store["a"]!)
        let model = world.screens.changes
        await model.load()
        #expect(model.rows.count == 3)
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.partial && devices.removed.isEmpty && devices.changed.map(\.id) == ["DEMOCHG0002"] && devices.withheld.count == 1)
        #expect(Self.change(model, "mdm_servers")?.changed.map(\.id) == ["DEMOSVC1"])
        #expect(model.comparison?.skipped.map(\.resource).sorted() == ["activation_lock", "applecare", "users"])
        #expect(model.rows[0].marks == ["partial: Devices (page cap)", "not read: People (HTTP 403 FORBIDDEN_ERROR)"], "\(model.rows[0].marks)")
        for text in model.comparison?.changes.flatMap({ $0.added + $0.removed }).map(\.id) ?? [] { #expect(text.hasPrefix("DEMO")) }
    }

    /// The demo's first read waits for its seeding, once, so the screen never draws half a history.
    @Test func theFirstLoadWaitsForTheDemoSeedOnce() async throws {
        let world = try await World.make()
        let model = world.screens.changes
        var ran = 0
        model.beforeFirstLoad = {
            ran += 1
            await DemoHistory.seed(world.history!, org: world.orgs.store["a"]!)
        }
        await model.load()
        #expect(ran == 1 && model.rows.count == 3 && model.comparison != nil)
        await model.load()
        #expect(ran == 1 && model.rows.count == 3, "the hook runs once")
    }

    // MARK: the review round

    /// A part read is never written over as "no differences": the CSV has a `partial` row for each resource read in part, with
    /// changes or without.
    @Test func theCSVSaysPartialWhateverWasWithheld() async throws {
        let same: [String: [Resource]] = ["devices": [Self.device("D1")]]
        let (_, none) = try await Self.compared(older: same, newer: same, newerErrors: ["devices": "page cap"])
        let older = try #require(none.comparison).older.takenAt, newer = try #require(none.comparison).newer.takenAt
        let lines = none.csv().split(separator: "\r\n").map(String.init)
        #expect(lines.count == 2 && !none.csv().contains("no differences"), "\(lines)")
        #expect(lines[1].hasPrefix(",\(older),\(newer),partial,devices,") && lines[1].contains("the newer snapshot (page cap)"), "\(lines)")
        // With a change in what both read: the change and the partial row.
        let (_, some) = try await Self.compared(older: ["devices": [Self.device("D1"), Self.device("D2")]],
                                                newer: ["devices": [Self.device("D1", status: "UNASSIGNED")]], newerErrors: ["devices": "page cap"])
        let rows = some.csv().split(separator: "\r\n").map(String.init)
        #expect(rows.contains { $0.contains(",changed,devices,") } && rows.contains { $0.contains(",partial,devices,") }, "\(rows)")
        // Nothing partial, nothing skipped: "no differences".
        let (_, whole) = try await Self.compared(older: same, newer: same)
        #expect(whole.csv().contains("no differences") && !whole.csv().contains("partial"))
        // A skipped resource is not "no differences" either.
        let (_, skipped) = try await Self.compared(older: same, newer: same, newerErrors: ["users": "HTTP 403"], world: nil)
        #expect(!skipped.csv().contains("no differences") && skipped.csv().contains("not compared,users"))
    }

    /// 105 snapshots: the list shows the newest 100 and says so; exactly 100 says nothing.
    @Test func moreThanAHundredSnapshotsAreSaid() async throws {
        let world = try await World.make()
        for index in 0..<105 { try await Self.record(world, days: Double(index), ["devices": [Self.device("D\(index)")]]) }
        let model = world.screens.changes
        await model.load()
        #expect(model.rows.count == 100 && model.listNote == "Showing the newest 100 snapshots; older ones aren't listed.")
        #expect(model.rows.first?.devices == 1 && model.rows.first?.takenAt == model.comparison?.newer.takenAt)
        let exact = try await World.make()
        for index in 0..<100 { try await Self.record(exact, days: Double(index), ["devices": [Self.device("D\(index)")]]) }
        await exact.screens.changes.load()
        #expect(exact.screens.changes.rows.count == 100 && exact.screens.changes.listNote == nil)
    }

    /// No Apple MDM count is no data: no estimate for the details, and the line and basis say the count is unknown.
    @Test func noManagedDeviceCountMakesNoDetailsEstimate() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1"), Self.device("D2")]])
        let model = world.screens.changes
        await model.load()
        #expect(model.estimates[.mdmDetails] == nil && model.estimates[.appleCare] != nil)
        #expect(model.estimateLine(.mdmDetails) == "Apple MDM details: the time can't be estimated: the newest snapshot didn't read Apple MDM's device list, so the number of managed devices is unknown.")
        #expect(model.estimateBasis == "Counted from the newest snapshot: 2 devices, the number managed by Apple MDM unknown.")
    }

    /// Snapshots exist but the newest didn't read devices: the words say that, not "the first snapshot".
    @Test func aNewestSnapshotWithoutDevicesIsSaidSeparately() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        try await Self.record(world, days: 1, ["users": [Self.person("U1")]], errors: ["devices": "HTTP 403"])
        let model = world.screens.changes
        await model.load()
        #expect(model.estimates.isEmpty && model.estimateBasis == nil)
        #expect(model.estimateLine(.appleCare) == "AppleCare coverage: the time can't be estimated: the newest snapshot didn't read the device list, so there is no device count. A snapshot that reads it gives one.")
    }

    /// A page-capped device count is not shown as exact.
    @Test func aPartReadDeviceCountIsSaidToBePartial() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "mdm_enrolled": [Resource(type: "mdm_enrolled", id: "M1", attributes: ["serialNumber": .string("D1")])]],
                              errors: ["devices": "page cap", "mdm_enrolled": "page cap"])
        let model = world.screens.changes
        await model.load()
        #expect(model.estimateBasis == "Counted from the newest snapshot: 1 device (read in part), 1 managed by Apple MDM (read in part).", "\(String(describing: model.estimateBasis))")
    }

    /// An unchosen pair moves to the newest two when a snapshot is taken; a chosen pair survives a reload (and is dropped by a new snapshot).
    @Test func theDefaultPairFollowsTheNewestAndAChosenPairStays() async throws {
        let world = try await CollectorTests.world()
        let first = try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        let second = try await Self.record(world, days: 1, ["devices": [Self.device("D1"), Self.device("D2")]])
        let model = world.screens.changes
        await model.load()
        #expect(model.olderID == first && model.newerID == second)
        let outcome = await model.snapshotNow()
        guard case .recorded(let third)? = outcome else {
            Issue.record("\(String(describing: outcome))")
            return
        }
        // The snapshot is taken now (after the fake ones): it is the newest.
        #expect(model.newerID == third && model.olderID == second, "the default pair moved to the newest two")
        await model.choose(older: first, newer: second)
        await model.load()
        #expect(model.olderID == first && model.newerID == second, "a chosen pair survives a reload")
        await model.snapshotNow()
        #expect(model.rows.count == 4 && model.newerID == model.rows[0].id && model.olderID == model.rows[1].id, "a new snapshot resets it")
    }

    /// Deleting history is refused while a snapshot is being taken or an import runs; removing the org and keeping its history is not.
    @Test func historyIsNotDeletedWhileSomethingWritesToIt() async throws {
        let world = try await CollectorTests.world()
        try await Self.record(world, "b", days: 0, ["devices": [Self.device("B1")]])
        let gate = world.gates["a"]!
        gate.hold("users") { $0.path() == "/v1/users" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the users") { gate.held == 1 }
        let why = try #require(world.orgs.historyDeletionBlocked)
        #expect(why.hasPrefix("A snapshot is being taken"))
        await #expect(throws: OrgsModel.SaveFailure.self) { try await world.orgs.remove("b", deleteSecrets: true, deleteHistory: true) }
        #expect(world.orgs.store["b"] != nil, "the org stays")
        let bProfile = try #require(world.orgs.store["b"])
        let kept = try await world.history!.snapshots(org: bProfile).count
        #expect(kept == 1, "and its history")
        gate.release("users")
        _ = await running.value
        #expect(world.orgs.historyDeletionBlocked == nil)

        // An import running blocks it too.
        let source = try HistoryTransferTests.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let imp = try await HistoryTransferTests.world()
        let rows = [HistoryTransferTests.Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: HistoryTransferTests.a, items: [HistoryTransferTests.device("D1")])]
        let url = URL(filePath: try HistoryTransferTests.abapitFile(rows, in: source))
        var during: String?
        imp.screens.historyTransfer.beforeWrite = { during = imp.orgs.historyDeletionBlocked }
        await imp.screens.historyTransfer.importHistory(from: url)
        #expect(during?.hasPrefix("A history import or export is running") == true, "\(String(describing: during))")
        #expect(imp.orgs.historyDeletionBlocked == nil)
        // Keeping the history is allowed while a run goes.
        try await world.orgs.remove("b", deleteSecrets: true, deleteHistory: false)
        #expect(world.orgs.store["b"] == nil)
    }

    /// A switch clears the note about a list cut at 100 snapshots.
    @Test func aSwitchClearsTheListNote() async throws {
        let world = try await World.make()
        for index in 0..<101 { try await Self.record(world, days: Double(index), ["devices": [Self.device("D\(index)")]]) }
        let model = world.screens.changes
        await model.load()
        #expect(model.listNote != nil)
        world.orgs.select("b")
        #expect(model.listNote == nil && model.rows.isEmpty)
        await eventually("b's history read") { if case .loaded = model.state { true } else { false } }
        #expect(model.listNote == nil)
    }

    /// A read that returns after a switch is dropped: each guard (the list, the comparison, the estimates) is held by a hook that
    /// switches orgs while the read is out, and the screen shows nothing of the old org right after.
    @Test func aReadThatReturnsAfterASwitchIsDropped() async throws {
        func seeded() async throws -> (World, ChangesModel) {
            let world = try await World.make()
            try await Self.record(world, "a", days: 0, ["devices": [Self.device("A1")]])
            try await Self.record(world, "a", days: 1, ["devices": [Self.device("A1"), Self.device("A2")]])
            return (world, world.screens.changes)
        }
        // The list.
        var (world, model) = try await seeded()
        // Once, and b's own load finishes inside the hook: the stale list then returns after it, where only the guard stops it.
        var fired = false
        let before = model.loadsFinished, m0 = model, w0 = world
        model.afterRead = { stage in
            guard stage == "load", !fired else { return }
            fired = true
            w0.orgs.select("b")
            await eventually("b's own load") { m0.loadsFinished > before }
        }
        await model.load()
        #expect(model.rows.isEmpty && model.comparison == nil && model.newerID == nil, "the list read for a isn't shown under b")
        // The comparison.
        (world, model) = try await seeded()
        await model.load()
        #expect(model.comparison != nil)
        let w = world
        model.afterRead = { stage in if stage == "compare" { w.orgs.select("b") } }
        await model.compare()
        #expect(model.comparison == nil && model.rows.isEmpty, "the comparison of a isn't shown under b")
        // The estimates.
        (world, model) = try await seeded()
        let w2 = world
        model.afterRead = { stage in if stage == "estimate" { w2.orgs.select("b") } }
        await model.load()
        #expect(model.estimates.isEmpty && model.estimateBasis == nil, "a's estimates aren't shown under b")
    }

    // MARK: through the collector: R3 and R6

    /// R6: assignments are "not read" when every service's list failed, never counted as none; a screen compares nothing there.
    @Test func assignmentsEveryListFailedAreNotReadNeverNone() async throws {
        let world = try await CollectorTests.world()
        let model = world.screens.changes
        await model.snapshotNow()
        let stub = world.stubs["a"]!
        stub.forbid("/v1/mdmServers/S1/relationships")
        stub.forbid("/v1/mdmServers/S2/relationships")
        await model.snapshotNow()
        let newest = try #require(model.rows.first)
        #expect(newest.notRead.contains("Assignments (HTTP 403 FORBIDDEN_ERROR)") && !newest.partial.contains { $0.hasPrefix("Assignments") }, "\(newest)")
        let summary = try await world.history!.snapshots(org: world.orgs.active!)[0]
        #expect(summary.counts["assignments"] == nil && summary.errors["assignments"] == "HTTP 403 FORBIDDEN_ERROR")
        let skipped = try #require(model.comparison?.skipped.first { $0.resource == "assignments" })
        #expect(skipped.why == "not read in the newer snapshot (HTTP 403 FORBIDDEN_ERROR), so no change is shown.")
        #expect(Self.change(model, "assignments") == nil, "two devices were assigned: none is not shown as removals")
    }

    /// R3: a list that failed part-way keeps what it read, with its error, and the screen marks it partial.
    @Test func aListThatFailedPartWayIsKeptAndMarkedPartial() async throws {
        let world = try await CollectorTests.world(devices: ["a": 1001, "b": 0])
        let model = world.screens.changes
        await model.snapshotNow()
        world.stubs["a"]!.queue(403, for: "/v1/orgDevices?limit=1000&cursor=")
        await model.snapshotNow()
        let newest = try #require(model.rows.first)
        #expect(newest.partial == ["Devices (HTTP 403)"] && newest.devices == 1000, "\(newest)")
        let devices = try #require(Self.change(model, "devices"))
        #expect(devices.partial && devices.removed.isEmpty && devices.withheld.count == 1, "one device wasn't read: it is not removed")
    }
}
