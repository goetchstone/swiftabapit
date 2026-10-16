import Foundation

/// Pasted serial numbers as a list: abapit's `assign.parse_serials` (held to
/// `Tests/Fixtures/parity/serials.json`). Split on runs of whitespace, commas and semicolons; uppercase;
/// drop empties; keep the first of each, in order.
///
/// One deliberate deviation, listed in the golden: only ASCII `a`–`z` are uppercased. Python's
/// `str.upper()` follows its own Unicode version (`"straße"` becomes `"STRASSE"`), and a serial is ASCII,
/// so a token with any other letter matches no device either way. Serials always come from here, never
/// from a model's output (plan §5).
public enum SerialParser {
    /// Python's whitespace (`str.isspace()`, which `re`'s `\s` and `str.strip()` use), as the golden lists
    /// it: what an operator's paste can separate serials with.
    static let pythonWhitespace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "," || scalar == ";" || pythonWhitespace.contains(scalar.value)
    }

    public static func parse(_ raw: String) -> [String] {
        var tokens: [String] = []
        // Compared by code points: Swift's `String ==` is canonical equivalence, Python's is code points.
        var seen: Set<[UInt32]> = []
        var current = String.UnicodeScalarView()
        func finish() {
            defer { current = String.UnicodeScalarView() }
            guard !current.isEmpty, seen.insert(current.map(\.value)).inserted else { return }
            tokens.append(String(current))
        }
        for scalar in raw.unicodeScalars {
            if isSeparator(scalar) {
                finish()
            } else if ("a"..."z").contains(scalar), let upper = Unicode.Scalar(scalar.value - 0x20) {
                current.append(upper)
            } else {
                current.append(scalar)
            }
        }
        finish()
        return tokens
    }
}
