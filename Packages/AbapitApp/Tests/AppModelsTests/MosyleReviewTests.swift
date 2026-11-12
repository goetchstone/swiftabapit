import AppModels
import Foundation
import JSONAPI
import Mosyle
import Reports
import Testing
import TestSupport

/// What step 3's adversarial review found, each held by the test that failed on the reviewed code (its R1–R4), and the
/// branches its mutants showed no test drove (M24, M33–M37, M41).
@Suite("Mosyle screens: the review's findings")
@MainActor
struct MosyleReviewTests {
    static func daysAgo(_ days: Double) -> String { MosyleScreenTests.day(Date().addingTimeInterval(-days * 86_400)) }
    static let loaded = MosyleScreenTests.loaded

    static func twoEntries(_ world: World) {
        world.mosyleStub.add(adminLogs: [["date": .string(daysAgo(20)), "user": .string("old@example.com"), "action": .string("Twenty days ago")],
                                         ["date": .string(daysAgo(0)), "user": .string("ada@example.com"), "action": .string("Today")]])
    }

    /// R1: another range reads from nothing: the last range's rows never show under its banner, mid-read or after a failure.
    @Test func anotherRangeNeverShowsTheLastRangesEntries() async throws {
        let world = try await World.make(mosyle: true)
        Self.twoEntries(world)
        world.mosyle.load()
        world.mosyle.tab = .adminLog
        await eventually("admin log") { Self.loaded(world.mosyle.adminLog.state) }
        #expect(world.mosyle.adminLog.rows.count == 2 && world.mosyle.adminLog.total == 2)
        world.mosyleStub.holdRequests(to: "/v1/adminlogs", fromPage: 1)
        let before = world.mosyleStub.requests.count
        world.mosyle.adminDays = 7
        await eventually("held") { world.mosyleStub.requests.count > before }
        #expect(world.mosyle.adminLog.rows.isEmpty && world.mosyle.adminLog.total == nil && world.mosyle.adminLog.state == .loading(count: 0))
        #expect(world.mosyle.exportBlocked(.adminLog) == "The list is still loading.")
        world.mosyleStub.release()
        await eventually("7 days") { Self.loaded(world.mosyle.adminLog.state) }
        #expect(world.mosyle.adminLog.rows.map(\.title) == ["Today"])
        world.mosyleStub.queue(500, for: "/v1/adminlogs")
        world.mosyle.adminDays = 30
        await eventually("failed") { if case .failed = world.mosyle.adminLog.state { true } else { false } }
        #expect(world.mosyle.adminLog.rows.isEmpty && world.mosyle.adminLog.partialCount == nil)
    }

    /// M24: a range chosen before the admin log was ever shown reads nothing; showing it reads that range.
    @Test func aRangeChosenBeforeTheLogIsShownReadsNothing() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        world.mosyle.adminDays = 7
        #expect(world.mosyle.adminLog.state == .idle && !world.mosyleStub.requests.contains { $0.contains("adminlogs") })
        world.mosyle.tab = .adminLog
        await eventually("admin log") { Self.loaded(world.mosyle.adminLog.state) }
        #expect(world.mosyleStub.bodies.last?["filter_options"]?["start_date"]?.string == String(Self.daysAgo(6).prefix(10)))
    }

    /// R2: a guessed field holding an object or a list is never kept: not on screen, not in the CSV; its name is said.
    @Test func aContainerInAGuessedFieldIsNamedNeverExported() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(adminLogs: [["date": .string(Self.daysAgo(0)), "user": .string("ada@example.com"),
                                          "action": .object(["payload": .object(["wifi_password": .string("CANARY-PSK")])]),
                                          "description": .string("Updated a profile")]])
        world.mosyleStub.add(customAttributes: [["name": .string("Cost centre"), "source": .object(["api_token": .string("CANARY-TOKEN")]),
                                                 "Source": .array([.string("CANARY-LIST")])]], os: "mac")
        world.mosyle.load()
        world.mosyle.tab = .adminLog
        await eventually("admin log") { Self.loaded(world.mosyle.adminLog.state) }
        world.mosyle.tab = .attributes
        await eventually("attributes") { Self.loaded(world.mosyle.attributes.state) }
        #expect(world.mosyle.shown(world.mosyle.adminLog).map(\.title) == ["Updated a profile"], "the next source's scalar")
        #expect(!world.mosyle.csv(.adminLog).contains("CANARY") && !world.mosyle.csv(.attributes).contains("CANARY"))
        #expect(world.mosyle.note(.adminLog) == "Mosyle sent fields this version doesn't read, so they aren't shown or exported: action.")
        #expect(world.mosyle.note(.attributes) == "Mosyle sent fields this version doesn't read, so they aren't shown or exported: Source, source.")
        #expect(world.mosyle.shown(world.mosyle.attributes).map(\.note) == ["—"])
    }

    /// R3: a member with no UDID is never named as a device that has none.
    @Test func aMemberWithNoUDIDIsNoDevice() async throws {
        let world = try await World.make(mosyle: true)
        var noUDID = MosyleScreenTests.device("MAC1")
        noUDID["deviceudid"] = nil
        world.mosyleStub.add(devices: [noUDID], os: "mac")
        world.mosyleStub.add(deviceGroups: [["iddevicegroup": .string("G1"), "name": .string("Studio")]], os: "mac")
        world.mosyleStub.add(members: [("", true)], toGroup: "G1")
        world.mosyle.load()
        world.mosyle.tab = .deviceGroups
        await eventually("lists") { Self.loaded(world.mosyle.devices.state) && Self.loaded(world.mosyle.deviceGroups.state) }
        world.mosyle.selectedGroup = "G1"
        await eventually("members") { world.mosyle.members.readsFinished >= 1 }
        #expect(world.mosyle.memberRows.map(\.name) == ["A member with no UDID"])
        #expect(world.mosyle.memberRows.first?.device == nil && world.mosyle.memberNote == "1 member isn't in Mosyle's device list: shown by UDID.")
    }

    /// R4: a report's Export says why in the devices' words: a partial device read, or a list cut at the page cap.
    @Test func aReportsExportSaysWhyInTheDevicesWords() async throws {
        let failed = try await World.make(mosyle: true)
        failed.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        failed.mosyleStub.queue(500, for: "/v1/devices", page: 2)
        failed.mosyle.load()
        await eventually("failed") { if case .failed = failed.mosyle.devices.state { true } else { false } }
        for tab: MosyleModel.Tab in [.osVersions, .stale] {
            #expect(failed.mosyle.exportBlocked(tab) == "The list is partial: 50 devices were read before the error. Refresh, then export.", "\(tab)")
        }
        let cut = try await World.make(mosyle: true, mosylePageCap: 1)
        cut.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        cut.mosyle.load()
        await eventually("cut") { Self.loaded(cut.mosyle.devices.state) }
        for tab: MosyleModel.Tab in [.osVersions, .stale] {
            #expect(cut.mosyle.exportBlocked(tab) == cut.mosyle.reportNote && cut.mosyle.reportNote?.hasPrefix("Mosyle's device list stopped") == true)
        }
        let loading = try await World.make(mosyle: true)
        loading.mosyleStub.holdRequests(to: "/v1/devices", fromPage: 1)
        loading.mosyle.load()
        #expect(loading.mosyle.exportBlocked(.osVersions) == "The list is still loading.")
        loading.mosyleStub.release()
    }

    /// M35, M41: Device 360 over a cut list says the device may be past it; over a failed read, why, never a spinner.
    @Test func device360SaysWhyMosyleDoesntHaveTheDevice() async throws {
        let cut = try await World.make(mosyle: true, mosylePageCap: 1)
        cut.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        cut.detail.show("ADEV0000002")
        if case .reading = cut.detail.mosyleSide {} else { Issue.record("while read: \(cut.detail.mosyleSide)") }
        await eventually("cut") { Self.loaded(cut.mosyle.devices.state) }
        if case .notFound(let why) = cut.detail.mosyleSide {
            #expect(why == "Not among the 50 devices read before Mosyle's list stopped at the page limit.")
        } else { Issue.record("\(cut.detail.mosyleSide)") }
        let failed = try await World.make(mosyle: true)
        failed.mosyleStub.queue(500, for: "/v1/devices")
        failed.detail.show("ADEV0000002")
        await eventually("failed") { if case .failed = failed.mosyle.devices.state { true } else { false } }
        if case .failed(let why) = failed.detail.mosyleSide { #expect(why == "Mosyle's service failed (HTTP 500). Try again later.") }
        else { Issue.record("\(failed.detail.mosyleSide)") }
        #expect(failed.detail.mosyleReadAt == nil)
    }

    /// M36, M37: the dates from both sources carry the device's own audit events, and only its own.
    @Test func theDatesFromBothCarryOnlyThisDevicesAuditEvents() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000001"), MosyleScreenTests.device("ADEV0000002")], os: "mac")
        let when = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        world.stubs["a"]!.add([Resource(type: "auditEvents", id: "E1", attributes: [
            "eventDateTime": .string(when), "type": .string("DEVICE_ASSIGNED_TO_SERVER"), "category": .string("DEVICE"),
            "subjectType": .string("DEVICE"), "subjectId": .string("ADEV0000001"), "outcome": .string("SUCCESS"),
            "eventDataPropertyKey": .string("deviceAssignedToServer"), "deviceAssignedToServer": .object([:]),
        ])])
        world.detail.show("ADEV0000001")
        await eventually("both halves") {
            world.detail.timelineReadsFinished >= 1 && { if case .found = world.detail.mosyleSide { true } else { false } }()
        }
        #expect(world.detail.bothTimeline.contains { $0.kind == "audit" && $0.label == "Device Assigned To Server \u{B7} SUCCESS" })
        #expect(world.detail.mosyleReadAt == nil || world.mosyle.devices.isWhole, "no age while the list is still read")
        await eventually("the whole list") { world.mosyle.devices.isWhole }
        #expect(world.detail.mosyleReadAt != nil)
        world.detail.show("ADEV0000002")
        #expect(!world.detail.bothTimeline.contains { $0.kind == "audit" }, "the last device's events")
        await eventually("its timeline") { world.detail.timelineReadsFinished >= 2 }
        #expect(!world.detail.bothTimeline.contains { $0.kind == "audit" })
    }

    /// M33, M34: a Refresh makes the report again from the new reads, Mosyle's and Apple's, even at the same counts; and the
    /// report says how old it is.
    @Test func aRefreshRemakesTheReportFromBothReads() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000")], os: "mac")
        world.reconciliation.load()
        await eventually("both") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole }
        let first = try #require(world.reconciliation.readAt)
        #expect(world.reconciliation.report?.both.map(\.mosyleStatus) == [.string("enrolled")])
        // Apple's devices alone read again (Refresh on Devices): Mosyle's read, and every count but Apple's, unchanged.
        world.stubs["a"]!.add(devices: [World.device("ADEV", 9)])
        world.devices.load(force: true)
        await eventually("Apple again") { world.devices.devicesReadWhole && world.reconciliation.report != nil }
        #expect(world.reconciliation.report?.appleOnly.map(\.serial).contains("ADEV0000009") == true, "Apple's new read")
        // Mosyle's alone, at the same count: its device's status changed.
        var changed = MosyleScreenTests.device("ADEV0000000")
        changed["status"] = .string("pending")
        world.mosyleStub.add(devices: [changed], os: "ios")
        world.mosyle.load(force: true)
        await eventually("Mosyle again") { world.mosyle.devices.isWhole && world.reconciliation.report != nil }
        #expect(world.mosyle.devices.rows.count == 1)
        #expect(world.reconciliation.report?.both.first?.mosyleStatus == .string("pending"), "Mosyle's new read, the same count")
        #expect(try #require(world.reconciliation.readAt) >= first)
    }
}
