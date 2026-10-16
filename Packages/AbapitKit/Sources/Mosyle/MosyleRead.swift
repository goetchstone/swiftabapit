import Foundation
import JSONAPI
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

    static func body(_ operation: String?, _ options: JSONObject) -> Data {
        var object = JSONObject()
        if let operation { object["operation"] = JSONValue.string(operation) }
        if !options.isEmpty { object["options"] = JSONValue.object(options) }
        let text: String = JSONValue.dumps(JSONValue.object(object))
        return Data(text.utf8)
    }

    static func read(_ path: String, _ operation: String?, _ options: JSONObject = [:], host: APIHost = .mosyle) -> ReadRequest {
        precondition(allowed.contains("\(path)#\(operation ?? "")"), "\(path) \(operation ?? "") is not a Mosyle read")
        return ReadRequest(host: host, method: .post, path: path, template: "\(path) \(operation ?? "")", body: body(operation, options))
    }

    /// One page of one platform's devices, only the allowlisted columns (defect 1: no bypass codes requested).
    public static func devices(os: String, page: Int, columns: [String]) -> ReadRequest {
        var options = JSONObject()
        options["os"] = JSONValue.string(os)
        options["page"] = JSONValue.number(String(page))
        options["page_size"] = JSONValue.number(String(pageSize))
        options["specific_columns"] = JSONValue.array(columns.map(JSONValue.string))
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

    /// The Logs Stream page `page` of the given log types (separate host and token). Consuming.
    package static func logsStream(types: [String], page: Int) -> ReadRequest {
        // Its body is top-level (`{"LogType": [...], "page": n}`), not an operation with options (abapit's `logs`).
        let body: JSONObject = ["LogType": .array(types.map(JSONValue.string)), "page": .number(String(page))]
        precondition(allowed.contains("/v1/logsstream#"))
        return ReadRequest(host: .mosyleLogs, method: .post, path: "/v1/logsstream", template: "/v1/logsstream",
                           body: Data(JSONValue.dumps(.object(body)).utf8))
    }
}
