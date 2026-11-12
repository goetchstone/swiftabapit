import Foundation
import JSONAPI
import MosyleModels
import Wire

/// Every Mosyle read this app sends (plan §3.3, invariant 2): Mosyle reads are POSTs, so a read is a
/// `(path, operation)` on this allowlist, and only these builders make one. Anything else Mosyle offers is a
/// write and goes through ChangeCore (Phase 8). The Logs Stream consumes what it returns, so its read is made
/// only for `LogsDrain`.
public enum MosyleRead {
    /// The allowlist, by path and operation (`nil`: an endpoint without an `operation`).
    public static let allowed: Set<String> = [
        "/v1/devices#list", "/v1/devices#list_custom_device_attributes", "/v1/users#list_users",
        "/v1/usergroups#list_usergroup", "/v1/devicegroups#list_devicegroup", "/v1/devicegroups#get_info", "/v1/adminlogs#",
        "/v1/logsstream#",
    ]

    /// The platforms the device list must be asked for one at a time (`os` is required).
    public static let platforms = ["ios", "mac", "tvos", "visionos"]
    /// Requested per page; the server may send fewer (abapit assumed 500 and lost rows past 50: defect 2).
    public static let pageSize = 500

    /// Each list's own statuses for "past the end" (Phase 7a review M1: only `DEVICES_NOTFOUND` ended a list, so
    /// 50 users and then a status lost all 50). `DEVICES_NOTFOUND` is abapit's (its recorded envelope) and
    /// `USERGROUP_NOTFOUND` the plan's (§3.5); the rest are guesses, listed in docs/domains/mosyle.md to check live.
    /// A status that isn't the list's own still fails closed.
    static let endOfList: [String: Set<String>] = [
        "/v1/devices#list": ["DEVICES_NOTFOUND"],
        "/v1/users#list_users": ["USERS_NOTFOUND", "USER_NOTFOUND"],
        "/v1/usergroups#list_usergroup": ["USERGROUP_NOTFOUND", "USERGROUPS_NOTFOUND"],
        "/v1/devicegroups#list_devicegroup": ["DEVICEGROUPS_NOTFOUND", "DEVICEGROUP_NOTFOUND"],
    ]

    /// The end-of-list statuses of the list `request` reads (none for anything else).
    static func ends(_ request: ReadRequest) -> Set<String> { key(of: request).flatMap { endOfList[$0] } ?? [] }

    static func body(_ operation: String?, _ options: JSONObject, top: JSONObject = [:]) -> Data {
        var object = JSONObject()
        if let operation { object["operation"] = JSONValue.string(operation) }
        for (key, value) in top { object[key] = value }
        if !options.isEmpty { object["options"] = JSONValue.object(options) }
        let text: String = JSONValue.dumps(JSONValue.object(object))
        return Data(text.utf8)
    }

    static func read(_ path: String, _ operation: String?, _ options: JSONObject = [:], top: JSONObject = [:], host: APIHost = .mosyle) -> ReadRequest {
        precondition(allowed.contains("\(path)#\(operation ?? "")"), "\(path) \(operation ?? "") is not a Mosyle read")
        return ReadRequest(host: host, method: .post, path: path, template: "\(path) \(operation ?? "")", body: body(operation, options, top: top))
    }

    /// `path#operation` as Mosyle will read the request: nil unless the body is exactly what `body(_:_:)` writes
    /// (so no duplicate key, odd spacing or escape can make Mosyle read another operation than this check did) and
    /// its operation, when it has one, is a non-empty string.
    static func key(of request: ReadRequest) -> String? {
        guard let data = request.body, let parsed = JSONValue.parse(String(decoding: data, as: UTF8.self)),
              let object = parsed.object, Data(JSONValue.dumps(parsed).utf8) == data else { return nil }
        switch object["operation"] {
        case nil: return "\(request.path)#"
        case .string(let operation)? where !operation.isEmpty: return "\(request.path)#\(operation)"
        default: return nil
        }
    }

    /// Whether `request`, as it will be sent, is a Mosyle read: a POST with no query, its `(path, operation)` on the
    /// allowlist, to the host that path belongs to. Checked again just before sending (Phase 7a review M4), so a
    /// `ReadRequest` made anywhere else in the package can't carry a write past the builders' `precondition`.
    package static func isAllowed(_ request: ReadRequest) -> Bool {
        guard request.method == .post, request.query.isEmpty, let key = key(of: request), allowed.contains(key) else { return false }
        return request.host == (request.path == "/v1/logsstream" ? .mosyleLogs : .mosyle)
    }

    /// One page of one platform's devices, the adapter's columns only (defect 1: no bypass codes requested).
    public static func devices(os: String, page: Int) -> ReadRequest {
        devices(os: os, page: page, columns: MosyleAdapter.deviceColumns)
    }

    /// The same, asking for `columns` (only those the adapter keeps), or with no `specific_columns` at all (nil):
    /// the client's fallback when Mosyle refuses a column (Phase 7a review H3). Not public: no caller picks columns.
    static func devices(os: String, page: Int, columns: [String]?) -> ReadRequest {
        var options = JSONObject()
        options["os"] = JSONValue.string(os)
        options["page"] = JSONValue.number(String(page))
        options["page_size"] = JSONValue.number(String(pageSize))
        if let columns {
            let kept = columns.filter(MosyleAdapter.deviceColumns.contains)
            options["specific_columns"] = JSONValue.array(kept.map(JSONValue.string))
        }
        return read("/v1/devices", "list", options)
    }

    static func paging(_ page: Int) -> JSONObject {
        var options = JSONObject()
        options["page"] = JSONValue.number(String(page))
        options["page_size"] = JSONValue.number(String(pageSize))
        return options
    }

    public static func users(page: Int) -> ReadRequest {
        read("/v1/users", "list_users", paging(page))
    }

    public static func userGroups(page: Int) -> ReadRequest {
        read("/v1/usergroups", "list_usergroup", paging(page))
    }

    public static func deviceGroups(os: String, page: Int) -> ReadRequest {
        var options = paging(page)
        options["os"] = JSONValue.string(os)
        return read("/v1/devicegroups", "list_devicegroup", options)
    }

    /// One platform's custom device attributes (`list_custom_device_attributes`). Its `os` sits beside the operation, not
    /// in `options` (plan §2.2, Mosyle's own doc; a third-party client of Mosyle Manager sends it the same way). Not paged:
    /// no source shows a page. Its answer's shape has no source here: docs/domains/mosyle.md, "Assumed, check live".
    public static func customAttributes(os: String) -> ReadRequest {
        read("/v1/devices", "list_custom_device_attributes", top: ["os": .string(os)])
    }

    /// `security_compliance_status`, the device-group read's filter: its two values are a third-party client's (of Mosyle
    /// Manager, which takes the same option); Mosyle Business's own doc names the option (plan §2.2).
    public enum Compliance: String, Sendable, CaseIterable {
        case compliant, noncompliant
    }

    /// A device group's members (`get_info`, `options.iddevicegroup`, the id as a string as Mosyle's Postman collection
    /// sends it), only those `compliance` names when given.
    public static func deviceGroupInfo(id: String, compliance: Compliance? = nil) -> ReadRequest {
        var options = JSONObject()
        options["iddevicegroup"] = JSONValue.string(id)
        if let compliance { options["security_compliance_status"] = JSONValue.string(compliance.rawValue) }
        return read("/v1/devicegroups", "get_info", options)
    }

    /// The admin audit log from `start` to `end` (`YYYY-MM-DD`, both included): `/adminlogs` takes no operation, only
    /// `filter_options` (plan §2.2, Mosyle's own doc). The dates' format has no source: docs/domains/mosyle.md.
    public static func adminLogs(start: String, end: String) -> ReadRequest {
        precondition([start, end].allSatisfy(isDay), "an admin-log date is YYYY-MM-DD")
        return read("/v1/adminlogs", nil, top: ["filter_options": .object(["start_date": .string(start), "end_date": .string(end)])])
    }

    static func isDay(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 10 && scalars.indices.allSatisfy { [4, 7].contains($0) ? scalars[$0] == "-" : ("0"..."9").contains(scalars[$0]) }
    }

    /// The Logs Stream page `page` of the given log types (separate host and token). Consuming.
    package static func logsStream(types: [String], page: Int) -> ReadRequest {
        // Its body is top-level (`{"LogType": [...], "page": n}`), not an operation with options (abapit's `logs`).
        let body: JSONObject = ["LogType": .array(types.map(JSONValue.string)), "page": .number(String(page))]
        precondition(allowed.contains("/v1/logsstream#"))
        return ReadRequest(host: .mosyleLogs, method: .post, path: "/v1/logsstream", template: "/v1/logsstream",
                           body: Data(JSONValue.dumps(.object(body)).utf8))
    }
}
