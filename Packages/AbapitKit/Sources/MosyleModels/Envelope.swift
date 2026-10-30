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
    /// The device list read past its end. Each list has its own end-of-list statuses, which a list read passes to
    /// `read(_:endOfList:)` (Phase 7a review M1: this one ended every list, and no other ended any).
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
    /// Why this isn't an answer Mosyle sends, when it isn't: no `response`, a `response` that is neither a list nor
    /// an object, an empty list, a first entry that isn't an object, or a `status` that isn't a string. Each of
    /// these read as an empty list, and a ping as "ok" (Phase 7a review H2: defect 3 again).
    public let malformed: String?

    /// Nil when the body isn't a JSON object.
    public init?(_ body: Data) {
        guard let root = JSONValue.parse(String(decoding: body, as: UTF8.self))?.object else { return nil }
        var entry = JSONObject(), malformed: String?
        switch root["response"] {
        case .array(let items)?:
            if let first = items.first {
                if let object = first.object { entry = object } else { malformed = "its first entry isn't an object" }
            } else {
                malformed = "its response list is empty"
            }
        case .object(let object)?: entry = object
        case nil:
            // `{"status": "ERROR", "message": …}`: a code is worth showing; the message is Mosyle's text, not shown.
            let code = root["status"]?.string.flatMap { text in
                text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") } ? text : nil
            }
            malformed = "it has no response" + (code.map { " (status \($0))" } ?? "")
        default: malformed = "its response is neither a list nor an object"
        }
        switch entry["status"] {
        case nil: status = nil
        case .string(let text)?: status = OpenEnum(text)
        default:
            status = nil
            malformed = malformed ?? "its status isn't a string"
        }
        self.entry = entry
        self.malformed = malformed
        info = entry["info"]?.string
    }

    /// The operation failed by its own status (anything but success and the end of a list). Unknown statuses fail
    /// closed: a new error code must not read as rows. A list read uses `read(_:endOfList:)` instead.
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

    /// `rows` or `rows_count`, an integer or a string of one. Whether it is the overall total or the page's count is
    /// unconfirmed, so no walk stops on it (stopping early was defect 2); the client logs it for the Phase 7 live check.
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

    /// One page of a list read.
    public enum Page: Sendable, Equatable {
        case rows([JSONObject])
        /// The list's own end-of-list status, or an empty list.
        case end
    }

    /// Why a page of a list can't be read.
    public enum Problem: Error, Sendable, Equatable {
        case malformed(String)
        case status(OpenEnum<MosyleStatus>, info: String?)
    }

    /// One page of a list read. Two answers are a page, on every page: a list under the first of `keys` that holds
    /// one (abapit's `_extract`; an empty list is the end), or the list's own end-of-list status (`endOfList`,
    /// compared byte for byte) with no rows beside it. `OK` is no status. Anything else is an error: another status,
    /// an unknown one included (defect 3); a list key holding something else (`null`, a string, PHP's object-keyed
    /// array); an end status beside rows; or no list at all. Each read as an empty list and a ping as "ok", on page 1
    /// beside an `OK` and on any later page (Phase 7a review H2, and its verification): no source says Mosyle ends a
    /// list that way, so it is said, not guessed (docs/domains/mosyle.md, "Assumed, check live").
    public func read(_ keys: [String], endOfList: Set<String>) throws(Problem) -> Page {
        if let malformed { throw .malformed(malformed) }
        var end: OpenEnum<MosyleStatus>?
        if let status, status != .known(.ok) {
            guard endOfList.contains(where: { $0.utf8.elementsEqual(status.rawValue.utf8) }) else { throw .status(status, info: info) }
            end = status
        }
        var rows: [JSONObject]?
        for key in keys {
            guard case .array(let items)? = entry[key] else { continue }
            let objects = items.compactMap(\.object)
            guard objects.count == items.count else { throw .malformed("a row under \(key) isn't an object") }
            rows = objects
            break
        }
        if rows == nil, let key = keys.first(where: { entry[$0] != nil }) { throw .malformed("its \(key) isn't a list") }
        if let end {
            guard rows?.isEmpty ?? true else { throw .malformed("its status \(end.rawValue) ends the list, yet it holds rows") }
            return .end
        }
        guard let rows else { throw .malformed("it has no \(keys.joined(separator: " or ")) list and no end-of-list status") }
        return rows.isEmpty ? .end : .rows(rows)
    }
}
