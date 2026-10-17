import Foundation
import Testing
import TestSupport

/// The screen models moved into the package to be testable (Phase 1b review M6), and the compiler now lets them
/// see `package` declarations the app can't: a secret's bytes, the Vault's reads and signatures, the read and
/// credential builders, the HTTP client. They stay on the app's side of that line (invariants 1–3): this scan holds
/// them to the routes the app itself may use, and a screen model that needs more is a design change, reviewed.
@Suite("Screen-model boundary")
struct BoundaryTests {
    static let directory = "Packages/AbapitKit/Sources/AppModels"

    /// The package-only routes, by the names a use would spell: `Secret.bytes`, `Vault.secret`/`optionalSecret`/
    /// `sign`/`refresh` and its `secretStore:` init, the `SecretStore` protocol, `ImportedKey.key`, the request and
    /// credential builders, the HTTP client, the assertion signer, the write ticket, `JSONValue.dumps`.
    static let routes = ["bytes", "secret", "optionalSecret", "sign", "refresh", "secretStore", "SecretStore", "ReadRequest", "AuthRequest",
                         "AppleRead", "HTTPClient", "ClientAssertion", "WriteTicket", "dumps", "KeychainStore", "MemoryStore", "Transport"]

    /// Swift source with its comments (nested block comments too) removed and its string and regex literals' text
    /// blanked, line breaks kept. What is inside an interpolation, `\( … )` or a raw string's `\#( … )`, stays code: a
    /// package-only call written in a status message is still a use (verifier round 1: the scan erased whole literals,
    /// interpolations included, so `"\(vault.secret(item))"` passed). A literal left open at a line's end (only a
    /// multi-line one may span lines) ends there, so a stray quote hides no more than its own line.
    static func code(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView(), i = 0
        func at(_ index: Int) -> Unicode.Scalar? { index < s.count ? s[index] : nil }
        func blank(_ count: Int) {
            for _ in 0..<count where i < s.count {
                out.append(s[i] == "\n" ? "\n" : " ")
                i += 1
            }
        }
        func hashes(from index: Int) -> Int {
            var count = 0
            while at(index + count) == "#" { count += 1 }
            return count
        }
        // Code up to the `)` that closes an interpolation (`closing`), or to the end.
        func scanCode(closing: Bool) {
            var depth = 0
            while i < s.count {
                let c = s[i], next = at(i + 1)
                if c == "/", next == "/" {
                    while i < s.count, s[i] != "\n" { blank(1) }
                } else if c == "/", next == "*" {
                    var nested = 0
                    while i < s.count {
                        if s[i] == "/", at(i + 1) == "*" {
                            nested += 1
                            blank(2)
                        } else if s[i] == "*", at(i + 1) == "/" {
                            nested -= 1
                            blank(2)
                            if nested == 0 { break }
                        } else {
                            blank(1)
                        }
                    }
                } else if c == "\"" || c == "#" {
                    let count = c == "#" ? hashes(from: i) : 0
                    if at(i + count) == "\"" {
                        blank(count)
                        scanString(hashes: count)
                    } else if c == "#", at(i + count) == "/" {
                        blank(count + 1)
                        scanRegex(hashes: count)
                    } else {
                        out.append(c)
                        i += 1
                    }
                } else {
                    if closing, c == "(" { depth += 1 }
                    if closing, c == ")" {
                        if depth == 0 {
                            blank(1)
                            return
                        }
                        depth -= 1
                    }
                    out.append(c)
                    i += 1
                }
            }
        }
        // A string literal from its opening quote: its text blanked, its interpolations scanned as code.
        func scanString(hashes count: Int) {
            let multiline = at(i + 1) == "\"" && at(i + 2) == "\""
            let quotes = multiline ? 3 : 1
            blank(quotes)
            while i < s.count {
                let c = s[i]
                if c == "\\", hashes(from: i + 1) >= count {
                    let interpolation = at(i + 1 + count) == "("
                    blank(count + 2)
                    if interpolation { scanCode(closing: true) }
                } else if c == "\"", (0..<quotes).allSatisfy({ at(i + $0) == "\"" }), hashes(from: i + quotes) >= count {
                    blank(quotes + count)
                    return
                } else if c == "\n", !multiline {
                    return
                } else {
                    blank(1)
                }
            }
        }
        // An extended regex literal from after its opening `#/`: no interpolation, so all of it is text.
        func scanRegex(hashes count: Int) {
            while i < s.count {
                if s[i] == "/", hashes(from: i + 1) >= count {
                    blank(1 + count)
                    return
                }
                blank(1)
            }
        }
        scanCode(closing: false)
        return String(out)
    }

    /// A snippet's identifiers outside comments and literal text, with `.key` kept apart (`ImportedKey.key` is the
    /// private key itself).
    static func words(_ text: String) -> (words: Set<String>, readsKey: Bool) { identifiers(code(text)) }

    /// The identifiers of code already through `code(_:)`. `.key` ends where an identifier does, not at a Unicode word
    /// boundary: `\b` reads `key.rawRepresentation` as one word, so `imported.key.rawRepresentation` slipped by.
    static func identifiers(_ code: String) -> (words: Set<String>, readsKey: Bool) {
        let words = Set(code.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        return (words, code.contains(#/\.\s*key(?![A-Za-z0-9_])/#))
    }

    @Test func theScreenModelsTakeNoPackageOnlyRoute() throws {
        let files = try SourceScan.swiftFiles(in: Self.directory)
        // The scan must see what it guards.
        #expect(Set(files.map(\.path)).isSuperset(of: ["OrgsModel.swift", "DevicesModel.swift", "DeviceDetailModel.swift"].map { "\(Self.directory)/\($0)" }))
        for file in files {
            // The whole file at once: a multi-line literal's lines are text, and its interpolations code.
            for (index, line) in Self.code(file.text).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let (words, readsKey) = Self.identifiers(String(line))
                let used = words.intersection(Self.routes)
                #expect(used.isEmpty && !readsKey, "\(file.path):\(index + 1): \(used.sorted()) \(readsKey ? ".key" : "")")
            }
        }
    }

    /// The scan sees a use however it is spaced, and wherever it sits in code, an interpolation included; it ignores
    /// one in literal text or a comment.
    @Test func theScanSeesAUseAndOnlyAUse() {
        #expect(Self.words("        let value = try await orgs.vault.secret(item)").words.contains("secret"))
        #expect(Self.words("let raw = key.key").readsKey)
        #expect(Self.words("_ = imported .key").readsKey)
        #expect(Self.words("let raw = imported.key.rawRepresentation").readsKey)
        #expect(Self.words("let note = \"a secret's bytes\" // sign here").words.isDisjoint(with: Self.routes))
        #expect(!Self.words("try await vault.storeKey(key, as: item)").readsKey)
        // Interpolations are code (verifier round 1, mutants V31 and V32).
        #expect(Self.words(#"problem = "\((try? await vault.secret(item)) == nil)""#).words.contains("secret"))
        #expect(Self.words(##"static func leak(_ s: Secret) -> String { #"\#(s.bytes.base64EncodedString())"# }"##).words.contains("bytes"))
        #expect(Self.words(###"let x = ##"a \#(no) \##(s.bytes)"##"###).words.contains("bytes"))
        #expect(Self.words(#"let shown = "\(f("\(vault.sign(data))"))""#).words.contains("sign"))
        // A call's own parentheses don't end the interpolation: what follows them is still code.
        #expect(Self.words(#"let shown = "\(f(x) + vault.secret(item))""#).words.contains("secret"))
        #expect(Self.words("let text = \"\"\"\n  key: \\(imported.key)\n  \"\"\"").readsKey)
        #expect(Self.words(#"let s = "a \"quoted\" \(x)"; let t = vault.refresh()"#).words.contains("refresh"))
        // Literal text isn't: a raw string's `\(` is text, an escaped quote doesn't end the literal, a regex literal
        // has no interpolation, and a comment inside an interpolation is a comment.
        #expect(Self.words(##"let x = #"\(s.bytes)"#"##).words.isDisjoint(with: Self.routes))
        #expect(Self.words(#"let x = "say \"secret\" twice""#).words.isDisjoint(with: Self.routes))
        #expect(Self.words(##"let r = #/secret "sign"/#; let n = 1"##).words.isDisjoint(with: Self.routes))
        #expect(Self.words(#"let x = "\(a /* vault.secret */ + b)""#).words.isDisjoint(with: Self.routes))
        #expect(Self.words("let x = \"\"\"\n  a secret, signed\n  \"\"\"").words.isDisjoint(with: Self.routes))
        // A raw string's backslash is text unless its hashes follow: one ending in `\` still closes at `"#`.
        #expect(Self.words(##"let path = #"C:\"#; let value = vault.secret(item)"##).words.contains("secret"))
        // A quote left open hides no more than its own line.
        #expect(Self.words("let x = \"open\nvault.sign(x)").words.contains("sign"))
        // Line breaks survive, so a finding's line number is the file's.
        #expect(Self.code("a\n\"\"\"\nsecret\n\"\"\"\n/* x\ny */ b").split(separator: "\n", omittingEmptySubsequences: false).count == 6)
    }
}
