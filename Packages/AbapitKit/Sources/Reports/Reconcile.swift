import Foundation
import JSONAPI
import MosyleModels

/// abapit's `reports.reconcile_enrollments` (held to `Tests/Fixtures/parity/reports.json`): an Apple Business org's devices
/// joined to a Mosyle Business org's by serial. What neither tool shows alone: owned in Apple Business but not enrolled in this
/// Mosyle, enrolled in Mosyle but unknown to Apple Business, and in both. For a device in both, ownership comes from Apple
/// (the purchase record) and live posture from Mosyle.
public struct Reconciliation: Sendable {
    /// Where a serial was found. The raw values are abapit's, which its CSV wrote.
    public enum Presence: String, Sendable, CaseIterable {
        case appleOnly = "abm_only"
        case both
        case mosyleOnly = "mosyle_only"
    }

    /// One serial's row. Each value is as the device's attributes held it (abapit's `attrs.get(key, "")`: a missing key is
    /// `""`, a null stays null), so the CSV and the golden read the same values.
    public struct Row: Sendable, Identifiable {
        /// The serial as its source spelled it (Apple's, for a device in both).
        public let serial: String
        public let presence: Presence
        public let appleStatus: JSONValue
        public let mosyleStatus: JSONValue
        public let productFamily: JSONValue
        public let deviceModel: JSONValue
        public let osVersion: JSONValue
        public let lastCheckIn: JSONValue
        public let added: JSONValue
        public let currentUser: JSONValue

        /// A serial is in one bucket only: two spellings of one key are one device.
        public var id: String { serial }

        /// abapit's row, by its keys: what the CSV writes.
        public var attributes: JSONObject {
            ["serial": .string(serial), "presence": .string(presence.rawValue), "abm_status": appleStatus, "mosyle_status": mosyleStatus,
             "productFamily": productFamily, "deviceModel": deviceModel, "osVersion": osVersion, "lastCheckIn": lastCheckIn,
             "addedToOrgDateTime": added, "currentUser": currentUser]
        }
    }

    /// Each bucket sorted by serial, by code points as Python sorts.
    public let appleOnly: [Row]
    public let both: [Row]
    public let mosyleOnly: [Row]
    /// Distinct serials on each side, and in either.
    public let totalApple: Int
    public let totalMosyle: Int
    public let totalUnique: Int

    /// The share of distinct serials found in both, in percent to one decimal (Python's `round`); 0 with none.
    public var enrollmentRate: Double { totalUnique == 0 ? 0 : Python.round1(Double(both.count) / Double(totalUnique) * 100) }

    /// Every row, in abapit's export order: Apple only, both, Mosyle only.
    public var rows: [Row] { appleOnly + both + mosyleOnly }

    /// abapit's `_norm_serial`: stripped of Python's whitespace and upper-cased, compared by its bytes. Apple's serials are
    /// upper case; Mosyle's casing varies.
    public static func key(_ serial: String) -> [UInt8] { Array(Python.upper(Python.strip(serial)).utf8) }

    public init(apple: [Resource], mosyle: [Resource]) {
        // A later device with the same key replaces an earlier one, as abapit's dict did; an empty key is no device.
        func index(_ devices: [Resource]) -> [[UInt8]: Resource] {
            var found: [[UInt8]: Resource] = [:]
            for device in devices {
                let key = Self.key(device.id)
                if !key.isEmpty { found[key] = device }
            }
            return found
        }
        let apples = index(apple), mosyles = index(mosyle)
        func value(_ attributes: JSONObject, _ key: String) -> JSONValue { attributes[key] ?? .string("") }
        func appleRow(_ device: Resource) -> Row {
            let a = device.attributes
            return Row(serial: device.id, presence: .appleOnly, appleStatus: value(a, "status"), mosyleStatus: .string(""),
                       productFamily: value(a, "productFamily"), deviceModel: value(a, "deviceModel"), osVersion: .string(""),
                       lastCheckIn: .string(""), added: value(a, "addedToOrgDateTime"), currentUser: .string(""))
        }
        func mosyleRow(_ device: Resource) -> Row {
            let m = device.attributes
            return Row(serial: device.id, presence: .mosyleOnly, appleStatus: .string(""), mosyleStatus: value(m, "status"),
                       productFamily: value(m, "productFamily"), deviceModel: value(m, "deviceModel"), osVersion: value(m, "osVersion"),
                       lastCheckIn: value(m, "lastCheckIn"), added: .string(""), currentUser: value(m, "currentUser"))
        }
        func bothRow(_ device: Resource, _ other: Resource) -> Row {
            let a = device.attributes, m = other.attributes
            // `abm.get(key) or mosyle.get(key, "")`: Apple's value unless it is falsy.
            func either(_ key: String) -> JSONValue { Python.truthy(a[key]) ? a[key]! : value(m, key) }
            return Row(serial: device.id, presence: .both, appleStatus: value(a, "status"), mosyleStatus: value(m, "status"),
                       productFamily: either("productFamily"), deviceModel: either("deviceModel"), osVersion: value(m, "osVersion"),
                       lastCheckIn: value(m, "lastCheckIn"), added: value(a, "addedToOrgDateTime"), currentUser: value(m, "currentUser"))
        }
        func sorted(_ rows: [Row]) -> [Row] { rows.sorted { Python.precedes($0.serial, $1.serial) } }
        appleOnly = sorted(apples.filter { mosyles[$0.key] == nil }.map { appleRow($0.value) })
        mosyleOnly = sorted(mosyles.filter { apples[$0.key] == nil }.map { mosyleRow($0.value) })
        both = sorted(apples.compactMap { key, device in mosyles[key].map { bothRow(device, $0) } })
        totalApple = apples.count
        totalMosyle = mosyles.count
        totalUnique = apples.count + mosyleOnly.count
    }
}
