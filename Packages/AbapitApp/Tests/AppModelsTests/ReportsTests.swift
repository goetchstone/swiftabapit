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

/// The Reports screen (plan Phase 3; docs/domains/history.md, "The Reports screen"): six reports, each built from the data it is
/// meant to read. The sweep reports (Coverage, Out of warranty, Activation Lock, Fleet age's coverage column) read the latest
/// snapshot that read that sweep with that same snapshot's device list, never a live one; MDM migration and service health read the
/// live lists. A failed newest attempt, no snapshot, a part-read list, the caps and the unknown groups are said in words; a switch
/// clears everything; the CSV names its client only with several. Over the strict stub, into a real `SnapshotStore`.
@MainActor
@Suite("Reports screen", .serialized)
struct ReportsTests {
    static let base = ChangesTests.base
    static let day = ChangesTests.day
    /// The model's clock: twenty days after the first snapshot.
    static let now = Date(timeIntervalSince1970: base + 20 * day)

    static func device(_ id: String, order: String? = "2025-01-10T00:00:00Z", model: String = "MacBook Air") -> Resource {
        var attributes: JSONObject = ["serialNumber": .string(id), "deviceModel": .string(model), "productFamily": .string("Mac"), "status": .string("ASSIGNED"),
                                      "addedToOrgDateTime": .string("2025-01-12T00:00:00Z")]
        if let order { attributes["orderDateTime"] = .string(order) }
        return Resource(type: "devices", id: id, attributes: attributes)
    }

    static func care(_ serial: String, status: String = "ACTIVE", endsInDays: Double? = 30, extra: JSONObject = [:]) -> Resource {
        var attributes: JSONObject = ["serialNumber": .string(serial), "description": .string("AppleCare+"), "status": .string(status)]
        if let endsInDays { attributes["endDateTime"] = .string(iso(now.addingTimeInterval(endsInDays * day))) }
        for (key, value) in extra { attributes[key] = value }
        return Resource(type: "applecare", id: "\(serial):0", attributes: attributes)
    }

    static func lock(_ serial: String, locked: Bool, type: String?, extra: JSONObject = [:]) -> Resource {
        var attributes: JSONObject = ["isLocked": .bool(locked)]
        if let type { attributes["lockType"] = .string(type) }
        for (key, value) in extra { attributes[key] = value }
        return Resource(type: "activation_lock", id: serial, attributes: attributes)
    }

    static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)) }

    /// A model over `world`, its clock held at `now`, its history loaded.
    static func model(_ world: World) async -> ReportsModel {
        let model = world.screens.reports
        model.now = { now }
        await model.load()
        return model
    }

    /// Records a snapshot of org `org` `days` days after `base`.
    @discardableResult
    static func record(_ world: World, _ org: String = "a", days: Double, _ resources: [String: [Resource]], errors: [String: String] = [:],
                       notes: [String: String] = [:]) async throws -> Int64 {
        try await ChangesTests.record(world, org, days: days, resources, errors: errors, notes: notes)
    }

    static func titles(_ output: ReportsModel.Output) -> [String] { output.lines.map(\.title) }

    static func text(_ output: ReportsModel.Output) -> String { (output.source + output.summary + output.lines.map { $0.title + " " + $0.detail } + [output.judgesNothing ?? ""]).joined(separator: "\n") }

    // MARK: where each report's data comes from

    /// Coverage reads the newest snapshot that read AppleCare and that snapshot's own devices: a newer snapshot with other devices
    /// and no AppleCare isn't the source, and Apple is asked for nothing.
    @Test func coverageReadsTheLatestSweepSnapshotAndItsOwnDeviceList() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1"), Self.device("D2")], "applecare": [Self.care("D1", endsInDays: 30)]])
        try await Self.record(world, days: 14, ["devices": [Self.device("D1"), Self.device("D2"), Self.device("D3")]])
        let model = await Self.model(world)
        let output = model.build(.coverage, tokens: ["days": "90"])
        #expect(output.judgesNothing == nil && Self.titles(output) == ["D1"], "\(Self.text(output))")
        #expect(output.source[0].hasPrefix("From the snapshot of 21 Sep 2026, 20 days old."), "\(output.source)")
        // D3 is only in the newer snapshot, which didn't read AppleCare: it is nowhere in this report.
        #expect(!Self.text(output).contains("D3"))
        #expect(output.summary.contains { $0.contains("1 devices have ACTIVE coverage; 1 have none among the records read") }, "\(output.summary)")
        #expect(world.stubs["a"]!.requests.isEmpty, "the screen asked Apple for nothing: \(world.stubs["a"]!.requests)")
        #expect(output.canExport && output.fileBase == "coverage ending within 90 days (snapshot 20260921T141320Z)")
    }

    /// A live device list is never mixed with a snapshot's sweep: with the Devices model holding other devices, the sweep reports
    /// list only the snapshot's, and Fleet age with a snapshot uses the snapshot's devices and coverage.
    @Test func aLiveDeviceListIsNeverMixedWithASnapshotsSweep() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("SNAP1"), Self.device("SNAP2")], "applecare": [Self.care("SNAP1")],
                                               "activation_lock": [Self.lock("SNAP1", locked: true, type: "USER"), Self.lock("SNAP2", locked: false, type: nil)]])
        let model = await Self.model(world)
        world.devices.load()
        await eventually("the live devices") { world.devices.readsFinished >= 2 }
        #expect(world.devices.rows.count == 3)
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .activationLock, .fleetAge] {
            let output = model.build(report, tokens: report == .fleetAge ? ["years": "1"] : [:])
            let text = Self.text(output)
            #expect(!text.contains("ADEV"), "\(report): \(text)")
            if report != .coverage { #expect(text.contains("SNAP"), "\(report): \(text)") }
        }
        let age = model.build(.fleetAge, tokens: ["years": "1"])
        #expect(Self.titles(age).sorted() == ["SNAP1", "SNAP2"] && age.source[0].hasPrefix("From the snapshot of 21 Sep 2026"), "\(age.source)")
        #expect(age.lines.first { $0.title == "SNAP1" }?.detail.contains("AppleCare: active") == true && age.lines.first { $0.title == "SNAP2" }?.detail.contains("AppleCare: none active") == true)
        // The live reports use the live list.
        let live = model.build(.migration, tokens: [:])
        #expect(Self.titles(live).allSatisfy { $0.hasPrefix("ADEV") } && live.source[0].hasPrefix("Read live from Apple on "), "\(live.source)")
    }

    /// The newest attempt read none of the sweep: its code and the collector's note are said, and the last good copy is used with its
    /// own date and its own device list: no other snapshot's list is mixed in, in any report.
    @Test func aNewestAttemptThatReadNothingIsSaidAndTheLastGoodCopyUsed() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("OLD1")], "applecare": [Self.care("OLD1")]])
        try await Self.record(world, days: 14, ["devices": [Self.device("NEW1"), Self.device("NEW2")]], errors: ["applecare": "HTTP 500"],
                              notes: ["applecare": "2 of 2 not read: 2 failed twice (HTTP 500)"])
        let model = await Self.model(world)
        for report in [ReportsModel.Report.coverage, .outOfWarranty] {
            let output = model.build(report, tokens: [:])
            #expect(output.judgesNothing == nil && output.source[0].hasPrefix("From the snapshot of 21 Sep 2026, 20 days old."), "\(report): \(output.source)")
            #expect(!Self.text(output).contains("NEW"), "\(report) mixed in the failed attempt's devices: \(Self.text(output))")
            #expect(output.source.contains { $0.contains("The newest snapshot that read AppleCare coverage (5 Oct 2026) failed with HTTP 500: 2 of 2 not read: 2 failed twice (HTTP 500), so this is the last good copy, from 21 Sep 2026") }, "\(output.source)")
            #expect(output.summary[0] == "Read in full.", "the last good copy is a whole read: \(output.summary)")
        }
        #expect(Self.titles(model.build(.outOfWarranty, tokens: [:])) == ["OLD1"])
        // A newest attempt that failed before any item says so the same way.
        let second = try await World.make()
        try await Self.record(second, days: 0, ["devices": [Self.device("OLD1")], "activation_lock": [Self.lock("OLD1", locked: false, type: nil)]])
        try await Self.record(second, days: 14, ["devices": [Self.device("OLD1")]], errors: ["activation_lock": "HTTP 403 FORBIDDEN_ERROR"])
        let lock = await Self.model(second).build(.activationLock, tokens: [:])
        #expect(lock.source.contains { $0.contains("failed with HTTP 403 FORBIDDEN_ERROR, so this is the last good copy") }, "\(lock.source)")
    }

    /// The code is worded for what it is: a run's "not asked after HTTP 401" isn't "failed with" it.
    @Test func aFailureCodeIsWordedForWhatItIs() {
        func words(_ code: String, _ note: String? = nil) -> String {
            ReportsModel.failureWords(ReportsModel.Failure(takenAt: "2026-10-05T14:13:20Z", code: code, note: note), sweep: .activationLock)
        }
        #expect(words("not asked after HTTP 401") == "The newest snapshot that read Activation Lock (5 Oct 2026) didn't read it (not asked after HTTP 401)")
        #expect(words("not read: devices failed") == "The newest snapshot that read Activation Lock (5 Oct 2026) didn't read it (not read: devices failed)")
        #expect(words("HTTP 500", "1 of 6 not read") == "The newest snapshot that read Activation Lock (5 Oct 2026) failed with HTTP 500: 1 of 6 not read")
    }

    /// With no good copy the report judges nothing: said, with the code and the note, never a zero, and nothing to export.
    @Test func aFailedAttemptWithNoGoodCopyJudgesNothing() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]], errors: ["applecare": "HTTP 500"],
                              notes: ["applecare": "1 of 1 not read: 1 failed twice (HTTP 500)"])
        let model = await Self.model(world)
        for report in [ReportsModel.Report.coverage, .outOfWarranty] {
            let output = model.build(report, tokens: [:])
            let why = try #require(output.judgesNothing, "\(report)")
            #expect(why.contains("failed with HTTP 500: 1 of 1 not read: 1 failed twice (HTTP 500)") && why.contains("No earlier snapshot read AppleCare coverage") && why.contains("Snapshot now"), "\(why)")
            #expect(output.summary.isEmpty && output.lines.isEmpty && !output.canExport)
        }
        #expect(model.exportBlocked != nil)
    }

    /// A part-read newest sweep is used (the coordinating session's decision), over its own device list, and said, on screen and in
    /// the CSV's `listRead`: with no earlier copy, and with an older whole one it is the newest part read that is used.
    @Test func aPartReadSweepIsUsedAndSaidWithItsOwnDeviceList() async throws {
        let world = try await World.make()
        // An older whole copy over other devices; then a newer part read (the collector's `counts` and `errors` both).
        try await Self.record(world, days: 0, ["devices": [Self.device("OLD1")], "applecare": [Self.care("OLD1")], "activation_lock": [Self.lock("OLD1", locked: false, type: nil)]])
        try await Self.record(world, days: 14, ["devices": [Self.device("P1"), Self.device("P2"), Self.device("P3")],
                                                "applecare": [Self.care("P1")], "activation_lock": [Self.lock("P1", locked: true, type: "USER"), Self.lock("P2", locked: false, type: nil)]],
                              errors: ["applecare": "HTTP 500", "activation_lock": "HTTP 404"],
                              notes: ["applecare": "1 of 3 not read: 1 failed twice (HTTP 500)", "activation_lock": "1 of 3 not read: 1 failed twice (HTTP 404)"])
        let model = await Self.model(world)
        let care = model.build(.coverage, tokens: ["days": "90"])
        #expect(care.judgesNothing == nil && !Self.text(care).contains("OLD1"), "the newest part read is used, not the older whole copy: \(Self.text(care))")
        #expect(care.source[0].hasPrefix("From the snapshot of 5 Oct 2026, 6 days old."), "\(care.source)")
        #expect(care.source.contains { $0.contains("read AppleCare coverage only in part: the AppleCare coverage read was cut: HTTP 500 (1 of 3 not read: 1 failed twice (HTTP 500))") && $0.contains("a device with no record") }, "\(care.source)")
        #expect(care.summary[0].hasPrefix("Read in part: the AppleCare coverage read was cut: HTTP 500 (1 of 3 not read: 1 failed twice (HTTP 500)); in a part read a device with no record counts as not read"), "\(care.summary)")
        // P2 and P3 have no record: in a part read they count as not read, never as uncovered.
        #expect(care.summary.contains { $0.contains("1 devices have ACTIVE coverage; 0 have none among the records read; 2 had their coverage unread") }, "\(care.summary)")
        #expect(Self.titles(care) == ["P1"])
        let csv = model.csv(of: care)
        #expect(csv.contains(",read in part: the AppleCare coverage read was cut: HTTP 500 (1 of 3 not read: 1 failed twice (HTTP 500)); in a part read a device with no record counts as not read,"), "\(csv)")
        let warranty = model.build(.outOfWarranty, tokens: [:])
        let by = Dictionary(uniqueKeysWithValues: warranty.lines.map { ($0.title, $0) })
        #expect(by["P1"]?.group == "active" && by["P2"]?.group == "not-read" && by["P3"]?.group == "not-read" && by["OLD1"] == nil, "\(warranty.lines)")
        #expect(by["P2"]?.detail.contains("the sweep didn't reach this device") == true)
        #expect(warranty.summary[0].hasPrefix("Read in part: the AppleCare coverage read was cut"))
        let age = model.build(.fleetAge, tokens: ["years": "1"])
        #expect(age.summary[0].hasPrefix("Read in part: the AppleCare coverage read was cut") && Set(Self.titles(age)) == ["P1", "P2", "P3"])
        #expect(age.lines.first { $0.title == "P2" }?.detail.contains("AppleCare: not read") == true && age.lines.first { $0.title == "P1" }?.detail.contains("AppleCare: active") == true)
        // Activation Lock: a device with no item is not read; the rest are judged.
        let lock = model.build(.activationLock, tokens: [:])
        #expect(lock.summary[0].hasPrefix("Read in part: the Activation Lock read was cut: HTTP 404 (1 of 3 not read"), "\(lock.summary)")
        #expect(lock.lines.filter { $0.group == "not-read" }.map(\.title) == ["P3"] && lock.lines.filter { $0.group != "not-read" }.count == 2 && !Self.text(lock).contains("OLD1"))
        // The same with no earlier copy.
        let alone = try await World.make()
        try await Self.record(alone, days: 3, ["devices": [Self.device("P1"), Self.device("P2")], "applecare": [Self.care("P1")]], errors: ["applecare": "HTTP 500"])
        let only = await Self.model(alone).build(.coverage, tokens: [:])
        #expect(only.judgesNothing == nil && Self.titles(only) == ["P1"] && only.summary[0].hasPrefix("Read in part: the AppleCare coverage read was cut: HTTP 500;"), "\(only.summary)")
    }

    /// Through the real collector and the strict stub (as the review did): Activation Lock with one device answering 404 of 6 is
    /// used, marked part, five judged and one not read; AppleCare with one device failing twice is used by Coverage, Out of warranty
    /// and Fleet age, marked part, devices with no record not read; and a newer part read beats an older whole copy.
    @Test func aRealCollectorsPartReadSweepIsUsed() async throws {
        let world = try await SweepTests.world(devices: 6)
        let a = world.stubs["a"]!
        for _ in 0..<2 { a.queue(404, for: SweepTests.lock(3)) }
        let whole = try await SweepTests.recorded(world, [.appleCare])
        #expect(whole.summary.errors["applecare"] == nil)
        let part = try await SweepTests.recorded(world, [.activationLock])
        #expect(part.summary.errors["activation_lock"] == "HTTP 404" && part.summary.counts["activation_lock"] == 5)
        for _ in 0..<2 { a.queue(500, for: SweepTests.care(3)) }
        let care = try await SweepTests.recorded(world, [.appleCare])
        #expect(care.summary.errors["applecare"] == "HTTP 500")
        let model = world.screens.reports
        await model.load()
        let lock = model.build(.activationLock, tokens: [:])
        #expect(lock.judgesNothing == nil && lock.lines.count == 6 && lock.lines.filter { $0.group == "not-read" }.map(\.title) == [SweepTests.serial(3)], "\(lock.lines)")
        #expect(lock.lines.filter { $0.group != "not-read" }.count == 5 && lock.summary[0].hasPrefix("Read in part: the Activation Lock read was cut: HTTP 404"), "\(lock.summary)")
        #expect(!lock.source.contains { $0.localizedCaseInsensitiveContains("take another") })
        #expect(model.csv(of: lock).contains("read in part: the Activation Lock read was cut"))
        // AppleCare: the newest attempt (part) is used over the older whole copy; device 0 has records, the rest none on record or not reached.
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .fleetAge] {
            let output = model.build(report, tokens: report == .fleetAge ? ["years": "1"] : report == .coverage ? ["days": "90"] : [:])
            #expect(output.judgesNothing == nil && output.summary.first?.hasPrefix("Read in part: the AppleCare coverage read was cut: HTTP 500") == true, "\(report): \(output.summary) \(output.judgesNothing ?? "") \(output.problems)")
            #expect(output.source.first?.hasPrefix("From the snapshot of ") == true, "\(output.source)")
        }
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(warranty.lines.filter { $0.group == "not-read" }.count == 5 && warranty.lines.first { $0.group == "active" }?.title == SweepTests.serial(0), "\(warranty.lines)")
    }

    /// Different snapshots hold different devices: each sweep's report uses its own snapshot's list, never the other's.
    @Test func eachSweepUsesItsOwnSnapshotsDeviceList() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("A1"), Self.device("A2")], "applecare": [Self.care("A1")]])
        try await Self.record(world, days: 5, ["devices": [Self.device("L1"), Self.device("L2"), Self.device("L3")],
                                               "activation_lock": [Self.lock("L1", locked: true, type: "USER"), Self.lock("L2", locked: false, type: nil), Self.lock("L3", locked: false, type: nil)]])
        let model = await Self.model(world)
        #expect(Self.titles(model.build(.outOfWarranty, tokens: [:])).sorted() == ["A1", "A2"])
        let lock = model.build(.activationLock, tokens: [:])
        #expect(Self.titles(lock).sorted() == ["L1", "L2", "L3"] && !Self.text(lock).contains("A1"), "\(Self.text(lock))")
        #expect(lock.source[0].hasPrefix("From the snapshot of 26 Sep 2026"), "\(lock.source)")
        #expect(Self.titles(model.build(.fleetAge, tokens: ["years": "1"])).sorted() == ["A1", "A2"])
    }

    /// No snapshot has read the sweep: the report says it judges nothing and where to take one, never "0".
    @Test func noSnapshotMeansNothingJudgedAndNeverZero() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")]])
        let model = await Self.model(world)
        for (report, name) in [(ReportsModel.Report.coverage, "AppleCare coverage"), (.outOfWarranty, "AppleCare coverage"), (.activationLock, "Activation Lock")] {
            let output = model.build(report, tokens: [:])
            let why = try #require(output.judgesNothing, "\(report)")
            #expect(why.hasPrefix("No snapshot has read \(name), so this report judges nothing.") && why.contains("Activity › Changes › Snapshot now"), "\(why)")
            #expect(output.summary.isEmpty && output.lines.isEmpty && output.groups.isEmpty && !output.canExport, "\(report)")
        }
        // An empty history is the same words.
        let empty = await Self.model(try await World.make(profiles: [World.profile("b")]))
        #expect(empty.build(.coverage, tokens: [:]).judgesNothing?.hasPrefix("No snapshot has read AppleCare coverage") == true)
    }

    /// Fleet age with no AppleCare snapshot reads the live list with no coverage data, and says why the column is empty.
    @Test func fleetAgeWithoutASnapshotUsesTheLiveListAndSaysTheColumnIsEmpty() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("SNAP1")]])
        let model = await Self.model(world)
        // Loaded history, devices not yet read: the live list is "not read", said, never an empty fleet.
        model.select(.fleetAge)
        let waiting = model.build(.fleetAge, tokens: ["years": "1"])
        #expect(waiting.summary.first == "Not read: the device list is still being read. Nothing below can be judged." || waiting.summary.first == "Not read: the device list hasn't been read yet. Nothing below can be judged.", "\(waiting.summary)")
        await eventually("the live devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        let output = model.build(.fleetAge, tokens: ["years": "1"])
        #expect(Self.titles(output).sorted() == ["ADEV0000000", "ADEV0000001", "ADEV0000002"], "\(Self.text(output))")
        #expect(output.source.contains { $0.hasPrefix("The AppleCare column is empty. No snapshot has read AppleCare coverage. This screen doesn't read it") }, "\(output.source)")
        #expect(output.lines.allSatisfy { $0.detail.contains("AppleCare: not read by this screen") } && !Self.text(output).contains("SNAP1"))
        #expect(output.summary.contains("No coverage data was read: nothing is said about coverage."))
        // Selecting it asked the Devices model for the list: reads only.
        #expect(world.stubs["a"]!.requests.allSatisfy { $0.hasPrefix("POST") || $0.contains("/v1/orgDevices") || $0.contains("/v1/mdmServers") }, "\(world.stubs["a"]!.requests)")
    }

    /// The device list of the snapshot was cut at the page cap: said first, on screen and in the CSV's `listRead`; a list the
    /// snapshot didn't read judges nothing.
    @Test func aPartReadDeviceListIsSaidOnScreenAndInTheCSV() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1"), Self.device("D2")], "applecare": [Self.care("D1")]],
                              errors: ["devices": "page cap"], notes: ["devices": "stopped at the page limit: 2 of 5 read, more not read"])
        let model = await Self.model(world)
        let output = model.build(.coverage, tokens: ["days": "90"])
        #expect(output.summary[0] == "Read in part: the snapshot's device list was cut: page cap (stopped at the page limit: 2 of 5 read, more not read). The counts below cover only what was read.", "\(output.summary)")
        let rows = model.csv(of: output).split(separator: "\r\n").map(String.init)
        #expect(rows.count == 2 && rows[1].contains(",\"read in part: the snapshot's device list was cut: page cap"), "\(rows)")
        // The pure rule over summaries the store holds: counts and errors both is part; counts alone whole; neither not read.
        try await Self.record(world, days: 1, ["devices": [Self.device("D1")]])
        try await Self.record(world, days: 2, [:], errors: ["devices": "HTTP 403"])
        try await Self.record(world, days: 3, ["users": []])
        let summaries = try await world.history!.snapshots(org: world.orgs.active!)
        #expect(summaries.count == 4)
        #expect(ReportsModel.deviceList(summaries[0]) == .notRead("the snapshot has no device list"))
        #expect(ReportsModel.deviceList(summaries[1]) == .notRead("the snapshot's device list wasn't read (HTTP 403)"))
        #expect(ReportsModel.deviceList(summaries[2]) == .whole)
        #expect(ReportsModel.deviceList(summaries[3]).csvWords.hasPrefix("read in part: "))
    }

    /// A device the sweep has no status for is not read, never unlocked; an unknown lock type is shown raw and found by `lock:other`.
    @Test func activationLockNamesWhatItCouldntJudgeAndEveryUnknownType() async throws {
        let world = try await World.make()
        let devices = ["U1", "M1", "N1", "X1", "F1", "G1"].map { Self.device($0) }
        try await Self.record(world, days: 0, ["devices": devices, "activation_lock": [
            Self.lock("U1", locked: true, type: "USER"), Self.lock("M1", locked: true, type: "MDM"), Self.lock("N1", locked: false, type: nil),
            Self.lock("X1", locked: true, type: "BOGUS"),
            Resource(type: "activation_lock", id: "F1", attributes: ["lockType": .string("USER")]),
        ]])
        let model = await Self.model(world)
        let output = model.build(.activationLock, tokens: [:])
        let by = Dictionary(uniqueKeysWithValues: output.lines.map { ($0.title, $0) })
        #expect(by["U1"]?.detail.contains("blocks release: yes") == true && by["M1"]?.detail.contains("blocks release: no") == true)
        #expect(by["G1"]?.group == "not-read" && by["G1"]?.detail.contains("blocks release: not read") == true, "G1 has no status: not read, never unlocked")
        #expect(by["X1"]?.group == "lock:BOGUS" && by["X1"]?.detail.contains("lock: lock:BOGUS (lock:other)") == true, "an unknown type is named raw")
        #expect(by["F1"]?.group == "unclear", "no isLocked: unclear")
        #expect(output.summary.contains { $0.contains("lock type BOGUS") }, "\(output.summary)")
        // Every group is counted and the filter finds the unknown type.
        #expect(output.groups.first { $0.key == "lock:other" }?.count == 1 && output.groups.first { $0.key == "not-read" }?.count == 1)
        let filtered = model.build(.activationLock, tokens: ["group": "lock:other"])
        #expect(Self.titles(filtered) == ["X1"] && filtered.matching == 1)
        #expect(model.csv(of: output).contains("BOGUS"), "the unknown type is in the file")
    }

    /// Out of warranty keeps its four things apart, labels every estimate and shows the assumption; an unknown status is named, never
    /// counted as out of warranty.
    @Test func outOfWarrantyLabelsEveryEstimateAndNamesTheUnknownStatus() async throws {
        let world = try await World.make()
        let devices = [Self.device("ACT"), Self.device("INA"), Self.device("NOREC"), Self.device("ODD"), Self.device("NODATE", order: nil)]
        try await Self.record(world, days: 0, ["devices": devices, "applecare": [
            Self.care("ACT"), Self.care("INA", status: "INACTIVE", endsInDays: -100), Self.care("ODD", status: "SUSPENDED", endsInDays: nil),
        ]])
        let model = await Self.model(world)
        let output = model.build(.outOfWarranty, tokens: [:])
        #expect(output.estimateNote == WarrantyReport.assumption)
        let by = Dictionary(uniqueKeysWithValues: output.lines.map { ($0.title, $0) })
        #expect(by["INA"]?.detail.contains("estimate: past the assumed one year") == true && by["NOREC"]?.detail.contains("estimate: past the assumed one year") == true)
        #expect(by["NODATE"]?.detail.contains("estimate not possible: no order date") == true)
        #expect(by["ACT"]?.detail.contains("estimate") == false, "an active device has no estimate")
        #expect(by["ODD"]?.group == "status-unknown" && by["ODD"]?.detail.contains("SUSPENDED") == true && by["ODD"]?.detail.contains("estimate") == false)
        #expect(by["NOREC"]?.detail.contains("no coverage record (may mean no AppleCare, not expired)") == true)
        // Never an unlabelled date: every estimated end sits beside the word.
        for line in output.lines where line.detail.contains("ended ") { #expect(line.detail.contains("estimate:")) }
        #expect(output.groups.map(\.key) == WarrantyReport.fixedGroups + [WarrantyReport.estimatedPastToken])
        #expect(Self.titles(model.build(.outOfWarranty, tokens: ["group": "estimated-past-limit"])).sorted() == ["INA", "NOREC"])
        let csv = model.csv(of: output)
        #expect(csv.contains("estimate: past the assumed one year") && csv.contains("Estimate only: assumes Apple's one-year limited warranty"))
    }

    /// MDM migration over the live list: whole, then the page cap's part read said first with "showing N of ≥M"; before the read, not
    /// read, said.
    @Test func migrationReadsTheLiveListAndSaysAPartRead() async throws {
        let world = try await World.make(devices: ["a": 1001, "b": 1], pageCap: 1)
        let model = await Self.model(world)
        let before = model.build(.migration, tokens: [:])
        #expect(before.summary == ["Not read: the device list hasn't been read yet. Nothing below can be judged."] && before.lines.isEmpty, "\(before.summary)")
        model.select(.migration)
        await eventually("the live devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        let output = model.build(.migration, tokens: [:])
        #expect(output.source[0].hasPrefix("Read live from Apple on ") && output.source[0].contains(": the device list the Devices screen holds."), "\(output.source)")
        #expect(output.summary[0].hasPrefix("Read in part: showing 1,000 of ") && output.summary[0].contains("the list stopped at the page limit"), "\(output.summary)")
        #expect(output.matching == 1000 && output.lines.count == 200 && output.capNote == "Showing 200 of 1,000: the rest are in the CSV export.")
        #expect(model.csv(of: output).split(separator: "\r\n")[1].contains(",\"read in part: showing 1,000 of "))
        // A whole list says so.
        let whole = try await World.make(devices: ["a": 2, "b": 1])
        let wholeModel = await Self.model(whole)
        wholeModel.select(.migration)
        await eventually("the live devices") { whole.devices.state != .idle && !whole.devices.state.isLoading }
        #expect(wholeModel.build(.migration, tokens: [:]).summary[0] == "Read in full.")
    }

    /// Service health over the live services: the device counts are the ones the Devices model read whole; a service whose device
    /// list wasn't read says "not read", never a zero.
    @Test func serviceHealthUsesTheLiveServicesAndTheirReadCounts() async throws {
        let world = try await World.make()
        let a = world.stubs["a"]!
        a.add(services: [World.service("S1", name: "Main MDM"), World.service("S2", name: "Lab")])
        a.assign("ADEV0000000", to: "S1")
        a.forbid("/v1/mdmServers/S2/relationships")
        let model = await Self.model(world)
        model.select(.serviceHealth)
        await eventually("the live services") { world.devices.servicesState != .idle && !world.devices.servicesState.isLoading }
        let output = model.build(.serviceHealth, tokens: ["days": "30"])
        #expect(output.source[0].hasPrefix("Read live from Apple on ") && output.source[0].contains(": the services list the Services screen holds."), "\(output.source)")
        let by = Dictionary(uniqueKeysWithValues: output.lines.map { ($0.title, $0) })
        #expect(by["Main MDM"]?.detail.contains("devices: 1") == true, "\(by)")
        #expect(by["Lab"]?.detail.contains("devices: not read") == true, "\(by)")
        #expect(output.groups.map(\.key) == ServiceHealth.fixedGroups)
        #expect(model.csv(of: output).contains("not read"))
    }

    // MARK: filters and tokens

    @Test func tokensResolveThroughTheCatalogAndProblemsAreSaidAndNothingIsRun() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("U1")], "activation_lock": [Self.lock("U1", locked: true, type: "USER")],
                                               "applecare": [Self.care("U1")]])
        let model = await Self.model(world)
        // A catalog value normalizes; the report runs with it.
        let lock = model.build(.activationLock, tokens: ["Group": " LOCK:user "])
        #expect(lock.problems.isEmpty && lock.filters == ["Group: lock:USER"] && Self.titles(lock) == ["U1"], "\(lock.problems)")
        #expect(model.build(.migration, tokens: ["group": "status: success"]).problems.isEmpty)
        // A value off the list, a name it has no filter for, a bad number: problems in words, and the report isn't run.
        for (report, tokens, problem) in [
            (ReportsModel.Report.activationLock, ["group": "lock:bogus"], "lock:bogus isn't a group this report accepts"),
            (.activationLock, ["colour": "red"], "Activation Lock has no filter named colour"),
            (.serviceHealth, ["days": "soon"], "days must be a whole number of days"),
            (.serviceHealth, ["days": "5000"], "days must be a whole number of days from 1 to 1825"),
            (.coverage, ["days": "0"], "days must be a whole number of days from 1 to 1825"),
            (.coverage, ["days": "1826"], "days must be a whole number of days from 1 to 1825"),
            (.coverage, ["years": "3"], "AppleCare coverage ending has no filter named years"),
            (.fleetAge, ["years": "11"], "years must be a whole number of years from 1 to 10"),
            (.fleetAge, ["years": "0"], "years must be a whole number of years from 1 to 10"),
            (.fleetAge, ["years": "x"], "years must be a whole number of years from 1 to 10"),
        ] {
            let output = model.build(report, tokens: tokens)
            #expect(output.problems == [problem] && output.judgesNothing == "The filters weren't understood, so the report wasn't run." && output.built == nil, "\(report) \(tokens): \(output.problems)")
        }
        // The bounds are inclusive.
        #expect(model.build(.coverage, tokens: ["days": "1825"]).problems.isEmpty && model.build(.coverage, tokens: ["days": "1"]).problems.isEmpty)
        #expect(model.build(.fleetAge, tokens: ["years": "10"]).problems.isEmpty && model.build(.fleetAge, tokens: ["years": "1"]).problems.isEmpty)
        // The filters on screen are tokens through the same function.
        model.select(.coverage)
        model.coverageDays = 45
        #expect(model.tokens == ["days": "45"] && model.current.filters == ["Ending within 45 days"])
        model.select(.activationLock)
        model.setGroup("lock:bogus")
        #expect(model.group == nil, "a group the catalog doesn't list isn't taken")
        model.setGroup("unlocked")
        #expect(model.tokens == ["group": "unlocked"])
    }

    /// Coverage's window is the filter: a coverage ending after it isn't listed, and one ending inside it is.
    @Test func theCoverageWindowIsTheFilter() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("S"), Self.device("L")], "applecare": [Self.care("S", endsInDays: 20), Self.care("L", endsInDays: 200)]])
        let model = await Self.model(world)
        #expect(Self.titles(model.build(.coverage, tokens: ["days": "30"])) == ["S"])
        #expect(Self.titles(model.build(.coverage, tokens: ["days": "365"])) == ["S", "L"])
        #expect(model.build(.coverage, tokens: ["days": "30"]).filters == ["Ending within 30 days"])
    }

    /// Fleet age's years are the filter, the buckets are named, and an AppleCare column says which.
    @Test func fleetAgeBucketsAndCandidates() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("OLD", order: "2021-01-10T00:00:00Z"), Self.device("NEW", order: "2026-09-01T00:00:00Z")],
                                               "applecare": [Self.care("OLD")]])
        let model = await Self.model(world)
        let output = model.build(.fleetAge, tokens: ["years": "4"])
        #expect(Self.titles(output) == ["OLD"] && output.summary.contains("< 1 yr: 1") && output.summary.contains("4+ yrs: 1"), "\(output.summary)")
        #expect(output.lines[0].detail.contains("5.7 years") && output.lines[0].detail.contains("AppleCare: active"))
        #expect(model.csv(of: output).contains("OLD"))
    }

    // MARK: caps

    @Test func theDisplayCapIsSaidAndTheCSVHoldsEveryRow() async throws {
        let world = try await World.make()
        let serials = (0..<5).map { "C\($0)" }
        try await Self.record(world, days: 0, ["devices": serials.map { Self.device($0) }, "activation_lock": serials.map { Self.lock($0, locked: false, type: nil) }])
        let model = await Self.model(world)
        model.displayLimit = 2
        let output = model.build(.activationLock, tokens: [:])
        #expect(output.lines.count == 2 && output.matching == 5 && output.capNote == "Showing 2 of 5: the rest are in the CSV export.", "\(output.capNote ?? "")")
        #expect(model.csv(of: output).split(separator: "\r\n").count == 6, "the file holds every row")
        model.displayLimit = 5
        #expect(model.build(.activationLock, tokens: [:]).capNote == nil)
        // Coverage says its file holds the expiring coverages only.
        try await Self.record(world, days: 1, ["devices": serials.map { Self.device($0) }, "applecare": serials.map { Self.care($0) }])
        let reload = await Self.model(world)
        reload.displayLimit = 3
        let coverage = reload.build(.coverage, tokens: ["days": "90"])
        #expect(coverage.capNote == "Showing 3 of 5: the rest are in the CSV export. The file holds the expiring coverages only.", "\(coverage.capNote ?? "")")
    }

    // MARK: org kinds

    @Test func aSchoolOrgRefusesWhatItsAPIHasNotAndNoReportHere() throws {
        // A read School's API lacks is refused in words, with nothing sent.
        #expect(ReportsModel.refusal([.users], scope: .school) == "Apple School Manager's API has no users to read, so this report can't run for this organization. Nothing was sent.")
        #expect(ReportsModel.refusal([.users], scope: .business) == nil && ReportsModel.refusal([.users], scope: nil) == nil)
        // Every read each report makes is one School has: devices and services, with the sweeps' two reads and the services' device lists.
        for report in ReportsModel.Report.allCases {
            #expect(ReportsModel.refusal(report.reads, scope: .school) == nil, "\(report)")
            #expect(report.reads.allSatisfy { !$0.businessOnly })
        }
        let school = try String(contentsOf: Fixtures.contracts.appending(path: "apple/school-1.8.json"), encoding: .utf8)
        for path in ["/v1/orgDevices", "/v1/mdmServers", "/v1/mdmServers/{id}/relationships/devices", "/v1/orgDevices/{id}/appleCareCoverage",
                     "/v1/orgDevices/{id}/activationLockStatus", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime", "isMdmMigrationCapable"] {
            #expect(school.contains("\"\(path)\"") || school.contains(path), "Apple School Manager's contract has \(path)")
        }
        #expect(Sweep.appleCare.rule.businessOnly == false && Sweep.activationLock.rule.businessOnly == false)
    }

    /// A School org's reports run over its own history and the same two lists, with no Business-only request.
    @Test func aSchoolOrgRunsTheReportsAndSendsNoBusinessOnlyRead() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "applecare": [Self.care("D1")]])
        let model = await Self.model(world)
        let output = model.build(.coverage, tokens: ["days": "90"])
        #expect(output.judgesNothing == nil && Self.titles(output) == ["D1"])
        model.select(.migration)
        await eventually("the live devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        #expect(model.build(.migration, tokens: [:]).judgesNothing == nil)
        let requests = world.stubs["a"]!.requests
        #expect(requests.filter { $0.hasPrefix("GET") }.allSatisfy { $0.contains("api-school.apple.com") } && requests.contains { $0.hasPrefix("GET") }, "\(requests)")
        #expect(!requests.contains { $0.contains("/v1/users") || $0.contains("/v1/mdmDevices") })
    }

    @Test func aMosyleOrgJudgesNothingAndSendsNothing() async throws {
        let world = try await World.make(mosyle: true)
        world.orgs.select("m")
        let model = await Self.model(world)
        for report in ReportsModel.Report.allCases {
            let output = model.build(report, tokens: [:])
            #expect(output.judgesNothing == ReportsModel.mosyleWords && output.lines.isEmpty && output.summary.isEmpty && !output.canExport, "\(report)")
        }
        model.select(.migration)
        #expect(model.state == .unusable(ReportsModel.mosyleWords))
        #expect(world.stubs["a"]!.requests.isEmpty && world.devices.state == .idle, "a Mosyle org reads nothing from Apple")
    }

    @Test func noOrgSaysSo() async throws {
        let world = try await World.make(profiles: [])
        let model = await Self.model(world)
        #expect(model.state == .unusable(ScreenWords.noOrganization))
        #expect(model.build(.coverage, tokens: [:]).judgesNothing == ScreenWords.noOrganization)
    }

    // MARK: this screen never reads Apple for a sweep

    @Test func theScreenNeverStartsASweepOrASnapshot() async throws {
        let world = try await World.make()
        let a = world.stubs["a"]!
        a.setCoverage("ADEV0000000", [Resource(type: "appleCareCoverage", id: "C1", attributes: ["status": .string("ACTIVE")])])
        a.setLock("ADEV0000000", isLocked: true, lockType: "USER")
        let model = await Self.model(world)
        for report in ReportsModel.Report.allCases {
            model.select(report)
            _ = model.current
            await eventually("\(report)") { !world.devices.state.isLoading && !world.devices.servicesState.isLoading }
        }
        world.screens.refresh(.reports)
        await eventually("refresh") { !world.devices.state.isLoading && !world.devices.servicesState.isLoading }
        let requests = a.requests
        #expect(!requests.isEmpty && requests.allSatisfy { !$0.contains("appleCareCoverage") && !$0.contains("activationLockStatus") && !$0.contains("/details") }, "\(requests)")
        #expect(try await world.history!.snapshots(org: world.orgs.active!).isEmpty, "no snapshot was taken")
        #expect(!world.snapshots.isRunning)
    }

    // MARK: the CSV

    /// One client: the file is named without one. Several: the client's name leads it. Its words say what it holds, and it
    /// leads with how much of the list was read.
    @Test func theCSVNamesTheClientOnlyWithSeveralAndSaysWhatItHolds() async throws {
        let resources: [String: [Resource]] = ["devices": [Self.device("D1")], "applecare": [Self.care("D1")], "activation_lock": [Self.lock("D1", locked: true, type: "USER")]]
        let one = try await World.make(profiles: [World.profile("a")], mosyle: true)
        try await Self.record(one, days: 0, resources)
        let single = await Self.model(one)
        #expect(!one.orgs.showsClients && single.exportFileName == "coverage ending within 90 days (snapshot 20260921T141320Z).csv", "\(single.exportFileName)")
        #expect(!single.exportWords.contains("client"), "\(single.exportWords)")
        single.select(.activationLock)
        #expect(single.exportFileName == "activation lock (snapshot 20260921T141320Z).csv")

        let two = try await World.make()
        try await Self.record(two, days: 0, resources)
        let several = await Self.model(two)
        #expect(two.orgs.showsClients && several.exportFileName == "Org a - coverage ending within 90 days (snapshot 20260921T141320Z).csv", "\(several.exportFileName)")
        #expect(several.exportWords.contains("client \"Org a\"'s data only"), "\(several.exportWords)")
        #expect(several.exportWords.hasPrefix("Saves the AppleCare coverage ending report for \"Org a\". From the snapshot of 21 Sep 2026, 20 days old."))
        #expect(several.exportWords.contains("A value under a secret's name is withheld. No key or token is in it."))
        #expect(several.csv().hasPrefix("id,listRead,serialNumber,"), "\(several.csv().prefix(60))")
        two.orgs.selectClient(try #require(two.orgs.store.client(of: "b")).id)
        #expect(several.exportFileName.hasPrefix("Org b - "), "\(several.exportFileName)")
        // A live report's file is named for the day it was read.
        several.select(.migration)
        await eventually("the devices") { two.devices.state != .idle && !two.devices.state.isLoading }
        guard case .loaded(let readAt) = two.devices.state else { Issue.record("the devices weren't read"); return }
        #expect(several.exportFileName == "Org b - mdm migration (read live \(ReportsModel.dayStamp(readAt))).csv", "the day the list was read: \(several.exportFileName)")
    }

    /// The CSV is each report's own columns: a secret-named attribute on a record or a status never leaves, and a lock's bypass code
    /// stays out.
    @Test func theCSVMasksSecretsThroughTheExistingPolicy() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, [
            "devices": [Self.device("D1")],
            "applecare": [Self.care("D1", extra: ["password": .string("CANARYPASSWORD"), "nested": .object(["token": .string("CANARYTOKEN")])])],
            "activation_lock": [Self.lock("D1", locked: true, type: "USER", extra: ["activation_bypass_code": .string("CANARYBYPASS")])],
        ])
        let model = await Self.model(world)
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .activationLock, .fleetAge] {
            let output = model.build(report, tokens: report == .fleetAge ? ["years": "1"] : [:])
            let csv = model.csv(of: output)
            #expect(!csv.isEmpty && !csv.contains("CANARY"), "\(report): \(csv)")
            #expect(!Self.text(output).contains("CANARY"), "\(report) on screen")
        }
    }

    // MARK: one org at a time

    /// A switch clears everything at once: nothing of org a is on screen, in a filter or in a CSV under b.
    @Test func aSwitchClearsEverythingAtOnce() async throws {
        let world = try await World.make()
        try await Self.record(world, "a", days: 0, ["devices": [Self.device("A1")], "applecare": [Self.care("A1")]])
        let model = await Self.model(world)
        model.select(.coverage)
        model.coverageDays = 400
        model.fleetYears = 7
        model.quietDays = 90
        #expect(Self.titles(model.current) == ["A1"] && !model.csv().isEmpty)
        model.select(.activationLock)
        model.setGroup("unlocked")
        #expect(model.group == "unlocked")
        world.orgs.select("b")
        #expect(model.sources.isEmpty && model.state == .idle)
        #expect(model.coverageDays == 90 && model.fleetYears == 4 && model.quietDays == 30 && model.report == .coverage && model.group == nil, "filters and the chosen report reset")
        let after = model.current
        #expect(after.lines.isEmpty && !after.canExport && !Self.text(after).contains("A1") && model.csv().isEmpty)
        await eventually("b's history read") { if case .loaded = model.state { true } else { false } }
        #expect(!Self.text(model.current).contains("A1"))
    }

    /// A read that returns after a switch is dropped (the generation guard), and one that returns after a newer load is dropped (the
    /// token guard): a hook switches orgs, or loads again, while the read is out.
    @Test func aReadThatReturnsAfterASwitchOrANewerLoadIsDropped() async throws {
        // The generation guard alone: the switch to b comes while a's read is out, and a's read returns before b's own load has begun
        // (a switch doesn't touch the token), so only the generation says it is a's.
        let world = try await World.make()
        try await Self.record(world, "a", days: 0, ["devices": [Self.device("A1")], "applecare": [Self.care("A1")]])
        let model = world.screens.reports
        model.now = { Self.now }
        var fired = false
        model.afterRead = { stage in
            guard stage == "load", !fired else { return }
            fired = true
            world.orgs.select("b")
        }
        await model.load()
        #expect(model.sources.isEmpty && model.state == .idle, "the read for a isn't shown under b: \(model.sources.keys)")
        #expect(!Self.text(model.build(.coverage, tokens: [:])).contains("A1"))
        await eventually("b's own load") { if case .loaded = model.state { true } else { false } }
        #expect(model.sources[.appleCare] == .unavailable(nil) && !Self.text(model.build(.coverage, tokens: [:])).contains("A1"))
        // And the same with b's own load finished before a's read returns.
        let third = try await World.make()
        try await Self.record(third, "a", days: 0, ["devices": [Self.device("A1")], "applecare": [Self.care("A1")]])
        let late = third.screens.reports
        late.now = { Self.now }
        var lateFired = false
        let before = late.loadsFinished
        late.afterRead = { stage in
            guard stage == "load", !lateFired else { return }
            lateFired = true
            third.orgs.select("b")
            await eventually("b's own load") { late.loadsFinished > before }
        }
        await late.load()
        #expect(late.sources[.appleCare] == .unavailable(nil), "the read for a isn't shown under b")

        // The token guard: a second load, over a newer snapshot, finishes while the first is out; the first returns after it.
        let second = try await World.make()
        try await Self.record(second, "a", days: 0, ["devices": [Self.device("OLD")], "applecare": [Self.care("OLD")]])
        let again = second.screens.reports
        again.now = { Self.now }
        var once = false
        again.afterRead = { stage in
            guard stage == "load", !once else { return }
            once = true
            _ = try? await Self.record(second, "a", days: 5, ["devices": [Self.device("NEWER")], "applecare": [Self.care("NEWER")]])
            await again.load()
        }
        await again.load()
        #expect(Self.titles(again.build(.coverage, tokens: ["days": "90"])) == ["NEWER"], "the older read didn't land over the newer: \(Self.titles(again.build(.coverage, tokens: ["days": "90"])))")
    }

    /// Phase 9: the one function a Siri intent calls builds any report from tokens, and reads nothing from Apple.
    @Test func oneFunctionBuildsAnyReportFromTokens() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "applecare": [Self.care("D1")], "activation_lock": [Self.lock("D1", locked: true, type: "USER")]])
        let model = await Self.model(world)
        for (report, tokens) in [(ReportsModel.Report.coverage, ["days": "90"]), (.fleetAge, ["years": "1"]), (.activationLock, ["group": "lock:USER"]),
                                 (.outOfWarranty, ["group": "active"]), (.migration, [:]), (.serviceHealth, ["days": "30", "group": "healthy"])] {
            let output = model.build(report, tokens: tokens)
            #expect(output.problems.isEmpty && output.title == report.title, "\(report)")
        }
        #expect(world.stubs["a"]!.requests.isEmpty)
    }

    // MARK: live part reads

    /// The services list cut at the page cap is a part read, said; never a whole one.
    @Test func aServicesListCutAtThePageCapIsSaidAsPartial() async throws {
        let world = try await World.make(pageCap: 1)
        world.stubs["a"]!.add(services: (0..<1001).map { World.service(String(format: "S%04d", $0), name: "Service \($0)") })
        let model = await Self.model(world)
        model.select(.serviceHealth)
        await eventually("the services") { world.devices.servicesState != .idle && !world.devices.servicesState.isLoading }
        let output = model.build(.serviceHealth, tokens: [:])
        #expect(output.summary[0] == "Read in part: showing 1,000 services: the list stopped at the page limit. The counts below cover only what was read.", "\(output.summary)")
        #expect(model.csv(of: output).contains(",\"read in part: showing 1,000 services"))
    }

    /// A device list refused part-way (the first page read, the next 403) is a part read, with the rows read, said.
    @Test func aDeviceListRefusedPartWayIsSaidAsPartial() async throws {
        let world = try await World.make(devices: ["a": 1001, "b": 1])
        world.stubs["a"]!.queue(403, for: "/v1/orgDevices?limit=1000&cursor=")
        let model = await Self.model(world)
        model.select(.migration)
        await eventually("the devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        #expect(world.devices.state == .forbidden && world.devices.rows.count == 1000)
        let output = model.build(.migration, tokens: [:])
        #expect(output.summary[0] == "Read in part: your role can't read devices; 1,000 were read before the refusal. The counts below cover only what was read.", "\(output.summary)")
        #expect(output.matching == 1000 && model.csv(of: output).contains(",\"read in part: your role can't read devices"))
    }

    /// A device list that failed part-way is a part read: the rows read, and why it stopped.
    @Test func aDeviceListThatFailedPartWayIsSaidAsPartial() async throws {
        let world = try await World.make(devices: ["a": 1001, "b": 1])
        for _ in 0..<6 { world.stubs["a"]!.queue(500, for: "/v1/orgDevices?limit=1000&cursor=") }
        let model = await Self.model(world)
        model.select(.migration)
        await eventually("the devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        guard case .failed = world.devices.state else { Issue.record("\(world.devices.state)"); return }
        let output = model.build(.migration, tokens: [:])
        #expect(output.summary[0].hasPrefix("Read in part: the read failed after 1,000 devices: ") && output.matching == 1000, "\(output.summary)")
    }

    /// A live list says when it was read and how old it is, from the Devices model's own read; the file's stamp is that day, not today.
    @Test func aLiveReportSaysWhenItsListWasRead() async throws {
        let world = try await World.make()
        let model = await Self.model(world)
        model.select(.migration)
        // Before anything was read: said, no date made up.
        #expect(model.build(.migration, tokens: [:]).source.first?.hasPrefix("Not read from Apple yet") == true)
        await eventually("the devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        guard case .loaded(let readAt) = world.devices.state else { Issue.record("\(world.devices.state)"); return }
        model.now = { readAt.addingTimeInterval(3 * 86_400 + 60) }
        let output = model.build(.migration, tokens: [:])
        #expect(output.source[0] == "Read live from Apple on \(ReportsModel.dayTime(readAt)), 3 days old: the device list the Devices screen holds. No snapshot is used.", "\(output.source)")
        #expect(output.fileBase == "mdm migration (read live \(ReportsModel.dayStamp(readAt)))" && ReportsModel.dayTime(readAt).hasSuffix(" UTC"))
    }

    // MARK: building and redrawing

    /// One build per redraw: the view builds the report once and asks the same output for the Export button, the file name and the panel's
    /// words. At 10,000 devices a build is real work.
    @Test func aRedrawBuildsTheReportOnce() async throws {
        let world = try await World.make()
        let serials = (0..<10_000).map { String(format: "BIG%05d", $0) }
        try await Self.record(world, days: 0, ["devices": serials.map { Self.device($0) }, "activation_lock": serials.map { Self.lock($0, locked: false, type: nil) }])
        let model = await Self.model(world)
        model.select(.activationLock)
        let before = model.builds
        let output = model.current
        #expect(model.exportBlocked(for: output) == nil && model.exportFileName(for: output).hasSuffix(".csv") && model.exportWords(for: output).hasPrefix("Saves the Activation Lock report"))
        #expect(model.builds == before + 1, "the export values come from the one output")
        #expect(output.matching == 10_000 && output.lines.count == 200)
        // The date words are made by calendar, not a formatter per row: a coverage run over 10,000 devices stays quick.
        let clock = ContinuousClock()
        let took = clock.measure { _ = model.build(.activationLock, tokens: [:]) }
        #expect(took < .seconds(5), "a build of 10,000 devices took \(took)")
    }

    /// A missing token is the report's default, never the screen's stepper value (an intent has no stepper).
    @Test func aMissingTokenTakesTheReportsDefault() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "applecare": [Self.care("D1", endsInDays: 40)]])
        let model = await Self.model(world)
        model.coverageDays = 5
        model.fleetYears = 9
        model.quietDays = 400
        #expect(model.build(.coverage, tokens: [:]).filters == ["Ending within 90 days"] && Self.titles(model.build(.coverage, tokens: [:])) == ["D1"])
        #expect(model.build(.fleetAge, tokens: [:]).filters == ["Candidates: 4+ years old"])
        #expect(model.build(.serviceHealth, tokens: [:]).filters.contains("Quiet after 30 days"))
        // The screen passes its values explicitly.
        #expect(model.current.filters == ["Ending within 5 days"] && model.current.lines.isEmpty)
    }

    /// A record with no serial number is counted and said, and left out of the report; two expiring records of one device have two ids.
    @Test func aRecordWithNoSerialIsCountedAndRowsHaveUniqueIDs() async throws {
        let world = try await World.make()
        var attributes = Self.care("X", endsInDays: 10).attributes
        attributes["serialNumber"] = nil
        let orphan = Resource(type: "applecare", id: "orphan", attributes: attributes)
        let twin = Resource(type: "applecare", id: "D1:1", attributes: Self.care("D1", endsInDays: 20).attributes)
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "applecare": [Self.care("D1", endsInDays: 30), twin, orphan]])
        let model = await Self.model(world)
        let output = model.build(.coverage, tokens: ["days": "90"])
        #expect(output.source.contains("1 coverage record has no serial number and can't be matched to a device: counted here and left out of the report."), "\(output.source)")
        #expect(output.lines.count == 2 && Set(output.lines.map(\.id)).count == 2, "\(output.lines)")
    }

    // MARK: refresh

    /// ⌘R on Reports re-reads the history either way, and reads the live lists again only for a live report.
    @Test func refreshReadsTheHistoryAndTheLiveListsOnlyForALiveReport() async throws {
        let world = try await World.make()
        try await Self.record(world, days: 0, ["devices": [Self.device("D1")], "applecare": [Self.care("D1")]])
        let model = await Self.model(world)
        var before = model.loadsFinished
        world.screens.refresh(.reports)
        await eventually("the history again") { model.loadsFinished > before }
        #expect(world.devices.state == .idle && world.stubs["a"]!.requests.isEmpty, "a sweep report forces no Apple read")
        model.select(.migration)
        await eventually("the devices") { world.devices.state != .idle && !world.devices.state.isLoading }
        before = model.loadsFinished
        let reads = world.devices.readsFinished
        world.screens.refresh(.reports)
        #expect(world.devices.state.isLoading, "a live report reads its lists again")
        await eventually("the history and the lists again") { model.loadsFinished > before && world.devices.readsFinished >= reads + 2 }
    }

    /// Fleet age on screen with no AppleCare snapshot asks the Devices model for its list when the history load finishes.
    @Test func fleetAgeReadsTheLiveListWhenTheHistoryLoadFinishesWithNoSnapshot() async throws {
        let world = try await World.make()
        let model = world.screens.reports
        model.now = { Self.now }
        model.select(.fleetAge)
        #expect(world.devices.state == .idle, "nothing is read while the history is unknown")
        await model.load()
        #expect(world.devices.state != .idle, "the live list is read once it is known there is no snapshot")
        await eventually("the devices") { !world.devices.state.isLoading }
    }

    // MARK: the demo

    /// The demo's snapshot has a fake AppleCare and Activation Lock sweep, so every sweep report draws something, over a part-read
    /// device list (invariant 8), with fake serials only.
    @Test func theDemoHistoryFeedsTheSweepReports() async throws {
        let world = try await World.make()
        await DemoHistory.seed(world.history!, org: world.orgs.store["a"]!, now: Self.now)
        let model = await Self.model(world)
        let coverage = model.build(.coverage, tokens: ["days": "90"])
        #expect(Self.titles(coverage) == ["DEMOCHG0001"] && coverage.summary[0].hasPrefix("Read in part: the snapshot's device list was cut: page cap"), "\(Self.text(coverage))")
        let warranty = model.build(.outOfWarranty, tokens: [:])
        #expect(Self.titles(warranty).sorted() == ["DEMOCHG0001", "DEMOCHG0002", "DEMOCHG0003"] && warranty.lines.contains { $0.detail.contains("estimate: past the assumed one year") })
        let lock = model.build(.activationLock, tokens: [:])
        #expect(lock.lines.first { $0.title == "DEMOCHG0001" }?.detail.contains("blocks release: yes") == true)
        for output in [coverage, warranty, lock] { #expect(Self.text(output).contains("DEMOCHG") && !Self.text(output).contains("ADEV")) }
    }
}
