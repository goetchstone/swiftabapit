import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Orgs
import Reports
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

    /// Phase 2b verifier round 2, probe vServiceWithAnUnsafeID: a service whose id can't go in a path is never asked for its
    /// devices, and the note says why, never "Apple has no such item." of a service Apple has just listed (review L1's class
    /// in a fifth model); the other services are read as before.
    @Test func aServiceWhoseIDCantBeSentIsNeverAskedForItsDevices() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("S 1", name: "Spaced MDM"), World.service("s2", name: "Lab MDM")])
        stub.assign("ADEV0000000", to: "s2")
        world.devices.load()
        await world.settled(2)
        if case .loaded = world.devices.servicesState {} else { Issue.record("services: \(world.devices.servicesState)") }
        #expect(!stub.requests.contains { $0.contains("S%201") || $0.contains("S 1") }, "\(stub.requests)")
        #expect(world.devices.serviceNote == "A device not found in a service shows its service as Unknown: Spaced MDM's id can't be sent to "
                + "Apple, so its devices weren't asked for.", "\(world.devices.serviceNote ?? "nil")")
        #expect(!(world.devices.serviceNote ?? "").contains("no such item"))
        #expect(world.devices.deviceCount == ["s2": 1])
        let by = Dictionary(uniqueKeysWithValues: world.devices.rows.map { ($0.serial, $0.assignment) })
        #expect(by["ADEV0000000"] == .service("Lab MDM") && by["ADEV0000001"] == .unknown)
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
        // What the Overview counts, now that every list was read whole.
        #expect(world.devices.servicesUnread == nil)
        #expect(world.devices.serviceCount == 1)
        #expect(world.devices.unassignedCount == 2)
        let lastConnected = try #require(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        // Services not connected lately, by the one rule the Overview and the Services screen share (`QuietServices`).
        #expect(world.dashboard.quiet(now: lastConnected.addingTimeInterval(10 * 86_400))?.isEmpty == true)
        #expect(world.dashboard.quiet(now: lastConnected.addingTimeInterval(31 * 86_400))?.map(\.service.name) == ["Main MDM"])
    }

    /// Phase 2b review L4, probe p7: the Services screen's Last connected column is Reports' rule, the Overview's: a date
    /// this app can't read says so, never "Never"; a deleted service isn't flagged; exactly 30 days isn't quiet and a second
    /// more is, by the instant, not by whole days; and the column flags exactly the services the quiet card lists.
    @Test func theServicesColumnIsTheOverviewsQuietRule() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z"))
        func service(_ id: String, status: String = "ACTIVE", _ last: JSONValue?) -> MDMService {
            var attributes: JSONObject = ["serverName": .string("MDM \(id)"), "status": .string(status)]
            if let last { attributes["lastConnectedDateTime"] = last }
            return MDMService(resource: Resource(type: "mdmServers", id: id, attributes: attributes))
        }
        func stamp(_ secondsAgo: Double) -> JSONValue { .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))) }
        let services = [
            service("unreadable", .string("yesterday")), service("deleted", status: "DELETED", .string("2025-01-01T00:00:00Z")),
            service("absent", nil), service("null", .null), service("thirty", stamp(30 * 86_400)), service("past", stamp(30 * 86_400 + 1)),
            service("today", stamp(2 * 3_600)), service("one", stamp(86_400 + 60)), service("inactive", status: "INACTIVE", stamp(40 * 86_400)),
            // A stamp ahead of this Mac's clock (skew) is today, never "-1 days ago" (verifier round 2, mutant V-todayFuture).
            service("ahead", stamp(-2 * 86_400)),
        ]
        let cells = Dictionary(uniqueKeysWithValues: services.map { ($0.id, DevicesModel.connection(of: $0, now: now)) })
        #expect(cells["unreadable"] == ServiceConnection(text: #"Unreadable date: "yesterday""#, isQuiet: true, spoken: #"Unreadable date: "yesterday""#))
        #expect(cells["deleted"] == ServiceConnection(text: "668 days ago", isQuiet: false, spoken: "668 days ago"))
        #expect(cells["absent"] == ServiceConnection(text: "Never connected", isQuiet: true, spoken: "Never connected"))
        #expect(cells["null"]?.text == "Never connected" && cells["null"]?.isQuiet == true)
        #expect(cells["thirty"] == ServiceConnection(text: "30 days ago", isQuiet: false, spoken: "30 days ago"))
        #expect(cells["past"] == ServiceConnection(text: "30 days ago", isQuiet: true, spoken: "Not connected for 30 days"))
        #expect(cells["today"] == ServiceConnection(text: "Today", isQuiet: false, spoken: "Today"))
        #expect(cells["one"]?.text == "1 day ago" && cells["one"]?.isQuiet == false)
        #expect(cells["inactive"] == ServiceConnection(text: "40 days ago", isQuiet: true, spoken: "Not connected for 40 days"))
        #expect(cells["ahead"] == ServiceConnection(text: "Today", isQuiet: false, spoken: "Today"))
        let flagged = Set(services.filter { cells[$0.id]?.isQuiet == true }.map(\.id))
        #expect(flagged == Set(QuietServices(services, now: now, days: QuietServices.defaultDays).rows.map(\.service.id)))
        // The quiet card says each the same way.
        for row in QuietServices(services, now: now).rows {
            #expect(DashboardModel.lastConnected(row, now: now) == cells[row.service.id]?.text)
        }
    }

    /// Devices and services load side by side, so the devices can be loaded while the services are still read. That
    /// was silent: the Service column blank as if unassigned, the "not assigned" tile 0, the Services tile 0 and the
    /// health box green (verifier round 1).
    @Test func servicesStillBeingReadAreSaid() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM")])
        stub.assign("ADEV0000002", to: "s1")
        world.gates["a"]!.hold("list", { $0.path().hasPrefix("/v1/mdmServers/s1/") })
        world.devices.load()
        await eventually("s1's device list held") { world.gates["a"]!.held == 1 && world.devices.services.count == 1 }
        await world.settled(1)
        if case .loaded = world.devices.state {} else { Issue.record("devices: \(world.devices.state)") }
        #expect(world.devices.servicesState.isLoading, "services aren't loaded before their device lists are: \(world.devices.servicesState)")
        #expect(world.devices.rows.allSatisfy { $0.assignment == .pending && $0.service == "Reading…" }, "\(world.devices.rows.map(\.service))")
        #expect(world.devices.serviceNote?.hasPrefix("Reading the device management services") == true, "\(world.devices.serviceNote ?? "nil")")
        #expect(world.devices.servicesUnread != nil)
        #expect(world.devices.serviceCount == nil, "a Services tile of \(world.devices.serviceCount ?? 0) while they're read")
        #expect(world.devices.unassignedCount == nil, "a \"not assigned\" tile of \(world.devices.unassignedCount ?? 0) while they're read")
        #expect(world.dashboard.quiet() == nil, "a health verdict on a list still being read")
        world.gates["a"]!.release("list")
        await world.settled(2)
        #expect(world.devices.serviceNote == nil)
        #expect(world.devices.unassignedCount == 2)
    }

    /// A role that can't read services: the Overview said "Services 0" and "every service has connected".
    @Test func refusedServicesShowNoCountsAndNoHealth() async throws {
        let world = try await World.make(devices: ["a": 5, "b": 0])
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.servicesUnread?.contains("can't read device management services") == true, "\(world.devices.servicesUnread ?? "nil")")
        #expect(world.devices.serviceCount == nil)
        #expect(world.devices.unassignedCount == nil)
        #expect(world.dashboard.quiet() == nil)
        #expect(world.devices.servicesPartialCount == nil, "nothing was read, so nothing is partial")
    }

    /// A services list that fails part-way: what was read stays listed, said to be partial, and counts nothing.
    @Test func aServicesReadThatFailsPartWayIsPartial() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0])
        world.stubs["a"]!.add(services: (0..<1001).map { World.service(String(format: "s%05d", $0), name: "MDM \($0)") })
        world.gates["a"]!.hold("later", { $0.path() == "/v1/mdmServers" && ($0.query() ?? "").contains("cursor=") })
        world.devices.load()
        await eventually("the first page of services") { world.devices.services.count == 1000 }
        await world.settled(1)
        world.stubs["a"]!.failTransport(50)
        world.gates["a"]!.release("later")
        await world.settled(2)
        guard case .failed = world.devices.servicesState else {
            Issue.record("\(world.devices.servicesState)")
            return
        }
        #expect(world.devices.servicesPartialCount == 1000)
        #expect(world.devices.servicesUnread?.hasPrefix("The services couldn't be read") == true, "\(world.devices.servicesUnread ?? "nil")")
        #expect(world.devices.serviceCount == nil, "the Services tile counted a partial list")
        #expect(world.dashboard.quiet() == nil)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unknown })
    }

    /// A services list refused part-way (a 403 on a later page) is partial too, and counts nothing.
    @Test func aServicesReadRefusedPartWayIsPartial() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0])
        world.stubs["a"]!.add(services: (0..<1001).map { World.service(String(format: "s%05d", $0), name: "MDM \($0)") })
        world.gates["a"]!.hold("later", { $0.path() == "/v1/mdmServers" && ($0.query() ?? "").contains("cursor=") })
        world.devices.load()
        await eventually("the first page of services") { world.devices.services.count == 1000 }
        await world.settled(1)
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.gates["a"]!.release("later")
        await world.settled(2)
        #expect(world.devices.servicesState == .forbidden)
        #expect(world.devices.servicesPartialCount == 1000, "the services read before the refusal aren't said to be partial")
        #expect(world.devices.serviceCount == nil)
        #expect(world.devices.rows.allSatisfy { $0.assignment == .unknown })
    }

    /// A services list cut at the page cap: a device in none of the lists read is unknown, not unassigned, and the
    /// Overview counts neither.
    @Test func aServicesListCutAtTheCapLeavesDevicesUnknown() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0], pageCap: 1)
        world.stubs["a"]!.add(services: (0..<1001).map { World.service(String(format: "s%05d", $0), name: "MDM \($0)") })
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.servicesTruncated)
        #expect(!world.devices.rows.contains { $0.assignment == .unassigned }, "\(world.devices.rows.map(\.assignment))")
        #expect(world.devices.serviceNote?.contains("list of services stopped at the page limit") == true, "\(world.devices.serviceNote ?? "nil")")
        #expect(world.devices.servicesUnread?.contains("page limit") == true)
        #expect(world.devices.serviceCount == nil)
        #expect(world.devices.unassignedCount == nil)
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

    /// A walk refused part-way (a 403 on a later page) is partial too, and doesn't export.
    @Test func aRefusedWalkIsPartialToo() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        world.stubs["a"]!.forbid("/v1/orgDevices")
        world.gates["a"]!.release("later")
        await world.settled(2)
        #expect(world.devices.state == .forbidden)
        #expect(world.devices.partialCount == 1000)
        #expect(world.devices.exportBlocked?.contains("partial") == true)
    }

    /// Apple's total, when it sends one, is kept for "showing N of M".
    @Test func applesTotalIsKept() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0], pageCap: 1)
        world.stubs["a"]!.reportTotals()
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.truncated)
        #expect(world.devices.total == 2500)
        #expect(!world.devices.devicesReadWhole, "a list the page cap stopped is counted on the Overview as if whole")
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
        let world = try await World.make(profiles: [World.unusable])
        world.devices.load()
        guard case .unusable(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(why.contains("can't be used") && why.contains("district"))
        #expect(world.devices.servicesState == world.devices.state)
        world.detail.show("ADEV0000001")
        if case .failed(let text) = world.detail.device { #expect(text.contains("can't be used")) } else { Issue.record("a spinner that can't end") }
        // Every panel, not only the first (verifier round 2, X10: the other three spun for good).
        if case .failed = world.detail.coverage {} else { Issue.record("AppleCare: a spinner that can't end") }
        if case .failed = world.detail.lock {} else { Issue.record("Activation Lock: a spinner that can't end") }
        if case .failed = world.detail.service {} else { Issue.record("Service: a spinner that can't end") }
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

    // MARK: verifier round 2

    /// Each service counts only its own devices (X01: a count carried over into the next service's).
    @Test func eachServiceCountsItsOwnDevices() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM"), World.service("s2", name: "Lab MDM")])
        stub.assign("ADEV0000000", to: "s1")
        stub.assign("ADEV0000001", to: "s2")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.deviceCount == ["s1": 1, "s2": 1], "\(world.devices.deviceCount)")
    }

    /// One service's list cut at the page cap leaves the next one, read whole, counted and known (X02: one cut list
    /// marked every later service cut).
    @Test func aServiceCutAtTheCapDoesntCutTheNext() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0], pageCap: 1)
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM"), World.service("s2", name: "Lab MDM")])
        for index in 0..<1001 { stub.assign(String(format: "AAAA%07d", index), to: "s1") }
        stub.assign("ADEV0000001", to: "s2")
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.deviceCount == ["s2": 1], "\(world.devices.deviceCount)")
        #expect(world.devices.serviceNote?.contains("Main MDM") == true)
        #expect(world.devices.serviceNote?.contains("Lab MDM") == false, "\(world.devices.serviceNote ?? "nil")")
        #expect(world.devices.rows.first { $0.serial == "ADEV0000001" }?.assignment == .service("Lab MDM"))
    }

    /// A 403 on one inspector panel says "your role can't read this" there, and the others load (X11: it showed as a
    /// failure).
    @Test func aRefusedInspectorPanelSaysSo() async throws {
        let world = try await World.make()
        world.stubs["a"]!.forbid("/v1/orgDevices/ADEV0000001/appleCareCoverage")
        world.detail.show("ADEV0000001")
        await eventually("four panels read") { world.detail.readsFinished == 4 }
        if case .forbidden = world.detail.coverage {} else { Issue.record("AppleCare: \(world.detail.coverage)") }
        if case .loaded = world.detail.device {} else { Issue.record("device: \(world.detail.device)") }
    }

    /// A serial that can't go in a path is never sent, and the four panels say so, never "Apple has no such item." of a
    /// device Apple listed (Phase 2b verifier round 1: review L1's class in Device 360); the timeline says its own words.
    @Test func aSerialThatCantBeSentIsNeverAskedFor() async throws {
        let world = try await World.make()
        let before = world.stubs["a"]!.requests.count
        world.detail.show("A B")
        func failed<Value>(_ panel: Panel<Value>) -> String? { if case .failed(let why) = panel { why } else { nil } }
        let panels = [failed(world.detail.device), failed(world.detail.coverage), failed(world.detail.lock), failed(world.detail.service)]
        #expect(panels == Array(repeating: ScreenWords.unsendableID, count: 4), "\(panels)")
        await eventually("the timeline said why") { world.detail.timelineReadsFinished >= 1 }
        #expect(failed(world.detail.timeline) == "This serial can't be asked of the audit log.")
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.stubs["a"]!.requests.count == before, "\(world.stubs["a"]!.requests.dropFirst(before))")
        #expect(world.detail.readsFinished == 0, "no read was started")
    }

    /// A device with no family or status offers no empty choice to the filters (X19).
    @Test func theFiltersOfferNoEmptyChoice() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        world.stubs["a"]!.add(devices: [Resource(type: "orgDevices", id: "ZDEV0000001", attributes: ["serialNumber": .string("ZDEV0000001")])])
        world.devices.load()
        await world.settled(2)
        #expect(world.devices.rows.count == 2)
        #expect(world.devices.families == ["Mac"], "\(world.devices.families)")
        #expect(world.devices.statuses == ["ASSIGNED"], "\(world.devices.statuses)")
    }

    /// "Loading… N so far" counts every row read so far, not the last page's (X22).
    @Test func theLoadingCountIsEveryRowSoFar() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("third", { $0.path() == "/v1/orgDevices" && ($0.query() ?? "").contains("cursor=2000") })
        world.devices.load()
        await eventually("two pages") { world.devices.rows.count == 2000 }
        #expect(world.devices.state == .loading(count: 2000), "\(world.devices.state)")
        world.gates["a"]!.release("third")
        await world.settled(2)
        #expect(world.devices.rows.count == 2500)
    }

    /// The Overview's device tiles count a whole list only: "not assigned" read 0 while the devices loaded, and 1,000
    /// after a walk failed part-way, as if counted (behaviour verifier, round 2).
    @Test func theDeviceTilesWaitForAWholeList() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.devices.load()
        await eventually("a's first page and the services") {
            if case .loaded = world.devices.servicesState { world.devices.rows.count == 1000 } else { false }
        }
        #expect(!world.devices.devicesReadWhole)
        #expect(world.devices.unassignedCount == nil, "a \"not assigned\" tile of \(world.devices.unassignedCount ?? 0) while the devices load")
        world.stubs["a"]!.failTransport(50)
        world.gates["a"]!.release("later")
        await world.settled(2)
        #expect(world.devices.partialCount == 1000)
        #expect(!world.devices.devicesReadWhole)
        #expect(world.devices.unassignedCount == nil, "a \"not assigned\" tile of \(world.devices.unassignedCount ?? 0) over a partial list")
        // Read whole, it is counted.
        world.stubs["a"]!.failTransport(0)
        world.devices.load(force: true)
        await world.settled(4)
        #expect(world.devices.devicesReadWhole)
        #expect(world.devices.unassignedCount == 2500)
    }
}
