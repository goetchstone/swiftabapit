import Foundation
import Testing
import TestSupport

/// The Needs-attention explanations are shown and never stored (S9.12): only the explainer, the screen's model and view, and the
/// app's wiring of the model name them, and the model's recording, judging, CSV and line-building code never touch them. So no
/// explanation reaches the history store, a snapshot, the attention store, a CSV, a log, `Answers` or an intent.
@Suite("Explain scan")
struct ExplainScanTests {
    static let allowed: Set = [
        "Packages/AbapitKit/Sources/Assist/Explain.swift",
        "Packages/AbapitApp/Sources/AppModels/NeedsAttentionModel.swift",
        "App/Screens/NeedsAttentionView.swift",
        "App/AppServices.swift",
    ]
    static let needles = ["Explain.", "Explain(", "explanation", "explained", "explainer", "explainKey", "explainsOn", ".explain("]

    @Test func onlyTheScreenAndItsWiringNameTheExplanations() throws {
        var naming: Set<String> = []
        for directory in ["Packages/AbapitKit/Sources", "Packages/AbapitApp/Sources", "App"] {
            naming.formUnion(try SourceScan.files(in: directory, matching: Self.needles))
        }
        #expect(naming == Self.allowed, Comment(rawValue: "\(naming.sorted())"))
    }

    /// The body of `name` in `text`: from its `func` line to the closing brace at its indent.
    static func body(of name: String, in text: String) -> String? {
        guard let start = text.range(of: "    \(name)") else { return nil }
        let rest = text[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return nil }
        return String(rest[..<end.upperBound])
    }

    @Test func recordingJudgingAndTheCSVNeverTouchThem() throws {
        let file = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path.hasSuffix("/NeedsAttentionModel.swift") })
        let code = SourceScan.code(file.text, strings: false)
        for name in ["public func evaluate(", "package func judge(", "public func csv(", "private func lines(", "public func dismiss(",
                     "public func snooze(_ finding: Finding, until", "private func choose("] {
            let body = try #require(Self.body(of: name, in: code), Comment(rawValue: name))
            for needle in Self.needles { #expect(!body.contains(needle), Comment(rawValue: "\(name) names \(needle)")) }
        }
        // The screen's model writes no log of them.
        for needle in ["print(", "Logger", "os_log", "NSLog"] { #expect(!code.contains(needle), Comment(rawValue: needle)) }
    }

    /// The screen's model builds the facts in one place, from the line's rule, counts, read and age alone: no finding's subject,
    /// reason or source line can reach the prompt through it.
    @Test func theScreenBuildsTheFactsFromCountsAlone() throws {
        let file = try #require(try SourceScan.swiftFiles(in: "Packages/AbapitApp/Sources/AppModels").first { $0.path.hasSuffix("/NeedsAttentionModel.swift") })
        let code = SourceScan.code(file.text, strings: false)
        #expect(code.components(separatedBy: "Explain.Facts(").count == 2, "one place builds the facts")
        let body = try #require(Self.body(of: "func facts(_ line: Line) -> Explain.Facts?", in: code))
        let expected = "return Explain.Facts(rule: line.rule, thresholds: thresholds, found: line.findings.count, hidden: line.hidden, "
            + "read: line.isPartial ? .partial : .whole, ageDays: age)"
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        #expect(squeezed(body).contains(squeezed(expected)))
        for word in ["subject", "reason", "source", "words", "title", "keeperOrg"] { #expect(!body.contains(word), Comment(rawValue: word)) }
    }

    /// The scan sees what it is meant to: a planted use in another file is found.
    @Test func theScanFindsAPlantedUse() {
        let planted = SourceScan.File(path: "x.swift", text: "func f() { store.save(model.explanation(line)) }")
        #expect(SourceScan.mentions(planted, Self.needles))
        #expect(Self.body(of: "public func csv(", in: "    public func csv() -> String {\n        x\n    }\n") != nil)
    }
}
