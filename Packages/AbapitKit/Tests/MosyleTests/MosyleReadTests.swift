import Foundation
import HTTPCore
import JSONAPI
@testable import Mosyle
import MosyleModels
import Testing
import Wire

/// The Mosyle read allowlist as values, not only as source text (invariant 2; Phase 7a review M4: a `reduce(into:)`
/// after the literal, a `|| true` in the `precondition` and an operation in the Logs Stream's body all passed).
@Suite("Mosyle reads")
struct MosyleReadTests {
    @Test func theAllowlistIsExactlyTheseEight() {
        #expect(MosyleRead.allowed == [
            "/v1/devices#list", "/v1/devices#list_custom_device_attributes", "/v1/users#list_users", "/v1/usergroups#list_usergroup",
            "/v1/devicegroups#list_devicegroup", "/v1/devicegroups#get_info", "/v1/adminlogs#", "/v1/logsstream#",
        ])
    }

    /// Every builder's request passes the check made before sending, the Logs Stream's included, with no operation.
    @Test func everyBuilderMakesARead() throws {
        let logs = MosyleRead.logsStream(types: ["compliance", "dns"], page: 2)
        for request in [MosyleRead.devices(os: "mac", page: 1), MosyleRead.devices(os: "ios", page: 3, columns: nil), MosyleRead.users(page: 2),
                        MosyleRead.userGroups(page: 1), MosyleRead.deviceGroups(os: "tvos", page: 1), logs] {
            #expect(MosyleRead.isAllowed(request), "\(request.template)")
        }
        let body = try #require(logs.body.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self))?.object })
        #expect(body.keys == ["LogType", "page"])
        #expect(logs.host == .mosyleLogs)
    }

    /// The device list asks only for columns the adapter keeps, whatever the caller passes.
    @Test func theDeviceColumnsAreTheAdapters() throws {
        let request = MosyleRead.devices(os: "mac", page: 1, columns: ["serial_number", "activation_bypass", "password"])
        let body = try #require(request.body.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) })
        #expect(body["options"]?["specific_columns"] == .array([.string("serial_number")]))
        let whole = try #require(MosyleRead.devices(os: "mac", page: 1).body.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) })
        #expect(whole["options"]?["specific_columns"] == .array(MosyleAdapter.deviceColumns.map(JSONValue.string)))
    }

    /// A request made anywhere else in the package is checked as Mosyle will read it.
    @Test func aForgedReadIsRefused() {
        func forged(_ body: String?, path: String = "/v1/devices", host: APIHost = .mosyle, method: HTTPMethod = .post,
                    query: [QueryItem] = []) -> ReadRequest {
            ReadRequest(host: host, method: method, path: path, query: query, body: body.map { Data($0.utf8) })
        }
        #expect(MosyleRead.isAllowed(forged(#"{"operation": "list"}"#)), "the control: the builders' own form")
        let refused: [(ReadRequest, String)] = [
            (forged(#"{"operation": "wipe_devices"}"#), "a write"),
            (forged(#"{"operation": "list", "operation": "wipe_devices"}"#), "a duplicate key Mosyle reads last"),
            (forged(#"{"operation":"list"}"#), "not the builders' serialization"),
            (forged(#"{"operation": "l\u0069st"}"#), "an escape Mosyle decodes"),
            (forged(#"{"operation": ""}"#, path: "/v1/adminlogs"), "an empty operation"),
            (forged(#"{"operation": 1}"#), "an operation that isn't a string"),
            (forged(#"{"options": {}}"#, path: "/v1/lostmode"), "an operation-less write"),
            (forged(#"{"operation": "list"}"#, host: .mosyleLogs), "the wrong host"),
            (forged(#"{"LogType": ["dns"], "page": 1}"#, path: "/v1/logsstream", host: .mosyle), "the Logs Stream on the business host"),
            (forged(#"{"operation": "wipe_devices", "LogType": ["dns"]}"#, path: "/v1/logsstream", host: .mosyleLogs), "an operation on the Logs Stream"),
            (forged(#"{"operation": "list"}"#, method: .get), "not a POST"),
            (forged(#"{"operation": "list"}"#, query: [QueryItem("operation", "wipe_devices")]), "a query"),
            (forged(nil), "no body"),
            (forged(#"["list"]"#), "a body that isn't an object"),
        ]
        for (request, why) in refused { #expect(!MosyleRead.isAllowed(request), "\(why)") }
    }

    /// The builders' own `precondition` traps, in a child process: a builder for anything else can't be made.
    @Test func aBuilderForAnythingElseTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = MosyleRead.read("/v1/devices", "wipe_devices")
        }
        await #expect(processExitsWith: .failure) {
            _ = MosyleRead.read("/v1/lostmode", nil)
        }
    }

    /// The login's request and answer carry the access token, the password and the JWT: none prints, dumps or
    /// reflects (Phase 7a review L6), as `Secret` doesn't.
    @Test func aLoginsRequestAndAnswerNeverShowTheirSecrets() {
        let request = AuthRequest(host: .mosyle, path: "/v1/login", contentType: "application/json", headers: ["accessToken": "TOKEN-SECRET"],
                                  body: Data(#"{"email": "admin@example.com", "password": "PASSWORD-SECRET"}"#.utf8))
        let response = HTTPResponse(status: 200, headers: ["authorization": "Bearer JWT-SECRET", "set-cookie": "PHPSESSID=COOKIE-SECRET"],
                                    body: Data(#"{"token": "JWT-SECRET"}"#.utf8))
        for value in [request as Any, response as Any] {
            var dumped = ""
            dump(value, to: &dumped)
            let reflected = Mirror(reflecting: value).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: ", ")
            for text in [String(describing: value), String(reflecting: value), dumped, reflected, "\(value)"] {
                #expect(!text.contains("SECRET") && !text.contains("admin@example.com"), "\(text)")
            }
        }
        #expect(String(describing: request).contains("accessToken") && String(describing: response).contains("200"))
    }
}
