import Foundation
import Testing
import TestSupport

/// The gate scripts' own shape. Phase 7a's review H1: under `set -o pipefail`, `nm "$BINARY" | grep -qE …` read
/// every match as none. `grep -q` exits at its first match, `nm` (still writing over 1 MB) dies of SIGPIPE, and
/// `if` reads the failed pipeline as false, so `scripts/check_app.sh` passed the 101 `MemoryStore` symbols in every
/// Release build. A script under pipefail captures a tool's output, then searches it.
@Suite("Gate scripts")
struct GateScriptTests {
    /// The pipes in `script` into a reader that can stop before the writer is done: `head`, or `grep` with `-q`,
    /// `-m`, `-l` or `-L` (alone, grouped or long). Comment lines and single-quoted text (a grep pattern's `|`) are
    /// skipped; `||` isn't a pipe, and `|&` is. Not read: `sed …q` and `awk … exit`, which no script uses.
    static func earlyExits(_ script: String) -> [String] {
        var found: [String] = []
        for line in script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            let code = Array(line.replacing(#/'[^']*'/#, with: "''"))
            for index in code.indices where code[index] == "|" {
                guard index == 0 || code[index - 1] != "|", index + 1 == code.count || code[index + 1] != "|" else { continue }
                var rest = code[(index + 1)...].drop(while: { $0 == "&" }).drop(while: \.isWhitespace)
                if let end = rest.firstIndex(where: { "|;&)".contains($0) }) { rest = rest[..<end] }
                let words = String(rest).split(whereSeparator: \.isWhitespace).map(String.init)
                guard let command = words.first else { continue }
                if command == "head" || (["grep", "egrep", "fgrep"].contains(command) && words.dropFirst().contains(where: Self.stopsEarly)) {
                    found.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return found
    }

    /// A grep option that ends the read before the input does.
    static func stopsEarly(_ word: String) -> Bool {
        if word.hasPrefix("--") {
            return ["--quiet", "--silent", "--max-count", "--files-with-matches", "--files-without-match"].contains { word.hasPrefix($0) }
        }
        return word.hasPrefix("-") && word.dropFirst().prefix(while: \.isLetter).contains { "qmlL".contains($0) }
    }

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
    ])
    func aCapturedSearchIsNot(_ script: String) {
        #expect(Self.earlyExits(script).isEmpty, "\(Self.earlyExits(script))")
    }
}
