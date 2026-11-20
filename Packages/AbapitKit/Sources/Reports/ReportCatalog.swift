import Foundation

/// The deterministic list of reports (plan §5, "Reports by voice"): a Siri intent maps a spoken request onto an entry
/// and its filter tokens, and the operator can edit the tokens before the report runs. The model only picks from this
/// list; it never computes a report, and a token that isn't listed here is refused (`problems`). No abapit counterpart.
public enum ReportCatalog {
    public enum ID: String, Sendable, CaseIterable {
        case activationLock = "activation-lock"
        case migration
        case serviceHealth = "service-health"
        case outOfWarranty = "out-of-warranty"
        case quietServices = "quiet-services"
    }

    /// A filter a report accepts. `values` are the exact tokens; `acceptsRawPrefix` is set where Apple's own values
    /// may add more (`lock:<raw type>`); `isNumber` for a count of days.
    public struct Filter: Sendable, Equatable {
        public let name: String
        public let values: [String]
        public let acceptsRawPrefix: String?
        public let isNumber: Bool
        public let summary: String
    }

    /// What a report needs read before it runs, so the caller knows what to load and says what it couldn't.
    public struct Input: Sendable, Equatable {
        public let resource: String
        public let note: String
    }

    public struct Entry: Sendable, Equatable {
        public let id: ID
        public let title: String
        public let summary: String
        public let filters: [Filter]
        public let inputs: [Input]
        /// The CSV export's columns, nil for a report with none.
        public let csvColumns: [String]?
    }

    public static let entries: [Entry] = [
        Entry(id: .activationLock, title: "Activation Lock",
              summary: "Devices by who holds the Activation Lock; a USER lock blocks redeploy and release. Devices whose status wasn't read are counted apart.",
              filters: [Filter(name: "group", values: ActivationLockReport.fixedGroups, acceptsRawPrefix: "lock:", isNumber: false,
                               summary: "lock:USER, lock:MDM, another lock type as lock:<RAW>, unlocked, unclear or not-read")],
              inputs: [Input(resource: "orgDevices", note: "the device list"),
                       Input(resource: "activationLockStatus", note: "each device's status, read one by one")],
              csvColumns: ExportPolicy.activationLockReport.names),
        Entry(id: .migration, title: "MDM migration",
              summary: "Devices by migration status, days to each deadline, and which are past it.",
              filters: [Filter(name: "group", values: MigrationReport.fixedGroups + [MigrationReport.pastDueToken], acceptsRawPrefix: "status:", isNumber: false,
                               summary: "status:REQUESTED, status:STARTED, status:SUCCESS, status:FAILED, another status as status:<RAW>, no-status, no-data or past-due")],
              inputs: [Input(resource: "orgDevices", note: "the device list, with its migration attributes")],
              csvColumns: ExportPolicy.migrationReport.names),
        Entry(id: .serviceHealth, title: "Device management service health",
              summary: "Each service's last connection, status and device count, and whether it is healthy, quiet, inactive or deleted.",
              filters: [Filter(name: "group", values: ServiceHealth.fixedGroups, acceptsRawPrefix: nil, isNumber: false,
                               summary: "healthy, quiet, inactive, deleted, other-status or cannot-judge"),
                        Filter(name: "days", values: [], acceptsRawPrefix: nil, isNumber: true, summary: "quiet means silent for more than this many days (30)")],
              inputs: [Input(resource: "mdmServers", note: "the services list, and which attributes Apple didn't send"),
                       Input(resource: "mdmServers/{id}/relationships/devices", note: "each service's device count, when read")],
              csvColumns: ExportPolicy.serviceHealth.names),
        Entry(id: .outOfWarranty, title: "Out of warranty",
              summary: "Devices with no ACTIVE AppleCare coverage, kept apart from devices with no coverage record at all, from devices not read, and from an estimate based on the order date.",
              filters: [Filter(name: "group", values: WarrantyReport.fixedGroups + [WarrantyReport.estimatedPastToken], acceptsRawPrefix: nil, isNumber: false,
                               summary: "active, no-active-coverage, no-record, not-read or estimated-past-limit")],
              inputs: [Input(resource: "orgDevices", note: "the device list, with its order dates"),
                       Input(resource: "appleCareCoverage", note: "each device's coverage, read one by one")],
              csvColumns: ExportPolicy.warrantyReport.names),
        Entry(id: .quietServices, title: "Services not connected lately",
              summary: "Services that haven't connected in N days, or never.",
              filters: [Filter(name: "days", values: [], acceptsRawPrefix: nil, isNumber: true, summary: "the number of days (30)")],
              inputs: [Input(resource: "mdmServers", note: "the services list")],
              csvColumns: nil),
    ]

    public static func entry(_ id: ID) -> Entry { entries.first { $0.id == id }! }

    /// What's wrong with `tokens` for the report `id`, one phrase each; empty when it can run. A name this report
    /// doesn't accept, a value off its list and a non-number where a number is wanted are all refused.
    public static func problems(_ id: ID, tokens: [String: String]) -> [String] {
        let entry = entry(id)
        return tokens.sorted { byBytes($0.key, $1.key) }.compactMap { name, value in
            guard let filter = entry.filters.first(where: { $0.name == name }) else { return "\(entry.title) has no filter named \(name)" }
            if filter.isNumber { return Int(value).map { $0 > 0 } == true ? nil : "\(name) must be a whole number of days" }
            if filter.values.contains(where: { $0.utf8.elementsEqual(value.utf8) }) { return nil }
            if let prefix = filter.acceptsRawPrefix, value.hasPrefix(prefix), value.count > prefix.count { return nil }
            return "\(value) isn't a \(name) this report accepts"
        }
    }
}
