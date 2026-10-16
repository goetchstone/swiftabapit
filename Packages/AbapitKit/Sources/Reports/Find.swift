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
/// scalar boundary. One gap left: Swift's `lowercased()` has no final-sigma rule and Python's `lower()` does.
public enum Find {
    public static func matches(_ query: String, in devices: [OrgDevice]) -> [OrgDevice] {
        let needle = Array(strip(query).lowercased().utf8)
        guard !needle.isEmpty else { return [] }
        let identified = devices.map { (device: $0, values: ([$0.id] + $0.identifiers).map { Array($0.lowercased().utf8) }) }
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

    /// `str.strip()`: Python's whitespace off both ends, by scalar.
    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !pythonWhitespace.contains($0.value) }),
              let end = scalars.lastIndex(where: { !pythonWhitespace.contains($0.value) }) else { return "" }
        return String(scalars[start...end])
    }
}
