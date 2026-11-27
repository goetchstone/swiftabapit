import Foundation
import Testing
import TestSupport

/// Invariant 9's structural half (plan §5; SwiftGamGui's `noIntentReachesAWrite`): what Siri, Shortcuts and the model reach can't
/// name the write path. The App Intents (`App/Intents/`), Assist and the answers they give (`AppModels/Answers.swift`, and the Ask's
/// `AppModels/AskModel.swift`) name no
/// `Executor`, `WriteTicket`, `send(_:ticket:)`, `HeldPreview`, `OperatorConfirmation`, `WireOperation`, write builder, `Guard`, or
/// the modules that hold them; the intents import only what answers. `scripts/check_app.sh` reads the same intents from the built
/// metadata: each in the background only, with the Mac's own authentication.
@Suite("Intents")
struct IntentTests {
    static let intents = "App/Intents"
    static let assist = "Packages/AbapitKit/Sources/Assist"
    static let answers = "Packages/AbapitApp/Sources/AppModels/Answers.swift"
    static let ask = "Packages/AbapitApp/Sources/AppModels/AskModel.swift"
    static let liveWait = "Packages/AbapitApp/Sources/AppModels/LiveWait.swift"

    /// Names of the write path, matched anywhere in code and string literals (`SourceScan.mentions`): the chokepoint's types, the
    /// ticket's label, the write builders (`AppleWriteBuilders`, `MosyleWriteBuilders`, plan §3.2), and the modules that hold them.
    static let writes = ["Executor", "WriteTicket", "ticket:", "HeldPreview", "OperatorConfirmation", "WireOperation", "WriteBuilder",
                         "ChangeCore", "HTTPCore"]
    /// Whole names only, in code (`SourceScan.names`): `send` sits inside `sender`, and `Guard` beside Swift's `guard`.
    static let writeNames = ["send", "Guard"]
    /// What an intent file may import: the framework, SwiftUI for the snippet, and the screen models whose `Answers` it calls.
    static let intentImports: Set = ["AppIntents", "AppModels", "SwiftUI", "Foundation"]

    /// What the CSV intent's files may not hold: a write to disk, a log, a dump, a handle, a pasteboard, a defaults store, a network call.
    static let outputNeedles = ["write(to", "FileManager", "createFile", "NSTemporaryDirectory", "temporaryDirectory", "Logger", "OSLog", "print(", "NSLog",
                                "os_log", "NSPasteboard", "UIPasteboard", "URLSession", "dump(", "FileHandle", "debugPrint", "UserDefaults",
                                "fputs(", "fwrite(", "FileWrapper", "NSSharingService", "NSItemProvider", "CFPreferences", "NSUbiquitousKeyValueStore"]
    /// What `Answers` may not do on the way to a CSV or any answer: switch the client, write a snapshot or the history, record a finding.
    static let answersMayNot = [".select(", "selectClient", "snapshots.", "historyTransfer", "record("]

    static func files() throws -> [SourceScan.File] {
        let answers = try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").filter { [Self.answers, Self.ask].contains($0.path) }
        return try SourceScan.swiftFiles(in: Self.intents) + SourceScan.swiftFiles(in: Self.assist) + answers
    }

    static func reachesAWrite(_ file: SourceScan.File) -> Bool {
        SourceScan.mentions(file, writes) || SourceScan.names(file, writeNames)
    }

    @Test func noIntentReachesAWrite() throws {
        for file in try Self.files() {
            #expect(!Self.reachesAWrite(file), "\(file.path) names the write path")
        }
        for file in try SourceScan.swiftFiles(in: Self.intents) {
            let extra = Set(SourceScan.imports(of: file)).subtracting(Self.intentImports)
            #expect(extra.isEmpty, "\(file.path) imports \(extra.sorted())")
        }
    }

    /// The screen models an intent must not reach: through them, the snapshot collector, the history transfer, Dismiss and Snooze, and
    /// a switch of client all write (the review of PR 52 planted `screens.snapshots.run` and `orgs.selectClient` in an intent, and every
    /// test passed). The intents' dependency is `Answers` alone, which holds the models it reads privately. `Mirror` reads a private
    /// property by reflection, so it would reach them all the same.
    static let models = ["ScreenModels", "OrgsModel", "SnapshotCollector", "HistoryTransfer", "NeedsAttentionModel", "DevicesModel", "MosyleModel",
                         "ReportsModel.init", "ChangesModel", "selectClient", "snapshots.", "historyTransfer", "AppServices", "Mirror"]
    static let answersHolds = ["orgs", "devices", "mosyle", "reports", "attentionModel"]

    @Test func theIntentsReachAnswersAlone() throws {
        let reaching = try SourceScan.files(in: Self.intents, matching: Self.models)
        #expect(reaching.isEmpty, "\(reaching.sorted())")
        // The Ask the intent makes is held to the same list: through it, an intent would reach whatever it reaches. Its own uses of
        // `ReportsModel` (the report type, the defaults, `apply(to:)`, which the intent can't call without a `ReportsModel`) are not on
        // the list, which names only `ReportsModel.init`.
        let askFile = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.ask })
        #expect(!SourceScan.mentions(askFile, Self.models), "\(Self.ask) reaches a screen model")
        #expect(SourceScan.mentions(askFile, ["ReportsModel"]), "the scan sees AskModel")
        #expect(SourceScan.mentions(SourceScan.File(path: "x.swift", text: "let held = Mirror(reflecting: answers).children"), Self.models))
        for file in try SourceScan.swiftFiles(in: Self.intents) where SourceScan.mentions(file, ["@Dependency"]) {
            let dependencies = file.text.components(separatedBy: "@Dependency").dropFirst().map { $0.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespaces) }
            #expect(dependencies.allSatisfy { $0 == "private var answers: Answers" }, "\(file.path): \(dependencies)")
        }
        // What `Answers` holds is private: an intent holding it reaches none of the models behind it.
        let answers = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.answers })
        for name in Self.answersHolds {
            let declarations = answers.text.matches(of: try Regex("(?m)^\\s*([a-z ]*)\\b(let|var) \(name)\\s*:")).map { String(answers.text[$0.range]) }
            #expect(declarations.count == 1 && declarations.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("private let") }, "\(name): \(declarations)")
        }
        // The Ask holds `Answers` and the model privately too, and its intent makes it from `Answers` alone, with the on-device model.
        let ask = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.ask })
        for name in ["answers", "model"] {
            let declarations = ask.text.matches(of: try Regex("(?m)^\\s*([a-z ]*)\\b(let|var) \(name)\\s*:")).map { String(ask.text[$0.range]) }
            #expect(declarations.count == 1 && declarations.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("private let") }, "\(name): \(declarations)")
        }
        let made = try SourceScan.files(in: Self.intents, matching: ["AskModel("])
        #expect(made == ["\(Self.intents)/AskIntent.swift"], "\(made)")
        let intent = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/AskIntent.swift") })
        #expect(intent.text.components(separatedBy: "AskModel(").count == 2 && intent.text.contains("AskModel(answers: answers).ask(question)"))
        let app = try String(contentsOf: Fixtures.repoRoot.appending(path: "App/AppServices.swift"), encoding: .utf8)
        #expect(app.contains("let answers = screens.answers\n        AppDependencyManager.shared.add(dependency: answers)\n"), "the registration isn't Answers alone")
        #expect(app.components(separatedBy: "AppDependencyManager").count == 2 && app.components(separatedBy: "add(dependency:").count == 2)
    }

    /// No intent words an answer: every dialog is the answer's own spoken words, made in the snippet's file, and every file an intent
    /// returns is made there from `Answers`' text. Counted over code with its comments blanked, so a commented-out call counts for
    /// nothing (the review of PR 55).
    @Test func everyDialogIsTheAnswersWords() throws {
        let dialogs = try SourceScan.files(in: Self.intents, matching: ["IntentDialog(", "dialog:"])
        #expect(dialogs == ["\(Self.intents)/Snippets.swift"], "\(dialogs.sorted())")
        let snippet = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/Snippets.swift") })
        #expect(snippet.text.contains("dialog: IntentDialog(\"\\(answer.spoken)\")"))
        for file in try SourceScan.swiftFiles(in: Self.intents) {
            let code = SourceScan.code(file.text, strings: true)
            let sites = code.components(separatedBy: "IntentDialog(").count - 1
            let spoken = code.components(separatedBy: "IntentDialog(\"\\(answer.spoken)\")").count - 1
            #expect(sites == spoken, "\(file.path): \(sites) IntentDialog sites, \(spoken) of them the answer's words")
            let labelled = code.components(separatedBy: "dialog:").count - 1
            let labelledSpoken = code.components(separatedBy: "dialog: IntentDialog(\"\\(answer.spoken)\")").count - 1
            #expect(labelled == labelledSpoken, "\(file.path): \(labelled) dialog: sites, \(labelledSpoken) the answer's words")
            // A file an intent returns is made in the snippet's file alone.
            if file.path != snippet.path {
                #expect(!code.contains("IntentFile("), "\(file.path) makes a file")
            }
        }
        // Every intent's answer comes from `Answers`: each `perform` hands the snippet what `answers` returned.
        for file in try SourceScan.swiftFiles(in: Self.intents) where file.text.contains("func perform(") {
            let code = SourceScan.code(file.text, strings: true)
            let performs = code.components(separatedBy: "func perform(").count - 1
            let answered = code.components(separatedBy: "AnswerSnippet.result(await answers.").count - 1
                + code.components(separatedBy: "AnswerSnippet.result(await AskModel(answers: answers).ask(").count - 1
                + code.components(separatedBy: "AnswerSnippet.fileResult(await answers.reportCSV(").count - 1
            #expect(performs == answered, "\(file.path): \(performs) intents, \(answered) answered by Answers")
        }
    }

    /// What `Answers` may call on each model it holds, and why each is a read (each checked against the model's own code on
    /// 2026-11-27; the coordinating session's allowlist, in place of a list of the writes a reviewer thought of). A path is a member
    /// and what it is read through (`dates.day`); `devices` on `mosyle` is a value (`Listing`), so what is read from it is not named. Any other
    /// member of a held model fails `answersCallsOnlyTheAllowlist`; a member that writes, records, switches or changes a setting is
    /// never added here.
    static let answersMayCall: [String: [String: String]] = [
        "orgs": [
            "active": "the active profile, a value",
            "mosyleOrg": "the client's Mosyle profile, a computed value",
            "generation": "the switch counter, `private(set)`",
            "showsClients": "whether there are two or more clients, computed",
            "exportClient": "the client's name when shown, computed",
            "onSwitch": "registers a handler to run on a switch (the Ask clears its draft); it stores a closure and changes no data, setting or client",
        ],
        "devices": [
            "rows": "the device list read, `private(set)`",
            "state": "the list's read state, `private(set)`",
            "total": "the count Apple said, `private(set)`",
            "services": "the service list read, `private(set)`",
            "servicesState": "the service list's read state, `private(set)`",
            "servicesTruncated": "whether the service list stopped at the page limit, `private(set)`",
            "serviceDevices": "the devices of each service as read, `private(set)`",
            "servicesAbsent": "the services Apple didn't send, `private(set)`",
        ],
        "mosyle": [
            "devices": "the Mosyle device list as a value (`Listing`): its rows and state are read from it",
            "columns": "the Mosyle columns as read, `private(set)`",
        ],
        "reports": [
            "build": "builds an `Output` over what the history and the Devices model hold; it reads nothing from Apple and starts no sweep",
            "loadHistory": "reads the snapshot history and the screen's live lists; it opens the store and writes nothing",
            "state": "the history read's state, `private(set)`",
            "sources": "the sweeps read from history, `private(set)`",
            "isMosyle": "whether the active org is a Mosyle one, computed",
            "exportFileName": "the file's name, computed from the output and the client",
            "csv": "the CSV text of an `Output`, computed; the file is made in memory",
            "dates.day": "words a date (`DateWords`, a value), so `dates` itself is never set",
            "dates.dayTime": "words a date and time (`DateWords`, a value)",
        ],
        "attentionModel": [
            "loadHistory": "reads the history, the settings file and the live lists; it records no finding",
            "judge": "judges without recording: no `seen`, no first-seen date (the operator, 2026-11-25, \"Don't record\")",
            "inputKey": "what the rules read now, computed",
            "state": "the history read's state, `private(set)`",
            "thresholds": "the settings' thresholds, computed",
        ],
    ]

    /// The only places `Answers` names a held model bare, not through a member: its declaration and init, the capture lists that hand
    /// a model to a closure that reads it, and the `LiveWait` it makes over the three lists it waits on (its own file, which reads).
    /// A bare use anywhere else could pass a model on or give it another name.
    static let answersBare = [
        "private let orgs: OrgsModel", "private let devices: DevicesModel", "private let mosyle: MosyleModel", "private let reports: ReportsModel",
        "private let attentionModel: NeedsAttentionModel",
        "public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel, reports: ReportsModel, attention: NeedsAttentionModel)",
        "self.orgs = orgs", "self.devices = devices", "self.mosyle = mosyle", "self.reports = reports", "self.attentionModel = attention",
        "{ [reports]", "{ [attentionModel]", "LiveWait(orgs: orgs, devices: devices, mosyle: mosyle, now: now, sleep: sleep)",
        // The report's device models by id: `devices` there is a parameter, not the held model.
        "static func models(_ devices: [Resource])", "for device in devices where",
    ]

    /// What `LiveWait` (handed `orgs`, `devices` and `mosyle` bare by `Answers`) may call, each checked against the model's own code on
    /// 2026-11-27. It starts reads, as the screens do, and nothing else: no client switch, setting, snapshot or finding.
    static let liveWaitMayCall: [String: [String: String]] = [
        "orgs": [
            "generation": "the switch counter, `private(set)`",
            "mosyleOrg": "the client's Mosyle profile, a computed value",
            "mosyleUnavailable": "why there is no Mosyle org, computed",
        ],
        "devices": [
            "state": "the device list's read state, `private(set)`",
            "servicesState": "the service list's read state, `private(set)`",
            "serviceDevices": "the devices of each service as read, `private(set)`",
            "load": "`load(force: true)` starts the screen's own read of Apple's device and service lists (it resets what the screen holds, as Refresh does); it writes nothing and switches nothing",
        ],
        "mosyle": [
            "devices": "the Mosyle device list as a value (`Listing`)",
            "reloadDevices": "starts the read of the Mosyle device list again, and only it; it writes nothing",
            "devicesStoppedAt": "when the read stopped, `private(set)`",
            "reportNote": "words about the read, computed",
        ],
    ]

    /// `LiveWait`'s bare uses: its declarations and init, and the two functions that read `devices`
    /// (`ReportsModel.liveDevices`, `liveServices`: neither assigns or calls anything that changes it).
    static let liveWaitBare = [
        "private let orgs: OrgsModel", "private let devices: DevicesModel", "private let mosyle: MosyleModel",
        "public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel,", "self.orgs = orgs", "self.devices = devices", "self.mosyle = mosyle",
        "ReportsModel.liveDevices(devices)", "ReportsModel.liveServices(devices)",
    ]

    /// The uses of the held `models` in `file`: each `<name>.<member>…` (also `self.<name>`, `?.`, across lines and in interpolations;
    /// comments don't count) as the path of members it reads through, and each bare use not in `answersBare`, as `<name> (bare)`.
    static func heldUses(_ file: SourceScan.File, _ models: [String], bare allowed: [String] = Self.answersBare) -> [(model: String, path: [String])] {
        var flat = SourceScan.code(file.text, strings: false).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for text in allowed { flat = flat.replacingOccurrences(of: text, with: " ") }
        let chars = Array(flat)
        func isName(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var found: [(model: String, path: [String])] = []
        for model in models {
            let name = Array(model)
            var i = 0
            while i + name.count <= chars.count {
                defer { i += 1 }
                guard Array(chars[i..<i + name.count]) == name, i + name.count == chars.count || !isName(chars[i + name.count]),
                      i == 0 || !isName(chars[i - 1]) else { continue }
                // Behind it: nothing, or `self.`; any other `.` makes it another value's member (`used.devices`).
                var back = i - 1
                while back >= 0, chars[back] == " " { back -= 1 }
                if back >= 0, chars[back] == "." {
                    let before = String(chars[max(0, back - 4)..<back])
                    guard before == "self", back < 4 || !isName(chars[back - 5]) else { continue }
                }
                var path: [String] = []
                var j = i + name.count
                while true {
                    var k = j
                    while k < chars.count, chars[k] == " " { k += 1 }
                    if k < chars.count, chars[k] == "?" || chars[k] == "!" { k += 1; while k < chars.count, chars[k] == " " { k += 1 } }
                    guard k < chars.count, chars[k] == "." else { break }
                    k += 1
                    while k < chars.count, chars[k] == " " { k += 1 }
                    var member = ""
                    while k < chars.count, isName(chars[k]) { member.append(chars[k]); k += 1 }
                    guard !member.isEmpty else { break }
                    path.append(member)
                    j = k
                }
                found.append((model, path))
            }
        }
        return found
    }

    /// The allowlist entry of `model` that covers `path`: the entry whose members are the path's first ones.
    static func entry(_ model: String, _ path: [String], in allowed: [String: [String: String]]) -> String? {
        allowed[model]?.keys.first { Array(path.prefix($0.split(separator: ".").count)) == $0.split(separator: ".").map(String.init) }
    }

    /// The held-model uses in `file` that the allowlist doesn't cover, as `model.path`, and `model (bare)` for a bare one.
    static func uncalled(_ file: SourceScan.File, allowed: [String: [String: String]] = Self.answersMayCall, bare: [String] = Self.answersBare) -> [String] {
        heldUses(file, allowed.keys.sorted(), bare: bare).compactMap { use in
            guard !use.path.isEmpty else { return "\(use.model) (bare)" }
            return Self.entry(use.model, use.path, in: allowed) == nil ? "\(use.model).\(use.path.joined(separator: "."))" : nil
        }
    }

    /// `Answers` only reads. A reviewer planted `attentionModel.evaluate(force: true)`, `orgs.remove(_, deleteSecrets: true)`,
    /// `orgs.move`, `orgs.changeSettings` and `attentionModel.setMosyleService(nil)` in `reportCSV`, and the scan of five names
    /// passed (the review of PR 55's follow-up). So each held model has the members `Answers` may call, and any other call fails;
    /// the five names stay as a second line of defence.
    @Test func answersCallsOnlyTheAllowlist() throws {
        let answers = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.answers })
        #expect(Self.uncalled(answers).isEmpty, "Answers.swift calls what no allowlist names: \(Self.uncalled(answers))")
        // The scan sees the uses, and every allowlisted member is one `Answers` makes (a stale entry is a member nothing reads).
        let used = Dictionary(grouping: Self.heldUses(answers, Self.answersHolds), by: \.model)
            .mapValues { Set($0.compactMap { Self.entry($0.model, $0.path, in: Self.answersMayCall) }) }
        for (model, members) in Self.answersMayCall {
            #expect(used[model] == Set(members.keys), "\(model): used \(used[model, default: []].sorted()), allowed \(members.keys.sorted())")
        }
        #expect(Set(Self.answersMayCall.keys) == Set(Self.answersHolds), "the allowlist names the models Answers holds")
        // `LiveWait` is handed three of the models bare: the same method over it.
        let wait = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.liveWait })
        #expect(Self.uncalled(wait, allowed: Self.liveWaitMayCall, bare: Self.liveWaitBare).isEmpty,
                "LiveWait.swift calls what no allowlist names: \(Self.uncalled(wait, allowed: Self.liveWaitMayCall, bare: Self.liveWaitBare))")
        let waitUsed = Dictionary(grouping: Self.heldUses(wait, Self.liveWaitMayCall.keys.sorted(), bare: Self.liveWaitBare), by: \.model)
            .mapValues { Set($0.compactMap { Self.entry($0.model, $0.path, in: Self.liveWaitMayCall) }) }
        for (model, members) in Self.liveWaitMayCall {
            #expect(waitUsed[model] == Set(members.keys), "LiveWait \(model): used \(waitUsed[model, default: []].sorted()), allowed \(members.keys.sorted())")
        }
        // Whatever hands `Answers`' models to `LiveWait` is its two makes, and each hands the three it holds.
        #expect(SourceScan.code(answers.text, strings: false).components(separatedBy: "LiveWait(").count == 3)
    }

    /// The scan finds a call the allowlist doesn't name, however it is spelled, and passes the ones it does.
    @Test func theAllowlistScanFindsWhatItDoesNotName() {
        let planted = [
            "attentionModel.evaluate(force: true)", "orgs.remove(\"a\", deleteSecrets: true)", "orgs.move(\"a\", to: 2)",
            "try orgs.changeSettings { $0.x = 1 }", "attentionModel.setMosyleService(nil)", "reports.refresh()", "devices.load(force: true)",
            "mosyle.loadDevices(force: true)", "self.orgs.select(\"b\")", "orgs\n    .selectClient(\"b\")", "orgs?.remove(\"a\")", "orgs . remove(\"a\")",
            "let line = \"\\(attentionModel.evaluate(force: true))\"", "let o = orgs", "take(orgs)", "reports.newMadeUpMethod()",
            "orgs.active?.name; orgs.reloadSettings()",
            // S9.12: Answers never explains (Siri and Shortcuts don't speak the model's explanations).
            "await attentionModel.explain()", "attentionModel.explanation(line)", "attentionModel.explainer = m",
        ]
        for code in planted {
            let found = Self.uncalled(SourceScan.File(path: "x.swift", text: "func f() {\n    \(code)\n}"))
            #expect(!found.isEmpty, "\(code)")
        }
        let fine = [
            "orgs.active", "self.orgs.generation", "orgs.active?.provider == .known(.apple)", "await attentionModel.judge()",
            "reports.build(r, tokens: t).judgesNothing", "mosyle.devices.state.isLoading", "// orgs.remove(\"a\")", "let s = \"orgs.remove\"",
            "used.devices.count", "let h = other.orgs.remove(1)", "let ok = orgsCount + devicesX",
        ]
        for code in fine {
            let found = Self.uncalled(SourceScan.File(path: "x.swift", text: "func f() {\n    \(code)\n}"))
            #expect(found.isEmpty, "\(code): \(found)")
        }
    }

    /// The second line of defence: `Answers` names no client switch, snapshot write, history transfer or recording (the review of
    /// PR 55 asked for a scan, since `reportCSV` sits beside the models it reads).
    @Test func answersSwitchesNothingAndWritesNothing() throws {
        let answers = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path == Self.answers })
        #expect(!SourceScan.mentions(answers, Self.answersMayNot), "Answers.swift switches, writes or records")
        #expect(SourceScan.mentions(answers, ["func reportCSV("]), "the scan sees reportCSV")
        for planted in ["orgs.selectClient(\"b\")", "orgs.select(\"b\")", "snapshots.run()", "historyTransfer.export()", "attentionModel.record(findings)"] {
            #expect(SourceScan.mentions(SourceScan.File(path: "x.swift", text: planted), Self.answersMayNot), "\(planted)")
        }
    }

    /// Get report CSV is for Shortcuts only and reads only: no App Shortcut or phrase names it, it holds `Answers` alone, it writes no
    /// file of its own and logs nothing (the CSV is the person's own Shortcut's), and it is made from the one `ReportChoice`.
    @Test func theCSVIntentHasNoPhraseWritesNothingAndLogsNothing() throws {
        let intent = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/ReportCSVIntent.swift") })
        let snippets = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/Snippets.swift") })
        let shortcuts = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/Shortcuts.swift") })
        #expect(!SourceScan.mentions(shortcuts, ["GetReportCSVIntent"]), "an App Shortcut names the CSV intent")
        #expect(intent.text.contains("static let supportedModes: IntentModes = .background") && intent.text.contains("@Dependency private var answers: Answers"))
        #expect(intent.text.contains("var report: ReportChoice") && intent.text.contains("var group: String?") && intent.text.contains("var number: Int?"))
        for file in [intent, snippets] {
            #expect(!SourceScan.mentions(file, Self.outputNeedles), "\(file.path) writes, logs or sends")
        }
        // The file is made in memory from `Answers`' text, as the screen's export is.
        #expect(snippets.text.contains("IntentFile(data: Data($0.text.utf8), filename: $0.name, type: .commaSeparatedText)"))
        for planted in ["let url = FileManager.default.temporaryDirectory", "try text.write(to: url)", "Logger().info(\"x\")", "print(rows)", "dump(rows)",
                        "let h = FileHandle.standardError", "debugPrint(rows)", "UserDefaults.standard.set(rows, forKey: \"k\")",
                        "NSPasteboard.general.setString(text, forType: .string)", "UIPasteboard.general.string = text",
                        "fputs(text, stderr)", "fwrite(p, 1, n, f)", "let w = FileWrapper(regularFileWithContents: d)", "NSSharingService(named: .composeEmail)",
                        "let i = NSItemProvider(object: s)", "CFPreferencesSetAppValue(k, v, id)", "NSUbiquitousKeyValueStore.default.set(rows, forKey: \"k\")"] {
            #expect(SourceScan.mentions(SourceScan.File(path: "x.swift", text: planted), Self.outputNeedles), "\(planted)")
        }
    }

    /// Siri and Shortcuts name the reports as the catalog does: each catalog title is a `ReportChoice` case's.
    @Test func theReportChoicesAreTheCatalogsTitles() throws {
        let catalog = try String(contentsOf: Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/Reports/ReportCatalog.swift"), encoding: .utf8)
        let titles = catalog.matches(of: #/Entry\(id: \.[A-Za-z]+, title: "([^"]+)"/#).map { String($0.output.1) }
        #expect(titles.count == 6, "\(titles)")
        let choices = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/ReportIntents.swift") })
        let shown = choices.text.matches(of: #/\.[A-Za-z]+: "([^"]+)",/#).map { String($0.output.1) }
        #expect(shown == titles, "\(shown) are not the catalog's \(titles)")
    }

    /// The scan must see what it guards and find each name it looks for, or the tests above pass vacuously.
    @Test func theScanSeesTheIntentsAndFindsEveryName() throws {
        let paths = Set(try Self.files().map(\.path))
        for name in ["ReportIntents", "ReportCSVIntent", "AttentionIntent", "LookUpIntent", "AskIntent", "Snippets", "Shortcuts"] {
            #expect(paths.contains("\(Self.intents)/\(name).swift"), "\(name)")
        }
        #expect(paths.contains(Self.answers) && paths.contains(Self.ask))
        #expect(paths.contains { $0.hasPrefix(Self.assist + "/") })
        let planted = [
            "let e = Executor()", "func f(_ t: WriteTicket) {}", "try await http.send(request, ticket: t)", "let p: HeldPreview? = nil",
            "let c = OperatorConfirmation.typed", "let w = WireOperation(path: x)", "AppleWriteBuilders.assign(x)", "import ChangeCore",
            "import HTTPCore", "let s = client.send", "let g = Guard.evaluate(x)",
        ]
        for code in planted {
            #expect(Self.reachesAWrite(SourceScan.File(path: "x.swift", text: code)), "\(code)")
        }
        for code in ["// Executor, in a comment", "let sender = 1", "guard let x else { return }", "let s = \"didn't send\""] {
            #expect(!Self.reachesAWrite(SourceScan.File(path: "x.swift", text: code)), "\(code)")
        }
    }
}
