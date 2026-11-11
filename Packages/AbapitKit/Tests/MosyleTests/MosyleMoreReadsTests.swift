import Foundation
import JSONAPI
@testable import Mosyle
import MosyleModels
import Testing
import TestSupport
import Wire

/// The three reads Phase 7 adds (plan §2.2, Appendix C): custom device attributes, a device group's members with the
/// compliance filter, and the admin log. Each request is the shape its source gives; each answer this app can't read is an
/// error, never an empty list; and a record no source shows is cut to the fields guessed at, the rest named, never shown.
@Suite("Mosyle: attributes, group members, admin logs")
struct MosyleMoreReadsTests {
    typealias Harness = MosyleClientTests.Harness

    static func dumps(_ items: [Resource]) -> String { JSONValue.dumps(.array(items.map { .object($0.attributes) })) }

    @Test func customAttributesAreAskedPerPlatformWithTheirOSBesideTheOperation() async throws {
        let harness = try await Harness()
        harness.stub.add(customAttributes: [["Name": .string("Cost centre"), "UniqueID": .string("CA1"), "Value": .string("Ops"),
                                             "token": .string("CANARY-SECRET")]], os: "ios")
        harness.stub.add(customAttributes: [["name": .string("Floor"), "id": .number("7"), "Source": .string("Manual")]], os: "mac")
        let records = try await harness.client.customAttributes()
        #expect(records.items.map(\.id) == ["ios/CA1", "mac/7"])
        #expect(records.items.map { $0.attributes["name"]?.string } == ["Cost centre", "Floor"])
        #expect(records.items.map { $0.attributes["os"]?.string } == ["ios", "mac"])
        #expect(!Self.dumps(records.items).contains("CANARY"))
        #expect(records.unread == ["token"])
        let asked = harness.stub.bodies.filter { $0["operation"]?.string == "list_custom_device_attributes" }
        #expect(asked.compactMap { $0["os"]?.string } == MosyleRead.platforms)
        #expect(asked.allSatisfy { $0["options"] == nil })
    }

    @Test func customAttributesOfAnotherShapeOrStatusAreAnError() async throws {
        let shaped = try await Harness()
        shaped.stub.queue(200, for: "/v1/devices", body: #"{"status":"OK","response":[{"definitions":[]}]}"#)
        await #expect(throws: MosyleAPIError.malformed("it has no custom_device_attributes or attributes or info list and no end-of-list status")) {
            try await shaped.client.customAttributes()
        }
        let ended = try await Harness()
        ended.stub.failEnvelope("ATTRIBUTES_NOTFOUND", for: "/v1/devices")
        await #expect(throws: MosyleAPIError.status(.unknown("ATTRIBUTES_NOTFOUND"), info: "stubbed")) {
            try await ended.client.customAttributes()
        }
        // An empty list is the platform's answer: none.
        let empty = try await Harness()
        #expect(try await empty.client.customAttributes().items.isEmpty)
    }

    @Test func aGroupsMembersAreAskedByItsIDAsAStringAndFilteredByCompliance() async throws {
        let harness = try await Harness()
        harness.stub.add(deviceGroups: [["iddevicegroup": .number("154"), "name": .string("Lab iPads"), "device_numbers": .number("3")]], os: "ios")
        harness.stub.add(members: [("UDID-1", true), ("UDID-2", false), ("UDID-3", true)], toGroup: "154")
        let id = try #require(try await harness.client.deviceGroups().items.first?.id)
        #expect(id == "154")
        #expect(try await harness.client.deviceGroupMembers(id) == MosyleGroupMembers(name: "Lab iPads", udids: ["UDID-1", "UDID-2", "UDID-3"]))
        #expect(try await harness.client.deviceGroupMembers(id, compliance: .compliant).udids == ["UDID-1", "UDID-3"])
        #expect(try await harness.client.deviceGroupMembers(id, compliance: .noncompliant).udids == ["UDID-2"])
        let asked = harness.stub.bodies.filter { $0["operation"]?.string == "get_info" }.compactMap { $0["options"]?.object }
        #expect(asked.map { $0["iddevicegroup"] } == Array(repeating: .string("154"), count: 3))
        #expect(asked.map { $0["security_compliance_status"]?.string } == [nil, "compliant", "noncompliant"])
    }

    @Test func aGroupMosyleDoesntHaveIsItsStatus() async throws {
        let harness = try await Harness()
        await #expect(throws: MosyleAPIError.status(.unknown("DEVICEGROUP_NOTFOUND"), info: "Device group not found")) {
            try await harness.client.deviceGroupMembers("999")
        }
    }

    /// Every shape the Postman collection's answer isn't: no group, a group without a list of UDIDs, a UDID that isn't a
    /// string, a status a write sends. Each is an error; none reads as a group with no members.
    @Test func aGroupAnswerOfAnotherShapeIsAnError() async throws {
        let cases: [(String, MosyleAPIError)] = [
            (#"{"status":"OK","response":{}}"#, .malformed("it has no devicegroup object")),
            (#"{"status":"OK","response":{"devicegroup":[]}}"#, .malformed("it has no devicegroup object")),
            (#"{"status":"OK","response":{"devicegroup":{"name":"G"}}}"#, .malformed("its devicegroup has no udids list")),
            (#"{"status":"OK","response":{"devicegroup":{"udids":null}}}"#, .malformed("its devicegroup has no udids list")),
            (#"{"status":"OK","response":{"devicegroup":{"udids":["U1",2]}}}"#, .malformed("a udid in its devicegroup isn't a string")),
            (#"{"status":"OK","response":{"status":"COMMAND_SENT","devicegroup":{"udids":[]}}}"#, .status(.known(.commandSent), info: nil)),
            (#"{"status":"OK"}"#, .malformed("it has no response (status OK)")),
        ]
        for (body, error) in cases {
            let harness = try await Harness()
            harness.stub.queue(200, for: "/v1/devicegroups", body: body)
            await #expect(throws: error, "\(body)") { try await harness.client.deviceGroupMembers("1") }
        }
        // An empty group is an answer: no members.
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/devicegroups", body: #"{"status":"OK","response":{"devicegroup":{"name":"G","udids":[]}}}"#)
        #expect(try await harness.client.deviceGroupMembers("1") == MosyleGroupMembers(name: "G", udids: []))
    }

    @Test func adminLogsAskTheLastDaysAsUTCDaysAndKeepOnlyTheFieldsRead() async throws {
        let harness = try await Harness()
        harness.stub.add(adminLogs: [
            ["date": .string("2026-11-10 09:00:00"), "user": .string("admin@example.com"), "action": .string("Updated profile"),
             "password": .string("CANARY-SECRET")],
            ["date": .string("2026-11-04 23:59:59"), "user": .string("it@example.com"), "action": .string("Too old")],
            ["date": .string("2026-11-05 00:00:00"), "email": .string("it@example.com"), "description": .string("Signed in"),
             "ip": .string("192.0.2.1")],
        ])
        let now = try #require(ISODate.parse("2026-11-11T08:00:00Z")?.date)
        let records = try await harness.client.adminLogs(days: 7, now: now)
        let options = try #require(harness.stub.bodies.last?["filter_options"]?.object)
        #expect(options["start_date"] == .string("2026-11-05") && options["end_date"] == .string("2026-11-11"))
        #expect(harness.stub.bodies.last?["operation"] == nil && harness.stub.bodies.last?["options"] == nil)
        #expect(records.items.map { $0.attributes["action"]?.string } == ["Updated profile", "Signed in"])
        #expect(records.items.map { $0.attributes["admin"]?.string } == ["admin@example.com", "it@example.com"])
        #expect(records.items.last?.attributes["ip"] == .string("192.0.2.1"))
        #expect(!Self.dumps(records.items).contains("CANARY"))
        #expect(records.unread == ["password"])
        #expect(records.total == 2)
    }

    @Test func adminLogsAreBoundedToAYear() async throws {
        let harness = try await Harness()
        let now = try #require(ISODate.parse("2026-11-11T08:00:00Z")?.date)
        _ = try await harness.client.adminLogs(days: 0, now: now)
        _ = try await harness.client.adminLogs(days: 10_000, now: now)
        let asked = harness.stub.bodies.compactMap { $0["filter_options"]?["start_date"]?.string }
        #expect(asked == ["2026-11-11", "2025-11-12"])
    }

    @Test func adminLogsOfAnotherShapeOrStatusAreAnError() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shaped = try await Harness()
        shaped.stub.queue(200, for: "/v1/adminlogs", body: #"{"status":"OK","response":[{"entries":[]}]}"#)
        await #expect(throws: MosyleAPIError.malformed("it has no logs or adminlogs or admin_logs list and no end-of-list status")) {
            try await shaped.client.adminLogs(days: 1, now: now)
        }
        let ended = try await Harness()
        ended.stub.failEnvelope("LOGS_NOTFOUND", for: "/v1/adminlogs")
        await #expect(throws: MosyleAPIError.status(.unknown("LOGS_NOTFOUND"), info: "stubbed")) {
            try await ended.client.adminLogs(days: 1, now: now)
        }
    }

    /// Each builder makes a request the session lets through as a read, as it will be sent.
    @Test func theNewBuildersAreReadsAsSent() {
        for request in [MosyleRead.customAttributes(os: "ios"), MosyleRead.deviceGroupInfo(id: "1"),
                        MosyleRead.deviceGroupInfo(id: "1", compliance: .noncompliant), MosyleRead.adminLogs(start: "2026-01-01", end: "2026-01-02")] {
            #expect(MosyleRead.isAllowed(request), "\(request.template)")
        }
        #expect(MosyleRead.isDay("2026-01-01") && !MosyleRead.isDay("2026-1-01") && !MosyleRead.isDay("2026-01-01T") && !MosyleRead.isDay("2026/01/01"))
    }
}

/// `Contracts/mosyle/operations.json` (plan §3.10, the add-api-operation skill): a row for every read on the allowlist, and
/// none for anything else, each part with a source that is one of the file's own.
@Suite("Mosyle contract")
struct MosyleContractTests {
    @Test func everyReadHasARowWithItsSources() throws {
        let data = try Data(contentsOf: Fixtures.contracts.appending(path: "mosyle/operations.json"))
        let contract = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        let known = Set(try #require(contract["sources"]?.object).keys)
        let rows = try #require(contract["operations"]?.array)
        #expect(Set(rows.compactMap { $0["read"]?.string }) == MosyleRead.allowed)
        #expect(rows.count == MosyleRead.allowed.count)
        for row in rows {
            for part in ["request_sources", "answer_sources"] {
                let sources = (row[part]?.array ?? []).compactMap(\.string).map { String($0.prefix { $0 != " " }) }
                #expect(!sources.isEmpty, "\(row["read"]?.string ?? "?") \(part)")
                #expect(sources.allSatisfy { known.contains($0) || $0 == "G" }, "\(row["read"]?.string ?? "?") \(part): \(sources)")
            }
        }
    }
}
