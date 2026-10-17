import AppleModels
import Foundation

/// abapit's `/find` (web/app.py:492-516): a query that identifies devices by serial, IMEI, MEID, EID, order
/// number or a MAC address — case-insensitive exact matches first, else substring matches. One hit opens the
/// device; several filter the table. One deliberate difference: each IMEI and MEID is matched on its own
/// (abapit matched the Python repr of the list, so an exact IMEI never matched exactly).
///
/// Matched by code point, as Python's `==` and `in` compare (verifier round 1): `String`'s `==` and
/// `contains(_:)` compare `Character`s under canonical equivalence, so U+00C9 matched `E` + U+0301 exactly, and
/// `e` wasn't found in `e` + U+0301. UTF-8 bytes stand in for code points: a valid UTF-8 needle matches only at a
/// scalar boundary. Lowercased as Python's `lower()` lowercases (`lower`), final sigma included.
///
/// What it matches: the device's id and its `identifiers`, abapit's `id` and eight fields. Never a model, a
/// family, a status or any other attribute (verifier round 2: adding one kept every test green).
public enum Find {
    public static func matches(_ query: String, in devices: [OrgDevice]) -> [OrgDevice] {
        let needle = lower(strip(query))
        guard !needle.isEmpty else { return [] }
        let identified = devices.map { (device: $0, values: ([$0.id] + $0.identifiers).map(lower)) }
        let exact = identified.filter { $0.values.contains(needle) }
        let hits = exact.isEmpty ? identified.filter { $0.values.contains { $0.firstRange(of: needle) != nil } } : exact
        return hits.map(\.device)
    }

    /// Python's whitespace (`str.isspace()`, which abapit's `q.strip()` trims), as the serials golden lists it.
    /// A paste brings a tab, a line break or a no-break space with it (Phase 1b review: a spaces-only trim
    /// survived); Foundation's `.whitespacesAndNewlines` also misses U+001C to U+001F, which Python trims.
    static let pythonWhitespace: Set<UInt32> = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// Python's `str.lower()`, as UTF-8 bytes. That is each scalar's full lowercase mapping, which is what Swift's
    /// `lowercased()` does, except for a capital sigma that ends a word: Python lowers it to the final U+03C2 and
    /// Swift to U+03C3 (verifier round 2: `\u{3A3}` found an order number `A\u{3A3}`, whose Python lower is
    /// `a\u{3C2}`). A scratch check against Python 3.12 agreed on 25,000 random strings and on every code point
    /// but the 55 letters Unicode 16 and 17 added, which Python's Unicode 15 doesn't case.
    static func lower(_ text: String) -> [UInt8] {
        guard text.unicodeScalars.contains("\u{3A3}") else { return Array(text.lowercased().utf8) }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{3A3}" {
                out.append(isFinalSigma(scalars, at: index) ? "\u{3C2}" : "\u{3C3}")
            } else {
                // `+=`, because RouteTests reads the other way of appending a sequence as a URL fetch.
                out += scalar.properties.lowercaseMapping.unicodeScalars
            }
        }
        return Array(String(out).utf8)
    }

    /// CPython's `handle_capital_sigma` (Unicode's Final_Sigma): a cased scalar before it and none after it,
    /// skipping case-ignorable ones (an apostrophe, a period, a combining mark) both ways.
    static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard let before = scalars[..<index].last(where: { !$0.properties.isCaseIgnorable }), before.properties.isCased else { return false }
        guard let after = scalars[(index + 1)...].first(where: { !$0.properties.isCaseIgnorable }) else { return true }
        return !after.properties.isCased
    }

    /// `str.strip()`: Python's whitespace off both ends, by scalar.
    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !pythonWhitespace.contains($0.value) }),
              let end = scalars.lastIndex(where: { !pythonWhitespace.contains($0.value) }) else { return "" }
        return String(scalars[start...end])
    }
}
