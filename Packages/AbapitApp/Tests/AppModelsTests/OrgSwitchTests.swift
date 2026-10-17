import AppleBusiness
import AppModels
import Foundation
import Testing
import TestSupport

/// Invariant 8's screen-model tests, part one: nothing read for one org shows on another's screen, in its CSV or
/// in Find, and a load that was superseded writes nothing (Phase 1b review H2; the review's RACE1–3).
@MainActor
@Suite("Org switching and superseded loads", .serialized)
struct OrgSwitchTests {
    /// RACE1: after a switch the rows, services, CSV and Find were still org a's, and the state said "As of now".
    @Test func aSwitchClearsTheOldOrgAndReadsTheNewOne() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [World.service("sa", name: "Org A MDM")])
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.count == 3)
        #expect(world.devices.services.count == 1)
        world.gates["b"]!.hold("b", Gate.devicePages)

        world.orgs.select("b")
        // At once, before anything of b's has arrived.
        #expect(world.devices.rows.isEmpty)
        #expect(world.devices.services.isEmpty)
        #expect(world.devices.deviceCount.isEmpty)
        #expect(!world.devices.csv().contains("ADEV"))
        world.devices.search = "ADEV0000001"
        #expect(world.devices.shown.isEmpty)
        world.devices.search = ""
        #expect(world.devices.state.isLoading, "a switch reads the new org, it doesn't sit idle: \(world.devices.state)")

        world.gates["b"]!.release("b")
        await eventually("org b loaded") { if case .loaded = world.devices.state { true } else { false } }
        #expect(world.devices.rows.map(\.serial) == ["BDEV0000000", "BDEV0000001"])
        #expect(!world.devices.csv().contains("ADEV"))
    }

    /// RACE2: a's cancelled load ran on, said "loaded" over its own rows while b was loading, and wrote a's learned
    /// rate into b's profile.
    @Test func aSupersededLoadSaysNothingAndRecordsNoRate() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 2], rates: ["b": 7])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        world.gates["b"]!.hold("b", Gate.devicePages)

        world.orgs.select("b")
        world.gates["a"]!.release("later")
        // a's device read has returned (its services read finished long ago), and b's devices are still held.
        await world.settled(3)
        #expect(world.devices.state == .loading(count: 0), "\(world.devices.state) while org b's devices are still held")
        #expect(world.devices.rows.isEmpty)
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 7, "org a's learned rate landed on org b's profile")

        world.gates["b"]!.release("b")
        await world.settled(4)
        #expect(world.devices.rows.map(\.serial) == ["BDEV0000000", "BDEV0000001"])
        if case .loaded = world.devices.state {} else { Issue.record("org b's load didn't finish: \(world.devices.state)") }
        #expect(world.orgs.store["b"]!.learnedReadsPerMinute == 7)
        #expect(world.orgs.store["a"]!.learnedReadsPerMinute == 0, "a cancelled load records no rate")
    }

    /// RACE3: Refresh during a load let the old load say "loaded" over 1000 of 2500 rows, with no truncation flag.
    @Test func aRefreshCancelsTheRunningLoadAndTheNewOneIsWhole() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        world.gates["a"]!.hold("all", Gate.devicePages)

        world.devices.load(force: true)
        world.gates["a"]!.release("later")
        await world.settled(3)
        #expect(world.devices.state == .loading(count: 0), "\(world.devices.state) while the refresh's first page is still held")
        #expect(world.devices.rows.isEmpty)

        world.gates["a"]!.release("all")
        await world.settled(4)
        #expect(world.devices.rows.count == 2500)
        #expect(Set(world.devices.rows.map(\.serial)).count == 2500, "the old load's rows were mixed in")
        #expect(!world.devices.truncated)
        if case .loaded = world.devices.state {} else { Issue.record("\(world.devices.state)") }
    }

    /// A page already answered when Refresh is pressed waits in the stream's buffer, and a cancelled loop can still
    /// be handed it: the check inside the loop drops it, so the old org's rows never mix into the new read.
    @Test func aPageAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 3500, "b": 0])
        let gate = world.gates["a"]!
        gate.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        gate.hold("third", { $0.path() == "/v1/orgDevices" && ($0.query() ?? "").contains("cursor=2000") })
        let answered = gate.answered
        gate.release("later")
        // Hold the main actor while page two is answered and handed on: it waits, unread, for the old loop.
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while gate.answered == answered, clock.now < end { usleep(500) }
        usleep(200_000)
        gate.hold("all", Gate.devicePages)
        world.devices.load(force: true)
        await world.settled(3)
        #expect(world.devices.rows.isEmpty, "\(world.devices.rows.count) rows of the cancelled read landed in the new one")
        #expect(world.devices.state == .loading(count: 0))
        gate.release("third")
        gate.release("all")
        await world.settled(4)
        #expect(world.devices.rows.count == 3500)
    }

    /// The same for a failure: a walk that failed just before Refresh hands its error to a loop that is already
    /// cancelled, and the old load's "failed" must not land on the new one.
    @Test func aFailureAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        let gate = world.gates["a"]!
        gate.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        world.stubs["a"]!.failTransport(5)
        let answered = gate.answered
        gate.release("later")
        // Hold the main actor while page two fails five times (the client's retries) and the error is handed on.
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while gate.answered < answered + 5, clock.now < end { usleep(500) }
        usleep(200_000)
        gate.hold("all", Gate.devicePages)
        world.devices.load(force: true)
        await world.settled(3)
        #expect(world.devices.state == .loading(count: 0), "the cancelled read's failure landed on the new one: \(world.devices.state)")
        gate.release("all")
        await world.settled(4)
        #expect(world.devices.rows.count == 2500)
    }

    /// The page cap stops the list and says so; a refresh during that load keeps its own flag.
    @Test func aListCutAtThePageCapSaysSoAfterARefresh() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0], pageCap: 2)
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        world.devices.load(force: true)
        world.gates["a"]!.release("later")
        await world.settled(4)
        #expect(world.devices.rows.count == 2000)
        #expect(world.devices.truncated)
        if case .loaded = world.devices.state {} else { Issue.record("\(world.devices.state)") }
    }

    /// The inspector held the old org's device after a switch.
    @Test func theInspectorEmptiesOnASwitch() async throws {
        let world = try await World.make()
        world.detail.show("ADEV0000001")
        await eventually("the device panel") { if case .loaded = world.detail.device { true } else { false } }
        world.orgs.select("b")
        #expect(world.detail.serial == nil)
        if case .loading = world.detail.device {} else { Issue.record("the inspector still shows org a's device") }
    }

    /// A screen nobody has opened isn't read on a switch: the first `load()` from a view does it.
    @Test func aSwitchReadsNothingForAScreenNobodyOpened() async throws {
        let world = try await World.make()
        world.orgs.select("b")
        #expect(world.devices.state == .idle)
        #expect(world.stubs["b"]!.requests.isEmpty)
    }

    // MARK: the services half (verifier round 1: every guard in readServices could be deleted and the suite stayed green)

    /// What b's screen shows while b's own services are still held: nothing of org a's, and the services loading.
    func expectOrgBsServicesStillLoading(_ world: World, _ what: String) {
        #expect(world.devices.services.isEmpty, "\(what): org a's services on org b's screen: \(world.devices.services.map(\.name))")
        #expect(world.devices.servicesState.isLoading, "\(what): b's services are still held: \(world.devices.servicesState)")
        #expect(world.devices.serviceNote?.hasPrefix("Reading") == true, "\(what): \(world.devices.serviceNote ?? "no note")")
        #expect(world.devices.deviceCount.isEmpty, "\(what): \(world.devices.deviceCount)")
        #expect(world.devices.rows.allSatisfy { $0.assignment == .pending }, "\(what): \(world.devices.rows.map(\.assignment))")
    }

    /// Org a's services list is in flight at the switch. Its cancelled loop ends without throwing: without the check
    /// after it, a's empty read said b's services were loaded and b's devices unassigned.
    @Test func aSupersededServicesReadLandsNowhere() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [World.service("sa", name: "Org A MDM")])
        world.gates["a"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.devices.load()
        await world.settled(1)
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.orgs.select("b")
        world.gates["a"]!.release("services")
        // a's devices, a's services (superseded), b's devices.
        await world.settled(3)
        expectOrgBsServicesStillLoading(world, "after a's services read returned")
        world.gates["b"]!.release("services")
        await world.settled(4)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unassigned })
    }

    /// Org a's services page, answered before the switch, is handed to a cancelled loop.
    @Test func aBufferedServicesPageLandsNowhere() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [World.service("sa", name: "Org A MDM")])
        world.gates["a"]!.hold("services", { $0.path() == "/v1/mdmServers" })
        world.devices.load()
        await world.settled(1)
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.buffer("a", release: "services")
        world.orgs.select("b")
        await world.settled(3)
        expectOrgBsServicesStillLoading(world, "after a's buffered page")
        // b can't read services at all: a's list must not be what its screen keeps.
        world.stubs["b"]!.forbid("/v1/mdmServers")
        world.gates["b"]!.release("services")
        await world.settled(4)
        #expect(world.devices.services.isEmpty, "\(world.devices.services.map(\.name))")
        #expect(world.devices.servicesState == .forbidden)
    }

    /// Org a's 403 on services, already on its way at the switch, never lands on b.
    @Test func aBufferedServicesFailureLandsNowhere() async throws {
        let world = try await World.make()
        world.gates["a"]!.hold("services", { $0.path() == "/v1/mdmServers" })
        world.devices.load()
        await world.settled(1)
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.buffer("a", release: "services")
        world.orgs.select("b")
        await world.settled(3)
        expectOrgBsServicesStillLoading(world, "after a's buffered 403")
        world.gates["b"]!.release("services")
        await world.settled(4)
        #expect(world.devices.serviceNote == nil)
    }

    /// A service's device list is in flight at the switch: its cancelled loop ends without throwing, and without the
    /// check after it a's count, "loaded" and a complete assignment map landed on b.
    @Test func aSupersededServiceDeviceListLandsNowhere() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [World.service("sa", name: "Org A MDM")])
        world.stubs["a"]!.assign("ADEV0000000", to: "sa")
        world.gates["a"]!.hold("lists", { $0.path().hasPrefix("/v1/mdmServers/") })
        world.devices.load()
        await eventually("sa's device list held") { world.devices.services.count == 1 && world.gates["a"]!.held == 1 }
        await world.settled(1)
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.orgs.select("b")
        world.gates["a"]!.release("lists")
        await world.settled(3)
        expectOrgBsServicesStillLoading(world, "after a's device list returned")
        world.gates["b"]!.release("services")
        await world.settled(4)
    }

    /// A service's device-list 403, already on its way at the switch, never lands on b.
    @Test func aBufferedServiceDeviceFailureLandsNowhere() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [World.service("sa", name: "Org A MDM")])
        world.gates["a"]!.hold("lists", { $0.path().hasPrefix("/v1/mdmServers/sa/") })
        world.devices.load()
        await eventually("sa's device list held") { world.gates["a"]!.held == 1 }
        await world.settled(1)
        world.stubs["a"]!.forbid("/v1/mdmServers/sa/")
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.buffer("a", release: "lists")
        world.orgs.select("b")
        await world.settled(3)
        expectOrgBsServicesStillLoading(world, "after a's buffered device-list 403")
        world.gates["b"]!.release("services")
        await world.settled(4)
        #expect(world.devices.serviceNote == nil)
    }

    /// Refresh while the services list is held: the same guard, from a Refresh rather than a switch.
    @Test func aRefreshWhileTheServicesAreHeldLandsNothingOfTheOldRead() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        world.gates["a"]!.hold("services", { $0.path() == "/v1/mdmServers" })
        world.devices.load()
        await world.settled(1)
        world.devices.load(force: true)
        await world.settled(3)
        #expect(world.devices.servicesState == .loading(count: 0), "\(world.devices.servicesState)")
        #expect(world.devices.rows.allSatisfy { $0.assignment == .pending }, "\(world.devices.rows.map(\.assignment))")
        world.gates["a"]!.release("services")
        await world.settled(4)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unassigned })
    }

    /// A switch clears the old org's note about unknown services at once, even to an org that can't be read.
    @Test func aSwitchClearsTheOldNote() async throws {
        let world = try await World.make(profiles: [World.profile("a"), World.unusable])
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.serviceNote?.contains("can't read") == true)
        world.orgs.select("district")
        #expect(world.devices.serviceNote == nil, "org a's note on District's screen: \(world.devices.serviceNote ?? "")")
        guard case .unusable = world.devices.servicesState else {
            Issue.record("\(world.devices.servicesState)")
            return
        }
        #expect(world.devices.servicesUnread?.contains("district") == true, "\(world.devices.servicesUnread ?? "nil")")
    }

    /// While b's services are still read, b's devices are "Reading…", never "unassigned" from a's read.
    @Test func aSwitchForgetsTheOldAssignments() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unassigned })
        world.gates["b"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.orgs.select("b")
        await world.settled(3)
        #expect(world.devices.rows.count == 2)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .pending && $0.service == "Reading…" }, "\(world.devices.rows.map(\.assignment))")
        world.gates["b"]!.release("services")
        await world.settled(4)
    }

    /// Removing the active org switches to the next: its rows leave the screen and the CSV at once.
    @Test func removingTheActiveOrgClearsItsRows() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        try await world.orgs.remove("a", deleteSecrets: false)
        #expect(world.devices.rows.isEmpty)
        #expect(!world.devices.csv().contains("ADEV"), "the removed org's rows are still exportable")
        await world.settled(4)
        #expect(world.devices.rows.map(\.serial) == ["BDEV0000000", "BDEV0000001"])
    }

    /// Showing a screen again reads nothing: the org's data is already here.
    @Test func aSecondLoadReadsNothing() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        let requests = world.stubs["a"]!.requests.count
        world.devices.load()
        if case .loaded = world.devices.state {} else { Issue.record("the screen read again: \(world.devices.state)") }
        #expect(world.stubs["a"]!.requests.count == requests)
    }

    /// After a switch, the next screen to appear doesn't read the new org a second time: the reload ran for the new
    /// generation, not the old one.
    @Test func aSwitchReadsTheNewOrgOnce() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        world.orgs.select("b")
        await world.settled(4)
        let requests = world.stubs["b"]!.requests.count
        world.devices.load()
        if case .loaded = world.devices.state {} else { Issue.record("the next appear read org b again: \(world.devices.state)") }
        #expect(world.stubs["b"]!.requests.count == requests)
    }

    /// The inspector: org a's AppleCare read, still in flight at the switch, never lands on the emptied inspector.
    @Test func aSupersededInspectorReadLandsNowhere() async throws {
        let world = try await World.make()
        let gate = world.gates["a"]!
        gate.hold("care", { $0.path().hasSuffix("/appleCareCoverage") })
        world.detail.show("ADEV0000001")
        await eventually("three panels read, AppleCare held") { world.detail.readsFinished == 3 && gate.held == 1 }
        world.orgs.select("b")
        gate.release("care")
        await eventually("the AppleCare read returned") { world.detail.readsFinished == 4 }
        #expect(world.detail.serial == nil)
        if case .loading = world.detail.coverage {} else { Issue.record("org a's AppleCare landed after the switch: \(world.detail.coverage)") }
    }

    /// A load superseded while it reads its learned rate records nothing. Here the active org's client ID is edited in
    /// that window: the old account's rate must not land on the new account's profile, which starts afresh.
    @Test func aRateReadAcrossAnAccountEditIsNotRecorded() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0], rates: ["a": 50])
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.devices.load()
        // a's services (it has none) are read; its devices are held.
        await world.settled(1)
        let client = try #require(world.orgs.appleClient)
        // Hold the main actor while the page is answered and handed on, then stall a's limiter behind another read, so
        // the load, once it has its page, waits there for its rate.
        world.buffer("a", release: "devices")
        world.stall.hold(World.clientID("a"))
        Task.detached { try? await client.ping() }
        let clock = ContinuousClock(), end = clock.now + .seconds(20)
        while !world.stall.entered, clock.now < end { usleep(500) }
        #expect(world.stall.entered)
        await eventually("a's devices loaded") { if case .loaded = world.devices.state { true } else { false } }
        var draft = OrgDraft(world.orgs.store["a"]!)
        draft.clientID = World.clientID("c")
        try await world.orgs.save(draft, key: nil, editing: "a")
        #expect(world.orgs.store["a"]!.learnedReadsPerMinute == 0, "another account starts afresh")
        world.stall.release()
        // a's devices, and both halves of the new account's load (the stub doesn't know it: both fail).
        await world.settled(4)
        #expect(world.orgs.store["a"]!.learnedReadsPerMinute == 0, "the old account's rate landed on the new account's profile")
    }

    // MARK: verifier round 2

    /// Choosing the org that is already active is no switch: nothing is cleared and nothing read again (X15).
    @Test func choosingTheActiveOrgAgainReadsNothing() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        let generation = world.orgs.generation, requests = world.stubs["a"]!.requests.count
        world.orgs.select("a")
        #expect(world.orgs.generation == generation)
        #expect(world.devices.rows.count == 3, "the screen was cleared for the org it already showed")
        #expect(world.stubs["a"]!.requests.count == requests)
    }

    /// An id that isn't an org is ignored: the active org stays and its screen with it (X16).
    @Test func choosingAnOrgThatIsntThereDoesNothing() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        let generation = world.orgs.generation
        world.orgs.select("gone")
        #expect(world.orgs.generation == generation)
        #expect(world.orgs.active?.id == "a")
        #expect(world.devices.rows.count == 3)
    }
}
