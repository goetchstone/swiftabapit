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

    /// A parity golden's bytes (`Tests/Fixtures/parity/<name>.json`): decode it with `JSONDecoder`, which keeps
    /// every string's code points. `JSONSerialization` dropped a leading U+FEFF from a string value, so the
    /// golden `"\u{FEFF}ab"` was tested as `ab` on both sides (Phase 0's review).
    public static func parity(_ name: String) throws -> Data {
        try Data(contentsOf: parity.appending(path: "\(name).json"))
    }
}

/// Swift sources as the source-scan tests read them: each file's path relative to the repo, and its
/// lines with whole-line comments dropped (a comment naming a guarded symbol is not a use of it).
public enum SourceScan {
    public struct File: Sendable {
        public let path: String
        public let lines: [String]
        public let text: String

        public init(path: String, text: String) {
            self.path = path
            self.text = text
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }
    }

    /// Every Swift file under `directory` (relative to the repo), sorted.
    public static func swiftFiles(in directory: String) throws -> [File] {
        let base = Fixtures.repoRoot.appending(path: directory)
        guard let paths = FileManager.default.subpaths(atPath: base.path) else { return [] }
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            try File(path: "\(directory)/\(path)", text: try String(contentsOf: base.appending(path: path), encoding: .utf8))
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

    /// The modules a file imports, however it is spelled: `import X`, `@testable import X`, `@preconcurrency
    /// import X`, `fileprivate import X`, `import struct X.Y`, several on one line after `;`, an `import` on
    /// one line and its module on the next. Comments and string literals are removed first, so neither hides
    /// an import nor fakes one (Phase 0's review).
    public static func imports(of file: File) -> [String] {
        let tokens = tokenize(file.text)
        var found: [String] = []
        let kinds: Set = ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias", "actor", "macro"]
        for (index, token) in tokens.enumerated() where token == "import" {
            var next = index + 1
            if next < tokens.count, kinds.contains(tokens[next]) { next += 1 }
            guard next < tokens.count else { continue }
            let module = tokens[next].split(separator: ".").first.map(String.init) ?? tokens[next]
            if !module.isEmpty, module.first?.isLetter == true || module.first == "_" { found.append(module) }
        }
        return found
    }

    /// Swift source as tokens, with comments (nested block comments too) and string literals' contents dropped,
    /// split on whitespace and punctuation other than `.`, `_` and `@`.
    static func tokenize(_ text: String) -> [String] {
        var out = "", depth = 0, inString = false, inLineComment = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index], next = index + 1 < scalars.count ? scalars[index + 1] : " "
            if inLineComment {
                if scalar == "\n" { inLineComment = false; out.append(" ") }
            } else if depth > 0 {
                if scalar == "*", next == "/" { depth -= 1; index += 1 } else if scalar == "/", next == "*" { depth += 1; index += 1 }
            } else if inString {
                if scalar == "\\" { index += 1 } else if scalar == "\"" || scalar == "\n" { inString = false; out.append(" ") }
            } else if scalar == "/", next == "/" {
                inLineComment = true
            } else if scalar == "/", next == "*" {
                depth = 1
                index += 1
            } else if scalar == "\"" {
                inString = true
            } else if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "." || scalar == "@" {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
            index += 1
        }
        return out.split(separator: " ").map(String.init)
    }
}
