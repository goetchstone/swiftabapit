import AppModels
import Foundation
import JSONAPI
import Mosyle
import Orgs
import Reports
import Testing
import TestSupport

/// The Mosyle screen, the reconciliation and Device 360's Mosyle half, through the strict `MosyleStub` (plan Phase 7). Mosyle
/// stays optional: an Apple org with no Mosyle org paired says so in every Mosyle list, sends nothing, and the Apple screens
/// are untouched.
@Suite("Mosyle screens")
@MainActor
struct MosyleScreenTests {
    /// A raw Mosyle device, as the list sends it.
    static func device(_ serial: String, os: String = "mac", version: String = "26.1", beat: Date? = Date(), udid: String? = nil) -> JSONObject {
        var raw: JSONObject = ["serial_number": .string(serial), "deviceudid": .string(udid ?? "UDID-\(serial)"), "device_name": .string("Device \(serial)"),
                               "device_model_name": .string(os == "mac" ? "MacBook Air" : "iPhone 16"), "os": .string(os), "osversion": .string(version),
                               "activation_bypass": .string("CANARY-BYPASS"), "status": .string("enrolled")]
        if let beat { raw["date_last_beat"] = .string(String(Int(beat.timeIntervalSince1970))) }
        return raw
    }

    static let notPaired = "Mosyle Business isn't in scope for Org a: no Mosyle Business organization is paired with it. Pair one in Settings."

    static func loaded(_ state: LoadState) -> Bool { if case .loaded = state { true } else { false } }

    @Test func anAppleOrgWithNoPairSaysMosyleIsntInScopeAndSendsNothing() async throws {
        let world = try await World.make()
        world.mosyle.load()
        for tab in MosyleModel.Tab.allCases { world.mosyle.tab = tab }
        let lists = [world.mosyle.devices.state, world.mosyle.users.state, world.mosyle.userGroups.state, world.mosyle.deviceGroups.state]
            + [world.mosyle.attributes.state, world.mosyle.adminLog.state]
        #expect(lists.allSatisfy { $0 == .notInScope(Self.notPaired) }, "\(lists)")
        #expect(world.mosyle.devices.unavailable == Self.notPaired)
        #expect(world.mosyle.reportNote == Self.notPaired)
        #expect(world.reconciliation.note == Self.notPaired && world.reconciliation.isNotInScope && world.reconciliation.report == nil)
        world.reconciliation.load(force: true)
        world.detail.show("ADEV0000001")
        if case .notInScope(let why) = world.detail.mosyleSide { #expect(why == Self.notPaired) } else { Issue.record("\(world.detail.mosyleSide)") }
        #expect(world.mosyleStub.requests.isEmpty)
        #expect(world.orgs.mosyleOrg == nil && world.orgs.mosyleClient == nil && !world.orgs.reconciles)
    }

    @Test func noOrganizationAndAPairGoneSayWhy() async throws {
        let none = try await World.make(profiles: [])
        none.mosyle.load()
        #expect(none.mosyle.devices.state == .unusable("No organization yet: add an Apple Business or Mosyle Business organization in Settings."))
        // Removing the paired Mosyle org clears what was read from it, and says the pair is gone.
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        try await world.orgs.remove("m", deleteSecrets: true)
        #expect(world.orgs.mosyleUnavailable?.why == Self.notPaired && world.orgs.store["a"]?.pairedOrg == "")
        #expect(world.mosyle.devices.rows.isEmpty && world.mosyle.devices.state == .notInScope(Self.notPaired))
        // A pair naming an org that isn't there (a profile written elsewhere), or one that isn't Mosyle.
        var dangling = World.profile("a")
        dangling.pairedOrg = "gone"
        let lone = try await World.make(profiles: [dangling])
        #expect(lone.orgs.mosyleUnavailable?.why == "The organization paired with Org a has been removed. Pair another in Settings.")
        var apple = World.profile("a")
        apple.pairedOrg = "b"
        let twoApple = try await World.make(profiles: [apple, World.profile("b")])
        #expect(twoApple.orgs.mosyleUnavailable?.why
                == "Org a is paired with Org b, which isn't a Mosyle Business organization. Pair a Mosyle Business one in Settings.")
        #expect(twoApple.orgs.mosyleUnavailable?.notInScope == true && twoApple.orgs.mosyleOrg == nil)
    }

    @Test func aPairedOrgsDevicesAreReadFirstAndEachTabWhenShown() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1"), Self.device("MAC2")], os: "mac")
        world.mosyleStub.add(devices: [Self.device("IOS1", os: "ios")], os: "ios")
        world.mosyleStub.add(users: [["iduser": .string("U1"), "name": .string("Ada"), "email": .string("ada@example.com"), "password": .string("CANARY")]])
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        // Platform by platform, iOS first (`MosyleRead.platforms`).
        #expect(world.mosyle.devices.rows.map(\.serial) == ["IOS1", "MAC1", "MAC2"])
        #expect(world.mosyle.users.state == .idle && !world.mosyleStub.requests.contains { $0.contains("/v1/users") })
        world.mosyle.tab = .users
        #expect(world.mosyle.users.state.isLoading)
        await eventually("users") { Self.loaded(world.mosyle.users.state) }
        #expect(world.mosyle.shown(world.mosyle.users).map(\.name) == ["Ada"])
        #expect(!world.mosyle.csv(.users).contains("CANARY") && !world.mosyle.csv(.devices).contains("CANARY"))
        // An unforced load reads nothing again; Refresh reads the devices and the tab on screen.
        let asked = world.mosyleStub.requests.count
        world.mosyle.load()
        #expect(world.mosyleStub.requests.count == asked)
        world.screens.refresh(.mosyle)
        #expect(world.mosyle.devices.state.isLoading && world.mosyle.users.state.isLoading)
        await eventually("read again") { Self.loaded(world.mosyle.devices.state) && Self.loaded(world.mosyle.users.state) }
        #expect(world.mosyle.devices.rows.count == 3, "a Refresh doesn't add to what was read")
    }

    @Test func aMosyleOrgShowsItsOwnSectionsAndReadsItself() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.orgs.select("m")
        #expect(SidebarItem.shown(for: world.orgs.active) == [.mosyle, .settings])
        #expect(SidebarItem.showing(.devices, for: world.orgs.active) == .mosyle)
        #expect(world.orgs.mosyleOrg?.id == "m" && !world.orgs.reconciles)
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        #expect(world.mosyle.devices.rows.map(\.serial) == ["MAC1"])
        world.devices.load()
        #expect(world.devices.state == .unusable(
            "This organization can't be used: Mosyle m is a Mosyle Business organization: Apple Business's and Apple School Manager's screens don't read it."))
        #expect(world.reconciliation.note == "Reconciliation runs from an Apple organization paired with a Mosyle Business one.")
    }

    /// An org switch drops everything the old Mosyle org read, selections included, and reads again if the screen was
    /// showing: the new org's Mosyle, or its sentence. (Choosing a pair in Settings, which is an org switch too, arrives
    /// with the Mosyle org editor.)
    @Test func anOrgSwitchClearsMosyleAndReadsAgain() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        world.mosyle.selectedDevice = "MAC1"
        world.mosyle.tab = .users
        await eventually("users") { Self.loaded(world.mosyle.users.state) }
        world.orgs.select("b")
        #expect(world.mosyle.devices.rows.isEmpty && world.mosyle.selectedDevice == nil && world.mosyle.users.rows.isEmpty)
        #expect(world.mosyle.devices.state == .notInScope(Self.notPaired.replacingOccurrences(of: "Org a", with: "Org b")))
        #expect(world.mosyle.users.state == .notInScope(Self.notPaired.replacingOccurrences(of: "Org a", with: "Org b")))
        world.orgs.select("a")
        #expect(world.mosyle.devices.state.isLoading && world.mosyle.users.state.isLoading)
        await eventually("devices again") { Self.loaded(world.mosyle.devices.state) && Self.loaded(world.mosyle.users.state) }
        #expect(world.mosyle.devices.rows.map(\.serial) == ["MAC1"])
    }

    /// A read a Refresh superseded writes nothing, its held page included.
    @Test func aSupersededReadWritesNothing() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: (0..<3).map { Self.device("MAC\($0)") }, os: "mac")
        world.mosyleStub.holdRequests(to: "/v1/devices", fromPage: 1)
        world.mosyle.load()
        await eventually("held") { world.mosyleStub.requests.contains { $0.contains("/v1/devices") } }
        #expect(world.mosyle.devices.state == .loading(count: 0))
        world.mosyle.load(force: true)
        world.mosyleStub.release()
        await eventually("both reads returned") { world.mosyle.readsFinished >= 2 && Self.loaded(world.mosyle.devices.state) }
        #expect(world.mosyle.devices.rows.map(\.serial) == ["MAC0", "MAC1", "MAC2"])
    }

    @Test func aListCutAtTheCapSaysSoAndTheReportsWait() async throws {
        let world = try await World.make(mosyle: true, mosylePageCap: 1)
        world.mosyleStub.add(devices: (0..<60).map { Self.device(String(format: "MAC%03d", $0)) }, os: "mac")
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        #expect(world.mosyle.devices.rows.count == 50 && world.mosyle.devices.truncated)
        #expect(world.mosyle.note(.devices) == nil, "the banner says the cut")
        #expect(world.mosyle.osBreakdown == nil && world.mosyle.stale() == nil)
        #expect(world.mosyle.note(.osVersions)?.hasPrefix("Mosyle's device list stopped at the page limit (50 devices read)") == true)
        #expect(world.mosyle.exportBlocked(.devices) == nil, "a cut list exports, as its note says it was cut")
        #expect(world.mosyle.exportBlocked(.osVersions) == world.mosyle.reportNote, "why, not \"nothing to export\"")
    }

    @Test func aListThatFailsPartWayIsPartialAndDoesntExport() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: (0..<60).map { Self.device(String(format: "MAC%03d", $0)) }, os: "mac")
        world.mosyleStub.queue(500, for: "/v1/devices", page: 2)
        world.mosyle.load()
        await eventually("failed") { if case .failed = world.mosyle.devices.state { true } else { false } }
        #expect(world.mosyle.devices.state == .failed("Mosyle's service failed (HTTP 500). Try again later."))
        #expect(world.mosyle.devices.partialCount == 50)
        #expect(world.mosyle.exportBlocked(.devices) == "The list is partial: 50 devices were read before the error. Refresh, then export.")
        #expect(world.mosyle.note(.devices) == nil, "the banner says the partial read")
    }

    @Test func aRefusedColumnIsSaidBesideTheDevices() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.mosyleStub.lackColumns(["imei"])
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        #expect(world.mosyle.columnFallback == .without(["imei"]))
        #expect(world.mosyle.note(.devices) == "Mosyle refused the columns imei, so they were left out of the request.")
    }

    @Test func aGroupsMembersAreReadWhenChosenAndNamedByTheirDevices() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1"), Self.device("MAC2")], os: "mac")
        world.mosyleStub.add(deviceGroups: [["iddevicegroup": .string("G1"), "name": .string("Studio"), "device_numbers": .string("3")]], os: "mac")
        world.mosyleStub.add(members: [("UDID-MAC1", true), ("UDID-MAC2", false), ("UDID-GONE", true)], toGroup: "G1")
        world.mosyle.load()
        world.mosyle.tab = .deviceGroups
        await eventually("lists") { Self.loaded(world.mosyle.devices.state) && Self.loaded(world.mosyle.deviceGroups.state) }
        #expect(world.mosyle.deviceGroups.rows.map(\.name) == ["Studio"])
        world.mosyle.selectedGroup = "G1"
        #expect(world.mosyle.hasSelection && world.mosyle.group?.name == "Studio")
        await eventually("members") { world.mosyle.members.readsFinished >= 1 }
        #expect(world.mosyle.memberRows.map(\.name) == ["Device MAC1", "Device MAC2", "UDID-GONE"])
        #expect(world.mosyle.memberNote == "1 member isn't in Mosyle's device list: shown by UDID.")
        world.mosyle.memberFilter = .compliant
        await eventually("compliant members") { world.mosyle.members.readsFinished >= 2 }
        #expect(world.mosyle.memberRows.map(\.udid) == ["UDID-MAC1", "UDID-GONE"])
        #expect(world.mosyleStub.bodies.last?["options"]?["security_compliance_status"] == .string("compliant"))
        // A group Mosyle no longer has says so in its own panel.
        world.mosyle.selectedGroup = "G9"
        await eventually("missing group") { world.mosyle.members.readsFinished >= 3 }
        if case .failed(let why) = world.mosyle.members.panel { #expect(why == "Mosyle answered DEVICEGROUP_NOTFOUND: Device group not found") }
        else { Issue.record("\(world.mosyle.members.panel)") }
        #expect(world.mosyle.selectionNote == "This device group isn't in the list Mosyle sent.")
    }

    /// A record no source shows is cut to the fields guessed at, and the fields Mosyle sent besides are named: a wrong guess
    /// is seen on the first live read (invariant 8), its values never shown (invariant 11).
    @Test func attributesAndTheAdminLogSayWhatTheyDidntRead() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(customAttributes: [["name": .string("Cost centre"), "value": .string("Ops"), "secret_note": .string("CANARY")]], os: "ios")
        world.mosyleStub.add(adminLogs: [["date": .string(Self.day(Date())), "user": .string("ada@example.com"), "action": .string("Signed in"),
                                          "session": .string("CANARY")]])
        world.mosyle.load()
        world.mosyle.tab = .attributes
        await eventually("attributes") { Self.loaded(world.mosyle.attributes.state) }
        #expect(world.mosyle.shown(world.mosyle.attributes).map(\.title) == ["Cost centre"])
        #expect(world.mosyle.note(.attributes) == "Mosyle sent fields this version doesn't read, so they aren't shown or exported: secret_note.")
        #expect(!world.mosyle.csv(.attributes).contains("CANARY") && !world.mosyle.csv(.attributes).contains("Ops"))
        world.mosyle.tab = .adminLog
        await eventually("admin log") { Self.loaded(world.mosyle.adminLog.state) }
        #expect(world.mosyle.shown(world.mosyle.adminLog).map(\.title) == ["Signed in"])
        #expect(world.mosyle.note(.adminLog) == "Mosyle sent fields this version doesn't read, so they aren't shown or exported: session.")
        #expect(!world.mosyle.csv(.adminLog).contains("CANARY"))
        let asked = world.mosyle.readsFinished
        world.mosyle.adminDays = 7
        #expect(world.mosyle.adminLog.state.isLoading)
        await eventually("admin log again") { world.mosyle.readsFinished > asked && Self.loaded(world.mosyle.adminLog.state) }
        let start = world.mosyleStub.bodies.last?["filter_options"]?["start_date"]?.string
        #expect(start == Self.day(Date().addingTimeInterval(-6 * 86_400)).prefix(10).description)
    }

    /// An answer this app can't read fails its own tab, in Mosyle's words, and the others read.
    @Test func aTabsUnreadableAnswerFailsThatTabOnly() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.mosyleStub.queue(200, for: "/v1/adminlogs", body: #"{"status":"OK","response":[{"entries":[]}]}"#)
        world.mosyle.load()
        world.mosyle.tab = .adminLog
        await eventually("both") { Self.loaded(world.mosyle.devices.state) && !world.mosyle.adminLog.state.isLoading }
        #expect(world.mosyle.adminLog.state == .failed(
            "Mosyle's answer couldn't be read as a list: it has no logs or adminlogs or admin_logs list and no end-of-list status. Nothing was read from it."))
        #expect(world.mosyle.devices.rows.count == 1)
    }

    @Test func theReportsCountAWholeFleet() async throws {
        let world = try await World.make(mosyle: true)
        let now = Date()
        world.mosyleStub.add(devices: [Self.device("MAC1", version: "26.1", beat: now), Self.device("MAC2", version: "26.1", beat: now - 40 * 86_400),
                                       Self.device("MAC3", version: "15.7", beat: nil)], os: "mac")
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        #expect(world.mosyle.shownVersions.map { "\($0.version) \($0.count) \($0.percent)" } == ["26.1 2 66.7", "15.7 1 33.3"])
        #expect(world.mosyle.shownStale(now: now).map(\.serial) == ["MAC3", "MAC2"])
        world.mosyle.staleDays = 60
        #expect(world.mosyle.shownStale(now: now).map(\.serial) == ["MAC3"])
        #expect(world.mosyle.exportBlocked(.stale, now: now) == nil)
        #expect(world.mosyle.csv(.osVersions).hasPrefix("id,osVersion,count,percent\r\n26.1,26.1,2,66.7\r\n"))
        world.mosyle.search = "nothing like this"
        for tab in MosyleModel.Tab.allCases { #expect(world.mosyle.exportBlocked(tab, now: now) != nil, "\(tab)") }
    }

    @Test func theInspectorShowsTheDeviceAndItsDates() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [Self.device("MAC1")], os: "mac")
        world.mosyle.load()
        await eventually("devices") { Self.loaded(world.mosyle.devices.state) }
        world.mosyle.selectedDevice = "MAC1"
        let row = try #require(world.mosyle.device)
        let fields = MosyleModel.fields(of: row)
        #expect(fields.first == PeopleModel.Field("Serial", "MAC1") && fields.contains(PeopleModel.Field("OS version", "26.1")))
        #expect(!fields.contains { $0.value.contains("CANARY") })
        #expect(MosyleModel.timeline(of: row).map(\.kind) == ["beat"])
        // Mosyle's numbers as strings (defect 19), shown as numbers; anything else as sent.
        var numbers = Self.device("MAC2")
        (numbers["total_disk"], numbers["available_disk"], numbers["battery"]) = (.string("256.0000000000"), .string("79.26"), .string("0.81"))
        world.mosyleStub.add(devices: [numbers], os: "mac")
        world.mosyle.load(force: true)
        await eventually("again") { Self.loaded(world.mosyle.devices.state) }
        world.mosyle.selectedDevice = "MAC2"
        let shown = MosyleModel.fields(of: try #require(world.mosyle.device))
        #expect(shown.contains(PeopleModel.Field("Disk, GB", "256")) && shown.contains(PeopleModel.Field("Free, GB", "79.3")), "\(shown.filter { $0.label.contains("GB") })")
        #expect(shown.contains(PeopleModel.Field("Battery", "81%")))
        #expect(world.mosyle.csv(.devices).contains("256.0000000000"), "the CSV keeps Mosyle's text")
        world.mosyle.selectedDevice = "GONE"
        #expect(world.mosyle.selectionNote == "This device isn't in the list Mosyle sent.")
    }

    @Test func aRevokedTokenFailsInMosylesWords() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.revoke()
        world.mosyle.load()
        await eventually("failed") { if case .failed = world.mosyle.devices.state { true } else { false } }
        #expect(world.mosyle.devices.state == .failed(MosyleAPIError.unauthorized.message))
    }

    static func day(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format.string(from: date)
    }
}

/// Apple Business against Mosyle Business: one read of each, shared with the Devices and Mosyle screens, and a report only
/// over two lists read whole.
@Suite("Reconciliation")
@MainActor
struct ReconciliationTests {
    @Test func theReportJoinsBothReadsBySerial() async throws {
        let world = try await World.make(mosyle: true)
        // Org a's devices are ADEV0000000…2; Mosyle has two of them, one in lower case, and one Apple doesn't.
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000"), MosyleScreenTests.device("adev0000001"),
                                       MosyleScreenTests.device("MOSYLEONLY")], os: "mac")
        world.reconciliation.load()
        #expect(world.reconciliation.report == nil && world.reconciliation.note?.hasPrefix("Reading Apple Business's devices…") == true)
        await eventually("both reads") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole }
        let report = try #require(world.reconciliation.report)
        #expect(report.both.map(\.serial) == ["ADEV0000000", "ADEV0000001"])
        #expect(report.appleOnly.map(\.serial) == ["ADEV0000002"] && report.mosyleOnly.map(\.serial) == ["MOSYLEONLY"])
        #expect(world.reconciliation.summary == "2 in both, 1 in Apple Business only, 1 in Mosyle only: 50% of 4 serials enrolled.")
        #expect(world.reconciliation.title(.both) == "In both (2)")
        world.reconciliation.presence = .both
        #expect(world.reconciliation.shown.map(\.mosyleStatus) == ["enrolled", "enrolled"])
        let csv = world.reconciliation.csv()
        #expect(csv.split(separator: "\r\n").count == 5 && !csv.contains("CANARY"))
        #expect(world.reconciliation.exportBlocked == nil)
        world.reconciliation.search = "nothing like this"
        #expect(world.reconciliation.shown.isEmpty && world.reconciliation.exportBlocked == ScreenWords.nothingToExport)
        // Refresh reads both again, and the report is made again from the new reads.
        world.screens.refresh(.reconciliation)
        #expect(world.devices.state.isLoading && world.mosyle.devices.state.isLoading && world.reconciliation.report == nil)
        await eventually("read again") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole }
        #expect(world.reconciliation.report?.both.count == 2)
    }

    /// A list cut at the page cap, or failed, would put the devices it didn't read in the wrong column: no report.
    @Test func aCutOrFailedListMakesNoReport() async throws {
        let cut = try await World.make(mosyle: true, mosylePageCap: 1)
        cut.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        cut.reconciliation.load()
        await eventually("both reads") { cut.devices.devicesReadWhole && MosyleScreenTests.loaded(cut.mosyle.devices.state) }
        #expect(cut.reconciliation.report == nil)
        #expect(cut.reconciliation.note
                == "Mosyle's device list stopped at the page limit (50 devices read): a reconciliation would put the devices past it in the wrong column.")
        #expect(cut.reconciliation.exportBlocked == cut.reconciliation.note)
        let failed = try await World.make(mosyle: true)
        failed.mosyleStub.queue(500, for: "/v1/devices")
        failed.reconciliation.load()
        await eventually("failed") { if case .failed = failed.mosyle.devices.state { failed.devices.devicesReadWhole } else { false } }
        #expect(failed.reconciliation.note == "Mosyle's devices couldn't be read: Mosyle's service failed (HTTP 500). Try again later.")
    }
}

/// Device 360's Mosyle half: the shown device in the paired Mosyle org, found by serial in the Mosyle screen's read.
@Suite("Device 360, Mosyle")
@MainActor
struct Device360MosyleTests {
    @Test func theDeviceIsFoundByItsSerialWhateverMosylesCasing() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [MosyleScreenTests.device(" adev0000001 ")], os: "mac")
        world.detail.show("ADEV0000001")
        #expect(world.mosyle.devices.state.isLoading, "showing a device reads Mosyle's devices")
        await eventually("found") { if case .found = world.detail.mosyleSide { true } else { false } }
        await eventually("the Apple panels") { world.detail.readsFinished >= 4 && world.detail.timelineReadsFinished >= 1 }
        let kinds = world.detail.bothTimeline.map(\.kind)
        #expect(kinds.contains("beat") && kinds.contains("added"), "\(kinds)")
        // Found as soon as its page arrived; "not enrolled" only once every platform was read: until then it is "reading".
        await eventually("the whole Mosyle list") { world.mosyle.devices.isWhole }
        world.detail.show("ADEV0000002")
        if case .notFound(let why) = world.detail.mosyleSide { #expect(why == "Mosyle Business doesn't list this serial: it isn't enrolled there.") }
        else { Issue.record("\(world.detail.mosyleSide)") }
        // One read of the four platforms (the Macs' answered past their one page), shared by both devices shown.
        #expect(world.mosyleStub.requests.filter { $0.contains("/v1/devices") }.count == 5)
    }
}
