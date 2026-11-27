import Foundation
import FoundationModels
import Reports
import TestSupport
import Testing
@testable import Assist

/// The explainer's model half. It calls the on-device model, so never in the fast run or on CI: `ABAPIT_MODEL_EVALS=1 swift test
/// --filter ExplainModelEvaluations` runs the dev set (refused when `CI` or `GITHUB_ACTIONS` is set, as `ModelEvaluations`). The set
/// held back runs once, behind `ABAPIT_MODEL_EVALS_SET=explain-held-out` besides, and prints scores only: no sentence, no id.
///
/// It passes (decided before the held-out run, the executor's): no kept sentence states a number the facts don't hold (the
/// independent scan, `Unsupported`), and at least three in four fact sets keep a sentence. `Explain.isOn` follows that result.
@Suite("ExplainModelEvaluations", .serialized) struct ExplainModelEvaluations {
    static func mayRunHeldBack(_ environment: [String: String]) -> Bool {
        ModelEvaluations.mayRun(environment) && environment["ABAPIT_MODEL_EVALS_SET"] == "explain-held-out"
    }

    static let flagged = ModelEvaluations.flagged
    static let heldBackFlagged = mayRunHeldBack(ProcessInfo.processInfo.environment)

    /// The on-device explainer, keeping what each call wrote so the dev run can print the dropped sentences beside their check.
    final class Recorder: Picker.Asking, @unchecked Sendable {
        let model = Explain.OnDevice()
        private let lock = NSLock()
        private var last: [String] = []
        var availability: SystemLanguageModel.Availability { model.availability }
        var supportsLocale: Bool { model.supportsLocale }
        var written: [String] { lock.withLock { last } }

        func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
            lock.withLock { last = [] }
            let content = try await model.answer(instructions: instructions, prompt: prompt, schema: schema)
            let sentences = (try? content.value([String].self, forProperty: "sentences")) ?? []
            lock.withLock { last = sentences }
            return content
        }
    }

    struct Run {
        var outcomes: [(sample: FactSample, outcome: Explain.Outcome, written: [String])] = []
        var seconds: [Double] = []

        var keptShare: Double { Double(outcomes.filter { !$0.outcome.sentences.isEmpty }.count) / Double(max(outcomes.count, 1)) }
        var writtenCount: Int { outcomes.map(\.written.count).reduce(0, +) }
        var droppedCount: Int { outcomes.map(\.outcome.dropped.count).reduce(0, +) }
        var unsupported: Int { outcomes.map { o in o.outcome.sentences.map { Unsupported.count($0, o.sample.facts) }.reduce(0, +) }.reduce(0, +) }
        var byCheck: [(String, Int)] {
            Dictionary(grouping: outcomes.flatMap(\.outcome.dropped), by: \.rawValue).mapValues(\.count).sorted { $0.key < $1.key }
        }
        var failures: [(String, Int)] {
            Dictionary(grouping: outcomes.compactMap { o -> String? in
                switch o.outcome {
                case .failed(let why): String(describing: why)
                case .off: "off"
                default: nil
                }
            }, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
        }

        var summary: String {
            let kept = outcomes.filter { !$0.outcome.sentences.isEmpty }.count
            return "kept \(kept) of \(outcomes.count) (\(String(format: "%.2f", keptShare))); dropped \(droppedCount) of \(writtenCount) sentences; "
                + "unsupported numbers kept \(unsupported); drops \(byCheck); failures \(failures); time mean "
                + String(format: "%.2f", seconds.reduce(0, +) / Double(max(seconds.count, 1))) + " s, most " + String(format: "%.2f", seconds.max() ?? 0) + " s"
        }

        var passes: Bool { unsupported == 0 && keptShare >= 0.75 }
    }

    static func run(_ samples: [FactSample]) async throws -> Run {
        let model = Recorder()
        try #require(model.availability == .available, "the flag is set and the on-device model isn't available on this Mac")
        var run = Run()
        let clock = ContinuousClock()
        for sample in samples {
            let start = clock.now
            let outcome = try await Explain.explain(sample.facts, using: model)
            let took = start.duration(to: clock.now).components
            run.seconds.append(Double(took.seconds) + Double(took.attoseconds) / 1e18)
            run.outcomes.append((sample, outcome, model.written))
        }
        return run
    }

    @Test(.enabled(if: ExplainModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set, or CI or GITHUB_ACTIONS is: this calls the on-device model"))
    func theExplainerOnDev() async throws {
        let dev = try ExplainSamples.dev()
        let run = try await Self.run(dev)
        print("EVAL explain dev: \(run.summary); passes \(run.passes)")
        // Dev only: every sentence as written, kept or dropped with its check, for a person to judge which drops were true.
        for (sample, outcome, written) in run.outcomes {
            let facts = sample.facts
            print("EVAL explain \(sample.id) FACTS \(sample.rule) found \(sample.found) hidden \(sample.hidden) read \(sample.read) age \(sample.ageDays.map(String.init) ?? "live")")
            for sentence in written {
                let tidy = sentence.trimmingCharacters(in: .whitespaces)
                let kept = outcome.sentences.contains(tidy)
                print("EVAL explain \(sample.id) \(kept ? "KEPT" : "DROP \(Explain.check(tidy, facts).map(\.rawValue) ?? "repeat/extra")"): \(tidy)")
            }
            if case .failed(let why) = outcome { print("EVAL explain \(sample.id) FAILED \(why)") }
        }
        // The same through Apple's Evaluations, which must agree with the run's own counts (the recorded outcomes, no second call).
        let kept = Dictionary(uniqueKeysWithValues: run.outcomes.map { ($0.sample.id, ($0.outcome, $0.written.count)) })
        let evaluation = ExplainEvaluation(samples: dev) { facts in
            let id = dev.first { $0.facts == facts }!.id
            return kept[id]!
        }
        let result = try await evaluation.run(info: ["split": "dev", "explainer": "model"])
        #expect(abs(result.aggregateValue(.mean(of: evaluation.kept)) - run.keptShare) < 1e-9)
        #expect(result.aggregateValue(.custom(label: ExplainEvaluation.unsupportedSum)) == Double(run.unsupported))
        #expect(run.unsupported == 0, "no kept sentence states a number the facts don't hold")
    }

    /// The single run over the set held back: scores and times only, no sentence, no id; it asserts nothing.
    @Test(.enabled(if: ExplainModelEvaluations.heldBackFlagged, "ABAPIT_MODEL_EVALS=1 and ABAPIT_MODEL_EVALS_SET=explain-held-out are not both set, or CI or GITHUB_ACTIONS is"))
    func theExplainerOnTheSetHeldBack() async throws {
        let run = try await Self.run(try ExplainSamples.explainHeldOut())
        print("EVAL explain held back: \(run.summary); passes \(run.passes)")
    }

    /// The largest call, counted with the model's own `tokenCount`: the instructions, the longest prompt and the schema, plus the cap.
    @Test(.enabled(if: ExplainModelEvaluations.flagged, "ABAPIT_MODEL_EVALS=1 is not set, or CI or GITHUB_ACTIONS is: tokenCount needs the on-device model"))
    func theWholeCallFitsTheBudget() async throws {
        let model = SystemLanguageModel.default
        try #require(model.availability == .available)
        let longest = try ExplainSamples.dev().map { Explain.prompt($0.facts) }.max { $0.count < $1.count }!
        let parts = [try await model.tokenCount(for: Instructions(Explain.instructions)), try await model.tokenCount(for: longest),
                     try await model.tokenCount(for: try Explain.schema())]
        let whole = parts.reduce(Explain.responseCap, +)
        print("BUDGET explain tokenCount: instructions \(parts[0]), prompt \(parts[1]), schema \(parts[2]), cap \(Explain.responseCap): \(whole); context \(model.contextSize)")
        #expect(whole <= 1500)
    }

    @Test func theSetHeldBackNeedsItsOwnSwitch() {
        #expect(!Self.mayRunHeldBack(["ABAPIT_MODEL_EVALS": "1"]))
        #expect(!Self.mayRunHeldBack(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "held-out"]), "the picker's switch isn't this one")
        #expect(!ModelEvaluations.mayRunHeldOut(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "explain-held-out"]), "nor this the picker's")
        #expect(Self.mayRunHeldBack(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "explain-held-out"]))
        #expect(!Self.mayRunHeldBack(["ABAPIT_MODEL_EVALS": "1", "ABAPIT_MODEL_EVALS_SET": "explain-held-out", "GITHUB_ACTIONS": "true"]))
    }
}

/// The shape of the two fact files, and the set held back kept out of everything but this test, its loader and the flagged run.
@Suite("Explain fact files")
struct ExplainSampleFileTests {
    func check(_ samples: [FactSample], prefix: String) {
        #expect(Set(samples.map(\.id)).count == samples.count)
        for sample in samples {
            #expect(sample.id.hasPrefix(prefix + "-"), Comment(rawValue: sample.id))
            #expect(NeedsAttention.Rule(rawValue: sample.rule) != nil, Comment(rawValue: sample.id))
            #expect(sample.found >= 1 && sample.hidden >= 0 && sample.hidden <= sample.found, Comment(rawValue: sample.id))
            #expect(sample.ageDays.map { $0 >= 0 } ?? true, Comment(rawValue: sample.id))
        }
        // Every rule has a fact set.
        #expect(Set(samples.map(\.rule)) == Set(NeedsAttention.Rule.allCases.map(\.rawValue)))
    }

    @Test func bothFilesHaveTheShape() throws {
        let dev = try ExplainSamples.dev(), held = try ExplainSamples.explainHeldOut()
        check(dev, prefix: "ed")
        check(held, prefix: "eh")
        #expect(dev.count >= 24 && held.count >= 12)
        #expect(dev.contains { $0.read == .partial } && dev.contains { $0.ageDays == nil } && dev.contains { $0.found >= 1000 })
    }

    /// Only the loader names the file and only the loader, this test and the flagged run read it.
    @Test func onlyTheLoaderNamesTheSetHeldBack() throws {
        let name = "explain-" + "held" + "out", reader = "explain" + "HeldOut()"
        var namers: [String] = [], readers: [String] = []
        for root in ["Packages", "scripts", ".github", "App"] where FileManager.default.fileExists(atPath: Fixtures.repoRoot.appending(path: root).path) {
            for case let url as URL in FileManager.default.enumerator(at: Fixtures.repoRoot.appending(path: root), includingPropertiesForKeys: nil)!
            where !url.path.contains("/.build/") && ["swift", "sh", "py", "yml", "yaml", "json"].contains(url.pathExtension) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(name) { namers.append(url.lastPathComponent) }
                if text.contains(reader) { readers.append(url.lastPathComponent) }
            }
        }
        #expect(namers.isEmpty, Comment(rawValue: "\(namers)"))
        #expect(Set(readers).isSubset(of: ["ExplainEvaluation.swift", "ExplainModelEvaluations.swift"]), Comment(rawValue: "\(readers)"))
    }
}
