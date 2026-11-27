import AppModels
import Foundation
import JSONAPI
import Reports
import Testing
import TestSupport

/// The CSV the "Get report CSV" intent returns (`Answers.reportCSV`, S9.10): exactly what the Reports screen's Export writes for the
/// same report, group and number, through the same `ExportPolicy` columns, under the same file name (the client's name first only
/// when the app shows clients); nothing when the client changes during the read or nothing was judged; a read in part said beside it.
/// Over the strict stubs and a real `SnapshotStore`, with fake serials (`ZQXSER…`, `ADEV…`).
@MainActor
@Suite("ReportCSV", .serialized, .timeLimit(.minutes(1)))
struct ReportCSVTests {
    /// The columns each report's export may hold, by the policy.
    static func allowed(_ report: ReportsModel.Report) -> [String] {
        switch report {
        case .coverage: ExportPolicy.coverageExpiring.names
        case .fleetAge: ExportPolicy.refreshCandidates.names
        case .activationLock: ExportPolicy.activationLockReport.names
        case .migration: ExportPolicy.migrationReport.names
        case .serviceHealth: ExportPolicy.serviceHealth.names
        case .outOfWarranty: ExportPolicy.warrantyReport.names
        }
    }

    static func header(_ text: String) -> [String] {
        (text.components(separatedBy: "\r\n").first ?? "").components(separatedBy: ",")
    }

    /// A snapshot of org `a` whose Activation Lock and AppleCare records and devices carry keys the policy doesn't list, one of them
    /// a bypass code.
    static func plantedSnapshot(_ world: World) async throws {
        let serials = ["ZQXSER1", "ZQXSER2", "ZQXSER3"]
        let devices = serials.map { serial -> Resource in
            let device = AnswersTests.device(serial)
            return Resource(type: device.type, id: device.id, attributes: device.attributes.merging(["ZQXUNLISTED": .string("ZQXPLANTED-device")]))
        }
        try await ReportsTests.record(world, days: 0, [
            "devices": devices,
            "applecare": serials.map { ReportsTests.care($0, endsInDays: 20, extra: ["ZQXUNLISTED": .string("ZQXPLANTED-care")]) },
            "activation_lock": serials.map {
                ReportsTests.lock($0, locked: true, type: "USER", extra: ["activationBypassCode": .string("ZQXBYPASS"), "ZQXUNLISTED": .string("ZQXPLANTED-lock")])
            },
        ])
    }

    /// Each report, with and without a group and a number: the intent's CSV and file name are the screen's, byte for byte.
    @Test func theCSVIsWhatTheScreenExports() async throws {
        let world = try await AnswersTests.world(oneClient: true)
        try await AnswersTests.snapshot(world)
        let answers = AnswersTests.answers(world, fixed: true)
        let reports = world.screens.reports
        let cases: [(ReportsModel.Report, [String: String])] = [
            (.coverage, [:]), (.coverage, ["days": "30"]), (.fleetAge, [:]), (.fleetAge, ["years": "1"]),
            (.activationLock, [:]), (.activationLock, ["group": "lock:USER"]),
            (.migration, [:]), (.serviceHealth, [:]), (.outOfWarranty, [:]), (.outOfWarranty, ["group": "no-record"]),
        ]
        for (report, tokens) in cases {
            let made = await answers.reportCSV(report: report, tokens: tokens)
            let file = try #require(made.file, "\(report) \(tokens): \(made.spoken)")
            let output = reports.build(report, tokens: tokens)
            #expect(file.text == reports.csv(of: output), "\(report) \(tokens)")
            #expect(file.name == reports.exportFileName(for: output), "\(report) \(tokens)")
            #expect(file.text.components(separatedBy: "\r\n").count > 1, "\(report) \(tokens) has a header only")
        }
        // A report given a group or number it doesn't have is refused in the screen's words, with no file.
        let bad = await answers.reportCSV(report: .coverage, tokens: ["days": "0"])
        #expect(bad.file == nil && bad.spoken.hasSuffix("The filters weren't understood, so the report wasn't run."), "\(bad.spoken)")
    }

    /// No column beyond the screen export's allowlist, and no value Apple sent under a key the policy doesn't list.
    @Test func theAllowlistHolds() async throws {
        let world = try await AnswersTests.world(oneClient: true)
        try await Self.plantedSnapshot(world)
        let answers = AnswersTests.answers(world, fixed: true)
        for report in ReportsModel.Report.allCases {
            let made = await answers.reportCSV(report: report, tokens: [:])
            let file = try #require(made.file, "\(report): \(made.spoken)")
            let columns = Self.header(file.text)
            #expect(columns.first == "id" && Set(columns.dropFirst()).isSubset(of: Self.allowed(report)), "\(report): \(columns)")
            for planted in ["ZQXBYPASS", "ZQXPLANTED", "ZQXUNLISTED", "activationBypass"] {
                #expect(!file.text.contains(planted), "\(report) holds \(planted)")
            }
        }
    }

    /// One client: the file's name is the report's alone. Two clients: the active client's name leads it, and the same file for the
    /// other client names the other.
    @Test func theFileNameNamesTheClientOnlyWhenThereAreSeveral() async throws {
        let one = try await AnswersTests.world(oneClient: true)
        try await AnswersTests.snapshot(one)
        #expect(!one.orgs.showsClients)
        let alone = try #require(await AnswersTests.answers(one, fixed: true).reportCSV(report: .outOfWarranty, tokens: [:]).file)
        #expect(alone.name.hasPrefix("out of warranty (snapshot ") && alone.name.hasSuffix(").csv"), "\(alone.name)")

        let two = try await AnswersTests.world()
        try await AnswersTests.snapshot(two)
        #expect(two.orgs.showsClients)
        let client = try #require(two.orgs.activeClient?.name)
        let several = try #require(await AnswersTests.answers(two, fixed: true).reportCSV(report: .outOfWarranty, tokens: [:]).file)
        #expect(several.name == "\(client) - \(alone.name)", "\(several.name)")
        // The CSV's rows are the same either way: only the name differs.
        #expect(several.text == alone.text)
    }

    /// A switch while the report is read (a live report waiting, a snapshot report reading the history): no file, and the switch said.
    @Test func aSwitchDuringTheReadReturnsNothing() async throws {
        for report in ReportsModel.Report.allCases {
            let world = try await AnswersTests.world()
            try await AnswersTests.snapshot(world)
            let answers = AnswersTests.answers(world)
            answers.afterStart = { world.orgs.select("b") }
            world.screens.reports.afterRead = { _ in
                world.screens.reports.afterRead = nil
                world.orgs.select("b")
            }
            let made = await answers.reportCSV(report: report, tokens: [:])
            #expect(made.file == nil && made.spoken.hasSuffix(Answers.Phrase.switched), "\(report): \(made.spoken)")
        }
    }

    /// A report that judged nothing (no snapshot) or a Mosyle org: no file, the screen's words.
    @Test func aReportThatJudgesNothingHasNoFile() async throws {
        let world = try await AnswersTests.world()
        let answers = AnswersTests.answers(world, fixed: true)
        for report in [ReportsModel.Report.coverage, .outOfWarranty, .activationLock] {
            let made = await answers.reportCSV(report: report, tokens: [:])
            #expect(made.file == nil && made.spoken.contains("No snapshot has read"), "\(report): \(made.spoken)")
        }
        world.orgs.select("m")
        let mosyle = await answers.reportCSV(report: .migration, tokens: [:])
        #expect(mosyle.file == nil && mosyle.spoken.hasSuffix(ReportsModel.mosyleWords), "\(mosyle.spoken)")
    }

    /// A snapshot read in part, and a live list read in part: the file is made, as the screen makes it, and the words say so beside it.
    @Test func aReadInPartIsSaidBesideTheFile() async throws {
        let world = try await AnswersTests.world()
        try await AnswersTests.snapshot(world, errors: ["applecare": "ZQXCODE"], notes: ["applecare": "ZQXNOTE"])
        let answers = AnswersTests.answers(world, fixed: true)
        let made = await answers.reportCSV(report: .outOfWarranty, tokens: [:])
        #expect(made.file != nil)
        #expect(made.spoken.contains("That snapshot read AppleCare coverage only in part"), "\(made.spoken)")
        #expect(made.spoken.hasPrefix((await answers.answer(report: .outOfWarranty, tokens: [:])).spoken))
        #expect(!made.spoken.contains("ZQXCODE") && !made.spoken.contains("ZQXNOTE"))

        let capped = try await AnswersTests.world(devices: 1002, pageCap: 1, mosyle: false)
        capped.stubs["a"]!.reportTotals()
        let live = await AnswersTests.answers(capped).reportCSV(report: .migration, tokens: [:])
        #expect(live.file != nil && live.spoken.contains("Apple's device list was read in part"), "\(live.spoken)")
        let text = try #require(live.file?.text)
        #expect(text.contains("read in part: ") && !text.contains("read in full"), "the file's own listRead column says it")
    }

    /// A group doesn't filter the file (as on the screen), and coverage leaves devices out of it: the dialog says what the file holds,
    /// in the screen's export note, so "The group no-record holds 0" is never read as the file's contents.
    @Test func theDialogSaysWhatTheFileHolds() async throws {
        let world = try await AnswersTests.world(oneClient: true)
        try await AnswersTests.snapshot(world)
        let answers = AnswersTests.answers(world, fixed: true)
        let reports = world.screens.reports
        let cases: [(ReportsModel.Report, [String: String])] = [
            (.activationLock, ["group": "lock:USER"]), (.migration, ["group": "past-due"]), (.serviceHealth, ["group": "healthy"]),
            (.outOfWarranty, ["group": "no-record"]), (.coverage, ["days": "30"]), (.fleetAge, [:]),
        ]
        for (report, tokens) in cases {
            let made = await answers.reportCSV(report: report, tokens: tokens)
            let note = reports.build(report, tokens: tokens).exportNote
            #expect(made.file != nil && note.hasPrefix("The file holds") && made.spoken.hasSuffix(" " + note), "\(report): \(made.spoken)")
        }
        // The group's own count is still said, and the note says the file holds every device whatever it is.
        let warranty = await answers.reportCSV(report: .outOfWarranty, tokens: ["group": "no-record"])
        #expect(warranty.spoken.contains("The group no-record holds") && warranty.spoken.contains("whatever group is shown"), "\(warranty.spoken)")
        // Nothing made, nothing said about a file.
        let none = await AnswersTests.answers(try await AnswersTests.world(oneClient: true)).reportCSV(report: .coverage, tokens: [:])
        #expect(none.file == nil && !none.spoken.contains("The file holds"), "\(none.spoken)")
    }
}
