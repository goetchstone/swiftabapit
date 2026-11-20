import AppleModels
import Foundation
import JSONAPI

extension ExportPolicy {
    /// Every fleet report's export leads with `listRead`: how much of the list the report was given. A list that wasn't read
    /// exports no judgment cells (they say "not read"). Every value Apple sent is written as sent: a string as it is, any
    /// other value as its JSON text (so `"true"` sent as a string is written with its quotes); yes and no only where a value
    /// can be judged.
    ///
    /// The Activation Lock report's export: every cell is computed from `isLocked` and `lockType`; nothing of the device's
    /// attributes beyond the three identifying ones is copied, so a bypass code or an unknown key never leaves (invariant 11).
    /// `blocksRelease` is yes or no only where it can be judged; else "unknown" or "not read".
    public static let activationLockReport = Columns(["listRead", "serialNumber", "deviceModel", "productFamily", "state", "isLocked", "lockType",
                                                      "blocksRelease", "note"])
    /// `pastDue` is yes or no only where it can be judged; `overdue` is "overdue N days" (N at least 1) for a migration past
    /// due, "deadline passed N days ago" for any other past deadline, and `daysToDeadline` the whole days left, never both.
    public static let migrationReport = Columns(["listRead", "serialNumber", "deviceModel", "productFamily", "state", "mdmMigrationStatus",
                                                 "isMdmMigrationCapable", "mdmMigrationDeadlineDateTime", "daysToDeadline", "overdue", "pastDue"])
    public static let serviceHealth = Columns(["listRead", "serverName", "serverType", "status", "health", "healthReason", "lastConnectedDateTime",
                                               "lastConnected", "deviceCount", "deviceCountIs", "notSentByApple"])
    public static let warrantyReport = Columns(["listRead", "serialNumber", "deviceModel", "productFamily", "orderDateTime", "coverage",
                                                "activeCoverageEnds", "recordStatuses", "estimate", "estimatedEnd", "assumption"])
}

/// A row for a list that wasn't read: the identifying cells and `listRead`, and "not read" in each judgment cell.
private func finish(_ list: ListRead, identity: JSONObject, full: JSONObject, judgments: [String]) -> JSONObject {
    var attributes = list.isNotRead ? identity : full
    attributes = attributes.merging(["listRead": .string(list.csvWords)])
    if list.isNotRead { for key in judgments { attributes = attributes.merging([key: .string("not read")]) } }
    return attributes
}

/// A list that wasn't read and left no rows still says so (invariant 8): one row whose `listRead` cell says why and whose
/// other cells are empty, so the file is never a bare header that reads as "nothing to report".
func withSentinel(_ list: ListRead, rows: [CSV.Item]) -> [CSV.Item] {
    guard list.isNotRead, rows.isEmpty else { return rows }
    return [CSV.Item(id: "", attributes: ["listRead": .string(list.csvWords)])]
}

private func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

private func identity(_ device: OrgDevice) -> JSONObject {
    ["serialNumber": .string(device.serialNumber), "deviceModel": text(sent(device.attributes, "deviceModel")),
     "productFamily": text(sent(device.attributes, "productFamily"))]
}

extension ActivationLockReport {
    public var csvItems: [CSV.Item] { withSentinel(list, rows: items) }

    private var items: [CSV.Item] {
        rows.map { row in
            var attributes = identity(row.device).merging(["state": .string(Self.title(row.group)), "blocksRelease": .string(row.blocksReleaseWords),
                                                           "isLocked": text(row.isLockedSent), "lockType": text(row.lockTypeSent)])
            switch row.kind {
            case .notRead(let why): attributes = attributes.merging(["note": .string(why)])
            case .unclear(let raw): attributes = attributes.merging(["note": .string(raw.map { "isLocked sent as \($0)" } ?? "no isLocked sent")])
            default: break
            }
            return CSV.Item(id: row.device.id, attributes: finish(list, identity: identity(row.device), full: attributes, judgments: ["state", "blocksRelease"]))
        }
    }
}

extension MigrationReport {
    public var csvItems: [CSV.Item] { withSentinel(list, rows: items) }

    private var items: [CSV.Item] {
        rows.map { row in
            var attributes = identity(row.device).merging([
                "state": .string(Self.title(row.group)), "mdmMigrationStatus": text(row.status?.rawValue),
                "isMdmMigrationCapable": text(Self.capableText(row.device)), "pastDue": .string(row.pastDueWords),
            ])
            let deadline = text(sent(row.device.attributes, "mdmMigrationDeadlineDateTime"))
            switch row.deadline {
            case .none: break
            case .unreadable(let raw): attributes = attributes.merging(["mdmMigrationDeadlineDateTime": .string(raw)])
            case .left(let days): attributes = attributes.merging(["mdmMigrationDeadlineDateTime": deadline, "daysToDeadline": .string(String(days))])
            case .overdue(let days):
                let words = row.pastDue ? "overdue \(days) day\(days == 1 ? "" : "s")" : "deadline passed \(days) day\(days == 1 ? "" : "s") ago"
                attributes = attributes.merging(["mdmMigrationDeadlineDateTime": deadline, "overdue": .string(words)])
            }
            return CSV.Item(id: row.device.id, attributes: finish(list, identity: identity(row.device), full: attributes,
                                                                   judgments: ["state", "daysToDeadline", "overdue", "pastDue"]))
        }
    }

    /// `yes` or `no` for a flag Apple sent as a boolean, nothing when it sent none, and what it sent otherwise (JSON text).
    static func capableText(_ device: OrgDevice) -> String? {
        switch device.attributes["isMdmMigrationCapable"] {
        case nil, .null?: nil
        case .bool(let flag)?: flag ? "yes" : "no"
        case let value?: value.jsonText
        }
    }
}

extension ServiceHealth {
    public var csvItems: [CSV.Item] { withSentinel(list, rows: items) }

    private var items: [CSV.Item] {
        rows.map { row in
            let name: JSONObject = ["serverName": .string(row.service.name)]
            var attributes: JSONObject = name.merging(["serverType": text(sent(row.service.attributes, "serverType")),
                                          "status": text(sent(row.service.attributes, "status")), "health": .string(row.group),
                                          "notSentByApple": .string(notSent.joined(separator: "; ")), "lastConnected": .string(row.lastConnected.words)])
            if case .cannotJudge(let why) = row.health { attributes = attributes.merging(["healthReason": .string(why)]) }
            if case .otherStatus(let raw) = row.health { attributes = attributes.merging(["healthReason": .string("status \(raw)")]) }
            switch row.lastConnected {
            case .notSent, .never: break
            case .unreadable(let raw): attributes = attributes.merging(["lastConnectedDateTime": .string(raw)])
            case .at(let date, _), .inFuture(let date): attributes = attributes.merging(["lastConnectedDateTime": .string(date.isoformat)])
            }
            switch row.deviceCount {
            case nil: attributes = attributes.merging(["deviceCountIs": .string("not read")])
            case .exactly(let count)?: attributes = attributes.merging(["deviceCount": .string(String(count)), "deviceCountIs": .string("exactly")])
            case .atLeast(let count)?: attributes = attributes.merging(["deviceCount": .string(String(count)), "deviceCountIs": .string("at least")])
            case .unreadable(let raw)?: attributes = attributes.merging(["deviceCount": .string(raw), "deviceCountIs": .string("not a whole number")])
            }
            return CSV.Item(id: row.service.id, attributes: finish(list, identity: name, full: attributes,
                                                                    judgments: ["health", "lastConnected", "deviceCountIs"]))
        }
    }
}

extension WarrantyReport {
    /// The order date as the CSV shows it on every row kind: a date as sent, anything `ISODate` can't read as its JSON text
    /// (a string keeps its quotes), nothing when not sent. A quoted cell means Apple sent a value in a shape this app
    /// didn't expect; it is shown as sent.
    static func orderDateCell(_ device: OrgDevice) -> String? {
        switch device.attributes["orderDateTime"] {
        case nil, .null?: nil
        case let value?: ISODate.parse(value.string) == nil ? unreadableDate(value) : sent(device.attributes, "orderDateTime")
        }
    }

    public var csvItems: [CSV.Item] { withSentinel(list, rows: items) }

    private var items: [CSV.Item] {
        let formatter = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)
        return rows.map { row in
            var attributes = identity(row.device).merging(["orderDateTime": text(Self.orderDateCell(row.device))])
            switch row.kind {
            case .active(let ends):
                // An end Apple sent that isn't a date is never left blank (invariant 10): its JSON text, after any readable one.
                let cells = [ends?.isoformat].compactMap { $0 } + row.unreadableEnds.map { "end date not readable: \($0)" }
                attributes = attributes.merging(["coverage": .string("active AppleCare coverage"),
                                                 "activeCoverageEnds": cells.isEmpty ? .null : .string(cells.joined(separator: "; "))])
            case .noActiveCoverage(let statuses):
                attributes = attributes.merging(["coverage": .string("coverage records read, none ACTIVE"), "recordStatuses": .string(statuses.joined(separator: "; "))])
            case .statusUnknown(let statuses):
                attributes = attributes.merging(["coverage": .string("coverage status not known to this version: not out of warranty, not estimated"),
                                                 "recordStatuses": .string(statuses.joined(separator: "; "))])
            case .noRecord: attributes = attributes.merging(["coverage": .string("no coverage record (may mean no AppleCare, not expired)")])
            case .notRead(let why): attributes = attributes.merging(["coverage": .string("not read: \(why)")])
            }
            switch row.estimate {
            case .notMade: break
            case .noOrderDate: attributes = attributes.merging(["estimate": .string("estimate not possible: no order date"), "assumption": .string(Self.assumption)])
            case .unreadableOrderDate:
                attributes = attributes.merging(["estimate": .string("estimate not possible: order date not readable"),
                                                 "assumption": .string(Self.assumption)])
            case .pastAssumedLimit(let end):
                attributes = attributes.merging(["estimate": .string("estimate: past the assumed one year"), "estimatedEnd": .string(end.formatted(formatter)),
                                                 "assumption": .string(Self.assumption)])
            case .withinAssumedLimit(let end):
                attributes = attributes.merging(["estimate": .string("estimate: within the assumed one year"), "estimatedEnd": .string(end.formatted(formatter)),
                                                 "assumption": .string(Self.assumption)])
            }
            return CSV.Item(id: row.device.id, attributes: finish(list, identity: identity(row.device).merging(["orderDateTime": attributes["orderDateTime"] ?? .null]),
                                                                   full: attributes, judgments: ["coverage"]))
        }
    }
}
