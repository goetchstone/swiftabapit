import Foundation
import Testing
import TestSupport

/// Invariant 9's structural half (plan §5; SwiftGamGui's `noIntentReachesAWrite`): what Siri, Shortcuts and the model reach can't
/// name the write path. The App Intents (`App/Intents/`), Assist and the answers they give (`AppModels/Answers.swift`) name no
/// `Executor`, `WriteTicket`, `send(_:ticket:)`, `HeldPreview`, `OperatorConfirmation`, `WireOperation`, write builder, `Guard`, or
/// the modules that hold them; the intents import only what answers. `scripts/check_app.sh` reads the same intents from the built
/// metadata: each in the background only, with the Mac's own authentication.
@Suite("Intents")
struct IntentTests {
    static let intents = "App/Intents"
    static let assist = "Packages/AbapitKit/Sources/Assist"
    static let answers = "Packages/AbapitApp/Sources/AppModels/Answers.swift"

    /// Names of the write path, matched anywhere in code and string literals (`SourceScan.mentions`): the chokepoint's types, the
    /// ticket's label, the write builders (`AppleWriteBuilders`, `MosyleWriteBuilders`, plan §3.2), and the modules that hold them.
    static let writes = ["Executor", "WriteTicket", "ticket:", "HeldPreview", "OperatorConfirmation", "WireOperation", "WriteBuilder",
                         "ChangeCore", "HTTPCore"]
    /// Whole names only, in code (`SourceScan.names`): `send` sits inside `sender`, and `Guard` beside Swift's `guard`.
    static let writeNames = ["send", "Guard"]
    /// What an intent file may import: the framework, SwiftUI for the snippet, and the screen models whose `Answers` it calls.
    static let intentImports: Set = ["AppIntents", "AppModels", "SwiftUI", "Foundation"]

    static func files() throws -> [SourceScan.File] {
        let answers = try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").filter { $0.path == Self.answers }
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
    /// test passed). The intents' dependency is `Answers` alone, which holds the models it reads privately.
    static let models = ["ScreenModels", "OrgsModel", "SnapshotCollector", "HistoryTransfer", "NeedsAttentionModel", "DevicesModel", "MosyleModel",
                         "ReportsModel.init", "ChangesModel", "selectClient", "snapshots.", "historyTransfer", "AppServices"]
    static let answersHolds = ["orgs", "devices", "mosyle", "reports", "attentionModel"]

    @Test func theIntentsReachAnswersAlone() throws {
        let reaching = try SourceScan.files(in: Self.intents, matching: Self.models)
        #expect(reaching.isEmpty, "\(reaching.sorted())")
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
        let app = try String(contentsOf: Fixtures.repoRoot.appending(path: "App/AppServices.swift"), encoding: .utf8)
        #expect(app.contains("let answers = screens.answers\n        AppDependencyManager.shared.add(dependency: answers)\n"), "the registration isn't Answers alone")
        #expect(app.components(separatedBy: "AppDependencyManager").count == 2 && app.components(separatedBy: "add(dependency:").count == 2)
    }

    /// No intent words an answer: the one dialog is the answer's own spoken words, made in the snippet's file.
    @Test func everyDialogIsTheAnswersWords() throws {
        let dialogs = try SourceScan.files(in: Self.intents, matching: ["IntentDialog(", "dialog:"])
        #expect(dialogs == ["\(Self.intents)/Snippets.swift"], "\(dialogs.sorted())")
        let snippet = try #require(try SourceScan.swiftFiles(in: Self.intents).first { $0.path.hasSuffix("/Snippets.swift") })
        #expect(snippet.text.contains("dialog: IntentDialog(\"\\(answer.spoken)\")"))
        // Every intent's answer comes from `Answers`: each `perform` hands the snippet what `answers` returned.
        for file in try SourceScan.swiftFiles(in: Self.intents) where SourceScan.mentions(file, ["func perform("]) {
            let performs = file.text.components(separatedBy: "func perform(").count - 1
            let answered = file.text.components(separatedBy: "AnswerSnippet.result(await answers.").count - 1
            #expect(performs == answered, "\(file.path): \(performs) intents, \(answered) answered by Answers")
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
        for name in ["ReportIntents", "AttentionIntent", "LookUpIntent", "Snippets", "Shortcuts"] {
            #expect(paths.contains("\(Self.intents)/\(name).swift"), "\(name)")
        }
        #expect(paths.contains(Self.answers))
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
