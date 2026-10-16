import Foundation
import JSONAPI

/// Mosyle's status codes inside an HTTP 200 (plan §3.5). A list that found nothing, a missing parameter or an
/// unknown column all arrive as 200 with a status here: abapit read them as empty lists and "ok" (defect 3).
public enum MosyleStatus: String, KnownValues {
    case ok = "OK"
    case missingData = "MISSING_DATA"
    case devicesNotFound = "DEVICES_NOTFOUND"
    case unknownColumns = "UNKNOWN_COLUMNS"
    case noDeviceUpdated = "NO_DEVICE_UPDATED"
    case userGroupNotFound = "USERGROUP_NOTFOUND"
    case lostModeNotEnabled = "LOSTMODE_NOTENABLED"
    case commandSent = "COMMAND_SENT"
    /// Mosyle spells it both ways; both mean the command was sent.
    case commandSended = "COMMAND_SENDED"
    case deviceUpdated = "DEVICE_UPDATED"
    case deviceAssigned = "DEVICE_ASSIGNED"

    /// Statuses that mean the request did what it asked.
    public var isSuccess: Bool { [.ok, .commandSent, .commandSended, .deviceUpdated, .deviceAssigned].contains(self) }
    /// A list read past its end: no more rows, not an error.
    public var isEndOfList: Bool { self == .devicesNotFound }
}

/// One Mosyle response: `{"status": "OK", "response": [{…}]}` for most operations, `{"response": {…}}` for
/// `devicegroups` and `logsstream`. The top-level `status` says nothing (it is "OK" on errors too); the entry's
/// `status` is the operation's.
public struct MosyleEnvelope: Sendable {
    /// `response[0]`, or `response` when it is an object.
    public let entry: JSONObject
    public let status: OpenEnum<MosyleStatus>?
    public let info: String?

    public init?(_ body: Data) {
        guard let root = JSONValue.parse(String(decoding: body, as: UTF8.self))?.object else { return nil }
        switch root["response"] {
        case .array(let items)?: entry = items.first?.object ?? [:]
        case .object(let object)?: entry = object
        default: entry = [:]
        }
        status = entry["status"]?.string.map(OpenEnum.init)
        info = entry["info"]?.string
    }

    /// The operation failed by its own status (anything but success and the end of a list). Unknown statuses fail
    /// closed: a new error code must not read as rows.
    public var failure: OpenEnum<MosyleStatus>? {
        guard let status else { return nil }
        if let known = status.known, known.isSuccess || known.isEndOfList { return nil }
        return status
    }

    /// The list under the first of `keys` that holds one (abapit's `_extract`: `devices`, `users`, `usergroups`…).
    public func list(_ keys: String...) -> [JSONObject] {
        for key in keys { if case .array(let items)? = entry[key] { return items.compactMap(\.object) } }
        return []
    }

    /// `rows` or `rows_count`: the total across pages, an integer or a string of one.
    public var total: Int? {
        for key in ["rows", "rows_count"] {
            switch entry[key] {
            case .number(let text)?: if let value = Int(text) { return value }
            case .string(let text)?: if let value = Int(text.trimmingCharacters(in: .whitespaces)) { return value }
            default: continue
            }
        }
        return nil
    }
}
