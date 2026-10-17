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

    /// Every package-only name the screen models can reach, by the names a use would spell: `Secret.bytes`,
    /// `Vault.secret`/`optionalSecret`/`sign`/`refresh` and its `secretStore:` init, the `SecretStore` protocol and
    /// its stores, the request and credential builders (`URL.make` among them), the HTTP client, the assertion
    /// signer, the write ticket, `JSONValue.dumps`. `everyPackageDeclarationTheModelsCanReachIsARoute` holds this
    /// list to the declarations themselves. Reflection too (`Mirror`, `String(reflecting:)`, `dump`): it reads
    /// stored properties that access control hides, so no screen model uses it (verifier round 2).
    static let routes = ["bytes", "secret", "optionalSecret", "sign", "refresh", "secretStore", "SecretStore", "ReadRequest", "AuthRequest",
                         "AppleRead", "HTTPClient", "ClientAssertion", "WriteTicket", "dumps", "KeychainStore", "MemoryStore", "Transport",
                         "make", "MosyleModelsModule", "Mirror", "reflecting", "dump"]

    /// Names that are a route only as a member: `ImportedKey.key` is the private key itself, and a bare `key` is
    /// everywhere (`storeKey(key, as:)`). `identifiers(_:)` reads `.key`.
    static let members = ["key"]

    /// LF or CR: swiftc ends a line, and so a `//` comment or an unclosed string, at either (verifier round 2: a lone
    /// CR ended a comment for swiftc and not here, and the code after it was blanked).
    static func isLineEnd(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }

    /// `[A-Za-z0-9_]`: a raw identifier made only of these is that plain name.
    static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_")
    }

    /// Swift source with its comments (nested block comments too) removed and its string and regex literals' text
    /// blanked, line breaks kept. What is inside an interpolation, `\( … )` or a raw string's `\#( … )`, stays code: a
    /// package-only call written in a status message is still a use (verifier round 1: the scan erased whole literals,
    /// interpolations included, so `"\(vault.secret(item))"` passed). A raw identifier is one name: a plain one stays
    /// (`` .`key` `` is `.key`), any other is blanked, and a quote in one opens no string; an extended regex's `\`
    /// escapes the next scalar, as swiftc reads `#/a\/#"/#` (verifier round 2). A bare `/…/` regex literal is not
    /// followed: `unreadable(_:)` refuses every `/` that could open one.
    static func code(_ text: String) -> String {
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView(), i = 0
        func at(_ index: Int) -> Unicode.Scalar? { index < s.count ? s[index] : nil }
        func blank(_ count: Int) {
            for _ in 0..<count where i < s.count {
                out.append(isLineEnd(s[i]) ? s[i] : " ")
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
                    while i < s.count, !isLineEnd(s[i]) { blank(1) }
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
                } else if c == "`", let close = (i + 1..<s.count).first(where: { s[$0] == "`" || isLineEnd(s[$0]) }), s[close] == "`" {
                    let name = s[(i + 1)..<close]
                    blank(1)
                    if name.allSatisfy(isPlain) {
                        out.append(contentsOf: name)
                        i = close
                    } else {
                        blank(close - i)
                    }
                    blank(1)
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
                } else if isLineEnd(c), !multiline {
                    return
                } else {
                    blank(1)
                }
            }
        }
        // An extended regex literal from after its opening `#/`: no interpolation, so all of it is text, and a `\`
        // escapes the scalar after it.
        func scanRegex(hashes count: Int) {
            while i < s.count {
                if s[i] == "\\" {
                    blank(2)
                } else if s[i] == "/", hashes(from: i + 1) >= count {
                    blank(1 + count)
                    return
                } else {
                    blank(1)
                }
            }
        }
        scanCode(closing: false)
        return String(out)
    }

    /// The lines (from 1) of Swift source `text` whose code holds a `/` other than division with a space on each side.
    /// Swift 6 lexes a bare `/…/` regex literal wherever an expression can start, and `code(_:)` doesn't follow one:
    /// `/"/` opened a string swiftc never saw and hid the rest of its line, and `/"""/` every line after it (verifier
    /// round 2). A regex literal can't begin with a space, so ` / ` is always division: the screen models write a regex
    /// as `#/…/#` and division with spaces, and are then read whole, as `SourceScan` reads the tree. The spaces are the
    /// source's own (`code(_:)` keeps every scalar's place), since a blanked quote would read as one.
    static func unreadable(_ text: String) -> [Int] {
        let source = Array(text.unicodeScalars), code = Array(Self.code(text).unicodeScalars)
        func spaced(_ index: Int) -> Bool {
            source.indices.contains(index) && (source[index] == " " || source[index] == "\t" || isLineEnd(source[index]))
        }
        var line = 1, lines: [Int] = []
        for index in code.indices {
            if code[index] == "\n" { line += 1 }
            if code[index] == "/", !(spaced(index - 1) && spaced(index + 1)) { lines.append(line) }
        }
        return lines
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

    /// Every `package` declaration in `code`, already through `code(_:)`: its name (an initializer's first label, so
    /// `init(secretStore:)` is `secretStore`; `init` when it has none) and the types it sits in, outermost first. A
    /// `package` before a word that is neither a modifier nor a declaration is named `?`, so it fails the check rather
    /// than pass unseen.
    static func packageDeclarations(_ code: String) -> [(name: String, types: [String])] {
        var tokens: [String] = [], word = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" {
                word.append(scalar)
                continue
            }
            if !word.isEmpty { tokens.append(String(word)) }
            word = String.UnicodeScalarView()
            if !scalar.properties.isWhitespace { tokens.append(String(scalar)) }
        }
        if !word.isEmpty { tokens.append(String(word)) }
        func token(_ index: Int) -> String? { index < tokens.count ? tokens[index] : nil }
        let types: Set = ["struct", "class", "enum", "actor", "protocol", "extension"]
        let members: Set = ["func", "var", "let", "init", "subscript", "typealias", "case", "macro", "associatedtype", "import"]
        let modifiers: Set = ["static", "final", "class", "nonisolated", "override", "mutating", "nonmutating", "convenience", "required", "lazy",
                              "weak", "unowned", "dynamic", "indirect", "optional", "distributed", "consuming", "borrowing"]
        var scopes: [String?] = [], pending: String?, found: [(name: String, types: [String])] = []
        var index = 0
        while let current = token(index) {
            defer { index += 1 }
            switch current {
            case "{":
                scopes.append(pending)
                pending = nil
            case "}":
                _ = scopes.popLast()
            case _ where types.contains(current) && !(current == "class" && token(index + 1).map(members.contains) == true):
                // The type's name, dotted for an extension of a nested type.
                var name = token(index + 1) ?? "", next = index + 2
                while token(next) == ".", let part = token(next + 1) {
                    name += "." + part
                    next += 2
                }
                pending = name
            case _ where members.contains(current):
                pending = nil
            case "package":
                // `package(set)`, then modifiers and attributes (`@MainActor`, `@available(…)`) in any order.
                var next = index + 1
                if token(next) == "(", token(next + 1) == "set", token(next + 2) == ")" { next += 3 }
                while let word = token(next) {
                    if modifiers.contains(word) {
                        next += 1
                    } else if word == "@" {
                        next += 2
                        var depth = 0
                        while let part = token(next), part == "(" || depth > 0 {
                            depth += part == "(" ? 1 : part == ")" ? -1 : 0
                            next += 1
                        }
                    } else {
                        break
                    }
                }
                // `package:`, `package = 1`, `return package }`: a name, not a modifier.
                guard let kind = token(next), kind.first.map({ $0.isLetter || $0 == "_" }) == true, kind != "import" else { break }
                guard types.contains(kind) || members.contains(kind) else {
                    found.append(("?", scopes.compactMap { $0 }))
                    break
                }
                // A subscript is reached by `[ ]`, never by a name: only its type can cover it.
                var name = kind == "subscript" ? kind : token(next + 1) ?? ""
                if kind == "init" {
                    var open = next + 1
                    while token(open) == "?" || token(open) == "!" { open += 1 }
                    let label = token(open) == "(" ? token(open + 1) ?? "" : ""
                    name = label.first.map { $0.isLetter || $0 == "_" } == true && label != "_" ? label : kind
                }
                found.append((name, scopes.compactMap { $0 }))
            default:
                break
            }
        }
        return found
    }

    /// The modules the screen models can reach: AppModels' dependencies in Package.swift, and theirs.
    static func reachableModules() throws -> Set<String> {
        let text = try String(contentsOf: Fixtures.packageManifest, encoding: .utf8)
        let target = try Regex(#"\.target\(name:\s*"([A-Za-z]+)"(?:,\s*dependencies:\s*\[([^\]]*)\])?"#)
        var edges: [String: [String]] = [:]
        for match in text.matches(of: target) {
            let list = match.output[2].substring.map(String.init) ?? ""
            edges[String(match.output[1].substring ?? "")] = list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }.filter { !$0.isEmpty }
        }
        var reached = Set<String>(), stack = ["AppModels"]
        while let module = stack.popLast() {
            for edge in edges[module] ?? [] where reached.insert(edge).inserted { stack.append(edge) }
        }
        return reached
    }

    @Test func theScreenModelsTakeNoPackageOnlyRoute() throws {
        let files = try SourceScan.swiftFiles(in: Self.directory)
        // The scan must see what it guards.
        #expect(Set(files.map(\.path)).isSuperset(of: ["OrgsModel.swift", "DevicesModel.swift", "DeviceDetailModel.swift"].map { "\(Self.directory)/\($0)" }))
        for file in files {
            // The whole file at once: a multi-line literal's lines are text, and its interpolations code.
            let code = Self.code(file.text)
            #expect(Self.unreadable(file.text).isEmpty, "\(file.path): lines \(Self.unreadable(file.text)) hold a / the scan can't read past")
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let (words, readsKey) = Self.identifiers(String(line))
                let used = words.intersection(Self.routes)
                #expect(used.isEmpty && !readsKey, "\(file.path):\(index + 1): \(used.sorted()) \(readsKey ? ".key" : "")")
            }
        }
    }

    /// The list is held to the declarations themselves: every `package` declaration in a module the screen models can
    /// reach is a route, or sits in a type that is one (verifier round 2: a route dropped from the list, or a new
    /// `package` API, passed unnoticed). A member of a route type is reached only through a value of that type, which
    /// the screen models never name. A new declaration is a decision: its name goes in `routes`, reviewed.
    @Test func everyPackageDeclarationTheModelsCanReachIsARoute() throws {
        let modules = try Self.reachableModules()
        #expect(modules.isSuperset(of: ["AppleBusiness", "AppleModels", "Orgs", "Vault", "Reports"]), "\(modules.sorted())")
        var seen = 0
        for module in modules.sorted() {
            for file in try SourceScan.swiftFiles(in: "Packages/AbapitKit/Sources/\(module)") {
                let code = Self.code(file.text)
                // A declaration a bare regex hid would pass unseen.
                #expect(Self.unreadable(file.text).isEmpty, "\(file.path): lines \(Self.unreadable(file.text)) hold a / the scan can't read past")
                for declaration in Self.packageDeclarations(code) {
                    seen += 1
                    let enclosing = declaration.types.flatMap { $0.split(separator: ".").map(String.init) }
                    let covered = Self.routes.contains(declaration.name) || Self.members.contains(declaration.name)
                        || enclosing.contains(where: Self.routes.contains)
                    #expect(covered, "\(file.path): package \(declaration.name) in \(declaration.types) is no route")
                }
            }
        }
        // 38 today; far fewer means the scan lost its way.
        #expect(seen >= 30, "\(seen) package declarations found")
    }

    /// The declaration scan finds a declaration however it is modified, with its types, and nothing else.
    @Test func theDeclarationScanFindsWhatItShould() {
        let source = """
            public struct S: P {
                package let bytes: Data
                package init(secretStore store: X) {}
                package init?(_ value: Int) {}
                public package(set) var count = 0
                func f(package: Int) -> Int { let package = 1; return package }
                package static func g() { struct Inner {} }
                // package func hidden()
                let text = "package func quoted()"
            }
            extension A.B { package nonisolated func make() {} }
            package enum E { package static let purpose = 1 }
            final class C { package class func h() {} }
            struct D { package @available(macOS 27, *) static func k() {}; package novel func n() {}; package subscript(key: String) -> Int { 0 } }
            """
        let found = Self.packageDeclarations(Self.code(source)).map { "\($0.types.joined(separator: "/")):\($0.name)" }
        #expect(found == ["S:bytes", "S:secretStore", "S:init", "S:count", "S:g", "A.B:make", ":E", "E:purpose", "C:h", "D:k", "D:?", "D:subscript"],
                "\(found)")
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
        // A quote left open ends at its line's end.
        #expect(Self.words("let x = \"open\nvault.sign(x)").words.contains("sign"))
        // Line breaks survive, so a finding's line number is the file's.
        #expect(Self.code("a\n\"\"\"\nsecret\n\"\"\"\n/* x\ny */ b").split(separator: "\n", omittingEmptySubsequences: false).count == 6)
    }

    /// Verifier round 2: spellings swiftc reads one way and the scan read another, each hiding a use after it.
    @Test func theScanReadsWhatSwiftcReads() {
        // A quote inside a multi-line literal doesn't end it (mutant X29).
        #expect(Self.words("let t = \"\"\"\n  say \"hi\"\n  \"\"\"\nlet s = vault.secret(x)").words.contains("secret"))
        #expect(Self.words("let t = \"\"\"\n  say \"\"hi\n  \"\"\"\nlet s = vault.secret(x)").words.contains("secret"))
        // A lone CR ends a comment and an unclosed string, as swiftc ends them.
        #expect(Self.words("let a = 1 // note\rlet b = vault.secret(x)").words.contains("secret"))
        #expect(Self.words("let a = \"open\rlet b = vault.sign(x)").words.contains("sign"))
        // An extended regex's `\` escapes the next scalar: `#/a\/#"/#` is one literal, and the code after it code.
        #expect(Self.words(##"let r = #/a\/#"/#; let b = vault.secret(x)"##).words.contains("secret"))
        #expect(Self.words(##"let r = #/a\\/#; let b = vault.secret(x)"##).words.contains("secret"))
        // A raw identifier is one name: a quote in it opens nothing, and a plain one is that name.
        #expect(Self.words("let `a\"b` = 1; let c = vault.secret(x)").words.contains("secret"))
        #expect(Self.words("let raw = imported.`key`.rawRepresentation").readsKey)
        #expect(Self.words("let s = vault.`secret`(x)").words.contains("secret"))
        #expect(Self.words("let `a // b` = 1; let c = vault.sign(x)").words.contains("sign"))
    }

    /// A bare `/…/` regex literal isn't followed, so any `/` that could open one is refused: `/"""/` opened a
    /// multi-line "string" that hid every line after it, `/"/` the rest of its line (verifier round 2, mutants X25,
    /// X26). Division with a space on each side reads, wherever it breaks a line.
    @Test func aSlashTheScanCantReadPastIsRefused() {
        #expect(Self.unreadable("_ = /\"\"\"/\nlet a = vault.secret(x)") == [1])
        #expect(Self.unreadable("let a = 1\n_ = /\"/; return s.bytes") == [2])
        #expect(Self.unreadable("let r = (/a/)") == [1, 1])
        #expect(Self.unreadable("let c = \"a\"/2") == [1])
        #expect(!Self.unreadable("let c = a/b").isEmpty)
        #expect(!Self.unreadable("x /= 2").isEmpty)
        #expect(Self.unreadable("let c = a / b\nlet d = a /\n  b\nlet e = a\t/\tb").isEmpty)
        // Comments, strings and extended regexes hold their slashes as text.
        #expect(Self.unreadable("// a/b\n/* a/b */ let p = \"/v1/orgDevices\"; let r = #/a/b/#").isEmpty)
    }
}
