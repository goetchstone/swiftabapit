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

/// The answers an intent or the in-app Ask gives (the operator, 2026-11-24: Q1 "Six reports + more", Q4 "Yes, bounded", Q5 "Counts
/// aloud, 10 rows", Q6 "Active client, named"). Over the strict stubs and a real `SnapshotStore`: no serial or name is ever spoken
/// (canaries: serials `ADEV…`, `BDEV…`, `ZQXSER…`, services and Mosyle devices named `ZQX…`); each error kind is a fixed phrase and
/// its own text (a canary in Apple's `detail`, Mosyle's message, the snapshot's code and note, the history's message) is never said;
/// each report's judges-nothing, part, still-reading and switched words; one client never says "client", two name it; a Mosyle org
/// active and a School org say what the screens say; at most 10 rows with the cap said; a field the API didn't send is said.
@MainActor
@Suite("Answers", .serialized, .timeLimit(.minutes(1)))
struct AnswersTests {
    static let now = ReportsTests.now
    /// What must never be spoken: the fleets' serials and every planted name.
    static let canaries = ["ADEV", "BDEV", "ZQX"]

    /// Org `a` (and `b`, each its own client, unless `oneClient`) with two services named `ZQX…`, ADEV0000000 on S1 and
    /// ADEV0000001 on S2; Mosyle org `m` in a's client (when `mosyle`) with ADEV0000000 and ZQXMAC1, named "Device …".
    static func world(devices: Int = 3, pageCap: Int = AppleClient.defaultPageCap, mosyle: Bool = true, oneClient: Bool = false,
                      scope: Scope = .business, history: (@MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>)? = nil) async throws -> World {
        let profiles: [OrgProfile]? = oneClient ? [World.profile("a", scope: scope)] : scope == .business ? nil : [World.profile("a", scope: scope), World.profile("b")]
        let world = try await World.make(devices: ["a": devices, "b": 2], pageCap: pageCap, profiles: profiles, mosyle: mosyle, history: history)
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("S1", name: "ZQXNAME-One"), World.service("S2", name: "ZQXNAME-Two")])
        stub.assign("ADEV0000000", to: "S1")
        stub.assign("ADEV0000001", to: "S2")
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000"), MosyleScreenTests.device("ZQXMAC1")], os: "mac")
        return world
    }

    /// The world's answers, the bound on `timer`; `fixed` holds every clock at `now` (the snapshot tests' dates).
    static func answers(_ world: World, _ timer: ManualTimer = ManualTimer(), fixed: Bool = false) -> Answers {
        let answers = world.screens.answers
        answers.sleep = { try await timer.sleep($0) }
        world.screens.reports.dates = ReportsTests.dates
        world.screens.attention.dates = ReportsTests.dates
        if fixed {
            answers.now = { now }
            world.screens.reports.now = { now }
            world.screens.attention.now = { now }
        }
        return answers
    }

    static func device(_ serial: String) -> Resource { ReportsTests.device(serial) }

    /// A snapshot of org `a` with `serials`' devices, each with AppleCare and Activation Lock read.
    static func snapshot(_ world: World, _ serials: [String] = ["ZQXSER1", "ZQXSER2", "ZQXSER3"], errors: [String: String] = [:],
                         notes: [String: String] = [:]) async throws {
        try await ReportsTests.record(world, days: 0, ["devices": serials.map(device), "applecare": serials.map { ReportsTests.care($0, endsInDays: 20) },
                                                       "activation_lock": serials.map { ReportsTests.lock($0, locked: true, type: "USER") }],
                                      errors: errors, notes: notes)
    }

    static func expectNoCanary(_ answer: Answers.Answer, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for canary in canaries {
            #expect(!answer.spoken.contains(canary) && !answer.lead.contains(canary), "\(what) said \(canary): \(answer.spoken)", sourceLocation: sourceLocation)
        }
        #expect(!answer.rows.contains { $0.model.contains("ZQX") || $0.serial.contains("ZQXNAME") || $0.serial.contains("ZQXMAC") },
                "\(what) showed a name: \(answer.rows)", sourceLocation: sourceLocation)
    }

    /// Org `a`'s requests, by path, never a device's own.
    static func paths(_ world: World) -> [String] { world.stubs["a"]!.requests.map(LiveWaitTests.path(of:)) }

    static let appleDetail = #"{"errors":[{"id":"e1","status":"400","code":"PARAMETER_ERROR.INVALID","title":"Invalid","detail":"ZQXDETAIL a tenant's words"}]}"#

    // MARK: the catalog

    /// Every report the screen has is in the catalog, and every catalog entry is a report: `catalogID` can't trap.
    @Test func everyReportMapsToACatalogEntry() {
        for report in ReportsModel.Report.allCases {
            #expect(ReportCatalog.ID(rawValue: report.rawValue) != nil, "\(report)")
        }
        #expect(Set(ReportsModel.Report.allCases.map(\.rawValue)) == Set(ReportCatalog.ID.allCases.map(\.rawValue)))
        #expect(Set(ReportCatalog.entries.map(\.id)) == Set(ReportsModel.Report.allCases.map(\.catalogID)))
    }

    // MARK: never a name

    /// Every question, over fleets whose serials and names are canaries: none is spoken; rows hold serials, never names.
    @Test func noSerialOrNameIsEverSpoken() async throws {
        let world = try await Self.world()
        try await Self.snapshot(world)
        let answers = Self.answers(world)
        for report in ReportsModel.Report.allCases {
            let answer = await answers.answer(report: report, tokens: report == .fleetAge ? ["years": "1"] : [:])
            Self.expectNoCanary(answer, "\(report)")
            #expect(!answer.spoken.isEmpty && answer.spoken.contains("Read in full") || answer.spoken.contains("read in full"), "\(report): \(answer.spoken)")
        }
        let lock = await answers.answer(report: .activationLock, tokens: ["group": "lock:USER"])
        #expect(lock.rows.map(\.serial) == ["ZQXSER1", "ZQXSER2", "ZQXSER3"] && lock.rows.allSatisfy { $0.model == "MacBook Air" && $0.state == "lock:USER" })
        #expect(lock.spoken.contains("The group lock:USER holds 3."), "\(lock.spoken)")
        let attention = await answers.attention()
        Self.expectNoCanary(attention, "attention")
        #expect(attention.spoken.contains("Mosyle's device list was read in full"), "\(attention.spoken)")
        let found = await answers.lookUp(serial: " adev0000001\t")
        Self.expectNoCanary(found, "lookUp")
        #expect(found.rows == [Answers.Answer.Row(serial: "ADEV0000001", model: "MacBook Air", state: "ASSIGNED")] && found.spoken.hasSuffix("1 device matches that identifier exactly."))
        let none = await answers.lookUp(serial: "ZQXNOSUCH")
        Self.expectNoCanary(none, "lookUp none")
        #expect(none.rows.isEmpty && none.spoken.contains("No device matches that identifier among the 3 devices read."), "\(none.spoken)")
        // Only the lists' own reads, never a device's.
        #expect(Set(Self.paths(world)).isSubset(of: ["/auth/oauth2/token", "/v1/orgDevices", "/v1/mdmServers", "/v1/mdmServers/S1/relationships/devices",
                                                     "/v1/mdmServers/S2/relationships/devices"]), "\(Self.paths(world))")
    }

    // MARK: each error kind, in a fixed phrase

    /// Each kind of not-read in its fixed phrase, whatever the state's own text says.
    @Test func eachKindIsAFixedPhraseNeverTheStatesText() {
        let canary = "ZQXWHY"
        let devices = Answers.name(.appleDevices)
        #expect(Answers.notRead(.appleDevices, state: .forbidden, mosyleOrg: true) == "Your role can't read Apple's device list.")
        #expect(Answers.notRead(.appleDevices, state: .failed(canary), mosyleOrg: true) == "Apple's device list couldn't be read: the read failed, and abapit says why.")
        #expect(Answers.notRead(.appleServices, state: .notInScope(canary), mosyleOrg: true) == "Apple's list of device management services isn't in this organization's scope.")
        #expect(Answers.notRead(.appleDevices, state: .unusable(canary), mosyleOrg: true) == Answers.Phrase.unusable(devices))
        #expect(Answers.notRead(.mosyleDevices, state: .notInScope(canary), mosyleOrg: false) == Answers.Phrase.noMosyleOrg)
        #expect(Answers.notRead(.mosyleDevices, state: .failed(canary), mosyleOrg: true) == Answers.Phrase.failed("Mosyle's device list"))
        #expect(Answers.Phrase.stillReading(devices, after: .seconds(25)).hasPrefix("Apple's device list was still being read after 25 seconds"))
    }

    /// A 403: "your role can't read", for every live question.
    @Test func a403IsTheRolesPhrase() async throws {
        let world = try await Self.world(mosyle: false)
        world.stubs["a"]!.forbid("/v1/orgDevices")
        world.stubs["a"]!.forbid("/v1/mdmServers")
        let answers = Self.answers(world)
        for report in [ReportsModel.Report.migration, .fleetAge] {
            #expect(await answers.answer(report: report, tokens: [:]).spoken.hasSuffix("Your role can't read Apple's device list. Nothing was judged."))
        }
        let health = await answers.answer(report: .serviceHealth, tokens: [:])
        #expect(health.spoken.hasSuffix("Your role can't read Apple's list of device management services. Nothing was judged.") && health.rows.isEmpty)
        let found = await answers.lookUp(serial: "ADEV0000001")
        #expect(found.spoken.hasSuffix("Your role can't read Apple's device list. Nothing was judged.") && found.rows.isEmpty)
        let attention = await answers.attention()
        #expect(attention.spoken.contains("Your role can't read Apple's device list. A rule that reads it is skipped."), "\(attention.spoken)")
        #expect(attention.spoken.contains(Answers.Phrase.noMosyleOrg), "\(attention.spoken)")
    }

    /// A failure whose `detail` Apple wrote: the failed phrase, never the detail, in whole and in part.
    @Test func applesDetailIsNeverSaid() async throws {
        let world = try await Self.world(mosyle: false)
        world.stubs["a"]!.queue(400, for: "/v1/orgDevices", body: Self.appleDetail)
        let answers = Self.answers(world)
        let failed = await answers.answer(report: .migration, tokens: [:])
        guard case .failed(let why) = world.devices.state else { Issue.record("\(world.devices.state)"); return }
        #expect(why.contains("ZQXDETAIL"), "the screen's words carry the detail: \(why)")
        #expect(failed.spoken.hasSuffix(Answers.Phrase.failed("Apple's device list") + " Nothing was judged."), "\(failed.spoken)")
        Self.expectNoCanary(failed, "failed")
        // After rows: in part, with the count read and no detail.
        let part = try await Self.world(devices: 1001, mosyle: false)
        part.stubs["a"]!.queue(400, for: "/v1/orgDevices?limit=1000&cursor=", body: Self.appleDetail)
        let cut = await Self.answers(part).answer(report: .migration, tokens: [:])
        guard case .failed(let partWhy) = part.devices.state else { Issue.record("\(part.devices.state)"); return }
        #expect(partWhy.contains("ZQXDETAIL") && part.devices.rows.count == 1000)
        #expect(cut.spoken.contains("Apple's device list was read in part") && cut.spoken.contains("the read stopped on an error after 1,000 devices. The counts cover only what was read."),
                "\(cut.spoken)")
        #expect(cut.spoken.contains("Status ASSIGNED") == false && cut.spoken.contains("No migration data from Apple: 1000."), "\(cut.spoken)")
        Self.expectNoCanary(cut, "part")
        #expect(cut.rows.count == 10 && cut.capNote == "Showing 10 of 1,000: the rest are in abapit.")
    }

    /// Mosyle's own message is never said: the failed phrase, and the rules that read it skipped.
    @Test func mosylesMessageIsNeverSaid() async throws {
        let world = try await Self.world()
        world.mosyleStub.failEnvelope("ZQXMOSYLE_STATUS", for: "/v1/devices")
        let attention = await Self.answers(world).attention()
        guard case .failed(let why) = world.mosyle.devices.state else { Issue.record("\(world.mosyle.devices.state)"); return }
        #expect(why.contains("ZQXMOSYLE"), "the screen's words carry Mosyle's: \(why)")
        #expect(attention.spoken.contains(Answers.Phrase.failed("Mosyle's device list") + " A rule that reads it is skipped."), "\(attention.spoken)")
        Self.expectNoCanary(attention, "attention")
    }

    /// The snapshot's codes and notes, and the history's own message, are never said: fixed phrases instead.
    @Test func aSnapshotsCodeAndTheHistorysMessageAreNeverSaid() async throws {
        let failed = try await Self.world(history: { .failure(.database(code: 1, message: "ZQXDB")) })
        let answers = Self.answers(failed, fixed: true)
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .activationLock] {
            let answer = await answers.answer(report: report, tokens: [:])
            #expect(failed.screens.reports.build(report, tokens: [:]).judgesNothing?.contains("ZQXDB") == true)
            #expect(answer.spoken == "\(failed.orgs.activeClient!.name): \(Answers.Phrase.historyFailed)", "\(answer.spoken)")
        }
        let age = await answers.answer(report: .fleetAge, tokens: [:])
        #expect(age.spoken.contains("The snapshot history couldn't be read, so no AppleCare coverage is used."), "\(age.spoken)")
        Self.expectNoCanary(age, "fleet age")
        // The newest attempt read none of the sweep, and none before it did.
        let world = try await Self.world()
        try await ReportsTests.record(world, days: 0, ["devices": [Self.device("ZQXSER1")]], errors: ["applecare": "ZQXCODE", "activation_lock": "ZQXCODE"],
                                      notes: ["applecare": "ZQXNOTE"])
        let later = Self.answers(world, fixed: true)
        for (report, sweep) in [(ReportsModel.Report.coverage, "AppleCare coverage"), (.outOfWarranty, "AppleCare coverage"), (.activationLock, "Activation Lock")] {
            let answer = await later.answer(report: report, tokens: [:])
            #expect(world.screens.reports.build(report, tokens: [:]).judgesNothing?.contains("ZQXCODE") == true)
            #expect(answer.spoken.hasSuffix(Answers.Phrase.sweepFailed(sweep)), "\(answer.spoken)")
        }
        #expect(world.stubs["a"]!.requests.isEmpty, "a snapshot report asks Apple nothing")
    }

    // MARK: per report: judges nothing, part, still reading, switched

    /// No snapshot: a snapshot report says the screen's words as they are, and asks Apple nothing.
    @Test func aSnapshotReportThatJudgesNothingSaysTheScreensWords() async throws {
        let world = try await Self.world()
        let answers = Self.answers(world, fixed: true)
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .activationLock] {
            let answer = await answers.answer(report: report, tokens: [:])
            let words = try #require(world.screens.reports.build(report, tokens: [:]).judgesNothing)
            #expect(answer.spoken == "\(world.orgs.activeClient!.name): \(words)" && words.contains("No snapshot has read"), "\(answer.spoken)")
            #expect(answer.rows.isEmpty)
        }
        #expect(world.stubs["a"]!.requests.isEmpty)
        // A token that doesn't resolve reads nothing at all.
        let bad = await answers.answer(report: .coverage, tokens: ["days": "0"])
        #expect(bad.spoken.hasSuffix("The filters weren't understood, so the report wasn't run.") && world.stubs["a"]!.requests.isEmpty)
        let badLive = await answers.answer(report: .migration, tokens: ["group": "status:NOPE"])
        #expect(badLive.spoken.hasSuffix("The filters weren't understood, so the report wasn't run.") && world.stubs["a"]!.requests.isEmpty)
    }

    /// A snapshot read in part: its date and age, the part said in fixed words, the counts; never its code or note.
    @Test func aSnapshotReadInPartSaysSo() async throws {
        let world = try await Self.world()
        try await Self.snapshot(world, errors: ["applecare": "ZQXCODE", "activation_lock": "ZQXCODE"], notes: ["applecare": "ZQXNOTE", "activation_lock": "ZQXNOTE"])
        let answers = Self.answers(world, fixed: true)
        for (report, sweep) in [(ReportsModel.Report.coverage, "AppleCare coverage"), (.outOfWarranty, "AppleCare coverage"), (.activationLock, "Activation Lock"),
                                (.fleetAge, "AppleCare coverage")] {
            let answer = await answers.answer(report: report, tokens: [:])
            #expect(answer.spoken.contains("From the snapshot of Sep 21, 2026, 20 days old; nothing was read from Apple now."), "\(report): \(answer.spoken)")
            #expect(answer.spoken.contains("That snapshot read \(sweep) only in part: a device it didn't read counts as not read."), "\(report): \(answer.spoken)")
            #expect(!answer.spoken.contains("Read in full"), "\(report): \(answer.spoken)")
            Self.expectNoCanary(answer, "\(report)")
        }
        #expect(world.stubs["a"]!.requests.isEmpty)
    }

    /// The page cap: each live report read in part, with the numbers, the services' short device lists counted.
    @Test func aLiveReportReadInPartSaysHowMuch() async throws {
        let world = try await Self.world(devices: 1002, pageCap: 1, mosyle: false)
        let stub = world.stubs["a"]!
        stub.reportTotals()
        for index in 2..<1002 { stub.assign(String(format: "ADEV%07d", index), to: "S1") }
        let answers = Self.answers(world)
        for report in [ReportsModel.Report.migration, .fleetAge] {
            let answer = await answers.answer(report: report, tokens: [:])
            #expect(answer.spoken.contains("Apple's device list was read in part") && answer.spoken.contains("it stopped at the page limit, showing 1,000 of 1,002. The counts cover only what was read."),
                    "\(report): \(answer.spoken)")
            Self.expectNoCanary(answer, "\(report)")
        }
        let health = await answers.answer(report: .serviceHealth, tokens: [:])
        #expect(health.spoken.contains("the device lists of 1 of 2 services weren't read whole"), "\(health.spoken)")
        #expect(health.rows.isEmpty && health.spoken.contains("(the Overview's rule; the status is beside it): 2"), "\(health.spoken)")
        Self.expectNoCanary(health, "service health")
    }

    /// A live report still being read at the bound counts nothing, and says so; the read goes on.
    @Test func aLiveReportStillReadingAtTheBoundCountsNothing() async throws {
        for (report, held) in [(ReportsModel.Report.migration, Gate.devicePages), (.fleetAge, Gate.devicePages),
                               (.serviceHealth, { @Sendable (url: URL) in url.path() == "/v1/mdmServers" })] {
            let world = try await Self.world(mosyle: false)
            let timer = ManualTimer()
            world.gates["a"]!.hold("held", held)
            let answers = Self.answers(world, timer)
            let request = Task { await answers.answer(report: report, tokens: [:]) }
            await eventually("held") { world.gates["a"]!.held == 1 && timer.sleeping == 1 }
            timer.advance(.seconds(25))
            let answer = await request.value
            let list = report == .serviceHealth ? "Apple's list of device management services" : "Apple's device list"
            #expect(answer.spoken.hasSuffix(Answers.Phrase.stillReading(list, after: .seconds(25))) && answer.rows.isEmpty, "\(report): \(answer.spoken)")
            world.gates["a"]!.release("held")
        }
    }

    /// A switch while a live report waits, or while a snapshot report reads the history: nothing of either client is answered.
    @Test func aSwitchAnswersNothingForEveryReport() async throws {
        for report in ReportsModel.Report.allCases {
            let world = try await Self.world()
            try await Self.snapshot(world)
            let answers = Self.answers(world)
            answers.afterStart = { world.orgs.select("b") }
            world.screens.reports.afterRead = { _ in
                world.screens.reports.afterRead = nil
                world.orgs.select("b")
            }
            let answer = await answers.answer(report: report, tokens: [:])
            #expect(answer.spoken.hasSuffix(Answers.Phrase.switched) && answer.rows.isEmpty, "\(report): \(answer.spoken)")
        }
        let world = try await Self.world()
        let answers = Self.answers(world)
        answers.afterStart = { world.orgs.select(world.orgs.active?.id == "a" ? "b" : "a") }
        #expect(await answers.attention().spoken.hasSuffix(Answers.Phrase.switched))
        #expect(await answers.lookUp(serial: "ADEV0000001").spoken.hasSuffix(Answers.Phrase.switched))
    }

    /// A cancel answers nothing.
    @Test func aCancelAnswersNothing() async throws {
        let world = try await Self.world()
        let answers = Self.answers(world)
        answers.afterStart = { withUnsafeCurrentTask { $0?.cancel() } }
        for report in [ReportsModel.Report.migration, .serviceHealth] {
            #expect(await Task { await answers.answer(report: report, tokens: [:]) }.value.spoken.hasSuffix(Answers.Phrase.cancelled))
        }
        #expect(await Task { await answers.attention() }.value.spoken.hasSuffix(Answers.Phrase.cancelled))
        #expect(await Task { await answers.lookUp(serial: "ADEV0000001") }.value.spoken.hasSuffix(Answers.Phrase.cancelled))
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await answers.answer(report: .coverage, tokens: [:])
        }
        #expect(await before.value.spoken.hasSuffix(Answers.Phrase.cancelled))
    }

    /// A list read again after the wait saw it end (a Refresh): nothing is answered, never a count over another read.
    @Test func aListChangedAfterTheWaitAnswersNothing() async throws {
        let world = try await Self.world(mosyle: false)
        let answers = Self.answers(world)
        answers.afterWait = {
            world.gates["a"]!.hold("devices", Gate.devicePages)
            world.devices.load(force: true)
        }
        let answer = await answers.answer(report: .migration, tokens: [:])
        #expect(answer.spoken.hasSuffix(Answers.Phrase.changed("Apple's device list")) && answer.rows.isEmpty, "\(answer.spoken)")
        world.gates["a"]!.release("devices")
    }

    // MARK: clients, the Mosyle org, a School org

    /// One client: nothing says "client", the lead is the title alone, and the Mosyle org's words leave "client" out.
    @Test func oneClientNeverSaysClient() async throws {
        let world = try await Self.world(oneClient: true)
        try await Self.snapshot(world)
        #expect(!world.orgs.showsClients)
        let answers = Self.answers(world)
        var said: [Answers.Answer] = []
        for report in ReportsModel.Report.allCases {
            let answer = await answers.answer(report: report, tokens: [:])
            #expect(answer.lead == report.title)
            said.append(answer)
        }
        said.append(await answers.attention())
        said.append(await answers.lookUp(serial: "ADEV0000001"))
        world.orgs.select("m")
        said.append(await answers.answer(report: .migration, tokens: [:]))
        let attention = await answers.attention()
        #expect(attention.spoken == "This is a Mosyle Business organization. Needs attention runs from the Apple organization: make it active to see what needs attention.")
        said.append(attention)
        said.append(await answers.lookUp(serial: "ADEV0000001"))
        for answer in said {
            #expect(!answer.spoken.lowercased().contains("client") && !answer.lead.lowercased().contains("client"), "\(answer.lead): \(answer.spoken)")
        }
    }

    /// Two clients: the active client's name leads every answer, the error phrases too.
    @Test func twoClientsNameTheActiveOne() async throws {
        let world = try await Self.world()
        #expect(world.orgs.showsClients)
        let client = try #require(world.orgs.activeClient?.name)
        let answers = Self.answers(world)
        var said = [await answers.answer(report: .coverage, tokens: [:]), await answers.answer(report: .migration, tokens: [:]), await answers.attention(),
                    await answers.lookUp(serial: "ADEV0000001")]
        world.stubs["a"]!.forbid("/v1/orgDevices")
        said.append(await answers.answer(report: .fleetAge, tokens: [:]))
        for answer in said {
            #expect(answer.lead.hasPrefix("\(client): ") && answer.spoken.hasPrefix("\(client): "), "\(answer.lead): \(answer.spoken)")
        }
        #expect(said[0].lead == "\(client): \(ReportsModel.Report.coverage.title)")
    }

    /// The Mosyle org active: each answer says what its screen says, and asks Apple and Mosyle nothing.
    @Test func aMosyleOrgActiveSaysWhatTheScreensSay() async throws {
        let world = try await Self.world()
        world.orgs.select("m")
        let client = try #require(world.orgs.activeClient?.name)
        let answers = Self.answers(world)
        for report in ReportsModel.Report.allCases {
            #expect(await answers.answer(report: report, tokens: [:]).spoken == "\(client): \(ReportsModel.mosyleWords)")
        }
        #expect(await answers.attention().spoken == "\(client): \(NeedsAttentionModel.mosyleWords)")
        #expect(await answers.lookUp(serial: "ADEV0000001").spoken == "\(client): \(Answers.mosyleLookUp)")
        #expect(world.stubs.values.allSatisfy { $0.requests.isEmpty } && world.mosyleStub.requests.isEmpty)
        // No organization at all.
        let none = try await World.make(profiles: [])
        #expect(await none.screens.answers.answer(report: .coverage, tokens: [:]).spoken == ScreenWords.noOrganization)
        #expect(await none.screens.answers.attention().spoken == ScreenWords.noOrganization)
    }

    /// A School org: the reports run as the screen runs them, and the summary says the screen's words, the Apple MDM rules skipped.
    @Test func aSchoolOrgSaysWhatTheScreensSay() async throws {
        let world = try await Self.world(mosyle: false, oneClient: true, scope: .school)
        let answers = Self.answers(world)
        let migration = await answers.answer(report: .migration, tokens: [:])
        let screen = world.screens.reports.build(.migration, tokens: [:])
        #expect(screen.judgesNothing == nil && screen.summary.dropFirst().allSatisfy { migration.spoken.contains($0) }, "\(migration.spoken)")
        let attention = await answers.attention()
        let summary = try #require(world.screens.attention.summary)
        #expect(summary.words.allSatisfy { attention.spoken.contains($0) } && attention.spoken.contains(summary.headline), "\(attention.spoken)")
        let skipped = world.screens.attention.lines.filter(\.isSkipped).map(\.rule)
        #expect(skipped.contains(.missingFromAppleMDM) && skipped.contains(.appleMDMNotInApple), "\(skipped)")
        Self.expectNoCanary(attention, "school")
    }

    // MARK: the rows, the estimate, fields not sent

    /// At most 10 rows, the cap said; under it, no cap.
    @Test func atMostTenRowsWithTheCapSaid() async throws {
        let world = try await Self.world()
        let serials = (0..<12).map { String(format: "ZQXSER%02d", $0) }
        try await ReportsTests.record(world, days: 0, ["devices": serials.map(Self.device), "applecare": [], "activation_lock": []])
        let answers = Self.answers(world, fixed: true)
        let warranty = await answers.answer(report: .outOfWarranty, tokens: [:])
        #expect(warranty.rows.count == 10 && warranty.capNote == "Showing 10 of 12: the rest are in abapit.", "\(warranty.rows) \(String(describing: warranty.capNote))")
        #expect(warranty.rows.allSatisfy { $0.state.hasPrefix("no-record") })
        let one = await answers.answer(report: .outOfWarranty, tokens: ["group": "active"])
        #expect(one.rows.isEmpty && one.capNote == nil && one.spoken.contains("The group active holds 0."))
        let found = await answers.lookUp(serial: "dev")
        #expect(found.rows.count == 3 && found.capNote == nil && found.spoken.contains("No device matches that identifier exactly; 3 devices have it as part of an identifier."), "\(found.spoken)")
        Self.expectNoCanary(warranty, "warranty")
    }

    /// Out of warranty: the estimate counted and called one, the assumption beside it, a status this version doesn't know named.
    @Test func anEstimateIsCalledOne() async throws {
        let world = try await Self.world()
        try await ReportsTests.record(world, days: 0, ["devices": [Self.device("ZQXSER1"), Self.device("ZQXSER2"), ReportsTests.device("ZQXSER3", order: nil)],
                                                       "applecare": [ReportsTests.care("ZQXSER2", status: "ZQXLAPSED")]])
        let answer = await Self.answers(world, fixed: true).answer(report: .outOfWarranty, tokens: [:])
        #expect(answer.spoken.contains("1 estimated from the order date to be past an assumed one-year warranty: an estimate only. 1 without active coverage have no readable order date, so no estimate."),
                "\(answer.spoken)")
        #expect(answer.spoken.contains("1 have coverage records whose status this version doesn't know"), "\(answer.spoken)")
        #expect(answer.estimateNote == WarrantyReport.assumption && !answer.spoken.contains(WarrantyReport.assumption))
        #expect(answer.rows.contains { $0.serial == "ZQXSER1" && $0.state == "no-record, estimated past" })
        Self.expectNoCanary(answer, "warranty")
    }

    /// A field the API didn't send is said, never counted as a value: the services' default fields, Mosyle's refused column, a device
    /// with no model.
    @Test func aFieldNotSentIsSaidNeverCounted() async throws {
        let world = try await Self.world()
        let stub = world.stubs["a"]!
        stub.refuseServiceFields()
        world.mosyleStub.lackColumns(["date_last_beat"])
        stub.add(devices: [Resource(type: "orgDevices", id: "ADEV0000009", attributes: ["serialNumber": .string("ADEV0000009")])])
        let answers = Self.answers(world)
        let health = await answers.answer(report: .serviceHealth, tokens: [:])
        #expect(world.devices.servicesAbsent.contains("lastConnectedDateTime"))
        #expect(health.spoken.contains("Apple didn't send") && health.spoken.contains("Can't be judged (Apple didn't send what's needed): 2."), "\(health.spoken)")
        #expect(!health.spoken.contains("Quiet:") && !health.spoken.contains("Active and connected"), "\(health.spoken)")
        let attention = await answers.attention()
        #expect(attention.spoken.contains("for any service: a rule that needs one doesn't judge it."), "\(attention.spoken)")
        #expect(attention.spoken.contains("Mosyle didn't send its devices' last check-in times: a rule that needs them doesn't judge them."), "\(attention.spoken)")
        let found = await answers.lookUp(serial: "ADEV0000009")
        #expect(found.rows == [Answers.Answer.Row(serial: "ADEV0000009", model: "model not sent", state: "status not sent")])
    }

    // MARK: Needs attention records as the screen does

    /// A rule judged over a whole read is recorded; over a part read it is shown and not recorded, as the screen does.
    @Test func findingsAreRecordedOnlyWhenJudgedWhole() async throws {
        let world = try await Self.world()
        let attention = await Self.answers(world).attention()
        #expect(attention.spoken.contains("In Mosyle, but not in Apple's device list: 1 open finding."), "\(attention.spoken)")
        let kept = try await world.history!.state(org: world.orgs.store["a"]!)
        #expect(kept.contains { $0.rule == NeedsAttention.Rule.mosyleNotInApple.rawValue && $0.subject == "ZQXMAC1" }, "\(kept)")
        // Mosyle read in part (the page cap): found and said, never kept.
        let part = try await World.make(mosyle: true, mosylePageCap: 1)
        part.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "ZQXMAC%03d", $0)) }, os: "mac")
        let partial = await Self.answers(part).attention()
        #expect(partial.spoken.contains("Mosyle's device list was read in part") && partial.spoken.contains("found over a part read and not kept."), "\(partial.spoken)")
        let none = try await part.history!.state(org: part.orgs.store["a"]!)
        #expect(!none.contains { $0.rule == NeedsAttention.Rule.mosyleNotInApple.rawValue }, "\(none)")
        Self.expectNoCanary(partial, "partial")
    }

    // MARK: the review's fixes

    /// A list still being read at the bound that ends during the history read (the review's case): nothing is answered, and nothing
    /// is judged or recorded over it.
    @Test func aListThatEndsAfterTheBoundAnswersNothingAndRecordsNothing() async throws {
        let world = try await Self.world()
        let timer = ManualTimer()
        let answers = Self.answers(world, timer)
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.screens.attention.afterAwait = { stage in
            guard stage == "load" else { return }
            world.screens.attention.afterAwait = nil
            world.gates["a"]!.release("devices")
            await eventually("Apple's devices read") { LiveWaitTests.loadedAt(world.devices.state) != nil }
        }
        let request = Task { await answers.attention() }
        await eventually("held, the bound's sleep") { world.gates["a"]!.held == 1 && timer.sleeping == 1 }
        timer.advance(.seconds(25))
        let answer = await request.value
        #expect(answer.spoken.hasSuffix(Answers.Phrase.changed("Apple's device list")), "\(answer.spoken)")
        #expect(!answer.spoken.contains("open finding"), "\(answer.spoken)")
        let kept = try await world.history!.state(org: world.orgs.store["a"]!)
        #expect(kept.isEmpty, "recorded over a list said not counted: \(kept)")
    }

    /// Needs attention says how old the snapshots behind its snapshot rules are: the oldest, once; with none, that none was used.
    @Test func attentionSaysTheOldestSnapshotUsed() async throws {
        let world = try await Self.world()
        try await Self.snapshot(world)
        let answer = await Self.answers(world, fixed: true).attention()
        #expect(answer.spoken.contains("The oldest snapshot used is from Sep 21, 2026, 20 days old."), "\(answer.spoken)")
        let none = try await Self.world()
        let bare = await Self.answers(none, fixed: true).attention()
        #expect(bare.spoken.contains("No snapshot was used.") && !bare.spoken.contains("oldest snapshot"), "\(bare.spoken)")
    }

    @MainActor final class Flag {
        var on = false
    }

    /// The screen's own history read replaced the answer's: the answer waits for it (bounded), never says "Reading the snapshot history…".
    @Test func anAnswerWhoseHistoryReadWasReplacedWaitsForTheScreens() async throws {
        for released in [true, false] {
            let world = try await Self.world()
            try await Self.snapshot(world)
            let timer = ManualTimer()
            let answers = Self.answers(world, timer, fixed: true)
            let reports = world.screens.reports
            let (held, release) = AsyncStream<Void>.makeStream()
            let screenHeld = Flag()
            reports.afterRead = { _ in
                // The answer's read: the screen's own read starts now, and waits at its own hook.
                reports.afterRead = { _ in
                    screenHeld.on = true
                    for await _ in held { break }
                }
                Task { await reports.load() }
                await eventually("the screen's read held") { screenHeld.on }
            }
            let request = Task { await answers.answer(report: .activationLock, tokens: [:]) }
            await eventually("the answer waits on the screen's read") { timer.sleeping == 1 }
            if released { release.yield() } else { timer.advance(.seconds(25)) }
            let answer = await request.value
            if released {
                #expect(answer.spoken.contains("From the snapshot of Sep 21, 2026") && !answer.spoken.contains("Reading the snapshot history"), "\(answer.spoken)")
            } else {
                #expect(answer.spoken.hasSuffix(Answers.Phrase.historyStillReading), "\(answer.spoken)")
                release.yield()
            }
        }
    }

    /// An answer's history read that replaced the screen's still asks for the live lists the screen's report needs.
    @Test func anAnswersHistoryReadHonoursTheScreensLiveRead() async throws {
        let world = try await Self.world(mosyle: false)
        let reports = world.screens.reports
        // Fleet age with no snapshot reads the live list, but only once the history says so.
        reports.select(.fleetAge)
        #expect(world.devices.state == .idle)
        reports.afterRead = { _ in
            reports.afterRead = nil
            await reports.loadHistory()
        }
        await reports.load()
        #expect(world.devices.state != .idle, "the screen's live read was dropped")
        // A history read alone, with no screen's read waiting, asks for nothing live.
        let quiet = try await Self.world(mosyle: false)
        quiet.screens.reports.select(.fleetAge)
        await quiet.screens.reports.loadHistory()
        #expect(quiet.devices.state == .idle)
    }

    /// A value this version doesn't know (a migration status, a lock type, a service status) is counted, never said; it stays in rows.
    @Test func aRawValueIsCountedNeverSaid() async throws {
        let world = try await Self.world(mosyle: false)
        let stub = world.stubs["a"]!
        stub.add(devices: [Resource(type: "orgDevices", id: "ADEV0000007", attributes: ["serialNumber": .string("ADEV0000007"), "deviceModel": .string("Mac mini"),
                                                                                         "mdmMigrationStatus": .string("ZQXSTATUS")])])
        stub.add(services: [Resource(type: "mdmServers", id: "S3", attributes: ["serverName": .string("ZQXNAME-Three"), "serverType": .string("MDM"),
                                                                              "status": .string("ZQXSVC"), "lastConnectedDateTime": .string(ReportsTests.iso(Date()))])])
        try await ReportsTests.record(world, days: 0, ["devices": [Self.device("ZQXSER1"), Self.device("ZQXSER2")],
                                                       "activation_lock": [ReportsTests.lock("ZQXSER1", locked: true, type: "ZQXLOCK"),
                                                                           ReportsTests.lock("ZQXSER2", locked: true, type: "NONE")]])
        let answers = Self.answers(world)
        let migration = await answers.answer(report: .migration, tokens: [:])
        #expect(migration.spoken.contains("1 with a migration status this version doesn't know."), "\(migration.spoken)")
        #expect(migration.rows.contains { $0.serial == "ADEV0000007" && $0.state == "status:ZQXSTATUS" })
        let lock = await answers.answer(report: .activationLock, tokens: [:])
        #expect(lock.spoken.contains("1 locked with a lock type this version doesn't know: can't say whether it blocks release.")
                && lock.spoken.contains("lock type NONE"), "\(lock.spoken)")
        #expect(lock.rows.contains { $0.state == "lock:ZQXLOCK" })
        let health = await answers.answer(report: .serviceHealth, tokens: [:])
        #expect(health.spoken.contains("A status this version doesn't know, and not quiet: 1."), "\(health.spoken)")
        for answer in [migration, lock, health] { Self.expectNoCanary(answer, answer.lead) }
    }

    /// Find matches any identifier, exactly or in part, and the answer says which: an IMEI exactly, a serial's start in part.
    @Test func aLookUpSaysExactOrPart() async throws {
        let world = try await Self.world(mosyle: false)
        world.stubs["a"]!.add(devices: [Resource(type: "orgDevices", id: "ADEV0000008", attributes: ["serialNumber": .string("ADEV0000008"),
                                                                                                      "imei": .array([.string("356938035643809")])])])
        let answers = Self.answers(world)
        let imei = await answers.lookUp(serial: "356938035643809")
        #expect(imei.spoken.hasSuffix("1 device matches that identifier exactly.") && imei.rows.map(\.serial) == ["ADEV0000008"], "\(imei.spoken)")
        let part = await answers.lookUp(serial: "0000008")
        #expect(part.spoken.hasSuffix("No device matches that identifier exactly; 1 device has it as part of an identifier."), "\(part.spoken)")
        #expect(!imei.spoken.contains("356938035643809") && !part.spoken.contains("0000008"))
    }
}
