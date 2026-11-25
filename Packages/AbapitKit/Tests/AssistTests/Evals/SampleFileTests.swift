import Foundation
import TestSupport
import Testing
@testable import Assist

/// The shape of the two sample files. It reads `heldout.json` to count and check it, and prints nothing from it.
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
                let choice = valid.first { $0.id == sample.choice }
                #expect(choice != nil, Comment(rawValue: "\(sample.id) names a choice that exists"))
                if let group = sample.group { #expect(choice?.groups.contains(group) == true, Comment(rawValue: "\(sample.id) group")) }
            } else {
                #expect(sample.choice == nil && sample.group == nil, Comment(rawValue: sample.id))
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
            let all = (dev + held).filter { $0.choice == entry.id }
            #expect(all.count >= 28, Comment(rawValue: "\(entry.id): \(all.count)"))
            let heldCount = held.filter { $0.choice == entry.id }.count
            #expect(heldCount * 3 >= all.count - 3 && heldCount * 3 <= all.count + 3, Comment(rawValue: "\(entry.id) held out \(heldCount)"))
        }
        for kind in ["change", "refuse"] {
            #expect((dev + held).filter { $0.expect == kind }.count >= 15, Comment(rawValue: kind))
            #expect(held.filter { $0.expect == kind }.count >= 4, Comment(rawValue: kind))
        }
        // Reports with groups have samples naming a group and samples asking for all of them.
        for id in ["report:activation-lock", "report:migration", "report:service-health", "report:out-of-warranty"] {
            let own = dev.filter { $0.choice == id }
            #expect(own.contains { $0.group != nil } && own.contains { $0.group == nil }, Comment(rawValue: id))
        }
    }

    /// Only the flagged model evaluation reads the held-out file: no other test source in the evals folder names it.
    @Test func onlyTheFlaggedRunReadsTheHeldOutSamples() throws {
        let folder = Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Tests/AssistTests")
        var readers: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("heldOut()") || text.contains("\"heldout\"") { readers.append(url.lastPathComponent) }
        }
        #expect(Set(readers).isSubset(of: ["SampleFileTests.swift", "Samples.swift", "ModelEvaluations.swift"]), Comment(rawValue: "\(readers)"))
    }
}
