import Foundation

/// The repo's shared fixtures (`Tests/Fixtures`), found from this source file's location, so the package
/// tests and any app-level test read the same files. Adapted from SwiftGamGui
/// Packages/GamKit/Sources/TestSupport/Fixtures.swift @ bfdb494.
public enum Fixtures {
    /// `<repo>/Packages/AbapitKit/Sources/TestSupport/Fixtures.swift` → `<repo>`.
    public static let repoRoot: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    public static var directory: URL { repoRoot.appending(path: "Tests/Fixtures") }
    public static var parity: URL { directory.appending(path: "parity") }
    public static var docc: URL { directory.appending(path: "docc") }
    public static var recorded: URL { directory.appending(path: "recorded") }
    public static var contracts: URL { repoRoot.appending(path: "Contracts") }
    public static var packageManifest: URL { repoRoot.appending(path: "Packages/AbapitKit/Package.swift") }

    /// A parity golden by name (`Tests/Fixtures/parity/<name>.json`), parsed.
    public static func parityGolden(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: parity.appending(path: "\(name).json")),
                                         options: [.fragmentsAllowed])
    }
}

/// Swift sources as the source-scan tests read them: each file's path relative to the repo, and its
/// lines with whole-line comments dropped (a comment naming a guarded symbol is not a use of it).
public enum SourceScan {
    public struct File: Sendable {
        public let path: String
        public let lines: [String]
        public let text: String
    }

    /// Every Swift file under `directory` (relative to the repo), sorted.
    public static func swiftFiles(in directory: String) throws -> [File] {
        let base = Fixtures.repoRoot.appending(path: directory)
        guard let paths = FileManager.default.subpaths(atPath: base.path) else { return [] }
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            let text = try String(contentsOf: base.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return File(path: "\(directory)/\(path)", lines: code, text: text)
        }
    }

    /// The files under `directory` whose code mentions any of `needles`, or `word` as a whole word.
    public static func files(in directory: String, matching needles: [String], orWord word: String? = nil) throws -> Set<String> {
        let pattern = try word.map { try Regex("\\b\($0)\\b") }
        return Set(try swiftFiles(in: directory).filter { file in
            file.lines.contains { line in
                needles.contains { line.contains($0) } || pattern.map { line.contains($0) } == true
            }
        }.map(\.path))
    }

    /// The modules a file imports (`import X`, `@testable import X`, `import struct X.Y`), in order.
    public static func imports(of file: File) -> [String] {
        file.lines.compactMap { line in
            var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, first.hasPrefix("@") || ["public", "package", "internal", "private"].contains(first) {
                words.removeFirst()
            }
            guard words.first == "import", words.count >= 2 else { return nil }
            let target = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].contains(words[1]) && words.count >= 3
                ? words[2] : words[1]
            return String(target.split(separator: ".").first ?? Substring(target))
        }
    }
}
