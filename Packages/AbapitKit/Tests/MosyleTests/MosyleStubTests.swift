import Foundation
import JSONAPI
import Synchronization
import Testing
import TestSupport

/// The stub's own strictness (invariant 5): a stub that stops checking turns a live break into a green test, and
/// Phase 7a's review deleted its `accessToken` and JWT-expiry checks with every test still green.
@Suite("Mosyle stub")
struct MosyleStubTests {
    final class Now: Sendable {
        private let date = Mutex(Date())
        var value: Date { date.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    static func post(_ stub: MosyleStub, host: String = "businessapi.mosyle.com", path: String, headers: [String: String],
                     body: String) async throws -> (Int, String?) {
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.utf8)
        let (_, response) = try await stub.send(request, limit: 1 << 20)
        return (response.statusCode, response.value(forHTTPHeaderField: "Authorization"))
    }

    static func login(_ stub: MosyleStub, host: String = "businessapi.mosyle.com", token: String = "access-token",
                      password: String = "pw") async throws -> (Int, String?) {
        try await post(stub, host: host, path: "/v1/login", headers: ["accessToken": token],
                       body: #"{"email": "admin@example.com", "password": "\#(password)"}"#)
    }

    static func list(_ stub: MosyleStub, _ headers: [String: String]) async throws -> Int {
        try await post(stub, path: "/v1/devices", headers: headers, body: #"{"operation": "list", "options": {"os": "mac"}}"#).0
    }

    /// The entry's status of an HTTP 200 from the stub.
    static func status(_ stub: MosyleStub, path: String, headers: [String: String], body: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://businessapi.mosyle.com\(path)")!)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await stub.send(request, limit: 1 << 20)
        #expect(response.statusCode == 200)
        let root = JSONValue.parse(String(decoding: data, as: UTF8.self))
        return root?["response"]?.array?.first?["status"]?.string ?? root?["response"]?["status"]?.string
    }

    @Test func aReadNeedsTheAccessTokenAndALiveJWTOfThisHost() async throws {
        let now = Now()
        let stub = MosyleStub(now: { now.value })
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw", logsToken: "logs-token"))
        stub.jwtLifetime(3600)
        let (status, bearer) = try await Self.login(stub)
        let jwt = try #require(bearer)
        #expect(status == 200 && jwt.hasPrefix("Bearer "))
        #expect(try await Self.list(stub, ["accessToken": "access-token", "Authorization": jwt]) == 200, "the control")
        #expect(try await Self.list(stub, ["Authorization": jwt]) == 401, "no accessToken")
        #expect(try await Self.list(stub, ["accessToken": "logs-token", "Authorization": jwt]) == 401, "another accessToken")
        #expect(try await Self.list(stub, ["accessToken": "access-token", "Authorization": jwt + "x"]) == 401, "a JWT it never issued")
        #expect(try await Self.list(stub, ["accessToken": "access-token"]) == 401, "no JWT")
        let logs = try #require(try await Self.login(stub, host: "businessapilogs.mosyle.com", token: "logs-token").1)
        #expect(try await Self.list(stub, ["accessToken": "access-token", "Authorization": logs]) == 401, "the Logs Stream's JWT")
        now.advance(3601)
        #expect(try await Self.list(stub, ["accessToken": "access-token", "Authorization": jwt]) == 401, "an expired JWT")
    }

    @Test func aLoginNeedsItsHostsTokenAndTheAdminsPassword() async throws {
        let stub = MosyleStub()
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw", logsToken: "logs-token"))
        #expect(try await Self.login(stub).0 == 200)
        #expect(try await Self.login(stub, password: "other").0 == 401)
        #expect(try await Self.login(stub, token: "logs-token").0 == 401, "the Logs Stream's token on the business host")
        #expect(try await Self.login(stub, host: "businessapilogs.mosyle.com").0 == 401, "the business token on the Logs host")
        #expect(try await Self.login(stub, host: "businessapilogs.mosyle.com", token: "logs-token").0 == 200)
        #expect(stub.logins == 2)
        let noLogs = MosyleStub()
        noLogs.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw"))
        #expect(try await Self.login(noLogs, host: "businessapilogs.mosyle.com", token: "").0 == 401, "no Logs Stream token, no login")
    }

    /// The stub's other refusals (Phase 7a's verification: deleting each survived): a login with another admin's
    /// email, a query string (Mosyle reads take a body), a device or device-group list without `os` or with an empty
    /// one (plan §6.3: `MISSING_DATA`; round 3: the empty one was never sent), and a column name that isn't a string.
    @Test func theStubRefusesWhatMosyleRefuses() async throws {
        let stub = MosyleStub()
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw"))
        let other = try await Self.post(stub, path: "/v1/login", headers: ["accessToken": "access-token"],
                                        body: #"{"email": "other@example.com", "password": "pw"}"#)
        #expect(other.0 == 401 && other.1 == nil, "another admin's email")
        let jwt = try #require(try await Self.login(stub).1)
        let auth = ["accessToken": "access-token", "Authorization": jwt]
        var query = URLRequest(url: URL(string: "https://businessapi.mosyle.com/v1/devices?operation=list")!)
        query.httpMethod = "POST"
        for (name, value) in auth { query.setValue(value, forHTTPHeaderField: name) }
        query.httpBody = Data(#"{"operation": "list", "options": {"os": "mac"}}"#.utf8)
        await #expect(throws: MosyleStub.StubFailure.self, "a query string") { _ = try await stub.send(query, limit: 1 << 20) }
        #expect(try await Self.status(stub, path: "/v1/devices", headers: auth, body: #"{"operation": "list", "options": {}}"#) == "MISSING_DATA")
        #expect(try await Self.status(stub, path: "/v1/devicegroups", headers: auth,
                                      body: #"{"operation": "list_devicegroup", "options": {"page": 1}}"#) == "MISSING_DATA")
        #expect(try await Self.status(stub, path: "/v1/devices", headers: auth, body: #"{"operation": "list", "options": {"os": ""}}"#) == "MISSING_DATA")
        #expect(try await Self.status(stub, path: "/v1/devicegroups", headers: auth,
                                      body: #"{"operation": "list_devicegroup", "options": {"os": "", "page": 1}}"#) == "MISSING_DATA")
        #expect(try await Self.status(stub, path: "/v1/devices", headers: auth,
                                      body: #"{"operation": "list", "options": {"os": "mac", "specific_columns": [1]}}"#) == "UNKNOWN_COLUMNS")
        #expect(stub.columnRefusals == 1)
        #expect(try await Self.status(stub, path: "/v1/devices", headers: auth,
                                      body: #"{"operation": "list", "options": {"os": "mac", "specific_columns": ["serial_number"]}}"#) == "DEVICES_NOTFOUND",
                "the control")
    }

    /// A device list with `specific_columns` answers those columns only, and one without answers every column: the
    /// client's own trimming is held elsewhere (`theDeviceColumnsAreTheAdapters`), the stub's here (round 3: a stub
    /// that answered every column whatever was asked survived).
    @Test func aDeviceListAnswersTheColumnsAsked() async throws {
        let stub = MosyleStub()
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw"))
        stub.add(devices: [["serial_number": .string("S1"), "device_name": .string("Mac"), "osversion": .string("27.0"),
                            "activation_bypass": .string("CODE")]], os: "mac")
        let jwt = try #require(try await Self.login(stub).1)
        func rows(_ options: String) async throws -> [JSONObject] {
            var request = URLRequest(url: URL(string: "https://businessapi.mosyle.com/v1/devices")!)
            request.httpMethod = "POST"
            request.setValue("access-token", forHTTPHeaderField: "accessToken")
            request.setValue(jwt, forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"operation": "list", "options": \#(options)}"#.utf8)
            let (data, _) = try await stub.send(request, limit: 1 << 20)
            return JSONValue.parse(String(decoding: data, as: UTF8.self))?["response"]?.array?.first?["devices"]?.array?.compactMap(\.object) ?? []
        }
        let asked = try await rows(#"{"os": "mac", "specific_columns": ["serial_number", "device_name"]}"#)
        #expect(asked.map { Set($0.keys) } == [["serial_number", "device_name"]])
        let every = try await rows(#"{"os": "mac"}"#)
        #expect(every.map { Set($0.keys) } == [["serial_number", "device_name", "osversion", "activation_bypass"]])
    }

    /// The Logs Stream's host takes only its own login, as the business host does, before it leaves the read itself
    /// to Phase 7b: a request it reaches carried the Logs token and a live Logs JWT.
    @Test func theLogsHostTakesOnlyItsOwnLogin() async throws {
        let now = Now()
        let stub = MosyleStub(now: { now.value })
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw", logsToken: "logs-token"))
        stub.jwtLifetime(3600)
        let logs = try #require(try await Self.login(stub, host: "businessapilogs.mosyle.com", token: "logs-token").1)
        let business = try #require(try await Self.login(stub).1)
        func read(_ headers: [String: String]) async throws -> Int {
            try await Self.post(stub, host: "businessapilogs.mosyle.com", path: "/v1/logsstream", headers: headers,
                                body: #"{"LogType": ["dns"], "page": 1}"#).0
        }
        await #expect(throws: MosyleStub.StubFailure.self, "the control: reached, and left to Phase 7b") {
            _ = try await read(["accessToken": "logs-token", "Authorization": logs])
        }
        #expect(try await read(["accessToken": "access-token", "Authorization": logs]) == 401, "the business token")
        #expect(try await read(["accessToken": "logs-token", "Authorization": business]) == 401, "the business JWT")
        #expect(try await read(["accessToken": "logs-token"]) == 401, "no JWT")
        #expect(try await read(["Authorization": logs]) == 401, "no token")
        now.advance(3601)
        #expect(try await read(["accessToken": "logs-token", "Authorization": logs]) == 401, "an expired JWT")
    }

    /// A column the stub's Mosyle lacks is refused, whoever asks.
    @Test func aColumnMosyleLacksIsRefused() async throws {
        let stub = MosyleStub()
        stub.register(.init(accessToken: "access-token", email: "admin@example.com", password: "pw"))
        let jwt = try #require(try await Self.login(stub).1)
        let (status, _) = try await Self.post(stub, path: "/v1/devices", headers: ["accessToken": "access-token", "Authorization": jwt],
                                              body: #"{"operation": "list", "options": {"os": "mac", "specific_columns": ["no_such_column"]}}"#)
        #expect(status == 200 && stub.columnRefusals == 1)
    }
}
