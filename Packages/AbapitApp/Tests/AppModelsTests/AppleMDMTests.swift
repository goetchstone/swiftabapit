import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Reports
import Testing
import TestSupport

/// Invariant 8's tests for Apple MDM (Appendix B: "Devices › Apple MDM"): the `mdmDevices` list, then each device's
/// `/details` read one at a time up to `AppleMDMModel.detailLimit`, every row's posture in words and never blank (a row
/// whose details weren't read says why in each posture column, so nothing unread reads as "off"), and nothing read for one
/// org or one load landing on another (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Suite("Apple MDM", .serialized)
struct AppleMDMTests {
    static func device(_ id: String, name: String? = nil, family: String = "Mac", serial: String? = nil, user: String? = nil) -> Resource {
        Resource(type: "mdmDevices", id: id, attributes: [
            "serialNumber": .string(serial ?? id), "deviceName": .string(name ?? "Studio Mac \(id)"), "productFamily": .string(family),
            "enrolledUserId": user.map { .string($0) } ?? .null,
        ])
    }

    /// A details record for `serial`: a Mac, FileVault and the firewall on, unlocked, not erased, not lost; `extra` sets over it.
    static func details(_ serial: String, _ extra: JSONObject = [:]) -> Resource {
        var attributes: JSONObject = [
            "serialNumber": .string(serial), "deviceName": .string("Studio Mac \(serial)"), "deviceModel": .string("Mac mini (M4)"),
            "osVersion": .string("27.0.1"), "platform": .string("macOS"), "lastCheckInDateTime": .string("2026-10-30T09:15:00Z"),
            "isFirewallEnabled": .bool(true), "isFileVaultEnabled": .bool(true), "storageFreeCapacity": .number("120000000000"),
            "storageTotalCapacity": .number("256000000000"), "deviceLockStatus": .string("UNLOCKED"),
            "deviceEraseStatus": .string("NOT_ERASED"), "lostModeStatus": .string("DISABLED"),
        ]
        for (key, value) in extra { attributes[key] = value }
        return Resource(type: "mdmDeviceDetails", id: serial, attributes: attributes)
    }

    /// `count` devices in org `org`'s stub, `M0000`, `M0001`, …, each with its details.
    @discardableResult
    static func fleet(_ world: World, _ org: String = "a", count: Int, prefix: String = "M") -> [String] {
        let ids = (0..<count).map { String(format: "\(prefix)%04d", $0) }
        let stub = world.stubs[org]!
        stub.add(ids.map { device($0) })
        for id in ids { stub.setDetails(id, details(id)) }
        return ids
    }

    /// Waits for `reads` of the model's reads (a load's list and details, an inspector's own read) to have returned,
    /// superseded ones included.
    static func settled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) Apple MDM reads finished, \(world.appleMDM.readsFinished) so far") { world.appleMDM.readsFinished >= reads }
    }

    static func detailRequests(_ world: World, _ org: String = "a") -> [String] {
        world.stubs[org]!.requests.filter { $0.contains("/v1/mdmDevices/") }
    }

    static let detailPaths: @Sendable (URL) -> Bool = { $0.path().hasPrefix("/v1/mdmDevices/") && $0.path().hasSuffix("/details") }
    static let listPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/mdmDevices" }

    static func row(_ world: World, _ id: String) -> AppleMDMRow? { world.appleMDM.rows.first { $0.id == id } }

    static func isLoaded(_ state: LoadState) -> Bool { if case .loaded = state { true } else { false } }

    /// The posture columns a row shows, in the table's order.
    static func posture(_ row: AppleMDMRow) -> [String] {
        [row.os, row.checkIn, row.fileVault, row.firewall, row.lock, row.erase, row.lostMode, row.storage]
    }

    // MARK: the list and its details

    @Test func theListThenEachDevicesDetailsAreRead() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        stub.add([Self.device("M2", family: "iPhone"), Self.device("M1")])
        stub.setDetails("M1", Self.details("M1"))
        stub.setDetails("M2", Self.details("M2", ["isFileVaultEnabled": .bool(false), "isFirewallEnabled": .bool(false),
                                                  "deviceLockStatus": .string("LOCKED"), "deviceEraseStatus": .string("ERASED"),
                                                  "lostModeStatus": .string("ENABLED")]))
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.isLoaded(world.appleMDM.state), "\(world.appleMDM.state)")
        let rows = world.appleMDM.shown
        #expect(rows.map(\.serial) == ["M1", "M2"], "sorted by serial")
        #expect(rows.map(\.name) == ["Studio Mac M1", "Studio Mac M2"])
        #expect(rows.map(\.family) == ["Mac", "iPhone"])
        #expect(rows.map(\.fileVault) == ["On", "Off"])
        #expect(rows.map(\.firewall) == ["On", "Off"])
        #expect(rows.map(\.lock) == ["Unlocked", "Locked"])
        #expect(rows.map(\.erase) == ["Not erased", "Erased"])
        #expect(rows.map(\.lostMode) == ["Off", "On"])
        #expect(rows.map(\.os) == ["27.0.1", "27.0.1"])
        #expect(rows.allSatisfy { $0.details.detail != nil && $0.details.word == "Read" })
        // In the list's order, one at a time, after the list.
        let requests = world.stubs["a"]!.requests.filter { $0.contains("/v1/mdmDevices") }
        #expect(requests.count == 3 && requests[0].contains("/v1/mdmDevices?"), "\(requests)")
        #expect(Self.detailRequests(world).map { $0.components(separatedBy: "/v1/mdmDevices/").last } == ["M2/details", "M1/details"])
        #expect(world.appleMDM.detailsNote == nil, "\(world.appleMDM.detailsNote ?? "")")
        #expect(world.appleMDM.exportBlocked == nil)
        #expect(world.appleMDM.emptyTitle == nil)
    }

    /// A device with no details on record (a 404, the stub's assumption) says so in every posture column, never "Off".
    @Test func aDeviceWithNoDetailsSaysSoNotOff() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        stub.add([Self.device("M1"), Self.device("M2")])
        stub.setDetails("M1", Self.details("M1"))
        world.appleMDM.load()
        await Self.settled(world, 1)
        let none = try #require(Self.row(world, "M2"))
        guard case .none = none.details else { Issue.record("\(none.details)"); return }
        #expect(Self.posture(none) == Array(repeating: "No details", count: 8))
        #expect(world.appleMDM.detailsNote == "Apple has no details on record for 1 device.", "\(world.appleMDM.detailsNote ?? "nil")")
        #expect(world.appleMDM.exportBlocked == nil)
    }

    /// A 403 on the details: said on that row, and no more are asked (the role can't read any); the rest say "Not read".
    @Test func aRefusedDetailIsSaidAndNoMoreAreAsked() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 3)
        world.stubs["a"]!.forbid("/v1/mdmDevices/")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.isLoaded(world.appleMDM.state), "the list itself was read: \(world.appleMDM.state)")
        #expect(Self.detailRequests(world).count == 1, "\(Self.detailRequests(world))")
        let rows = world.appleMDM.shown
        guard case .forbidden = rows[0].details else { Issue.record("\(rows[0].details)"); return }
        #expect(Self.posture(rows[0]) == Array(repeating: "Role can't read", count: 8))
        #expect(rows.dropFirst().allSatisfy { if case .notRead = $0.details { true } else { false } }, "\(rows.map(\.details.word))")
        #expect(Self.posture(rows[2]) == Array(repeating: "Not read", count: 8))
        #expect(world.appleMDM.detailsNote == "Your role can't read Apple MDM device details: the first read was refused, so no more were asked.",
                "\(world.appleMDM.detailsNote ?? "nil")")
        // Selecting one asks Apple for its own: refused again, and said.
        world.appleMDM.selection = "M0002"
        await Self.settled(world, 2)
        guard case .forbidden? = Self.row(world, "M0002")?.details else { Issue.record("\(String(describing: Self.row(world, "M0002")?.details))"); return }
        #expect(Self.detailRequests(world).count == 2)
        // The refusal was org a's role: org b's, which reads its details, says nothing of it.
        Self.fleet(world, "b", count: 1, prefix: "B")
        world.orgs.select("b")
        await Self.settled(world, 3)
        #expect(world.appleMDM.rows.map(\.details.word) == ["Read"])
        #expect(world.appleMDM.detailsNote == nil, "\(world.appleMDM.detailsNote ?? "nil")")
    }

    /// One device's details failing costs only that device's; selecting it tries again.
    @Test func aFailedDetailCostsOnlyItsDeviceAndASelectionTriesAgain() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 3)
        world.stubs["a"]!.queue(200, for: "/v1/mdmDevices/M0001/details", body: "{}")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.shown.map(\.details.word) == ["Read", "Failed", "Read"])
        let failed = try #require(Self.row(world, "M0001"))
        guard case .failed(let why) = failed.details else { Issue.record("\(failed.details)"); return }
        #expect(why.contains("wasn't the shape it documents"), "\(why)")
        #expect(Self.posture(failed) == Array(repeating: "Failed", count: 8))
        #expect(failed.details.status == "Failed: \(why)")
        #expect(world.appleMDM.csv().components(separatedBy: "\r\n")[2].contains(",Failed: Apple's answer wasn't the shape it documents"),
                "\(world.appleMDM.csv())")
        #expect(world.appleMDM.detailsNote == "Details couldn't be read for 1 device: select it to try again.", "\(world.appleMDM.detailsNote ?? "nil")")
        world.appleMDM.selection = "M0001"
        await Self.settled(world, 2)
        #expect(Self.row(world, "M0001")?.details.word == "Read")
        #expect(world.appleMDM.selected?.id == "M0001")
        #expect(world.appleMDM.detailsNote == nil)
        // A row already read isn't read again by selecting it.
        world.appleMDM.selection = "M0000"
        #expect(Self.detailRequests(world).count == 4)
        #expect(world.appleMDM.readsFinished == 2)
    }

    /// Two devices' failures are counted as two (a count one test sees only as 1 isn't held).
    @Test func twoFailuresAndTwoWithoutDetailsAreCountedAsTwo() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        stub.add(["M1", "M2", "M3", "M4", "M5"].map { Self.device($0) })
        stub.setDetails("M1", Self.details("M1"))
        stub.setDetails("M2", Self.details("M2"))
        stub.setDetails("M3", Self.details("M3"))
        stub.queue(500, for: "/v1/mdmDevices/M1/details")
        stub.queue(500, for: "/v1/mdmDevices/M3/details")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.shown.map(\.details.word) == ["Failed", "Read", "Failed", "No details", "No details"])
        #expect(world.appleMDM.detailsNote
                == "Details couldn't be read for 2 devices: select one to try again. Apple has no details on record for 2 devices.",
                "\(world.appleMDM.detailsNote ?? "nil")")
    }

    /// Only the first `detailLimit` devices' details are read; the rest say "Not read", and selecting one reads its own.
    @Test func onlyTheFirstDetailLimitAreReadAndASelectionReadsItsOwn() async throws {
        let limit = AppleMDMModel.detailLimit
        #expect(limit == 50)
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let ids = Self.fleet(world, count: limit + 2)
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.detailRequests(world).count == limit)
        #expect(Self.detailRequests(world).last?.contains("/v1/mdmDevices/\(ids[limit - 1])/details") == true)
        let past = ids.suffix(2)
        #expect(past.allSatisfy { if case .notRead? = Self.row(world, $0)?.details { true } else { false } })
        #expect(Self.posture(try #require(Self.row(world, ids[limit]))) == Array(repeating: "Not read", count: 8))
        #expect(world.appleMDM.detailsNote == "Details are read for the first 50 devices only: 2 more say \"Not read\" until one is selected.",
                "\(world.appleMDM.detailsNote ?? "nil")")
        #expect(world.appleMDM.exportBlocked == nil, "a list whose rows say what wasn't read exports")
        // While a selection past the limit is read, the sweep's progress is still the sweep's.
        world.gates["a"]!.hold("selection", Self.detailPaths)
        world.appleMDM.selection = ids[limit]
        #expect(world.appleMDM.detailsNote?.hasPrefix("Details are read for the first 50 devices only: 1 more says") == true,
                "\(world.appleMDM.detailsNote ?? "nil")")
        world.appleMDM.selection = nil
        world.gates["a"]!.release("selection")
        await Self.settled(world, 2)
        world.appleMDM.selection = ids[limit + 1]
        #expect(Self.row(world, ids[limit + 1])?.details.word == "Reading…", "at once, before Apple answers")
        await Self.settled(world, 3)
        #expect(Self.row(world, ids[limit + 1])?.details.word == "Read")
        #expect(Self.detailRequests(world).count == limit + 2)
        #expect(world.appleMDM.detailsNote == nil, "\(world.appleMDM.detailsNote ?? "nil")")
        // A refresh reads the list again; the selected device, past the limit, reads its own again too.
        world.appleMDM.load(force: true)
        #expect(world.appleMDM.selection == ids[limit + 1], "a refresh keeps the selection")
        // The refresh's load and the selection's own read, in either order.
        await Self.settled(world, 5)
        #expect(Self.row(world, ids[limit + 1])?.details.word == "Read")
        #expect(Self.detailRequests(world).count == 2 * limit + 3, "\(Self.detailRequests(world).count)")
    }

    /// An id that can't go in a path is never sent: the client would call it "no such item", which isn't so.
    @Test func anIDThatCantGoInAPathIsNeverSent() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.add([Self.device("M 1", serial: "M1")])
        world.appleMDM.load()
        await Self.settled(world, 1)
        let row = try #require(Self.row(world, "M 1"))
        guard case .failed(let why) = row.details else { Issue.record("\(row.details)"); return }
        #expect(why == "This id can't be sent to Apple, so nothing was asked for." && why == ScreenWords.unsendableID)
        #expect(Self.detailRequests(world).isEmpty, "\(Self.detailRequests(world))")
    }

    /// Details that name another serial aren't shown as this device's posture.
    @Test func detailsForAnotherSerialAreNotThisDevices() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        stub.add([Self.device("M1"), Self.device("M2")])
        stub.setDetails("M1", Self.details("OTHER1", ["isFileVaultEnabled": .bool(false)]))
        stub.setDetails("M2", Self.details("M2", ["serialNumber": .null]))
        world.appleMDM.load()
        await Self.settled(world, 1)
        let other = try #require(Self.row(world, "M1"))
        guard case .failed(let why) = other.details else { Issue.record("\(other.details)"); return }
        #expect(why == "Apple's details were for another serial number (OTHER1).")
        #expect(other.fileVault == "Failed")
        // Details with no serial of their own are the device's, as asked.
        #expect(Self.row(world, "M2")?.details.word == "Read")
    }

    /// The demo org's Apple MDM (the screen's snapshots): fifteen of the demo fleet's devices, each posture the screen must
    /// say at least once.
    @Test func theDemoShowsEachPosture() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        DemoAppleMDM.load(into: world.stubs["a"]!)
        world.appleMDM.load()
        await Self.settled(world, 1)
        let rows = world.appleMDM.rows
        let fleet = Set(DemoFleet.make().devices.map(\.id))
        #expect(rows.count == 15)
        #expect(rows.allSatisfy { $0.serial.hasPrefix("DEMO") && fleet.contains($0.serial) && $0.id == $0.serial }, "\(rows.map(\.serial))")
        #expect(Dictionary(grouping: rows, by: \.family).mapValues(\.count) == ["Mac": 7, "iPhone": 4, "iPad": 4])
        #expect(rows.filter { $0.fileVault == "Off" }.count == 2)
        #expect(rows.filter { $0.lock == "Locked" }.count == 1)
        #expect(rows.filter { $0.lostMode == "On" }.count == 1)
        #expect(rows.filter { $0.checkIn == "Never" }.count == 1)
        #expect(rows.filter { if case .none = $0.details { true } else { false } }.count == 1)
        #expect(rows.filter { $0.details.detail != nil }.count == 14)
        #expect(world.appleMDM.detailsNote == "Apple has no details on record for 1 device.")
        #expect(rows.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: states in words

    /// A School org has no Apple MDM: said in words, never an empty table, and nothing is sent.
    @Test func aSchoolOrgIsNotInScopeAndSendsNothing() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.state == .notInScope("Apple School Manager's API has no Apple MDM devices to read."))
        #expect(world.appleMDM.rows.isEmpty)
        #expect(world.appleMDM.emptyTitle == "Not in Apple School Manager")
        #expect(world.appleMDM.detailsNote == nil)
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("mdmDevices") }, "\(world.stubs["a"]!.requests)")
        // An unforced load reads nothing more.
        world.appleMDM.load()
        #expect(world.appleMDM.readsFinished == 1)
    }

    @Test func aRefusedListIsSaidAndNoDetailIsAsked() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 2)
        world.stubs["a"]!.forbid("/v1/mdmDevices")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.state == .forbidden)
        #expect(world.appleMDM.emptyTitle == "Your role can't read Apple MDM")
        #expect(Self.detailRequests(world).isEmpty)
        #expect(world.appleMDM.partialCount == nil, "nothing was read, so nothing is partial")
    }

    @Test func aFailedListIsSaid() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.queue(503, for: "/v1/mdmDevices")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.state == .failed("Apple's service failed (HTTP 503). Try again later."))
        #expect(world.appleMDM.emptyTitle == "Apple MDM couldn't be read")
    }

    /// No org, an org this version can't read, and an org with no Apple MDM devices each say so.
    @Test func nothingToReadIsSaid() async throws {
        let none = try await World.make(profiles: [])
        none.appleMDM.load()
        // Every screen's sentence, Apple School Manager named too (Phase 2b review L10: this copy had dropped it).
        #expect(none.appleMDM.state == .unusable("No organization yet: add an Apple Business or Apple School Manager API account in Settings."))
        #expect(none.appleMDM.emptyTitle == "Nothing to read")
        let unusable = try await World.make(profiles: [World.unusable])
        unusable.appleMDM.load()
        guard case .unusable(let why) = unusable.appleMDM.state else { Issue.record("\(unusable.appleMDM.state)"); return }
        #expect(why.hasPrefix("This organization can't be used: "), "\(why)")
        let empty = try await World.make(devices: ["a": 0, "b": 0])
        #expect(empty.appleMDM.emptyTitle == nil, "idle: nothing asked yet")
        empty.appleMDM.load()
        #expect(empty.appleMDM.emptyTitle == nil, "loading")
        await Self.settled(empty, 1)
        #expect(empty.appleMDM.emptyTitle == "No devices are enrolled in Apple's device management")
        #expect(empty.appleMDM.detailsNote == nil)
    }

    /// A list cut at the page cap says so, and its details are still read up to the limit.
    @Test func aListCutAtThePageCapSaysSo() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0], pageCap: 1)
        world.stubs["a"]!.add((0..<1001).map { Self.device(String(format: "M%04d", $0)) })
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.isLoaded(world.appleMDM.state))
        #expect(world.appleMDM.truncated && world.appleMDM.devices.count == 1000)
        #expect(Self.detailRequests(world).count == AppleMDMModel.detailLimit)
    }

    /// A list that fails part-way keeps what it read, says it's partial, doesn't export, and asks no details.
    @Test func aListThatFailsPartWayIsPartial() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.add((0..<1001).map { Self.device(String(format: "M%04d", $0)) })
        world.stubs["a"]!.queue(200, for: "/v1/mdmDevices?cursor=", body: "{}")
        world.appleMDM.load()
        await Self.settled(world, 1)
        guard case .failed = world.appleMDM.state else { Issue.record("\(world.appleMDM.state)"); return }
        #expect(world.appleMDM.devices.count == 1000)
        #expect(world.appleMDM.partialCount == 1000)
        #expect(world.appleMDM.exportBlocked == "The list is partial: \(1000.formatted()) devices were read before the error. Refresh, then export.",
                "\(world.appleMDM.exportBlocked ?? "nil")")
        #expect(Self.detailRequests(world).isEmpty)
        #expect(world.appleMDM.rows.allSatisfy { if case .notRead = $0.details { true } else { false } })
        #expect(world.appleMDM.detailsNote == "Details aren't read for a list that didn't finish: select a device to read its own.")
        #expect(world.appleMDM.emptyTitle == nil, "the rows read are shown")
    }

    // MARK: the export

    @Test func theExportIsTheListWithItsPostureAndWhatWasRead() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!, gate = world.gates["a"]!
        stub.add([Self.device("M1", user: "U1"), Self.device("M2")])
        stub.setDetails("M1", Self.details("M1", ["activationLockBypassCode": .string("canary-bypass-code"),
                                                  "someFutureAttribute": .string("canary-future")]))
        gate.hold("details", Self.detailPaths)
        world.appleMDM.load()
        await eventually("M1's details asked") { gate.held == 1 && world.appleMDM.devices.count == 2 }
        #expect(world.appleMDM.exportBlocked == "The devices' details are still being read.")
        #expect(world.appleMDM.detailsNote == "Reading each device's details: 0 of 2 so far.", "\(world.appleMDM.detailsNote ?? "nil")")
        #expect(Self.posture(try #require(Self.row(world, "M2"))) == Array(repeating: "Reading…", count: 8))
        gate.release("details")
        await Self.settled(world, 1)
        #expect(world.appleMDM.exportBlocked == nil)
        let text = world.appleMDM.csv()
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == (["id"] + ExportPolicy.appleMDM.names).joined(separator: ","))
        #expect(lines[1].hasPrefix("M1,M1,Studio Mac M1,Mac,U1,Read,27.0.1,2026-10-30T09:15:00Z,True,True,UNLOCKED,NOT_ERASED,DISABLED,"), "\(lines[1])")
        #expect(lines[2].hasPrefix("M2,M2,Studio Mac M2,Mac,,No details,,,,,"), "\(lines[2])")
        #expect(!text.contains("canary"), "an attribute off the list left the app")
        // What the table shows, searched: the export follows it.
        world.appleMDM.search = "M2"
        #expect(world.appleMDM.csv().components(separatedBy: "\r\n").count == 3)
    }

    // MARK: words

    /// Each posture column in words: what Apple sent, "Unknown" when it sent none, and anything that didn't read, raw
    /// (invariant 10).
    @Test func eachPostureColumnSaysWhatApplesSent() throws {
        let device = MDMDevice(resource: Self.device("M1"))
        func row(_ extra: JSONObject) -> AppleMDMRow {
            AppleMDMRow(device, details: .read(MDMDeviceDetail(resource: Self.details("M1", extra))))
        }
        let unknown = row(["isFileVaultEnabled": .null, "deviceLockStatus": .string("FROZEN"), "isFirewallEnabled": .string("true"),
                           "lastCheckInDateTime": .string("yesterday"), "lostModeStatus": .number("1"), "osVersion": .null])
        #expect(unknown.fileVault == "Unknown")
        #expect(unknown.lock == "FROZEN")
        #expect(unknown.firewall == "\"true\"")
        #expect(unknown.checkIn == "\"yesterday\"")
        #expect(unknown.lostMode == "1")
        #expect(unknown.os == "—")
        var missing = Self.details("M1").attributes
        for key in ["isFileVaultEnabled", "isFirewallEnabled", "deviceLockStatus", "deviceEraseStatus", "lostModeStatus", "lastCheckInDateTime",
                    "storageFreeCapacity", "storageTotalCapacity", "osVersion"] { missing[key] = nil }
        let bare = AppleMDMRow(device, details: .read(MDMDeviceDetail(resource: Resource(type: "mdmDeviceDetails", id: "M1", attributes: missing))))
        #expect(Self.posture(bare) == ["—", "Never", "Unknown", "Unknown", "Unknown", "Unknown", "Unknown", "Unknown"])
        #expect(row(["lastCheckInDateTime": .null]).checkIn == "Never")
        #expect(row(["lastCheckInDateTime": .null]).checkInSort == .distantPast)
        let read = row([:])
        let checkedIn = try #require(ISO8601DateFormatter().date(from: "2026-10-30T09:15:00Z"))
        #expect(read.checkInSort == checkedIn)
        #expect(read.checkIn == checkedIn.formatted(date: .abbreviated, time: .shortened))
        let free = Int64(120_000_000_000).formatted(.byteCount(style: .file)), total = Int64(256_000_000_000).formatted(.byteCount(style: .file))
        #expect(read.storage == "\(free) free of \(total)")
        #expect(read.storageSort == 120_000_000_000)
        #expect(row(["storageTotalCapacity": .null]).storage == "\(free) free of Unknown")
        #expect(row(["storageFreeCapacity": .string("lots")]).storage == "\"lots\" free of \(total)")
        // A row whose details weren't read says why in every posture column, and sorts below every read one.
        for details: AppleMDMRow.Details in [.reading, .none, .forbidden, .failed("x"), .notRead] {
            let unread = AppleMDMRow(device, details: details)
            #expect(Self.posture(unread) == Array(repeating: details.word, count: 8), "\(details)")
            #expect(unread.checkInSort == .distantPast && unread.storageSort == -1)
            #expect(details.detail == nil)
        }
        #expect([AppleMDMRow.Details.reading, .none, .forbidden, .failed("x"), .notRead].map(\.word)
                == ["Reading…", "No details", "Role can't read", "Failed", "Not read"])
        #expect(AppleMDMRow.Details.none.status == "No details" && AppleMDMRow.Details.failed("why").status == "Failed: why")
        // The list's own attributes: the serial falls back to the id, as abapit's did.
        let nameless = AppleMDMRow(MDMDevice(resource: Resource(type: "mdmDevices", id: "X1")), details: .notRead)
        #expect(nameless.serial == "X1" && nameless.name.isEmpty && nameless.family.isEmpty && nameless.user.isEmpty)
    }

    @Test func searchAndSort() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let stub = world.stubs["a"]!
        stub.add([Self.device("M10", name: "Lab iPad", family: "iPad"), Self.device("M02", name: "Front Desk Mac", user: "U7"),
                  Self.device("M1", name: "Loaner")])
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.shown.map(\.serial) == ["M02", "M1", "M10"], "serials sort as text")
        world.appleMDM.search = "lab"
        #expect(world.appleMDM.shown.map(\.serial) == ["M10"])
        world.appleMDM.search = "u7"
        #expect(world.appleMDM.shown.map(\.serial) == ["M02"])
        world.appleMDM.search = "  "
        #expect(world.appleMDM.shown.count == 3)
        world.appleMDM.search = ""
        world.appleMDM.sortOrder = [KeyPathComparator(\AppleMDMRow.name)]
        #expect(world.appleMDM.shown.map(\.name) == ["Front Desk Mac", "Lab iPad", "Loaner"])
    }

    // MARK: org switches, refreshes and superseded loads

    /// Nothing of the old org stays on screen, in the CSV or selected; the new org is read at once.
    @Test func aSwitchClearsTheOldOrgAndReadsTheNewOne() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, "a", count: 2, prefix: "A")
        Self.fleet(world, "b", count: 1, prefix: "B")
        world.appleMDM.load()
        await Self.settled(world, 1)
        world.appleMDM.selection = "A0000"
        world.appleMDM.search = "A"
        world.gates["b"]!.hold("b", Self.listPages)

        world.orgs.select("b")
        #expect(world.appleMDM.devices.isEmpty && world.appleMDM.rows.isEmpty)
        #expect(world.appleMDM.selection == nil && world.appleMDM.selected == nil)
        #expect(!world.appleMDM.csv().contains("A0000"))
        #expect(world.appleMDM.state.isLoading, "\(world.appleMDM.state)")
        #expect(world.appleMDM.detailsNote == nil)

        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        world.appleMDM.search = ""
        #expect(world.appleMDM.shown.map(\.serial) == ["B0000"])
        #expect(world.appleMDM.shown.map(\.details.word) == ["Read"])
        #expect(Self.detailRequests(world, "a").count == 2 && Self.detailRequests(world, "b").count == 1)
    }

    /// A switch while the details are read: the old org's reads stop, and nothing they return lands on the new org.
    @Test func aSwitchDuringTheDetailsStopsThem() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, "a", count: 3, prefix: "A")
        Self.fleet(world, "b", count: 1, prefix: "B")
        let gate = world.gates["a"]!
        gate.hold("details", Self.detailPaths)
        world.appleMDM.load()
        await eventually("a's first details asked") { gate.held == 1 && world.appleMDM.devices.count == 3 }
        world.gates["b"]!.hold("b", Self.listPages)
        world.orgs.select("b")
        await Self.settled(world, 1)
        gate.release("details")
        #expect(world.appleMDM.state == .loading(count: 0), "\(world.appleMDM.state) while b's list is held")
        #expect(world.appleMDM.devices.isEmpty)
        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        #expect(world.appleMDM.rows.map(\.id) == ["B0000"])
        #expect(Self.detailRequests(world, "a").isEmpty, "a's details reads went on after the switch: \(Self.detailRequests(world, "a"))")
    }

    /// A list superseded mid-walk says nothing and reads no details: a cancelled loop ends without throwing.
    @Test func aSupersededListSaysNothingAndReadsNoDetails() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.add((0..<1001).map { Self.device(String(format: "A%04d", $0)) })
        Self.fleet(world, "b", count: 1, prefix: "B")
        let gate = world.gates["a"]!
        gate.hold("later", { $0.path() == "/v1/mdmDevices" && ($0.query() ?? "").contains("cursor=") })
        world.appleMDM.load()
        await eventually("a's first page") { world.appleMDM.devices.count == 1000 }
        world.gates["b"]!.hold("b", Self.listPages)
        world.orgs.select("b")
        gate.release("later")
        await Self.settled(world, 1)
        #expect(world.appleMDM.state == .loading(count: 0), "\(world.appleMDM.state)")
        #expect(world.appleMDM.devices.isEmpty)
        #expect(Self.detailRequests(world, "a").isEmpty, "\(Self.detailRequests(world, "a").count) details asked for a superseded list")
        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        #expect(world.appleMDM.rows.map(\.id) == ["B0000"])
    }

    /// Details already answered when Refresh is pressed wait for an await that is about to return them: the check after it
    /// drops them, so the refreshed read doesn't show the old one's posture.
    @Test func aDetailAlreadyAnsweredWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 2)
        let gate = world.gates["a"]!
        gate.hold("details", Self.detailPaths)
        world.appleMDM.load()
        await eventually("M0000's details asked") { gate.held == 1 }
        world.buffer("a", release: "details")
        gate.hold("again", Self.detailPaths)
        world.appleMDM.load(force: true)
        await Self.settled(world, 1)
        await eventually("the new list read and its first details held") { world.appleMDM.devices.count == 2 && gate.held == 1 }
        #expect(Self.row(world, "M0000")?.details.word == "Reading…", "the cancelled load's answer landed: \(String(describing: Self.row(world, "M0000")?.details))")
        #expect(Self.detailRequests(world).count == 1, "the old load went on after its answer: \(Self.detailRequests(world))")
        gate.release("again")
        await Self.settled(world, 2)
        #expect(world.appleMDM.shown.map(\.details.word) == ["Read", "Read"])
        #expect(Self.detailRequests(world).count == 3)
    }

    /// Refresh during the details cancels them and reads everything again; an unforced load reads nothing.
    @Test func aRefreshReadsAgainAndAnUnforcedLoadDoesNot() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 2)
        world.appleMDM.load()
        await Self.settled(world, 1)
        let sent = world.stubs["a"]!.requests.count
        world.appleMDM.load()
        #expect(world.appleMDM.readsFinished == 1 && !world.appleMDM.state.isLoading)
        #expect(world.stubs["a"]!.requests.count == sent, "an unforced load read again")
        let gate = world.gates["a"]!
        gate.hold("details", Self.detailPaths)
        world.appleMDM.load(force: true)
        #expect(world.appleMDM.state.isLoading && world.appleMDM.devices.isEmpty)
        await eventually("the refresh's first details held") { gate.held == 1 }
        world.appleMDM.load(force: true)
        await Self.settled(world, 2)
        gate.release("details")
        await Self.settled(world, 3)
        #expect(world.appleMDM.shown.map(\.details.word) == ["Read", "Read"])
        #expect(Self.detailRequests(world).count == 4, "\(Self.detailRequests(world))")
    }

    /// A page already answered when Refresh is pressed waits in the stream's buffer, and a cancelled loop can still be handed
    /// it: the check inside the loop drops it, so the old read's rows never mix into the new one.
    @Test func aPageAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.add((0..<2500).map { Self.device(String(format: "M%04d", $0)) })
        let gate = world.gates["a"]!
        gate.hold("later", { $0.path() == "/v1/mdmDevices" && ($0.query() ?? "").contains("cursor=") })
        world.appleMDM.load()
        await eventually("the first page") { world.appleMDM.devices.count == 1000 }
        gate.hold("third", { $0.path() == "/v1/mdmDevices" && ($0.query() ?? "").contains("cursor=2000") })
        // Page two is answered and waits, unread, for the old loop while the main actor is held.
        world.buffer("a", release: "later")
        gate.hold("all", Self.listPages)
        world.appleMDM.load(force: true)
        await Self.settled(world, 1)
        #expect(world.appleMDM.devices.isEmpty, "\(world.appleMDM.devices.count) rows of the cancelled read landed in the new one")
        #expect(world.appleMDM.state == .loading(count: 0))
        gate.release("third")
        gate.release("all")
        await Self.settled(world, 2)
        #expect(world.appleMDM.devices.count == 2500)
    }

    /// The same for a failure: a list that failed just before Refresh hands its error to a loop already cancelled, and the
    /// old read's "failed" must not land on the new one.
    @Test func aFailureAlreadyOnItsWayWhenRefreshedIsDropped() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        world.stubs["a"]!.add((0..<1500).map { Self.device(String(format: "M%04d", $0)) })
        let gate = world.gates["a"]!
        gate.hold("later", { $0.path() == "/v1/mdmDevices" && ($0.query() ?? "").contains("cursor=") })
        world.appleMDM.load()
        await eventually("the first page") { world.appleMDM.devices.count == 1000 }
        world.stubs["a"]!.queue(500, for: "/v1/mdmDevices?cursor=")
        world.buffer("a", release: "later")
        gate.hold("all", Self.listPages)
        world.appleMDM.load(force: true)
        await Self.settled(world, 1)
        #expect(world.appleMDM.state == .loading(count: 0), "the cancelled read's failure landed on the new one: \(world.appleMDM.state)")
        gate.release("all")
        await Self.settled(world, 2)
        #expect(world.appleMDM.devices.count == 1500)
        #expect(Self.isLoaded(world.appleMDM.state))
    }

    /// An inspector's read started before a switch is cancelled with the load: nothing more reaches the old org's Apple.
    @Test func aSelectionsReadIsCancelledByASwitch() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let ids = Self.fleet(world, "a", count: AppleMDMModel.detailLimit + 1, prefix: "A")
        let gate = world.gates["a"]!
        world.appleMDM.load()
        await Self.settled(world, 1)
        gate.hold("details", Self.detailPaths)
        world.appleMDM.selection = ids.last
        await eventually("the selection's details asked") { gate.held == 1 }
        world.orgs.select("b")
        gate.release("details")
        await Self.settled(world, 3)
        #expect(Self.detailRequests(world, "a").count == AppleMDMModel.detailLimit, "the selection's read went on after the switch")
        #expect(world.appleMDM.rows.isEmpty && world.appleMDM.selection == nil)
        #expect(Self.isLoaded(world.appleMDM.state), "\(world.appleMDM.state)")
    }

    /// An inspector's read answered just as Refresh is pressed never lands on the refreshed list: its row says what the new
    /// read knows ("Not read", past the limit), not the old read's "Read".
    @Test func aSelectionsReadDoesNotLandOnARefresh() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        let ids = (0..<1001).map { String(format: "A%04d", $0) }, target = ids[60]
        let stub = world.stubs["a"]!, gate = world.gates["a"]!
        stub.add(ids.map { Self.device($0) })
        stub.setDetails(target, Self.details(target))
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.row(world, target)?.details.word == "Not read")
        gate.hold("details", Self.detailPaths)
        world.appleMDM.selection = target
        await eventually("the selection's details asked") { gate.held == 1 }
        world.buffer("a", release: "details")
        gate.hold("later", { $0.path() == "/v1/mdmDevices" && ($0.query() ?? "").contains("cursor=") })
        world.appleMDM.load(force: true)
        await Self.settled(world, 2)
        await eventually("the refresh's first page") { world.appleMDM.devices.count == 1000 }
        #expect(Self.row(world, target)?.details.word == "Not read", "the old selection's read landed: \(String(describing: Self.row(world, target)?.details))")
        gate.release("later")
        await Self.settled(world, 3)
        await eventually("the selection read again after the refresh") { Self.row(world, target)?.details.word == "Read" }
    }

    // MARK: the inspector's selection (Phase 2b review L7)

    /// A selection the list doesn't hold says why, as People's does: the list is being read again (a Refresh keeps the
    /// selection), or Apple's list no longer has it; never "Select a device" beside a selected one.
    @Test func aSelectionTheListLacksSaysWhy() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 2)
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(world.appleMDM.selectionNote == nil, "nothing selected")
        world.appleMDM.selection = "M0001"
        #expect(world.appleMDM.selected?.id == "M0001" && world.appleMDM.selectionNote == nil)
        let gate = world.gates["a"]!
        gate.hold("list", Self.listPages)
        world.appleMDM.load(force: true)
        await eventually("the refresh's list held") { gate.held == 1 }
        #expect(world.appleMDM.selection == "M0001" && world.appleMDM.selected == nil)
        #expect(world.appleMDM.selectionNote == "Reading the devices…")
        world.stubs["a"]!.queue(200, for: "/v1/mdmDevices", body: #"{"data":[],"links":{"self":"x"},"meta":{"paging":{"limit":1000}}}"#)
        gate.release("list")
        await Self.settled(world, 2)
        #expect(Self.isLoaded(world.appleMDM.state) && world.appleMDM.devices.isEmpty, "\(world.appleMDM.state)")
        #expect(world.appleMDM.selectionNote == "This device isn't in the list Apple sent.")
        world.stubs["a"]!.queue(503, for: "/v1/mdmDevices")
        world.appleMDM.load(force: true)
        await Self.settled(world, 3)
        #expect(world.appleMDM.selectionNote == "This device couldn't be read.", "\(world.appleMDM.state)")
    }

    // MARK: leaving the screen (Phase 2b review L9; invariant 7: a sweep is cancellable)

    static func asked(_ world: World, _ org: String = "a") -> [String] {
        detailRequests(world, org).compactMap { $0.components(separatedBy: "/v1/mdmDevices/").last }
    }

    static func lists(_ world: World, _ org: String = "a") -> Int { world.stubs[org]!.requests.filter { $0.contains("/v1/mdmDevices?") }.count }

    /// Leaving the screen stops the details read: the one in flight is never answered into the rows, none after it is
    /// sent, and none still to read says "Reading…". Coming back asks for those not read, and only those.
    @Test func leavingStopsTheDetailsAndComingBackAsksOnlyTheUnread() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 5)
        let gate = world.gates["a"]!
        gate.hold("third", { $0.path() == "/v1/mdmDevices/M0002/details" })
        world.appleMDM.load()
        await eventually("the third device's details held") { gate.held == 1 }
        #expect(Self.asked(world) == ["M0000/details", "M0001/details"])
        world.appleMDM.pause()
        #expect(world.appleMDM.rows.map(\.details.word) == ["Read", "Read", "Not read", "Not read", "Not read"])
        #expect(world.appleMDM.exportBlocked == nil, "nothing is still being read")
        #expect(world.appleMDM.detailsNote == "Reading the details stopped when the screen was left: 3 devices say \"Not read\" until it is shown again.",
                "\(world.appleMDM.detailsNote ?? "nil")")
        await Self.settled(world, 1)
        await eventually("the held read let go") { gate.held == 0 }
        gate.release("third")
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.asked(world) == ["M0000/details", "M0001/details"], "a details read went on after the screen was left")
        #expect(world.appleMDM.rows.map(\.details.word) == ["Read", "Read", "Not read", "Not read", "Not read"])
        world.appleMDM.load()
        await Self.settled(world, 2)
        #expect(Self.asked(world) == ["M0000/details", "M0001/details", "M0002/details", "M0003/details", "M0004/details"])
        #expect(Self.lists(world) == 1, "the list was read again")
        #expect(world.appleMDM.rows.allSatisfy { $0.details.word == "Read" } && world.appleMDM.detailsNote == nil)
        // Shown again and nothing left: an unforced load reads nothing.
        world.appleMDM.pause()
        world.appleMDM.load()
        await Self.settled(world, 3)
        #expect(Self.asked(world).count == 5 && Self.lists(world) == 1)
    }

    /// Refresh after a pause reads the list and every device's details again, as it always does.
    @Test func aRefreshAfterAPauseReadsEverythingAgain() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 3)
        let gate = world.gates["a"]!
        gate.hold("second", { $0.path() == "/v1/mdmDevices/M0001/details" })
        world.appleMDM.load()
        await eventually("the second device's details held") { gate.held == 1 }
        world.appleMDM.pause()
        await Self.settled(world, 1)
        gate.release("second")
        world.appleMDM.load(force: true)
        await Self.settled(world, 2)
        #expect(Self.asked(world) == ["M0000/details", "M0000/details", "M0001/details", "M0002/details"])
        #expect(Self.lists(world) == 2 && world.appleMDM.rows.allSatisfy { $0.details.word == "Read" })
    }

    /// Leaving during a Refresh's list: the part read is dropped, nothing is left "Reading…", nothing more is sent, and the
    /// way back reads the list again, the selection kept.
    @Test func aPauseDuringARefreshLeavesNothingStale() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 3)
        world.appleMDM.load()
        await Self.settled(world, 1)
        world.appleMDM.selection = "M0001"
        let gate = world.gates["a"]!
        gate.hold("list", Self.listPages)
        world.appleMDM.load(force: true)
        await eventually("the refresh's list held") { gate.held == 1 }
        world.appleMDM.pause()
        #expect(world.appleMDM.state == .idle && world.appleMDM.devices.isEmpty && world.appleMDM.rows.isEmpty)
        #expect(world.appleMDM.detailsNote == nil && world.appleMDM.emptyTitle == nil && !world.appleMDM.state.isLoading)
        await Self.settled(world, 2)
        gate.release("list")
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.lists(world) == 1 && Self.asked(world).count == 3, "\(world.stubs["a"]!.requests)")
        world.appleMDM.load()
        await Self.settled(world, 3)
        #expect(Self.isLoaded(world.appleMDM.state) && world.appleMDM.rows.allSatisfy { $0.details.word == "Read" })
        #expect(world.appleMDM.selected?.id == "M0001" && world.appleMDM.selectionNote == nil)
        #expect(Self.lists(world) == 2 && Self.asked(world).count == 6)
    }

    /// Leaving during an org switch's read: nothing of either org stays or is sent; and a switch while the screen is away
    /// reads nothing until it is shown.
    @Test func aPauseDuringAnOrgSwitchLeavesNothingStale() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, "a", count: 3, prefix: "A")
        Self.fleet(world, "b", count: 2, prefix: "B")
        let a = world.gates["a"]!, b = world.gates["b"]!
        a.hold("details", Self.detailPaths)
        world.appleMDM.load()
        await eventually("a's first details held") { a.held == 1 }
        world.appleMDM.selection = "A0002"
        b.hold("list", Self.listPages)
        world.orgs.select("b")
        await eventually("b's list held") { b.held == 1 }
        world.appleMDM.pause()
        #expect(world.appleMDM.state == .idle && world.appleMDM.devices.isEmpty && world.appleMDM.selection == nil)
        await Self.settled(world, 2)
        a.release("details")
        b.release("list")
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.asked(world, "a").isEmpty && Self.asked(world, "b").isEmpty && Self.lists(world, "b") == 0)
        #expect(world.appleMDM.state == .idle && world.appleMDM.devices.isEmpty)
        // Back to a while away: nothing is read until the screen shows.
        world.orgs.select("a")
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.appleMDM.state == .idle && Self.lists(world, "a") == 1)
        world.appleMDM.load()
        await Self.settled(world, 3)
        #expect(world.appleMDM.rows.map(\.id) == ["A0000", "A0001", "A0002"] && world.appleMDM.rows.allSatisfy { $0.details.word == "Read" })
    }

    /// A switch after the screen was left with every detail read: the new org isn't read until the screen shows again.
    @Test func aSwitchWhileAwayReadsNothingUntilShown() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, "a", count: 2, prefix: "A")
        Self.fleet(world, "b", count: 1, prefix: "B")
        world.appleMDM.load()
        await Self.settled(world, 1)
        world.appleMDM.pause()
        world.orgs.select("b")
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.appleMDM.state == .idle && world.appleMDM.devices.isEmpty && Self.lists(world, "b") == 0)
        world.appleMDM.load()
        await Self.settled(world, 2)
        #expect(world.appleMDM.rows.map(\.id) == ["B0000"] && Self.asked(world, "b") == ["B0000/details"])
    }

    /// Leaving while a selected device past the limit is being read on its own: it says "Not read", never "Reading…" for
    /// good, Export isn't held for it, and coming back reads it (Phase 2b verifier round 1, mutants
    /// N-pauseSkipsInFlightSelected and N-resumeNoSelected).
    @Test func aPauseDuringASelectionsOwnReadReadsItOnReturn() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: AppleMDMModel.detailLimit + 2)
        world.appleMDM.load()
        await Self.settled(world, 1)
        let target = String(format: "M%04d", AppleMDMModel.detailLimit + 1)
        let gate = world.gates["a"]!
        gate.hold("own", { $0.path() == "/v1/mdmDevices/\(target)/details" })
        world.appleMDM.selection = target
        await eventually("the selection's own read held") { gate.held == 1 }
        #expect(Self.row(world, target)?.details.word == "Reading…")
        world.appleMDM.pause()
        #expect(Self.row(world, target)?.details.word == "Not read")
        #expect(world.appleMDM.exportBlocked == nil, "nothing is still being read")
        await Self.settled(world, 2)
        gate.release("own")
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.row(world, target)?.details.word == "Not read", "the stopped read landed")
        world.appleMDM.load()
        await eventually("the selection read again on return") { Self.row(world, target)?.details.word == "Read" }
        // The stopped read never reached Apple: the one asked is the return's.
        #expect(Self.asked(world).filter { $0.hasPrefix(target) } == ["\(target)/details"] && Self.lists(world) == 1, "\(Self.asked(world).suffix(3))")
    }

    /// A role refused details isn't asked again when the screen is shown again: the refusal holds until a Refresh (Phase 2b
    /// verifier round 1, mutant N-resumeAfterRefusal).
    @Test func comingBackAfterARefusalAsksNothing() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, count: 3)
        world.stubs["a"]!.forbid("/v1/mdmDevices/")
        world.appleMDM.load()
        await Self.settled(world, 1)
        #expect(Self.asked(world) == ["M0000/details"])
        world.appleMDM.pause()
        world.appleMDM.load()
        try await Task.sleep(for: .milliseconds(150))
        #expect(Self.asked(world) == ["M0000/details"], "a refused read was asked again")
        #expect(world.appleMDM.rows.map(\.details.word) == ["Role can't read", "Not read", "Not read"])
        #expect(world.appleMDM.detailsNote?.hasPrefix("Your role can't read Apple MDM device details") == true, "\(world.appleMDM.detailsNote ?? "nil")")
    }

    /// Shown again after a pause, the screen is showing: an org switch then reads the new org at once (Phase 2b verifier
    /// round 1, mutant N-pausedNeverCleared: the pause outlived the return, and the switch read nothing).
    @Test func aSwitchAfterComingBackReadsTheNewOrg() async throws {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        Self.fleet(world, "a", count: 1, prefix: "A")
        Self.fleet(world, "b", count: 1, prefix: "B")
        world.appleMDM.load()
        await Self.settled(world, 1)
        world.appleMDM.pause()
        world.appleMDM.load()
        await Self.settled(world, 2)
        world.orgs.select("b")
        await eventually("b read while showing") { world.appleMDM.rows.map(\.id) == ["B0000"] }
        await Self.settled(world, 3)
        #expect(Self.isLoaded(world.appleMDM.state) && Self.asked(world, "b") == ["B0000/details"])
    }
}
