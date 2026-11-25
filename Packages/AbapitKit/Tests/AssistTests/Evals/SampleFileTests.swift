import Foundation
import Reports
import TestSupport
import Testing
@testable import Assist

/// The shape of the two sample files. It reads the held-out file to count and check it, and prints nothing from it.
@Suite("Sample files")
struct SampleFileTests {
    static let kinds: Set<String> = ["choice", "change", "refuse"]

    func check(_ samples: [Sample], prefix: String) {
        let valid = Samples.choices
        #expect(Set(samples.map(\.id)).count == samples.count, "ids are unique")
        #expect(Set(samples.map { $0.text.lowercased() }).count == samples.count, "no phrasing twice")
        for sample in samples {
            #expect(sample.id.hasPrefix(prefix + "-"), Comment(rawValue: sample.id))
            #expect(Self.kinds.contains(sample.expect), Comment(rawValue: sample.id))
            #expect(!sample.text.isEmpty && sample.text.count <= 300, Comment(rawValue: sample.id))
            if sample.expect == "choice" {
                #expect(!sample.choices.isEmpty && Set(sample.choices).count == sample.choices.count, Comment(rawValue: sample.id))
                for id in sample.choices { #expect(valid.contains { $0.id == id }, Comment(rawValue: "\(sample.id) names a choice that exists: \(id)")) }
                let first = valid.first { $0.id == sample.choices.first }
                for group in sample.groups.compactMap({ $0 }) { #expect(first?.groups.contains(group) == true, Comment(rawValue: "\(sample.id) group")) }
                #expect(first?.groups.isEmpty == false ? !sample.groups.isEmpty : sample.groups.isEmpty || sample.groups == [nil], Comment(rawValue: "\(sample.id) groups"))
            } else {
                #expect(sample.choices.isEmpty && sample.groups.isEmpty, Comment(rawValue: sample.id))
            }
            // Invented: no tenant terms, no serial-shaped word, and an address only at example.com.
            for word in sample.text.split(whereSeparator: { $0.isWhitespace }) where word.contains("@") {
                #expect(word.lowercased().hasSuffix("example.com") || word.lowercased().hasSuffix("example.com?"), Comment(rawValue: sample.id))
            }
            #expect(sample.text.range(of: #"\b[A-Z0-9]{10,12}\b"#, options: .regularExpression) == nil, Comment(rawValue: sample.id))
        }
    }

    @Test func bothFilesHaveTheShapeAndShareNothing() throws {
        let dev = try Samples.dev(), held = try Samples.heldOut()
        check(dev, prefix: "d")
        check(held, prefix: "h")
        let seen = Set(dev.map { $0.text.lowercased() })
        #expect(held.allSatisfy { !seen.contains($0.text.lowercased()) }, "a held-out phrasing is never in dev")
    }

    @Test func everyCategoryHasAboutThirtyAndAThirdIsHeldOut() throws {
        let dev = try Samples.dev(), held = try Samples.heldOut()
        for entry in Samples.choices.prefix(7) {
            let all = (dev + held).filter { $0.choices.first == entry.id }
            #expect(all.count >= 28, Comment(rawValue: "\(entry.id): \(all.count)"))
            let heldCount = held.filter { $0.choices.first == entry.id }.count
            #expect(heldCount * 3 >= all.count - 3 && heldCount * 3 <= all.count + 3, Comment(rawValue: "\(entry.id) held out \(heldCount)"))
        }
        // Every one of the twelve rules has samples of its own, a third of them held out.
        for rule in NeedsAttention.Rule.allCases {
            let all = (dev + held).filter { $0.choices.first == "rule:\(rule.rawValue)" }
            #expect(all.count >= 6, Comment(rawValue: "\(rule): \(all.count)"))
            #expect(held.filter { $0.choices.first == "rule:\(rule.rawValue)" }.count == all.count / 3, Comment(rawValue: "\(rule) held out"))
        }
        for kind in ["change", "refuse"] {
            #expect((dev + held).filter { $0.expect == kind }.count >= 15, Comment(rawValue: kind))
            #expect(held.filter { $0.expect == kind }.count >= 4, Comment(rawValue: kind))
        }
        // Reports with groups have samples naming a group and samples asking for all of them.
        for id in ["report:activation-lock", "report:migration", "report:service-health", "report:out-of-warranty"] {
            let own = dev.filter { $0.choices.first == id }
            #expect(own.contains { $0.groups.contains { $0 != nil } } && own.contains { $0.groups.contains { $0 == nil } }, Comment(rawValue: id))
        }
    }

    /// Where a request fits a report and a rule both, both are accepted: the pairs are the ones the choices share a subject in.
    @Test func aRequestThatFitsTwoChoicesAcceptsBoth() throws {
        let dev = try Samples.dev()
        func sample(_ id: String) -> Sample { dev.first { $0.id == id }! }
        #expect(sample("d-coverage-08").choices == ["report:coverage", "rule:applecare_expiring"])
        #expect(sample("d-migration-02").choices == ["report:migration", "rule:migration_deadline"])
        #expect(sample("d-activation-lock-04").choices == ["report:activation-lock", "rule:activation_lock_user"])
        #expect(sample("d-service-health-10").choices == ["report:service-health", "rule:quiet_service"])
        // lock:NONE is locked with a lock type of NONE: a request for "no lock" asks for unlocked.
        #expect(sample("d-activation-lock-07").groups == ["unlocked"] && sample("d-activation-lock-28").groups == ["unlocked"])
        #expect(!dev.contains { $0.groups.contains("lock:NONE") })
    }

    /// A fixed-window rule fits a request only when the request names no window or the rule's own (AppleCare ending: 90 days; a
    /// quiet service: 30), and the migration rule only where the request is for the past-due ones, which is all its findings are.
    /// A request for another window, for every date, or for all the deadlines is answered by the report alone.
    @Test func aRuleIsAcceptedOnlyForTheWindowItHas() throws {
        let t = Samples.thresholds
        let ownWindow: [String: (days: Int, words: [String])] = [
            "rule:applecare_expiring": (min(t.appleCareExpiringDays, 1825), ["quarter"]),
            "rule:quiet_service": (t.quietServiceDays, ["month"]),
        ]
        var checked = 0
        for sample in try Samples.dev() + Samples.heldOut() where sample.choices.first?.hasPrefix("rule:") == false {
            let text = sample.text.lowercased()
            for rule in sample.choices.dropFirst() where rule.hasPrefix("rule:") {
                checked += 1
                if let own = ownWindow[rule] {
                    for match in text.matches(of: /(\d+)\s*days?/) { #expect(Int(match.1) == own.days, Comment(rawValue: "\(sample.id) names \(match.1) days for \(rule)")) }
                    for word in ["week", "month", "year", "quarter", "summer", "winter"] where text.contains(word) {
                        #expect(own.words.contains(word), Comment(rawValue: "\(sample.id) names a \(word) for \(rule)"))
                    }
                    #expect(!text.contains("each") && !text.contains("first") && !text.contains("end date"), Comment(rawValue: "\(sample.id) asks for every date"))
                } else if rule == "rule:migration_deadline" {
                    #expect(sample.groups == ["past-due"] || text.contains("by now"), Comment(rawValue: "\(sample.id): the rule is past-due only"))
                }
            }
        }
        #expect(checked > 20, "the pairs were found")
        // The ones the review named stay report-only.
        let dev = try Samples.dev()
        for id in ["d-coverage-20", "d-coverage-25", "d-coverage-28", "d-coverage-19", "d-coverage-14", "d-coverage-22", "d-service-health-25"] {
            #expect(dev.first { $0.id == id }?.choices.count == 1, Comment(rawValue: id))
        }
        #expect(dev.first { $0.id == "d-coverage-07" }?.choices == ["report:out-of-warranty"])
    }

    // MARK: the held-out file stays out of everything but the shape test

    func files(under path: String, ext: String) throws -> [URL] {
        var found: [URL] = []
        let root = Fixtures.repoRoot.appending(path: path)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == ext && !url.path.contains("/.build/") { found.append(url) }
        return found
    }

    /// No held-out sentence appears in any Swift file under Packages/ or App/, or any Markdown file under docs/ (a test, the rule's
    /// word lists, a comment, a runbook): what a fixer reads is never what the held-out run is scored on. A paraphrase of a
    /// sentence, or one word of it, can't be caught by a scan: the rest is discipline, and the held-out file's isolation.
    @Test func noHeldOutSentenceIsInAnySourceOrDoc() throws {
        let held = try Samples.heldOut().map { $0.text.lowercased() }
        #expect(held.count > 50)
        var scanned = 0
        for (root, ext) in [("Packages", "swift"), ("App", "swift"), ("docs", "md")] {
            for url in try files(under: root, ext: ext) {
                let text = try String(contentsOf: url, encoding: .utf8).lowercased()
                scanned += 1
                for sentence in held { #expect(!text.contains(sentence), Comment(rawValue: "\(url.lastPathComponent) holds a held-out sentence")) }
            }
        }
        #expect(scanned > 100, "the scan found the sources")
    }

    /// Only this test names the file: no other source, script or workflow has the path, and only the loader and the flagged run
    /// call the held-out reader.
    @Test func onlyTheShapeTestNamesTheHeldOutFile() throws {
        let name = "held" + "out.json"
        var roots = ["Packages", "scripts", ".github"]
        roots = roots.filter { FileManager.default.fileExists(atPath: Fixtures.repoRoot.appending(path: $0).path) }
        let quoted = "\"held" + "out\""
        var namers: [String] = [], readers: [String] = [], quotedBy: [String] = []
        for root in roots {
            for case let url as URL in FileManager.default.enumerator(at: Fixtures.repoRoot.appending(path: root), includingPropertiesForKeys: [.isRegularFileKey])!
            where !url.path.contains("/.build/") && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(name) { namers.append(url.lastPathComponent) }
                if url.pathExtension == "swift", text.contains("heldOut()") { readers.append(url.lastPathComponent) }
                if url.pathExtension == "swift", url.lastPathComponent != "Samples.swift", text.contains(quoted) { quotedBy.append(url.lastPathComponent) }
            }
        }
        #expect(namers.isEmpty, Comment(rawValue: "\(namers)"))
        #expect(quotedBy.isEmpty, Comment(rawValue: "the quoted name is only in the loader: \(quotedBy)"))
        #expect(Set(readers).isSubset(of: ["SampleFileTests.swift", "Samples.swift", "ModelEvaluations.swift"]), Comment(rawValue: "\(readers)"))
    }
}
