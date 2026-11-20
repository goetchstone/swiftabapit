import Foundation

/// The deterministic list of reports (plan §5, "Reports by voice"): a Siri intent maps a spoken request onto an entry
/// and its filter tokens, and the operator can edit the tokens before the report runs. The model only picks from this
/// list; it never computes a report. `resolve` takes only known values: it normalizes case and surrounding spaces to the
/// canonical value and refuses anything else, so a token never silently matches nothing. No abapit counterpart.
public enum ReportCatalog {
    public enum ID: String, Sendable, CaseIterable {
        case activationLock = "activation-lock"
        case migration
        case serviceHealth = "service-health"
        case outOfWarranty = "out-of-warranty"
    }

    /// A filter a report accepts: `values` are the exact canonical tokens; a `days` filter takes a positive whole number.
    public struct Filter: Sendable, Equatable {
        public let name: String
        public let values: [String]
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
        public let csvColumns: [String]
    }

    /// The tokens as the report will take them, and what's wrong with the rest.
    public struct Resolution: Sendable, Equatable {
        public let tokens: [String: String]
        public let problems: [String]
    }

    public static let entries: [Entry] = [
        Entry(id: .activationLock, title: "Activation Lock",
              summary: "Devices by who holds the Activation Lock; a USER lock blocks redeploy and release. Devices whose status wasn't read are counted apart, never as unlocked.",
              filters: [Filter(name: "group", values: ActivationLockReport.fixedGroups, isNumber: false,
                               summary: "lock:USER, lock:MDM, lock:NONE, lock:other (a type this version doesn't know), unlocked, unclear or not-read")],
              inputs: [Input(resource: "orgDevices", note: "the device list"),
                       Input(resource: "activationLockStatus", note: "each device's status, read one by one; a device not reached counts as not read")],
              csvColumns: ExportPolicy.activationLockReport.names),
        Entry(id: .migration, title: "MDM migration",
              summary: "Devices by migration status, days to each deadline, and which are past it (a known status other than SUCCESS).",
              filters: [Filter(name: "group", values: MigrationReport.fixedGroups + [MigrationReport.pastDueToken, MigrationReport.pastDueStatusUnknownToken],
                               isNumber: false,
                               summary: "status:REQUESTED, status:STARTED, status:SUCCESS, status:FAILED, status:other, no-status, no-data, past-due or past-due-status-unknown")],
              inputs: [Input(resource: "orgDevices", note: "the device list, with its migration attributes")],
              csvColumns: ExportPolicy.migrationReport.names),
        Entry(id: .serviceHealth, title: "Device management service health",
              summary: "Each service's last connection, status and device count, and whether it is healthy, quiet (the Overview's rule), inactive or deleted.",
              filters: [Filter(name: "group", values: ServiceHealth.fixedGroups, isNumber: false,
                               summary: "healthy, quiet, inactive, deleted, other-status or cannot-judge"),
                        Filter(name: "days", values: [], isNumber: true, summary: "quiet means silent for more than this many days (30)")],
              inputs: [Input(resource: "mdmServers", note: "the services list, and which attributes Apple didn't send"),
                       Input(resource: "mdmServers/{id}/relationships/devices", note: "each service's device count, when read")],
              csvColumns: ExportPolicy.serviceHealth.names),
        Entry(id: .outOfWarranty, title: "Out of warranty",
              summary: "Devices with no ACTIVE AppleCare coverage, kept apart from devices with no coverage record at all, with a status this version doesn't know, and not read. Any estimate is from the order date and assumes Apple's one-year limited warranty from the order date; the real term varies by country and product and starts at purchase or delivery.",
              filters: [Filter(name: "group", values: WarrantyReport.fixedGroups + [WarrantyReport.estimatedPastToken], isNumber: false,
                               summary: "active, no-active-coverage, no-record, status-unknown, not-read or estimated-past-limit")],
              inputs: [Input(resource: "orgDevices", note: "the device list, with its order dates"),
                       Input(resource: "appleCareCoverage", note: "each device's coverage, read one by one; a device not reached counts as not read")],
              csvColumns: ExportPolicy.warrantyReport.names),
    ]

    public static func entry(_ id: ID) -> Entry { entries.first { $0.id == id }! }

    /// Trimmed, with the spaces around a colon dropped (`status: SUCCESS` is `status:SUCCESS`).
    static func tidy(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let head = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(head):\(tail)"
    }

    /// Each token normalized to its canonical name and value, or a problem: a name this report doesn't accept, a value off its
    /// list (a value only matches ignoring case and surrounding spaces) and a non-number where a number is wanted.
    public static func resolve(_ id: ID, tokens: [String: String]) -> Resolution {
        let entry = entry(id)
        var resolved: [String: String] = [:], problems: [String] = []
        for (rawName, rawValue) in tokens.sorted(by: { byBytes($0.key, $1.key) }) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let filter = entry.filters.first(where: { $0.name == name }) else {
                problems.append("\(entry.title) has no filter named \(rawName)")
                continue
            }
            let value = tidy(rawValue)
            if filter.isNumber {
                if let days = Int(value), days > 0 { resolved[name] = String(days) } else { problems.append("\(name) must be a whole number of days") }
            } else if let canonical = filter.values.first(where: { $0.lowercased() == value.lowercased() }) {
                resolved[name] = canonical
            } else {
                problems.append("\(rawValue) isn't a \(name) this report accepts")
            }
        }
        return Resolution(tokens: resolved, problems: problems)
    }

    /// What's wrong with `tokens` for the report `id`; empty when it can run.
    public static func problems(_ id: ID, tokens: [String: String]) -> [String] { resolve(id, tokens: tokens).problems }
}
