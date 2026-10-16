// Coverage-guided fuzzing (libFuzzer) of the pure modules (plan §6.6). Everything they read comes from an
// operator's paste or from Apple's and Mosyle's responses, so none of it is trusted.
//
// Built by `scripts/fuzz.sh` on Linux (Apple's toolchain ships no libFuzzer runtime) with the pure modules'
// sources compiled in as one module. CI's `fuzz` job runs it. The first byte picks a target; the rest is its
// input. A failed property traps, which libFuzzer reports as a crash and saves the input. Each phase adds the
// parsers it ports (JSON:API documents and paging, Mosyle envelopes and dates, the CSV writer).

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: size))
    guard let selector = bytes.first else { return 0 }
    let text = String(decoding: bytes.dropFirst(), as: UTF8.self)
    let targets: [(String) -> Void] = [serials]
    targets[Int(selector) % targets.count](text)
    return 0
}

func require(_ condition: Bool, _ what: @autoclosure () -> String) {
    if !condition { fatalError("property failed: \(what())") }
}

/// Pasted serials: never a crash; every token non-empty, free of separators and ASCII lowercase, unique by
/// code points; parsing its own output, joined, gives it back; and the tokens are exactly what a plain
/// reference reading of the spec gives (Phase 0's review: without that, a parser returning nothing passed).
func serials(_ raw: String) {
    let tokens = SerialParser.parse(raw)
    var seen: Set<[UInt32]> = []
    for token in tokens {
        let scalars = Array(token.unicodeScalars)
        require(!scalars.isEmpty, "an empty token from \(raw.debugDescription)")
        require(!scalars.contains(where: SerialParser.isSeparator), "a separator in \(token.debugDescription)")
        require(!scalars.contains { ("a"..."z").contains($0) }, "lowercase ASCII in \(token.debugDescription)")
        require(seen.insert(scalars.map(\.value)).inserted, "a duplicate \(token.debugDescription)")
    }
    let again = SerialParser.parse(tokens.joined(separator: "\n"))
    require(again.map { Array($0.utf8) } == tokens.map { Array($0.utf8) }, "not idempotent on \(raw.debugDescription)")
    require(referenceSerials(raw) == tokens.map { $0.unicodeScalars.map(\.value) }, "differs from the reference on \(raw.debugDescription)")
}

/// The spec, read plainly: runs of non-separators, ASCII a-z uppercased, first of each kept.
func referenceSerials(_ raw: String) -> [[UInt32]] {
    var out: [[UInt32]] = [], current: [UInt32] = []
    func flush() {
        if !current.isEmpty, !out.contains(current) { out.append(current) }
        current = []
    }
    for scalar in raw.unicodeScalars {
        if scalar == "," || scalar == ";" || SerialParser.pythonWhitespace.contains(scalar.value) {
            flush()
        } else {
            current.append((0x61...0x7A).contains(scalar.value) ? scalar.value - 0x20 : scalar.value)
        }
    }
    flush()
    return out
}
