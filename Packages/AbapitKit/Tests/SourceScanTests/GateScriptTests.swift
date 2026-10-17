import Foundation
import Testing
import TestSupport

/// The gate scripts' own shape. Phase 7a's review H1: under `set -o pipefail`, `nm "$BINARY" | grep -qE …` read
/// every match as none. `grep -q` exits at its first match, `nm` (still writing over 1 MB) dies of SIGPIPE, and
/// `if` reads the failed pipeline as false, so `scripts/check_app.sh` passed the 101 `MemoryStore` symbols in every
/// Release build. A script under pipefail captures a tool's output, then searches it.
@Suite("Gate scripts")
struct GateScriptTests {
    /// The pipes in `script`'s commands (`commands(_:)`) into a reader that can stop before the writer is done: `head`,
    /// `read`, or a `grep` with `-q`, `-m`, `-l` or `-L` (alone, grouped or long). The reader is the command after any
    /// assignments (`LC_ALL=C grep`) and wrappers (`command grep`, `env -i grep`), read by its file name, quotes and a
    /// leading `\` aside (`/usr/bin/grep`, `\grep`). In single-quoted text (a grep pattern) `|`, `;`, `&` and `)` are
    /// text. `||` isn't a pipe, and `|&` is. A pipe's reader runs to `;`, `&`, `)` or `||`, so a `|` in a
    /// double-quoted pattern doesn't hide an option after it. Not read: `sed …q` and `awk … exit`, which no script uses.
    /// Phase 1b gates verifier round 2: `| /usr/bin/grep -qE`, `| command grep -qE`, `| grep -E --quie` and a pipe at
    /// the end of its line each passed, and the first and the last blinded the gate.
    static func earlyExits(_ script: String) -> [String] {
        var found: [String] = []
        for command in commands(script) {
            let code = Array(Self.masked(command))
            for index in code.indices where code[index] == "|" {
                guard index == 0 || code[index - 1] != "|", index + 1 == code.count || code[index + 1] != "|" else { continue }
                var rest = code[(index + 1)...].drop(while: { $0 == "&" }).drop(while: \.isWhitespace)
                if let end = rest.indices.first(where: { ";&)".contains(rest[$0]) || rest[$0...].starts(with: "||") }) { rest = rest[..<end] }
                var words = String(rest).split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'")) }
                var wrapped = false
                while let first = words.first,
                      first.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*=.*/#) != nil || Self.wrappers.contains(first) || (wrapped && first.hasPrefix("-")) {
                    wrapped = wrapped || Self.wrappers.contains(first)
                    words.removeFirst()
                }
                guard let path = words.first else { continue }
                let reader = path.split(separator: "/").last.map(String.init) ?? path
                if ["head", "read"].contains(reader) || (reader.hasSuffix("grep") && words.dropFirst().contains(where: Self.stopsEarly)) {
                    found.append(command.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return found
    }

    /// What runs the command after it.
    static let wrappers: Set = ["command", "builtin", "exec", "env", "nice", "nohup", "time", "stdbuf"]

    /// `script`'s commands as bash reads them: a line that ends in `\`, or in `|`, `|&`, `||` or `&&` (before a
    /// trailing comment, or with none), goes on with the next line, and past blank and comment lines after a `|`. A
    /// comment line is dropped. Read a line at a time, `nm "$bin" |` then `grep -qE …` on the next line passed (Phase 1b gates
    /// verifier round 2).
    static func commands(_ script: String) -> [String] {
        var commands: [String] = [], pending: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if pending == nil, trimmed.hasPrefix("#") { continue }
            let text = pending.map { "\($0) \(line)" } ?? line
            if let head = Self.continued(text) {
                pending = head
            } else {
                commands.append(text)
                pending = nil
            }
        }
        return commands + (pending.map { [$0] } ?? [])
    }

    /// `text` without what makes it go on, if its command goes on with the next line: a last `\`, or a `|`, `|&`, `||`
    /// or `&&` at its end or before a comment (a `#` that starts a word), which is dropped.
    static func continued(_ text: String) -> String? {
        let code = Array(Self.masked(text))
        func goesOn(before end: Int) -> Bool {
            let head = String(code[..<end]).trimmingCharacters(in: .whitespaces)
            return head.hasSuffix("|") || head.hasSuffix("|&") || head.hasSuffix("&&")
        }
        if String(code).trimmingCharacters(in: .whitespaces).hasSuffix("\\") { return String(text.trimmingCharacters(in: .whitespaces).dropLast()) }
        if goesOn(before: code.count) { return text }
        if let comment = code.indices.first(where: { code[$0] == "#" && ($0 == 0 || code[$0 - 1].isWhitespace) && goesOn(before: $0) }) {
            return String(Array(text)[..<comment])
        }
        return nil
    }

    /// `text` with the `|`, `;`, `&`, `)`, `#` and `\` inside single quotes (a grep pattern's) masked as `_`, one for one,
    /// so an offset is the one in `text` and a quoted command (`'grep'`) is still a word.
    static func masked(_ text: String) -> String {
        text.replacing(#/'[^']*'/#) { match in String(match.output.map { "|;&)#\\".contains($0) ? "_" : $0 }) }
    }

    /// A grep option that ends the read before the input does: `-q`, `-m`, `-l` or `-L`, alone or grouped (`-Eq`), or
    /// a long one, which getopt_long takes by any unambiguous prefix (BSD grep reads `--quie` as `--quiet`). `--file`
    /// is an option of its own.
    static func stopsEarly(_ word: String) -> Bool {
        if word.hasPrefix("--") {
            let name = word.dropFirst(2).prefix { $0 != "=" }
            return !name.isEmpty && name != "file" && Self.stoppingOptions.contains { $0.hasPrefix(name) }
        }
        return word.hasPrefix("-") && word.dropFirst().prefix(while: \.isLetter).contains { "qmlL".contains($0) }
    }

    static let stoppingOptions = ["quiet", "silent", "max-count", "files-with-matches", "files-without-match"]

    @Test func noScriptPipesIntoAReaderThatStopsEarly() throws {
        let directory = Fixtures.repoRoot.appending(path: "scripts")
        var seen: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() where name.hasSuffix(".sh") {
            let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            guard text.contains("pipefail") else { continue }
            seen.append(name)
            #expect(Self.earlyExits(text).isEmpty, "scripts/\(name) pipes into a reader that stops early: \(Self.earlyExits(text))")
        }
        #expect(seen.contains("check_app.sh"), "the Release gate isn't where the scan looks: \(seen)")
    }

    /// Each one reads a match as no match once the writer outgrows the pipe.
    @Test(arguments: [
        #"if nm "$BINARY" | grep -qE 'MemoryStore|TestSupport'; then fail x; fi"#,
        #"nm "$bin" | grep -q TestSupport && fail "linked""#,
        #"strings -a "$bin" | grep -m1 TestSupport"#,
        #"strings -a "$bin" | grep --max-count=1 TestSupport"#,
        #"otool -v -s __TEXT __objc_methname "$bin" | grep --quiet environment"#,
        #"nm "$bin" | grep -Eq 'x'"#,
        #"nm "$bin" | grep -E -l x"#,
        #"nm "$bin" |& grep -q x"#,
        #"nm "$bin" | head -1"#,
        "nm \"$bin\" \\\n  | grep -q x",
        #"hits="$(nm "$bin" | grep -q x)""#,
        #"if strings -a "$bin" | egrep -q 'ABAPIT_'; then fail x; fi"#,
        // Phase 1b gates verifier round 2: each of these passed a line-at-a-time read of the literal command name.
        "if nm \"$bin\" 2>/dev/null |\n      grep -qE \"$DEBUG_ONLY\"; then fail x; fi",
        "if nm \"$bin\" 2>/dev/null | \\\n      grep -qE \"$DEBUG_ONLY\"; then fail x; fi",
        "nm \"$bin\" | # all of it\n  grep -q x",
        "nm \"$bin\" |\n\n  # the needles\n  grep -q x",
        "nm \"$bin\" |&\n  grep -q x",
        #"nm "$bin" | /usr/bin/grep -qE x"#,
        #"nm "$bin" | /usr/bin/head -1"#,
        #"nm "$bin" | ggrep -q x"#,
        #"nm "$bin" | command grep -qE x"#,
        #"nm "$bin" | command -p grep -q x"#,
        #"nm "$bin" | env -i LC_ALL=C grep -q x"#,
        #"nm "$bin" | LC_ALL=C grep -q x"#,
        #"nm "$bin" | \grep -q x"#,
        #"nm "$bin" | 'grep' -q x"#,
        #"nm "$bin" | grep -E --quie x"#,
        #"nm "$bin" | grep --q x"#,
        #"nm "$bin" | grep -L x"#,
        #"nm "$bin" | grep --silent x"#,
        #"nm "$bin" | grep --files-with-matches x"#,
        #"nm "$bin" | grep --files-without x"#,
        #"nm "$bin" | grep -E "a|b" -q"#,
        #"nm "$bin" | grep -E '(a);b' -q"#,
        #"nm "$bin" | read -r first"#,
        #"nm "$bin" | sort | grep -q x"#,
    ])
    func anEarlyExitPipeIsFound(_ script: String) {
        #expect(!Self.earlyExits(script).isEmpty)
    }

    /// What the gate does instead, and lines that only look like a pipe into `grep -q`.
    @Test(arguments: [
        #"names="$(nm "$bin" 2>/dev/null)" || fail "can't read""#,
        #"grep -qE 'flags=0x[0-9a-f]+' <<<"$info""#,
        #"if hits="$(grep -oE "$DEBUG_ONLY" <<<"$text" | sort -u)"; then"#,
        #"team="$(codesign -dv "$APP" 2>&1 | sed -nE 's/^TeamIdentifier=(.*)$/\1/p')""#,
        #"# never `nm | grep -q`: capture, then search"#,
        #"[ -n "$a" ] || grep -q x "$file""#,
        #"pattern="$(printf '%s|' $pure | sed 's/|$//')""#,
        #"if grep -E 'a| grep -q b' <<<"$x"; then"#,
        #"n="$(nm "$bin" | grep -c MemoryStore)""#,
        #"nm "$bin" | grep -oE 'Test|Demo' | sort -u"#,
        #"nm "$bin" | grep -o --file=needles.txt | sort -u"#,
        #"nm "$bin" | grep -E 'a|b' -c"#,
        "nm \"$bin\" |\n  sort -u",
        "[ -n \"$a\" ] ||\n  grep -q x \"$file\"",
        "names=\"$(nm \"$bin\")\" &&\n  grep -q x <<<\"$names\"",
        #"nm "$bin" | grep -c x || grep -q y "$file""#,
        "# a comment ending in a pipe |\ngrep -q x \"$file\"",
    ])
    func aCapturedSearchIsNot(_ script: String) {
        #expect(Self.earlyExits(script).isEmpty, "\(Self.earlyExits(script))")
    }
}
