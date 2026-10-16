import AppleBusiness
import AppModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport

/// Invariant 8's screen-model tests, part two: devices and services are separate panels, each with its own state
/// (Phase 1b review M3, the review's RACE4), and nothing partial, unusable or unknown is silent (the review's LOWs,
/// RACE5).
@MainActor
@Suite("Independent panels and saying why", .serialized)
struct PanelTests {
    /// RACE4: a role that can read devices but not services got "your role can't read this" and no devices.
    @Test func aRoleThatCantReadServicesStillSeesItsDevices() async throws {
        let world = try await World.make(devices: ["a": 5, "b": 0])
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.count == 5)
        if case .loaded = world.devices.state {} else { Issue.record("devices: \(world.devices.state)") }
        #expect(world.devices.servicesState == .forbidden)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unknown && $0.service == "Unknown" }, "a service nobody could read isn't \"unassigned\"")
        #expect(world.devices.serviceNote?.contains("can't read device management services") == true)
    }

    /// One service's device list failing failed the whole Devices screen.
    @Test func oneServicesFailingDeviceListCostsOnlyWhatItWouldHaveTold() async throws {
        let world = try await World.make(devices: ["a": 4, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM"), World.service("s2", name: "Lab MDM")])
        stub.assign("ADEV0000000", to: "s1")
        stub.assign("ADEV0000001", to: "s2")
        stub.forbid("/v1/mdmServers/s2/")
        world.devices.load()
        await world.settled(2)
        if case .loaded = world.devices.state {} else { Issue.record("devices: \(world.devices.state)") }
        if case .loaded = world.devices.servicesState {} else { Issue.record("services: \(world.devices.servicesState)") }
        let by = Dictionary(uniqueKeysWithValues: world.devices.rows.map { ($0.serial, $0.assignment) })
        #expect(by["ADEV0000000"] == .service("Main MDM"))
        #expect(by["ADEV0000001"] == .unknown, "it may be Lab MDM's")
        #expect(by["ADEV0000002"] == .unknown, "not found in a list read whole isn't proof it's unassigned")
        #expect(world.devices.deviceCount == ["s1": 1])
        #expect(world.devices.serviceNote?.contains("Lab MDM") == true)
    }

    /// With every list read whole, a device in none of them is unassigned, and rows that arrived before the services
    /// get their names once the services arrive.
    @Test func everyListReadWholeTellsAssignedFromUnassigned() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM")])
        stub.assign("ADEV0000002", to: "s1")
        world.gates["a"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.devices.load()
        await world.settled(1)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .pending })
        world.gates["a"]!.release("services")
        await world.settled(2)
        let by = Dictionary(uniqueKeysWithValues: world.devices.rows.map { ($0.serial, $0.assignment) })
        #expect(by == ["ADEV0000000": .unassigned, "ADEV0000001": .unassigned, "ADEV0000002": .service("Main MDM")])
        #expect(world.devices.serviceNote == nil)
        #expect(world.devices.deviceCount == ["s1": 1])
    }

    /// A service's device list cut at the page cap doesn't make the rest "unassigned".
    @Test func aServiceListCutAtThePageCapLeavesTheRestUnknown() async throws {
        let world = try await World.make(devices: ["a": 1001, "b": 0], pageCap: 1)
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM")])
        // Linkages come sorted: a thousand serials first, then this org's ADEV0000000 on the page the cap stops before.
        for index in 0..<1000 { stub.assign(String(format: "AAAA%07d", index), to: "s1") }
        stub.assign("ADEV0000000", to: "s1")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.count == 1000)
        #expect(world.devices.truncated)
        #expect(world.devices.rows.first { $0.serial == "ADEV0000000" }?.assignment == .unknown, "Main MDM's, on the page not read")
        #expect(!world.devices.rows.contains { $0.assignment == .unassigned })
        #expect(world.devices.deviceCount["s1"] == nil, "a count cut at the cap isn't the service's count")
        #expect(world.devices.serviceNote?.contains("page limit") == true)
    }

    /// RACE5: a failed walk left its rows on screen and exportable, with nothing saying they were partial.
    @Test func aFailedWalkMarksItsRowsPartialAndKeepsThemFromExport() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        #expect(world.devices.exportBlocked != nil, "a list still loading isn't exported as if whole")
        world.stubs["a"]!.failTransport(50)
        world.gates["a"]!.release("later")
        await world.settled(2)
        guard case .failed = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(world.devices.partialCount == 1000)
        #expect(world.devices.exportBlocked?.contains("partial") == true)
    }

    @Test func aWholeListExports() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.exportBlocked == nil)
        #expect(world.devices.partialCount == nil)
        #expect(world.devices.csv().contains("ADEV0000002"))
    }

    /// The active org had no Apple account (an unknown scope): the state was idle, the banner empty and the
    /// Overview zeros.
    @Test func anOrgThisVersionCantUseSaysWhy() async throws {
        let unusable = OrgProfile(raw: ["id": .string("district"), "name": .string("District"), "provider": .string("apple"),
                                        "scope": .string("district"), "client_id": .string("SCHOOLAPI.x"), "key_id": .string("k")])
        let world = try await World.make(profiles: [unusable])
        world.devices.load()
        guard case .unusable(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(why.contains("can't be used") && why.contains("district"))
        #expect(world.devices.servicesState == world.devices.state)
        world.detail.show("ADEV0000001")
        if case .failed(let text) = world.detail.device { #expect(text.contains("can't be used")) } else { Issue.record("a spinner that can't end") }
    }

    @Test func aMosyleOrgOnAnAppleScreenSaysWhy() async throws {
        let world = try await World.make(profiles: [OrgProfile(id: "fleet", name: "Fleet", provider: .mosyle)])
        world.devices.load()
        guard case .unusable(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(why.contains("mosyle"))
    }

    @Test func noOrganizationSaysSo() async throws {
        let world = try await World.make(profiles: [])
        world.devices.load()
        guard case .unusable(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(why.contains("No organization yet"))
    }
}
