import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Orgs
import Reports
import Testing
import TestSupport

/// The Dashboard (Overview): each card counts only what was read whole and says why otherwise (invariant 8), the
/// devices are read once for it and the Devices screen, and the recent audit events are its own read, whose refusal,
/// failure or School scope is said in that card only. An org switch, a Refresh or a superseded read leaves nothing of
/// the old read on screen (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Suite("Dashboard", .serialized)
struct DashboardTests {
    // MARK: one device read

    /// The Dashboard counts what the Devices screen reads: one device read for both, the audit log read beside it, and
    /// an unforced load once both are here reads nothing again. Refresh reads both again.
    @Test func theDevicesAreReadOnceAndTheAuditLogBeside() async throws {
        let world = try await World.make()
        world.dashboard.load()
        await world.settled(2)
        await world.auditSettled(1)
        #expect(world.reads("a", "/v1/orgDevices") == 1 && world.reads("a", "/v1/auditEvents") == 1, "\(world.stubs["a"]!.requests)")
        #expect(world.dashboard.stats()?.total == 3)

        world.dashboard.load()
        world.devices.load()
        #expect(!world.devices.state.isLoading && !world.dashboard.auditState.isLoading, "an unforced load read again")
        #expect(world.reads("a", "/v1/orgDevices") == 1 && world.reads("a", "/v1/auditEvents") == 1)

        world.dashboard.load(force: true)
        #expect(world.devices.state.isLoading && world.dashboard.auditState.isLoading)
        await world.settled(4)
        await world.auditSettled(2)
        #expect(world.reads("a", "/v1/orgDevices") == 2 && world.reads("a", "/v1/auditEvents") == 2)
    }

    /// Opened after the Devices screen read them, the Dashboard doesn't read the devices again; it reads only the audit log.
    @Test func aDashboardOpenedAfterTheDevicesScreenReadsOnlyTheAuditLog() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        #expect(world.reads("a", "/v1/auditEvents") == 0)
        world.dashboard.load()
        await world.auditSettled(1)
        #expect(world.reads("a", "/v1/orgDevices") == 1)
        #expect(world.reads("a", "/v1/auditEvents") == 1)
        #expect(world.devices.readsFinished == 2)
    }

    // MARK: the fleet's cards

    /// The counts by family and status and the months come from a device list read whole; while it is read, a dash and
    /// the words, never the counts of the pages read so far.
    @Test func theFleetCardsCountOnlyAListReadWhole() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0])
        world.gates["a"]!.hold("later", Gate.laterDevicePages)
        world.dashboard.load()
        await eventually("a's first page") { world.devices.rows.count == 1000 }
        #expect(world.dashboard.stats() == nil, "counts of 1000 of 2500 devices")
        #expect(world.dashboard.fleetWords == "Reading the devices… \(1000.formatted()) so far.", "\(world.dashboard.fleetWords ?? "nil")")
        world.gates["a"]!.release("later")
        await world.settled(2)
        #expect(world.dashboard.fleetWords == nil)
        let stats = try #require(world.dashboard.stats())
        #expect(stats.total == 2500)
        #expect(DashboardModel.summary(stats.byFamily) == "Mac \(2500.formatted())")
    }

    /// A device list the page cap stopped counts nothing on the cards, and says how far it got.
    @Test func aDeviceListCutAtThePageCapCountsNothing() async throws {
        let world = try await World.make(devices: ["a": 2500, "b": 0], pageCap: 2)
        world.dashboard.load()
        await world.settled(2)
        #expect(world.devices.truncated)
        #expect(world.dashboard.stats() == nil)
        #expect(world.dashboard.fleetWords == "Not counted: the device list stopped at the page limit after \(2000.formatted()) of more than \(2000.formatted()) devices.",
                "\(world.dashboard.fleetWords ?? "nil")")
        #expect(world.dashboard.unassigned == nil)
        #expect(world.dashboard.unassignedWords == world.dashboard.fleetWords)
    }

    /// A refused or failed device read is said on the cards, in its own words, and the audit card still reads.
    @Test func aRefusedOrFailedDeviceReadIsSaidOnTheCards() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        world.stubs["a"]!.forbid("/v1/orgDevices")
        world.dashboard.load()
        await world.settled(2)
        await world.auditSettled(1)
        #expect(world.dashboard.fleetWords == "Your role can't read devices.")
        #expect(world.dashboard.stats() == nil)
        #expect(world.dashboard.unassignedWords == "Your role can't read devices.")
        if case .loaded = world.dashboard.auditState {} else { Issue.record("audit: \(world.dashboard.auditState)") }

        let failing = try await World.make(devices: ["a": 3, "b": 0])
        failing.stubs["a"]!.queue(400, for: "/v1/orgDevices")
        failing.dashboard.load()
        await failing.settled(2)
        guard case .failed(let why) = failing.devices.state else { Issue.record("devices: \(failing.devices.state)"); return }
        #expect(failing.dashboard.fleetWords == "The devices couldn't be read: \(why)")
        #expect(failing.dashboard.stats() == nil)
    }

    /// An org with no devices says so rather than showing empty charts.
    @Test func anOrgWithNoDevicesSaysSo() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.dashboard.load()
        await world.settled(2)
        #expect(world.dashboard.stats()?.total == 0)
        #expect(world.dashboard.fleetWords == "This organization has no devices.")
    }

    /// Each chart's summary, for a screen reader, names every bar with its count.
    @Test func eachChartsSummaryReadsEveryBar() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let now = Date()
        world.stubs["a"]!.add(devices: [Self.device("TESTMAC001", added: now.addingTimeInterval(-86_400)),
                                        Self.device("TESTMAC002", status: "UNASSIGNED", added: now.addingTimeInterval(-40 * 86_400)),
                                        Self.device("TESTPHN001", family: "iPhone", added: now.addingTimeInterval(-100 * 86_400))])
        world.dashboard.load()
        await world.settled(2)
        let stats = try #require(world.dashboard.stats(now: now))
        #expect(DashboardModel.summary(stats.byFamily) == "Mac 2, iPhone 1")
        #expect(DashboardModel.summary(stats.byStatus) == "ASSIGNED 2, UNASSIGNED 1")
        #expect(stats.added30 == 1 && stats.added90 == 2, "the dashboard counts at the time it is given")
        let months = DashboardModel.summary(stats.addedByMonth)
        #expect(months.split(separator: ",").count == 12, "\(months)")
        #expect(DashboardModel.summary([Tally]()) == "none")
    }

    // MARK: the services' cards

    /// Devices per service: each list read whole is counted; one that wasn't is named and never counted as 0.
    @Test func perServiceCountsEachListReadWholeAndNamesTheRest() async throws {
        let world = try await World.make(devices: ["a": 4, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("s1", name: "Main MDM"), World.service("s2", name: "Lab MDM")])
        stub.assign("ADEV0000000", to: "s1")
        stub.assign("ADEV0000001", to: "s1")
        stub.assign("ADEV0000002", to: "s2")
        stub.forbid("/v1/mdmServers/s2/")
        world.dashboard.load()
        await world.settled(2)
        let counts = try #require(world.dashboard.perService)
        #expect(counts == [.init(id: "s1", name: "Main MDM", count: 2), .init(id: "s2", name: "Lab MDM", count: nil)])
        #expect(DashboardModel.summary(counts) == "Main MDM 2, Lab MDM not counted")
        #expect(world.dashboard.servicesWords == "Not counted, as their device lists weren't read whole: Lab MDM.")
        // A device the unread list may hold is never "unassigned".
        #expect(world.dashboard.unassigned == nil)
        #expect(world.dashboard.unassignedWords == world.devices.serviceNote && world.devices.serviceNote?.contains("Lab MDM") == true)
    }

    /// While the services are read, refused or failed, no service card counts anything: each says why.
    @Test func servicesNotReadWholeShowNoServiceCards() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        world.stubs["a"]!.add(services: [World.service("s1", name: "Main MDM")])
        world.gates["a"]!.hold("services", { $0.path().hasPrefix("/v1/mdmServers") })
        world.dashboard.load()
        await world.settled(1)
        #expect(world.dashboard.fleetWords == nil, "the devices are read")
        #expect(world.dashboard.perService == nil && world.dashboard.quiet() == nil && world.dashboard.unassigned == nil)
        #expect(world.dashboard.servicesWords == "Reading the device management services…")
        #expect(world.dashboard.quietWords() == "Reading the device management services…")
        #expect(world.dashboard.unassignedWords == "Reading the device management services…")
        world.gates["a"]!.release("services")
        await world.settled(2)
        #expect(world.dashboard.perService == [.init(id: "s1", name: "Main MDM", count: 0)])
        #expect(world.dashboard.servicesWords == nil)

        let refused = try await World.make(devices: ["a": 3, "b": 0])
        refused.stubs["a"]!.forbid("/v1/mdmServers")
        refused.dashboard.load()
        await refused.settled(2)
        #expect(refused.dashboard.perService == nil && refused.dashboard.quiet() == nil && refused.dashboard.unassigned == nil)
        #expect(refused.dashboard.servicesWords == "Your role can't read device management services.")
        #expect(refused.dashboard.quietWords() == "Your role can't read device management services.")
        #expect(refused.dashboard.unassignedWords == "Your role can't read device management services.")
    }

    /// An org with no services says so; and, every list read whole, every device is unassigned and listed.
    @Test func anOrgWithNoServicesSaysSo() async throws {
        let world = try await World.make(devices: ["a": 2, "b": 0])
        world.dashboard.load()
        await world.settled(2)
        #expect(world.dashboard.perService == [])
        #expect(world.dashboard.servicesWords == "This organization has no device management services.")
        #expect(world.dashboard.unassigned == ["ADEV0000000", "ADEV0000001"])
    }

    /// Unassigned devices, once every list is read whole: sorted by code point, the first 30 listed and the rest said.
    @Test func unassignedDevicesAreListedOnceEveryListIsReadWhole() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        let now = Date()
        stub.add(devices: [Self.device("TESTZ00001", added: now), Self.device("TESTA00001", added: now), Self.device("TESTM00001", added: now)])
        stub.add(services: [World.service("s1", name: "Main MDM")])
        stub.assign("TESTM00001", to: "s1")
        world.dashboard.load()
        await world.settled(2)
        #expect(world.dashboard.unassigned == ["TESTA00001", "TESTZ00001"])
        #expect(world.dashboard.unassignedWords == nil)
        #expect(world.devices.unassignedCount == 2)

        let many = try await World.make(devices: ["a": 35, "b": 0])
        many.stubs["a"]!.add(services: [World.service("s1", name: "Main MDM")])
        many.dashboard.load()
        await many.settled(2)
        #expect(many.dashboard.unassigned?.count == 35)
        #expect(many.dashboard.unassignedWords == "The first 30 of 35, by serial.")

        let none = try await World.make(devices: ["a": 1, "b": 0])
        none.stubs["a"]!.add(services: [World.service("s1", name: "Main MDM")])
        none.stubs["a"]!.assign("ADEV0000000", to: "s1")
        none.dashboard.load()
        await none.settled(2)
        #expect(none.dashboard.unassigned == [])
        #expect(none.dashboard.unassignedWords == "Every device is assigned to a service.")
    }

    /// Services not connected in N days are Reports' rule (`QuietServices`): a deleted service is skipped, a service that
    /// never connected and one whose date doesn't read come first, said as such, and N is the operator's, read again
    /// from what is here, not from Apple.
    @Test func quietServicesAreReportsRuleOverTheChosenDays() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        let now = Date()
        world.stubs["a"]!.add(services: [Self.service("s1", "Forty", lastConnected: .string(Self.iso(now.addingTimeInterval(-40 * 86_400)))),
                                         Self.service("s2", "Ten", lastConnected: .string(Self.iso(now.addingTimeInterval(-10 * 86_400)))),
                                         Self.service("s3", "Never", lastConnected: nil),
                                         Self.service("s4", "Gone", status: "DELETED", lastConnected: .string(Self.iso(now.addingTimeInterval(-100 * 86_400)))),
                                         Self.service("s5", "Garbled", lastConnected: .string("yesterday"))])
        world.dashboard.load()
        await world.settled(2)
        #expect(world.dashboard.quietDays == QuietServices.defaultDays)
        let rows = try #require(world.dashboard.quiet(now: now))
        #expect(rows.map(\.service.name) == ["Never", "Garbled", "Forty"])
        #expect(rows.map { DashboardModel.lastConnected($0, now: now) } == ["Never connected", "Unreadable date: \"yesterday\"", "40 days ago"])
        #expect(world.dashboard.quietWords(now: now) == nil)

        let requests = world.stubs["a"]!.requests.count
        world.dashboard.quietDays = 7
        #expect(world.dashboard.quiet(now: now)?.map(\.service.name) == ["Never", "Garbled", "Forty", "Ten"])
        #expect(world.stubs["a"]!.requests.count == requests, "a new N reads nothing")

        let fine = try await World.make(devices: ["a": 1, "b": 0])
        fine.stubs["a"]!.add(services: [Self.service("s1", "Daily", lastConnected: .string(Self.iso(now.addingTimeInterval(-86_400))))])
        fine.dashboard.load()
        await fine.settled(2)
        #expect(fine.dashboard.quiet(now: now)?.isEmpty == true)
        #expect(fine.dashboard.quietWords(now: now) == "Every service has connected in the last 30 days, deleted ones aside.")
        #expect(DashboardModel.lastConnected(try #require(QuietServices([MDMService(resource: Self.service("x", "One", lastConnected: .string(Self.iso(now.addingTimeInterval(-1.5 * 86_400)))))],
                                                                       now: now, days: 1).rows.first), now: now) == "1 day ago")
    }

    // MARK: recent audit events

    /// The recent events are the newest ten of the last seven days, newest first whatever order Apple sent them in, read
    /// over a range of exactly seven days to now; an older event isn't asked for.
    @Test func recentEventsAreTheNewestTenOfTheLastSevenDays() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        let now = Date()
        let hours = [5, 30, 1, 140, 12, 70, 2, 99, 50, 8, 120, 3]
        world.stubs["a"]!.add(hours.enumerated().map { Self.event("e\($0.offset)", at: now.addingTimeInterval(-Double($0.element) * 3_600)) }
                              + [Self.event("old", at: now.addingTimeInterval(-8 * 86_400))])
        world.dashboard.load()
        await world.auditSettled(1)
        #expect(world.dashboard.auditRead == 12)
        let newest = hours.enumerated().sorted { $0.element < $1.element }.prefix(10).map { "e\($0.offset)" }
        #expect(world.dashboard.recentEvents.map(\.id) == newest)
        #expect(world.dashboard.auditWords == "The newest 10 of 12 events in the last 7 days.")

        let request = try #require(world.stubs["a"]!.requests.first { $0.contains("/v1/auditEvents?") })
        let items = try #require(URLComponents(string: "https://" + request.dropFirst(4))?.queryItems)
        func instant(_ name: String) -> Date? { items.first { $0.name == name }?.value.flatMap { ISO8601DateFormatter().date(from: $0) } }
        let start = try #require(instant("filter[startTimestamp]")), end = try #require(instant("filter[endTimestamp]"))
        #expect(end.timeIntervalSince(start) == 7 * 86_400)
        #expect(abs(end.timeIntervalSince(now)) < 60)
    }

    /// Phase 2b review L3, probe p4: a recent event Apple named its actor and subject only by id shows the ids, as Activity's
    /// table does, never a dash that reads as no actor; its type and outcome are in Activity's words.
    @Test func aRecentEventNamedOnlyByIdShowsTheId() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        world.stubs["a"]!.add([Resource(type: "auditEvents", id: "E1", attributes: [
            "eventDateTime": .string(Self.iso(Date().addingTimeInterval(-3_600))), "type": .string("API_ACCOUNT_KEY_REVOKED"),
            "actorType": .string("API_ACCOUNT"), "actorId": .string("APIACTOR1"), "subjectId": .string("SUBJ1"), "outcome": .string("FAILURE"),
        ]), Self.event("E2", at: Date().addingTimeInterval(-7_200))])
        world.dashboard.load()
        await world.auditSettled(1)
        let rows = world.dashboard.recentRows
        #expect(rows.map(\.event.id) == world.dashboard.recentEvents.map(\.id) && rows.map(\.event.id) == ["E1", "E2"])
        // Each row its own id, as the card's `ForEach` needs (Phase 2b verifier round 1, mutant N-recentRowsSameID).
        #expect(rows.map(\.id) == [0, 1])
        let first = try #require(rows.first)
        #expect(first.actor == "APIACTOR1" && first.subject == "SUBJ1")
        #expect(first.type == "API account key revoked" && first.outcome == "Failure" && first.failed)
        let second = try #require(rows.dropFirst().first)
        #expect(second.actor == "Admin One" && second.type == "Device added to org" && second.outcome == "Success")
        let activity = ActivityRow(try #require(world.dashboard.recentEvents.first), id: 0)
        #expect([first.type, first.actor, first.subject, first.outcome] == [activity.type, activity.actor, activity.subject, activity.outcome])
    }

    /// Few events or none: each said in words.
    @Test func fewOrNoEventsAreSaid() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        world.dashboard.load()
        await world.auditSettled(1)
        #expect(world.dashboard.recentEvents.isEmpty)
        #expect(world.dashboard.auditWords == "No audit events in the last 7 days.")

        let one = try await World.make(devices: ["a": 1, "b": 0])
        one.stubs["a"]!.add([Self.event("e1", at: Date().addingTimeInterval(-60))])
        one.dashboard.load()
        await one.auditSettled(1)
        #expect(one.dashboard.recentEvents.map(\.id) == ["e1"])
        #expect(one.dashboard.auditWords == "1 event in the last 7 days.")

        let three = try await World.make(devices: ["a": 1, "b": 0])
        three.stubs["a"]!.add((0..<3).map { Self.event("e\($0)", at: Date().addingTimeInterval(-60 * Double($0 + 1))) })
        three.dashboard.load()
        await three.auditSettled(1)
        #expect(three.dashboard.auditWords == "3 events in the last 7 days.")
    }

    /// A role that can't read the audit log: said in that card, and every other card is unaffected.
    @Test func aRefusedAuditLogIsSaidInItsCardOnly() async throws {
        let world = try await World.make(devices: ["a": 3, "b": 0])
        world.stubs["a"]!.forbid("/v1/auditEvents")
        world.dashboard.load()
        await world.settled(2)
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .forbidden)
        #expect(world.dashboard.auditWords == "Your role can't read the audit log.")
        #expect(world.dashboard.recentEvents.isEmpty)
        if case .loaded = world.devices.state {} else { Issue.record("devices: \(world.devices.state)") }
        #expect(world.dashboard.fleetWords == nil && world.dashboard.stats()?.total == 3)
    }

    /// A School org has no audit endpoint: its card says not in scope, in words, and nothing is sent for it; the devices
    /// still read from School's host.
    @Test func aSchoolOrgsAuditCardSaysNotInScope() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.dashboard.load()
        await world.settled(2)
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .notInScope("Apple School Manager's API has no audit events to read."))
        #expect(world.dashboard.auditWords == "Apple School Manager's API has no audit events to read.")
        #expect(world.dashboard.recentEvents.isEmpty)
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("/v1/auditEvents") })
        #expect(world.dashboard.stats()?.total == 3)
    }

    /// A read that fails part-way shows no events: the newest of a part are not the newest.
    @Test func aFailedAuditReadShowsNoEvents() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        let now = Date()
        world.stubs["a"]!.add((0..<1001).map { Self.event(String(format: "e%04d", $0), at: now.addingTimeInterval(-Double($0) * 60)) })
        world.gates["a"]!.hold("later", { $0.path() == "/v1/auditEvents" && ($0.query() ?? "").contains("cursor=") })
        world.dashboard.load()
        await world.settled(2)
        await eventually("the audit log's first page") { world.dashboard.auditState == .loading(count: 1000) }
        // Every try at the second page fails (the client's retries too), after the first page was read.
        world.stubs["a"]!.failTransport(5)
        world.gates["a"]!.release("later")
        await world.auditSettled(1)
        guard case .failed(let why) = world.dashboard.auditState else { Issue.record("audit: \(world.dashboard.auditState)"); return }
        #expect(world.dashboard.auditWords == "The audit log couldn't be read: \(why)")
        #expect(world.dashboard.recentEvents.isEmpty && world.dashboard.auditRead == 0)
    }

    /// The page cap stops the audit read: the card shows the newest of what was read and says the list was cut, and that
    /// Apple's order isn't documented, so newer events may be missing.
    @Test func anAuditLogCutAtThePageCapSaysSo() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0], pageCap: 1)
        let now = Date()
        world.stubs["a"]!.add((0..<1001).map { Self.event(String(format: "e%04d", $0), at: now.addingTimeInterval(-Double($0) * 60)) })
        world.dashboard.load()
        await world.auditSettled(1)
        #expect(world.dashboard.auditTruncated)
        #expect(world.dashboard.recentEvents.count == 10)
        #expect(world.dashboard.auditWords == "Showing the newest 10 of the \(1000.formatted()) events read: the audit log stopped at the page limit, "
                + "and Apple documents no order for it, so newer events may be missing.", "\(world.dashboard.auditWords ?? "nil")")
    }

    // MARK: switches, refreshes and superseded reads

    /// An org switch clears the audit card at once and reads the new org's; a's read, still held, lands nothing.
    @Test func anOrgSwitchClearsTheAuditCardAndReadsTheNewOrg() async throws {
        let world = try await World.make()
        let now = Date()
        world.stubs["a"]!.add((0..<12).map { Self.event("a\($0)", at: now.addingTimeInterval(-Double($0 + 1) * 60)) })
        world.stubs["b"]!.add((0..<2).map { Self.event("b\($0)", at: now.addingTimeInterval(-Double($0 + 1) * 60)) })
        world.dashboard.load()
        await world.auditSettled(1)
        #expect(world.dashboard.recentEvents.count == 10)
        world.gates["b"]!.hold("audit", Self.auditPages)

        world.orgs.select("b")
        #expect(world.dashboard.recentEvents.isEmpty && world.dashboard.auditRead == 0)
        #expect(world.dashboard.auditState == .loading(count: 0), "a switch reads the new org: \(world.dashboard.auditState)")
        world.gates["b"]!.release("audit")
        await world.auditSettled(2)
        #expect(world.dashboard.recentEvents.map(\.id) == ["b0", "b1"])
        #expect(world.reads("a", "/v1/auditEvents") == 1)
    }

    /// A switch while a's audit read is held: a's answer, when it comes, writes nothing over b's.
    @Test func aSupersededAuditReadWritesNothing() async throws {
        let world = try await World.make()
        let now = Date()
        world.stubs["a"]!.add((0..<12).map { Self.event("a\($0)", at: now.addingTimeInterval(-Double($0 + 1) * 60)) })
        world.gates["a"]!.hold("audit", Self.auditPages)
        world.dashboard.load()
        await world.settled(2)
        await eventually("a's audit read held") { world.gates["a"]!.held == 1 }
        // a's page is answered and waits, unread, in its stream when the switch cancels the read.
        world.buffer("a", release: "audit")
        world.gates["b"]!.hold("audit", Self.auditPages)
        world.orgs.select("b")
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .loading(count: 0), "a's read landed on b: \(world.dashboard.auditState)")
        #expect(world.dashboard.recentEvents.isEmpty)
        world.gates["b"]!.release("audit")
        await world.auditSettled(2)
        #expect(world.dashboard.recentEvents.isEmpty && world.dashboard.auditRead == 0)
        #expect(world.dashboard.auditWords == "No audit events in the last 7 days.")
    }

    /// A switch while a's audit read waits on Apple: the cancelled loop ends without throwing and with nothing read, and
    /// that end must not say "loaded, no events" over b's read still under way.
    @Test func aSwitchWhileTheAuditReadWaitsWritesNothing() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<12).map { Self.event("a\($0)", at: Date().addingTimeInterval(-Double($0 + 1) * 60)) })
        world.gates["a"]!.hold("audit", Self.auditPages)
        world.dashboard.load()
        await world.settled(2)
        await eventually("a's audit read held") { world.gates["a"]!.held == 1 }
        world.gates["b"]!.hold("audit", Self.auditPages)
        world.orgs.select("b")
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .loading(count: 0), "a's ended read landed on b: \(world.dashboard.auditState)")
        #expect(world.dashboard.auditWords == "Reading the last 7 days of the audit log…")
        world.gates["a"]!.release("audit")
        world.gates["b"]!.release("audit")
        await world.auditSettled(2)
        #expect(world.dashboard.auditWords == "No audit events in the last 7 days.")
    }

    /// Refresh while the audit page is already answered: the old read's page, handed to a cancelled loop, is dropped, and
    /// the new read is whole and not mixed with it.
    @Test func aRefreshDuringTheAuditReadDropsTheOldRead() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        let now = Date()
        world.stubs["a"]!.add((0..<12).map { Self.event("e\($0)", at: now.addingTimeInterval(-Double($0 + 1) * 60)) })
        world.gates["a"]!.hold("audit", Self.auditPages)
        world.dashboard.load()
        await world.settled(2)
        await eventually("the audit read held") { world.gates["a"]!.held == 1 }
        world.buffer("a", release: "audit")
        world.gates["a"]!.hold("again", Self.auditPages)
        world.dashboard.load(force: true)
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .loading(count: 0), "the cancelled read wrote: \(world.dashboard.auditState)")
        #expect(world.dashboard.recentEvents.isEmpty)
        world.gates["a"]!.release("again")
        await world.auditSettled(2)
        #expect(world.dashboard.auditRead == 12, "the old read's events were mixed in")
        #expect(world.dashboard.recentEvents.count == 10)
        if case .loaded = world.dashboard.auditState {} else { Issue.record("audit: \(world.dashboard.auditState)") }
    }

    /// A refused read already on its way when Refresh is pressed: its "forbidden" doesn't land on the new read.
    @Test func aFailureAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 1, "b": 0])
        world.stubs["a"]!.queue(403, for: "/v1/auditEvents")
        world.gates["a"]!.hold("audit", Self.auditPages)
        world.dashboard.load()
        await world.settled(2)
        await eventually("the audit read held") { world.gates["a"]!.held == 1 }
        world.buffer("a", release: "audit")
        world.gates["a"]!.hold("again", Self.auditPages)
        world.dashboard.load(force: true)
        await world.auditSettled(1)
        #expect(world.dashboard.auditState == .loading(count: 0), "the cancelled read's refusal landed: \(world.dashboard.auditState)")
        world.gates["a"]!.release("again")
        await world.auditSettled(2)
        if case .loaded = world.dashboard.auditState {} else { Issue.record("audit: \(world.dashboard.auditState)") }
    }

    /// Only a dashboard that was showing reads the new org's audit log on a switch: the Devices screen alone reads no audit.
    @Test func aSwitchReadsNoAuditForADashboardNobodyOpened() async throws {
        let world = try await World.make()
        world.devices.load()
        await world.settled(2)
        world.orgs.select("b")
        await world.settled(4)
        #expect(world.dashboard.auditState == .idle)
        #expect(world.reads("a", "/v1/auditEvents") == 0 && world.reads("b", "/v1/auditEvents") == 0)
    }

    // MARK: no org, an unusable org (Phase 1's Overview)

    /// No org yet, or one this version can't read: every card says why, and nothing is sent.
    @Test func withNoOrgOrAnUnusableOrgEveryCardSaysWhy() async throws {
        let empty = try await World.make(profiles: [])
        empty.dashboard.load()
        #expect(empty.dashboard.auditState == .unusable("No organization yet: add an Apple Business or Apple School Manager API account in Settings."))
        #expect(empty.dashboard.auditWords == "No organization yet: add an Apple Business or Apple School Manager API account in Settings.")
        #expect(empty.dashboard.fleetWords == empty.dashboard.auditWords)
        #expect(empty.dashboard.servicesWords == empty.dashboard.auditWords)

        let world = try await World.make(profiles: [World.unusable])
        world.dashboard.load()
        guard case .unusable(let why) = world.dashboard.auditState else { Issue.record("audit: \(world.dashboard.auditState)"); return }
        #expect(why.hasPrefix("This organization can't be used: "), "\(why)")
        #expect(world.devices.state == world.dashboard.auditState)
        #expect(world.dashboard.auditWords == why && world.dashboard.fleetWords == why)
        #expect(world.dashboard.readsFinished == 0)
        #expect(world.stubs.values.allSatisfy { $0.requests.isEmpty })
    }

    // MARK: helpers

    static let auditPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/auditEvents" }

    static func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    static func device(_ serial: String, family: String = "Mac", status: String = "ASSIGNED", added: Date) -> Resource {
        Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string("Test \(family)"), "productFamily": .string(family),
            "status": .string(status), "addedToOrgDateTime": .string(iso(added)),
        ])
    }

    static func service(_ id: String, _ name: String, status: String = "ACTIVE", lastConnected: JSONValue?) -> Resource {
        var attributes: JSONObject = ["serverName": .string(name), "serverType": .string("MDM"), "status": .string(status)]
        if let lastConnected { attributes["lastConnectedDateTime"] = lastConnected }
        return Resource(type: "mdmServers", id: id, attributes: attributes)
    }

    static func event(_ id: String, _ type: String = "DEVICE_ADDED_TO_ORG", at date: Date) -> Resource {
        Resource(type: "auditEvents", id: id, attributes: [
            "eventDateTime": .string(iso(date)), "type": .string(type), "category": .string("DEVICE"), "actorType": .string("USER"),
            "actorId": .string("actor1"), "actorName": .string("Admin One"), "subjectType": .string("DEVICE"),
            "subjectId": .string("TESTSER001"), "subjectName": .string("TESTSER001"), "outcome": .string("SUCCESS"),
        ])
    }
}

extension World {
    /// Waits for `count` of the dashboard's audit reads, superseded ones too, to have returned.
    func auditSettled(_ count: Int) async {
        await eventually("\(count) audit reads finished, \(dashboard.readsFinished) so far") { dashboard.readsFinished >= count }
    }

    /// First-page reads of `path` on `org`'s stub (a later page carries a cursor).
    func reads(_ org: String, _ path: String) -> Int {
        stubs[org]!.requests.filter { $0.contains("\(path)?") && !$0.contains("cursor=") }.count
    }
}
