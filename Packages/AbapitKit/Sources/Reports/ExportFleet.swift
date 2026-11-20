import AppleModels
import Foundation
import JSONAPI

extension ExportPolicy {
    /// The Activation Lock report's export. Every cell is computed from `isLocked` and `lockType`; nothing of the device's
    /// attributes beyond the three identifying ones is copied, so a bypass code or an unknown key never leaves (invariant 11).
    public static let activationLockReport = Columns(["serialNumber", "deviceModel", "productFamily", "state", "lockType", "blocksRelease", "notRead"])
    public static let migrationReport = Columns(["serialNumber", "deviceModel", "productFamily", "state", "mdmMigrationStatus", "isMdmMigrationCapable",
                                                 "mdmMigrationDeadlineDateTime", "daysToDeadline", "pastDue"])
    public static let serviceHealth = Columns(["serverName", "serverType", "status", "health", "healthReason", "lastConnectedDateTime", "lastConnected",
                                               "deviceCount", "deviceCountIs", "notSentByApple"])
    public static let warrantyReport = Columns(["serialNumber", "deviceModel", "productFamily", "orderDateTime", "coverage", "activeCoverageEnds",
                                                "recordStatuses", "estimate", "estimatedEnd", "assumption"])
}

private func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

private func identity(_ device: OrgDevice) -> JSONObject {
    ["serialNumber": .string(device.serialNumber), "deviceModel": text(device.deviceModel), "productFamily": text(device.productFamily?.rawValue)]
}

extension ActivationLockReport {
    public var csvItems: [CSV.Item] {
        rows.map { row in
            var attributes = identity(row.device)
            attributes = attributes.merging(["state": .string(Self.title(row.group)), "blocksRelease": .string(yesNo(row.blocksRelease))])
            switch row.kind {
            case .userLock: attributes = attributes.merging(["lockType": .string("USER")])
            case .mdmLock: attributes = attributes.merging(["lockType": .string("MDM")])
            case .otherLock(let raw): attributes = attributes.merging(["lockType": .string(raw)])
            case .notRead(let why): attributes = attributes.merging(["notRead": .string(why)])
            case .unlocked, .unclear: break
            }
            return CSV.Item(id: row.device.id, attributes: attributes)
        }
    }
}

extension MigrationReport {
    public var csvItems: [CSV.Item] {
        rows.map { row in
            var attributes = identity(row.device).merging([
                "state": .string(Self.title(row.group)), "mdmMigrationStatus": text(row.status?.rawValue),
                "isMdmMigrationCapable": .string(yesNo(row.device.isMigrationCapable)), "pastDue": .string(yesNo(row.pastDue)),
            ])
            switch row.deadline {
            case .none: break
            case .unreadable(let raw): attributes = attributes.merging(["mdmMigrationDeadlineDateTime": .string(raw), "daysToDeadline": .string("deadline not readable")])
            case .left(let days): attributes = attributes.merging(["mdmMigrationDeadlineDateTime": text(row.device.attributes.string("mdmMigrationDeadlineDateTime")),
                                                                   "daysToDeadline": .string(String(days))])
            case .overdue(let days): attributes = attributes.merging(["mdmMigrationDeadlineDateTime": text(row.device.attributes.string("mdmMigrationDeadlineDateTime")),
                                                                      "daysToDeadline": .string("\(days) days overdue")])
            }
            return CSV.Item(id: row.device.id, attributes: attributes)
        }
    }
}

extension ServiceHealth {
    public var csvItems: [CSV.Item] {
        rows.map { row in
            var attributes: JSONObject = ["serverName": .string(row.service.name), "serverType": text(row.service.type?.rawValue),
                                          "status": text(row.service.status?.rawValue), "health": .string(row.group),
                                          "notSentByApple": .string(notSent.joined(separator: "; "))]
            if case .cannotJudge(let why) = row.health { attributes = attributes.merging(["healthReason": .string(why)]) }
            if case .otherStatus(let raw) = row.health { attributes = attributes.merging(["healthReason": .string("status \(raw)")]) }
            switch row.lastConnected {
            case .notSent: attributes = attributes.merging(["lastConnected": .string("not sent by Apple")])
            case .never: attributes = attributes.merging(["lastConnected": .string("never")])
            case .unreadable(let raw): attributes = attributes.merging(["lastConnected": .string("not a date"), "lastConnectedDateTime": .string(raw)])
            case .at(let date, let days):
                attributes = attributes.merging(["lastConnected": .string("\(days) days ago"), "lastConnectedDateTime": .string(date.isoformat)])
            }
            switch row.deviceCount {
            case nil: attributes = attributes.merging(["deviceCountIs": .string("not read")])
            case .exactly(let count)?: attributes = attributes.merging(["deviceCount": .string(String(count)), "deviceCountIs": .string("exactly")])
            case .atLeast(let count)?: attributes = attributes.merging(["deviceCount": .string(String(count)), "deviceCountIs": .string("at least")])
            }
            return CSV.Item(id: row.service.id, attributes: attributes)
        }
    }
}

extension WarrantyReport {
    public var csvItems: [CSV.Item] {
        let formatter = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)
        return rows.map { row in
            var attributes = identity(row.device).merging(["orderDateTime": text(row.device.attributes.string("orderDateTime"))])
            switch row.kind {
            case .active(let ends): attributes = attributes.merging(["coverage": .string("active AppleCare coverage"), "activeCoverageEnds": text(ends?.isoformat)])
            case .noActiveCoverage(let statuses):
                attributes = attributes.merging(["coverage": .string("coverage records read, none ACTIVE"), "recordStatuses": .string(statuses.joined(separator: "; "))])
            case .noRecord: attributes = attributes.merging(["coverage": .string("no coverage record (may mean no AppleCare, not expired)")])
            case .notRead(let why): attributes = attributes.merging(["coverage": .string("not read: \(why)")])
            }
            switch row.estimate {
            case .notMade: break
            case .noOrderDate: attributes = attributes.merging(["estimate": .string("estimate not possible: no order date"), "assumption": .string(Self.assumption)])
            case .unreadableOrderDate: attributes = attributes.merging(["estimate": .string("estimate not possible: order date not readable"), "assumption": .string(Self.assumption)])
            case .pastAssumedLimit(let end):
                attributes = attributes.merging(["estimate": .string("estimate: past the assumed one year"), "estimatedEnd": .string(end.formatted(formatter)),
                                                 "assumption": .string(Self.assumption)])
            case .withinAssumedLimit(let end):
                attributes = attributes.merging(["estimate": .string("estimate: within the assumed one year"), "estimatedEnd": .string(end.formatted(formatter)),
                                                 "assumption": .string(Self.assumption)])
            }
            return CSV.Item(id: row.device.id, attributes: attributes)
        }
    }
}
