import AppleModels
import Foundation

/// abapit's `/find` (web/app.py:492-516): a query that identifies devices by serial, IMEI, MEID, EID, order
/// number or a MAC address — case-insensitive exact matches first, else substring matches. One hit opens the
/// device; several filter the table. One deliberate difference: each IMEI and MEID is matched on its own
/// (abapit matched the Python repr of the list, so an exact IMEI never matched exactly).
public enum Find {
    public static func matches(_ query: String, in devices: [OrgDevice]) -> [OrgDevice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let identified = devices.map { (device: $0, values: ([$0.id] + $0.identifiers).map { $0.lowercased() }) }
        let exact = identified.filter { $0.values.contains(needle) }
        return (exact.isEmpty ? identified.filter { $0.values.contains { $0.contains(needle) } } : exact).map(\.device)
    }
}
