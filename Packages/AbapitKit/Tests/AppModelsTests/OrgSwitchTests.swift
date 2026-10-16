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
}
