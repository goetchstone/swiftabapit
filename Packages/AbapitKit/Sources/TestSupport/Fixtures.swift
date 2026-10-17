#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

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

    /// A parity golden as `JSONValue`: keys in the order the generator wrote them (abapit's CSV columns depend
    /// on it), strings and numbers as exact text.
    public static func parityValue(_ name: String) throws -> JSONValue {
        guard let value = JSONValue.parse(String(decoding: try parity(name), as: UTF8.self)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}

/// Swift sources as the source-scan tests read them: each file's path relative to the repo, its text, and its
/// lines with whole-line comments dropped. The scans read the text as Swift's lexer does (`code(_:strings:)`):
/// a comment is never a use of what it names; a string literal is, since it is how a run-time lookup names a
/// class (`NSClassFromString("NSURLSession")`).
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
            File(path: "\(directory)/\(path)", text: try String(contentsOf: base.appending(path: path), encoding: .utf8))
        }
    }

    /// The files under `directory` whose code or string literals mention any of `needles`
    /// (`mentions(_:_:except:)`).
    public static func files(in directory: String, matching needles: [String], except: [String] = []) throws -> Set<String> {
        Set(try swiftFiles(in: directory).filter { mentions($0, needles, except: except) }.map(\.path))
    }

    /// Whether `file`'s code or string literals mention any of `needles`; comments don't count. A needle matches
    /// anywhere, inside a longer name too (`NSURLSession`, `URLSessionConfiguration`), and across whitespace,
    /// which Swift accepts in `ReadRequest (host:`, `ReadRequest .init(host:` and `.init(` before a line break,
    /// and across a raw identifier's backticks, which name what they hold: `` Data(`contentsOf`: url) `` is
    /// `Data(contentsOf: url)`, and passed `contentsOf:` while the backticks stayed (Phase 1b gates verifier round 2).
    /// It never matches inside a whole `except` name, bounded by ASCII punctuation or space on both sides
    /// (`URLSessionTransport` is not `URLSession`). Phase 1b review H3: `\bURLSession\b` uses Unicode word
    /// boundaries, which don't split `URLSession.shared`, so `URLSession.shared.upload(…)` passed the transport scan.
    public static func mentions(_ file: File, _ needles: [String], except: [String] = []) -> Bool {
        var scalars = codeScalars(file.text, strings: true)
        for name in except {
            let length = name.unicodeScalars.count
            for start in offsets(of: name, in: scalars) where isBoundary(start - 1, in: scalars) && isBoundary(start + length, in: scalars) {
                for index in start..<start + length { scalars[index] = " " }
            }
        }
        let squeezed = scalars.filter { !$0.properties.isWhitespace && $0 != "`" }
        return needles.contains { !offsets(of: $0, in: squeezed).isEmpty }
    }

    /// The files under `directory` whose code names any of `names` (`names(_:_:)`).
    public static func files(in directory: String, naming names: [String]) throws -> Set<String> {
        Set(try swiftFiles(in: directory).filter { Self.names($0, names) }.map(\.path))
    }

    /// Whether `file`'s code holds any of `names` whole: with no `[A-Za-z0-9_]` right before or after it, so
    /// `` `send` ``, `t.send` and `send (r, limit: 1)` hold `send`, and `sender` doesn't. Comments and string literals
    /// don't count. For a name a substring needle can't hold, since it sits inside common ones (`send` in `sender`,
    /// `Process` in `ProcessInfo`, `environ` in `environment`).
    public static func names(_ file: File, _ names: [String]) -> Bool {
        let code = codeScalars(file.text, strings: false)
        return names.contains { !nameOffsets(of: $0, in: code).isEmpty }
    }

    /// What a scan reports: `what` on line `line` (from 1) of `path`.
    public struct Spot: Sendable, Equatable, CustomStringConvertible {
        public let path: String
        public let line: Int
        public let what: String
        public var description: String { "\(path):\(line): \(what)" }

        /// The spot at scalar `offset` of `file`. A line ends at LF, CR or CRLF, as it does for Swift's lexer.
        init(_ file: File, _ offset: Int, _ what: String) {
            let text = Array(file.text.unicodeScalars)
            path = file.path
            line = (0..<min(offset, text.count)).count { text[$0] == "\n" || (text[$0] == "\r" && ($0 + 1 == text.count || text[$0 + 1] != "\n")) } + 1
            self.what = what
        }
    }

    /// Where `file` holds code the lexer under every scan can't vouch for reading as Swift does: a `/` in code that
    /// isn't division written with a space on each side (` / `). Swift 6 lexes a bare `/…/` regex literal wherever an
    /// expression can start (`= /x/`, `return/x/`, `!/x/`, `(/x/`), and this lexer doesn't follow one: `/\/*/` opened a
    /// block comment here that swiftc never saw and blanked the code after it, and `/"/` a string (Phase 1b gates
    /// verifier round 1). A regex literal can't begin with a space, so ` / ` is always division. Write a regex as
    /// `#/…/#`, which the lexer follows, and division with spaces: the scans then read every file whole.
    public static func unreadable(_ file: File) -> [Spot] {
        let code = codeScalars(file.text, strings: false)
        func spaced(_ offset: Int) -> Bool { code.indices.contains(offset) && [" ", "\t", "\n", "\r"].contains(code[offset]) }
        return code.indices.filter { code[$0] == "/" && !(spaced($0 - 1) && spaced($0 + 1)) }.map {
            Spot(file, $0, "a / that isn't spaced division (a bare regex literal hides code from the scans: write #/…/# or a / b)")
        }
    }

    /// Where `file` mentions one of `needles` outside the true branch of an `#if DEBUG`, nested at any depth: an
    /// `#elseif DEBUG` branch counts; an `#else`, any other condition (`DEBUG || X`, `!DEBUG`) and no `#if` at
    /// all don't. Comments don't count; string literals do when `strings` is true. Directives are read from the
    /// code alone, so one in a comment or a string is text, and one after code on its line (`let a = 1; #if
    /// DEBUG`, which Swift accepts) still counts. A directive that doesn't balance is a spot too. Phase 1b review
    /// M1: a switch name of 15 bytes or fewer never reaches `strings` (Swift keeps it inside the instructions), so
    /// `scripts/check_app.sh` can't see `ABAPIT_DEMO`; this scan can. Each of `names` counts only whole, as in
    /// `names(_:_:)`: `environ`, not `environment`.
    public static func outsideDebug(_ file: File, _ needles: [String], names: [String] = [], strings: Bool) -> [Spot] {
        let code = codeScalars(file.text, strings: false)
        let searched = strings ? codeScalars(file.text, strings: true) : code
        var events: [(offset: Int, directive: String?, text: String)] = []
        var index = 0
        while index < code.count {
            guard code[index] == "#" else { index += 1; continue }
            var end = index + 1
            while end < code.count, isNameScalar(code[end]) { end += 1 }
            let word = String(String.UnicodeScalarView(code[index + 1..<end]))
            guard ["if", "elseif", "else", "endif"].contains(word) else { index = end; continue }
            var lineEnd = end
            while lineEnd < code.count, !isLineEnd(code[lineEnd]) { lineEnd += 1 }
            let condition = String(String.UnicodeScalarView(code[end..<lineEnd])).trimmingCharacters(in: .whitespacesAndNewlines)
            events.append((index, word, condition))
            index = lineEnd
        }
        for needle in needles {
            events += offsets(of: needle, in: searched).map { ($0, nil, needle) }
        }
        for name in names {
            events += nameOffsets(of: name, in: searched).map { ($0, nil, name) }
        }
        var branches: [Bool] = [], spots: [Spot] = []
        func spot(_ offset: Int, _ what: String) { spots.append(Spot(file, offset, what)) }
        for event in events.sorted(by: { $0.offset < $1.offset }) {
            switch event.directive {
            case "if": branches.append(event.text == "DEBUG")
            case "elseif", "else":
                guard !branches.isEmpty else { spot(event.offset, "#\(event.directive ?? "") without an #if"); continue }
                branches[branches.count - 1] = event.directive == "elseif" && event.text == "DEBUG"
            case "endif":
                if branches.popLast() == nil { spot(event.offset, "#endif without an #if") }
            default:
                if !branches.contains(true) { spot(event.offset, "\(event.text) outside #if DEBUG") }
            }
        }
        if !branches.isEmpty { spot(code.count, "an #if is never closed") }
        return spots
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

    /// Swift source as tokens: the code alone (`code(_:strings: false)`), split on whitespace and punctuation
    /// other than `.`, `_` and `@`.
    static func tokenize(_ text: String) -> [String] {
        let kept = codeScalars(text, strings: false).map { scalar -> Unicode.Scalar in
            scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "." || scalar == "@" ? scalar : " "
        }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").map(String.init)
    }

    /// `text` as the scans read it: every comment blanked (block comments nest), and every string literal's
    /// contents too unless `strings` is true, one space per scalar with line breaks kept, so an offset or a line
    /// is the one in the source. It follows Swift's lexer through raw strings (`#"…"#`, where `\` is a
    /// backslash), multi-line strings, escapes, interpolations (`\(…)`: code again, its comments and strings
    /// too), extended regex literals (`#/…/#`, blanked like a string, its slashes too) and raw identifiers (`` `a // b` ``, Swift
    /// 6.2: blanked unless the name is plain, as `` `URLSession` `` is), so a `//` or `/*` inside one can't hide
    /// the code after it and a directive inside one is text. A line ends at LF or CR, as it does for swiftc: a
    /// lone CR ended a `//` comment there and not here, and hid the code after it (Phase 1b gates verifier
    /// round 1). Not followed: a bare `/…/` regex literal, which `unreadable(_:)` refuses instead.
    public static func code(_ text: String, strings: Bool) -> String {
        String(String.UnicodeScalarView(codeScalars(text, strings: strings)))
    }

    static func codeScalars(_ text: String, strings: Bool) -> [Unicode.Scalar] {
        enum Context { case code, interpolation(depth: Int), string(hashes: Int, multiline: Bool), regex(hashes: Int) }
        let source = Array(text.unicodeScalars)
        var out = source, stack: [Context] = [.code], index = 0
        func at(_ offset: Int) -> Unicode.Scalar? { offset < source.count ? source[offset] : nil }
        func hashes(from offset: Int) -> Int {
            var end = offset
            while at(end) == "#" { end += 1 }
            return end - offset
        }
        func blank(_ range: Range<Int>) { for offset in range where !isLineEnd(source[offset]) { out[offset] = " " } }
        func literal(_ range: Range<Int>) { if !strings { blank(range) } }
        while index < source.count {
            let scalar = source[index]
            switch stack[stack.count - 1] {
            case .code, .interpolation:
                let count = hashes(from: index)
                if scalar == "/", at(index + 1) == "/" {
                    let start = index
                    while index < source.count, !isLineEnd(source[index]) { index += 1 }
                    blank(start..<index)
                } else if scalar == "`", let close = (index + 1..<source.count).first(where: { source[$0] == "`" || isLineEnd(source[$0]) }),
                          source[close] == "`" {
                    // A raw identifier is one name, whatever it holds. A plain one is kept (`` `URLSession` `` is URLSession);
                    // any other is a name no API has, and is blanked.
                    if !source[index + 1..<close].allSatisfy(isNameScalar) { blank(index + 1..<close) }
                    index = close + 1
                } else if scalar == "/", at(index + 1) == "*" {
                    let start = index
                    var depth = 0
                    repeat {
                        if source[index] == "/", at(index + 1) == "*" { depth += 1; index += 2 }
                        else if source[index] == "*", at(index + 1) == "/" { depth -= 1; index += 2 }
                        else { index += 1 }
                    } while depth > 0 && index < source.count
                    blank(start..<index)
                } else if at(index + count) == "\"" {
                    let multiline = at(index + count + 1) == "\"" && at(index + count + 2) == "\""
                    index += count + (multiline ? 3 : 1)
                    stack.append(.string(hashes: count, multiline: multiline))
                } else if count > 0, at(index + count) == "/" {
                    literal(index + count..<index + count + 1)  // a delimiter's `/` isn't code: `unreadable` reads every other
                    index += count + 1
                    stack.append(.regex(hashes: count))
                } else {
                    if case .interpolation(let depth) = stack[stack.count - 1] {
                        if scalar == "(" { stack[stack.count - 1] = .interpolation(depth: depth + 1) }
                        if scalar == ")" {
                            if depth == 0 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(depth: depth - 1) }
                        }
                    }
                    index += 1
                }
            case .string(let count, let multiline):
                let quotes = multiline ? 3 : 1
                if scalar == "\\", hashes(from: index + 1) >= count {
                    // An escape: `\` and the literal's own hashes, then `(` (an interpolation) or one scalar.
                    let after = index + 1 + count
                    let end = min(after + 1, source.count)
                    literal(index..<end)
                    index = end
                    if at(after) == "(" { stack.append(.interpolation(depth: 0)) }
                } else if scalar == "\"", (0..<quotes).allSatisfy({ at(index + $0) == "\"" }), hashes(from: index + quotes) >= count {
                    index += quotes + count
                    stack.removeLast()
                } else if isLineEnd(scalar), !multiline {
                    stack.removeLast()  // unterminated: Swift's lexer ends it at the line break too
                } else {
                    literal(index..<index + 1)
                    index += 1
                }
            case .regex(let count):
                if scalar == "\\" {
                    let end = min(index + 2, source.count)
                    literal(index..<end)
                    index = end
                } else if scalar == "/", hashes(from: index + 1) >= count {
                    literal(index..<index + 1)
                    index += 1 + count
                    stack.removeLast()
                } else {
                    literal(index..<index + 1)
                    index += 1
                }
            }
        }
        return out
    }

    /// Every offset in `scalars` where `needle` begins, compared scalar by scalar (canonical equivalence would
    /// let a decomposed spelling match a precomposed one, and the reverse miss).
    static func offsets(of needle: String, in scalars: [Unicode.Scalar]) -> [Int] {
        let pattern = Array(needle.unicodeScalars)
        guard let first = pattern.first, pattern.count <= scalars.count else { return [] }
        return (0...(scalars.count - pattern.count)).filter { start in
            scalars[start] == first && scalars[start..<start + pattern.count].elementsEqual(pattern)
        }
    }

    /// Every offset in `scalars` where `name` stands whole: no `[A-Za-z0-9_]` right before or after it. Any other
    /// scalar ends a name here, one outside ASCII too, so a scan for a name finds more, never less.
    static func nameOffsets(of name: String, in scalars: [Unicode.Scalar]) -> [Int] {
        let length = name.unicodeScalars.count
        func inName(_ offset: Int) -> Bool { scalars.indices.contains(offset) && isNameScalar(scalars[offset]) }
        return offsets(of: name, in: scalars).filter { !inName($0 - 1) && !inName($0 + length) }
    }

    /// LF or CR: Swift's lexer ends a line at either (a CRLF is two, which changes nothing here).
    static func isLineEnd(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }

    /// `[A-Za-z0-9_]`.
    static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
    }

    /// Whether `offset` is the edge of the text or ASCII that can't be part of a name. A scalar outside ASCII is
    /// never a boundary here: it might be part of a name, and a boundary only ever excuses code.
    static func isBoundary(_ offset: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.indices.contains(offset) else { return true }
        return scalars[offset].isASCII && !isNameScalar(scalars[offset])
    }
}
#endif
