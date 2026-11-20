import AppleModels
import Foundation
import JSONAPI
@testable import Reports

/// Builders for the fleet reports' tests. `now` is 2026-11-20T12:00:00Z.
enum Fleet {
    static let now = Date(timeIntervalSince1970: 1_795_176_000)

    static func device(_ serial: String, _ extra: JSONObject = [:]) -> OrgDevice {
        let base: JSONObject = ["serialNumber": .string(serial), "deviceModel": .string("Mac mini"), "productFamily": .string("Mac")]
        return OrgDevice(resource: Resource(type: "orgDevices", id: serial, attributes: base.merging(extra)))
    }

    static func lock(_ isLocked: Bool?, _ type: String?) -> ActivationLockStatus {
        var attributes: JSONObject = [:]
        if let isLocked { attributes = attributes.merging(["isLocked": .bool(isLocked)]) }
        if let type { attributes = attributes.merging(["lockType": .string(type)]) }
        return ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: attributes))
    }

    static func coverage(_ status: String?, end: String? = nil) -> AppleCareCoverage {
        var attributes: JSONObject = ["description": .string("AppleCare+")]
        if let status { attributes = attributes.merging(["status": .string(status)]) }
        if let end { attributes = attributes.merging(["endDateTime": .string(end)]) }
        return AppleCareCoverage(resource: Resource(type: "appleCareCoverage", id: "c", attributes: attributes))
    }

    static func service(_ id: String, status: String? = "ACTIVE", last: JSONValue? = nil, count: Int? = nil) -> MDMService {
        var attributes: JSONObject = ["serverName": .string(id)]
        if let status { attributes = attributes.merging(["status": .string(status)]) }
        if let last { attributes = attributes.merging(["lastConnectedDateTime": last]) }
        if let count { attributes = attributes.merging(["deviceCount": .number(String(count))]) }
        return MDMService(resource: Resource(type: "mdmServers", id: id, attributes: attributes))
    }

    /// An ISO stamp `seconds` from `now` (negative: before).
    static func stamp(_ seconds: TimeInterval) -> String {
        Date(timeIntervalSince1970: now.timeIntervalSince1970 + seconds).formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    /// A report's CSV as `id -> column -> cell`.
    static func table(_ text: String) -> [String: [String: String]] {
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let header = fields(lines[0])
        var out: [String: [String: String]] = [:]
        for line in lines.dropFirst() {
            let cells = fields(line)
            out[cells[0]] = Dictionary(uniqueKeysWithValues: zip(header, cells))
        }
        return out
    }

    static func header(_ text: String) -> String { text.components(separatedBy: "\r\n")[0] }

    /// One CSV line's fields, as `csv.reader` reads them: a quoted field may hold commas and `""` for a quote.
    static func fields(_ line: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        let scalars = Array(line.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { current.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { current.unicodeScalars.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { out.append(current); current = "" }
            else { current.unicodeScalars.append(ch) }
            i += 1
        }
        out.append(current)
        return out
    }
}
