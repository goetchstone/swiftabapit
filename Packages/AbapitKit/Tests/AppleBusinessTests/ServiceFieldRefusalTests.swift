import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// Apple's live server refused the services' field list (`fields[mdmServers]`, 400 `PARAMETER_ERROR.INVALID`) on 2026-11-19
/// although the contract allows every value sent (failure-log 2026-11-19). The client asks again without `fields`, once,
/// remembers the refusal, and says so (invariants 5 and 8). `AppleStub.refuseServiceFields()` is the switch.
@Suite("Services read with Apple's default fields", .serialized)
struct ServiceFieldRefusalTests {
    static let said = "Apple refused the field list (fields[mdmServers]), so the services were read with Apple's default fields"

    /// A service as Apple's own example of the list has it (`Tests/Fixtures/docc/business/get-mdm-servers.response.json`):
    /// four attributes, no status, no `lastConnectedDateTime`, no device count.
    static func example(_ id: String, name: String) -> Resource {
        Resource(type: "mdmServers", id: id, attributes: ["serverName": .string(name), "serverType": .string("MDM"),
                                                          "createdDateTime": .string("2025-05-01T03:21:44.685Z"),
                                                          "updatedDateTime": .string("2025-05-01T03:21:46.284Z")])
    }

    /// The harness's services, with the stub holding the full attributes of `Harness.service`, which the stub answers
    /// without `fields` as the example has them (four) when `refusing`.
    static func harness(refusing: Bool, services: Int = 2) async throws -> Harness {
        let harness = try await Harness()
        harness.stub.add(services: (0..<services).map { index in
            // What the stub holds is the full read's: the example's four, and the attributes it lacks.
            var full = Self.example("SVC\(index)", name: "Service \(index)").attributes
            full["status"] = .string("ACTIVE")
            full["deviceCount"] = .number("2")
            full["lastConnectedDateTime"] = .string("2026-10-01T00:00:00Z")
            return Resource(type: "mdmServers", id: "SVC\(index)", attributes: full)
        })
        if refusing { harness.stub.refuseServiceFields() }
        return harness
    }

    static func listRequests(_ harness: Harness) -> [String] {
        harness.stub.requests.filter { $0.contains("/v1/mdmServers") && !$0.contains("/relationships/") }
    }

    static func read(_ client: AppleClient) async throws -> [Page<MDMService>] {
        var pages: [Page<MDMService>] = []
        for try await page in client.services() { pages.append(page) }
        return pages
    }

    @Test func aRefusedFieldListIsReadAgainWithoutFieldsAndSaid() async throws {
        let harness = try await Self.harness(refusing: true)
        let pages = try await Self.read(harness.client)
        #expect(pages.flatMap(\.items).map(\.id) == ["SVC0", "SVC1"])
        let requests = Self.listRequests(harness)
        #expect(requests.count == 2, "\(requests)")
        #expect(requests[0].contains("fields") && requests[0].contains("limit=1000"), "\(requests)")
        #expect(!requests[1].contains("fields") && requests[1].contains("limit=1000"), "\(requests)")
        // The stub answers without `fields` with the example's four attributes: the others are said as absent, as data too.
        let absent = "status, deviceCount, lastConnectedDateTime, lastConnectedIp, defaultProductFamilies, enableMdmDisownFlag"
        #expect(pages.last?.note == Self.said + ". Absent from every service: \(absent).", "\(pages.last?.note ?? "nil")")
        #expect(pages.last?.absent == Set(absent.components(separatedBy: ", ")))
        #expect(pages.flatMap(\.items).allSatisfy { Set($0.attributes.keys) == ["serverName", "serverType", "createdDateTime", "updatedDateTime"] })
        // Apple's `detail` ("A value isn't allowed in fields[mdmServers].") names none of the ten fields.
        #expect(await harness.client.servicesFieldRefusal?.named == [])
    }

    @Test func theRefusalIsRememberedForLaterReads() async throws {
        let harness = try await Self.harness(refusing: true)
        _ = try await Self.read(harness.client)
        let second = try await Self.read(harness.client)
        let requests = Self.listRequests(harness)
        #expect(requests.count == 3, "\(requests)")
        #expect(!requests[2].contains("fields"), "the second read asked again with fields: \(requests)")
        #expect(second.last?.note?.hasPrefix(Self.said) == true, "\(second.last?.note ?? "nil")")
        #expect(second.flatMap(\.items).count == 2)
    }

    /// Later pages go on without `fields` too, and the refusal doesn't repeat per page.
    @Test func pagingGoesOnWithoutFields() async throws {
        let harness = try await Self.harness(refusing: true, services: AppleRead.pageLimit + 1)
        let pages = try await Self.read(harness.client)
        #expect(pages.map(\.items.count) == [AppleRead.pageLimit, 1])
        let requests = Self.listRequests(harness)
        #expect(requests.count == 3, "\(requests)")
        #expect(requests.dropFirst().allSatisfy { !$0.contains("fields") }, "\(requests)")
        #expect(pages.allSatisfy { $0.note?.hasPrefix(Self.said) == true })
        // Page 2 of the fallback read is the example's four attributes too.
        #expect(Set(pages[1].items[0].attributes.keys) == ["serverName", "serverType", "createdDateTime", "updatedDateTime"])
        #expect(pages[1].absent.contains("status") && pages[1].absent.contains("lastConnectedDateTime"))
    }

    /// Apple's next link keeps the request's parameters (get-org-devices.response.2.json): page 2 of a normal read still asks for
    /// `fields[mdmServers]`, with one `limit`, and its services have every attribute the stub holds.
    @Test func pageTwoOfANormalReadKeepsTheFieldsAndTheirAttributes() async throws {
        let harness = try await Self.harness(refusing: false, services: AppleRead.pageLimit + 1)
        let pages = try await Self.read(harness.client)
        #expect(pages.map(\.items.count) == [AppleRead.pageLimit, 1])
        let requests = Self.listRequests(harness)
        #expect(requests.count == 2, "\(requests)")
        #expect(requests[1].contains("cursor=") && requests[1].contains("fields"), "\(requests)")
        #expect(requests[1].components(separatedBy: "limit=").count == 2, "exactly one limit: \(requests[1])")
        #expect(pages[1].items[0].attributes.keys.contains("status") && pages[1].items[0].attributes.keys.contains("lastConnectedDateTime"))
        #expect(pages.allSatisfy { $0.note == nil && $0.absent.isEmpty })
    }

    @Test func withTheSwitchOffNothingChanges() async throws {
        let harness = try await Self.harness(refusing: false)
        let pages = try await Self.read(harness.client)
        let requests = Self.listRequests(harness)
        #expect(requests.count == 1 && requests[0].contains("fields"), "\(requests)")
        #expect(pages.allSatisfy { $0.note == nil })
        #expect(await harness.client.servicesFieldRefusal == nil)
    }

    /// Only a 400 `PARAMETER_ERROR.INVALID` about `fields[mdmServers]` is retried; any other answer stays an error, with
    /// one request sent.
    @Test(arguments: [
        (400, "PARAMETER_ERROR.INVALID", "limit"), (400, "PARAMETER_ERROR.INVALID", "fields[orgDevices]"),
        (400, "PARAMETER_ERROR.REQUIRED", "fields[mdmServers]"), (400, "PARAMETER_ERROR.INVALID", ""),
        (403, "PARAMETER_ERROR.INVALID", "fields[mdmServers]"), (422, "PARAMETER_ERROR.INVALID", "fields[mdmServers]"),
    ])
    func anyOtherRefusalStaysAnError(status: Int, code: String, parameter: String) async throws {
        let harness = try await Self.harness(refusing: false)
        harness.stub.queue(status, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(status, code: code, detail: "x", parameter: parameter.isEmpty ? nil : parameter))
        await #expect(throws: AppleAPIError.self) { _ = try await Self.read(harness.client) }
        #expect(Self.listRequests(harness).count == 1, "\(Self.listRequests(harness))")
        #expect(await harness.client.servicesFieldRefusal == nil)
    }

    /// A second refusal, of the read without `fields`, is thrown: never more than one retry.
    @Test func aRefusalOfTheSecondReadIsAnError() async throws {
        let harness = try await Self.harness(refusing: true)
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "x", parameter: "fields[mdmServers]"))
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "x", parameter: "fields[mdmServers]"))
        await #expect(throws: AppleAPIError.self) { _ = try await Self.read(harness.client) }
        #expect(Self.listRequests(harness).count == 2, "\(Self.listRequests(harness))")
    }

    @Test func theAcceptancePassLineCarriesTheNoteAndWhatApplesReasonNamed() async throws {
        let harness = try await Self.harness(refusing: true)
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(line.status == .ok && line.count == 2)
        #expect(line.note?.hasPrefix(Self.said) == true, "\(line.note ?? "nil")")
        #expect(line.note?.hasSuffix(" · Apple's reason mentions none of the fields asked for") == true, "\(line.note ?? "nil")")
        // The services' own device lists are still read.
        #expect(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" }?.status == .ok, "\(report.text)")
    }

    /// Apple's `detail` never reaches the pass's text: only which of the ten fields it names, however it is worded. An email,
    /// a serial-like string and an org name in it are dropped.
    @Test func appleDetailNeverReachesThePassOnlyTheFieldsItNames() async throws {
        let harness = try await Self.harness(refusing: false)
        let detail = "jane.doe@example.com asked for TESTD0000000 of Acme Org: lastConnectedIp and deviceCount aren't allowed\n\u{7}"
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: detail, parameter: "fields[mdmServers]"))
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(line.note?.hasSuffix(" · Apple's reason mentions: deviceCount, lastConnectedIp") == true, "\(line.note ?? "nil")")
        for word in ["jane", "example.com", "TESTD", "Acme", "aren't allowed"] { #expect(!report.text.contains(word), "\(word) in \(report.text)") }
        #expect(report.text.split(separator: "\n").count == report.lines.count, "a line was forged: \(report.text)")
    }

    /// A refusal followed by a retry that fails before any page: the line is the failure, and says what is true: Apple
    /// refused the list and the read without it then failed. It doesn't say the services were read.
    @Test func aRetryThatFailsKeepsTheRefusalOnTheLine() async throws {
        let harness = try await Self.harness(refusing: false)
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "status", parameter: "fields[mdmServers]"))
        for _ in 0..<6 { harness.stub.queue(500, for: "/v1/mdmServers") }
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(line.status == .error("error 500"), "\(report.text)")
        #expect(line.note == "Apple refused the field list (fields[mdmServers]); the read without it then failed · Apple's reason mentions: status", "\(line.note ?? "nil")")
    }

    /// A walk that fails after pages were read says what is absent from the services read, not from every service.
    @Test func aWalkThatFailsLaterSaysWhatTheServicesReadLack() async throws {
        let harness = try await Self.harness(refusing: true, services: AppleRead.pageLimit + 1)
        for _ in 0..<6 { harness.stub.queue(500, for: "/v1/mdmServers?cursor=") }
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(line.status == .error("error 500") && line.count == AppleRead.pageLimit, "\(report.text)")
        let note = try #require(line.note)
        #expect(note.contains("Absent from the \(AppleRead.pageLimit) services read: status,") && !note.contains("every service"), "\(note)")
        #expect(note.hasSuffix(" · Apple's reason mentions none of the fields asked for"), "\(note)")
    }

    /// Which fields Apple's reason names: whole identifiers, whatever the case; none, all, or no reason said so.
    @Test(arguments: [
        ("Check the statuses of your request", " · Apple's reason mentions none of the fields asked for"),
        ("xstatus and statuses and deviceCounts", " · Apple's reason mentions none of the fields asked for"),
        ("Check the status of your request", " · Apple's reason mentions: status"),
        ("serverName isn't allowed", " · Apple's reason mentions: serverName"),
        ("SERVERNAME, Status; (lastConnectedIp)", " · Apple's reason mentions: serverName, status, lastConnectedIp"),
        ("serverName,serverType,status,deviceCount,lastConnectedDateTime,lastConnectedIp,defaultProductFamilies,enableMdmDisownFlag,createdDateTime,updatedDateTime",
         " · Apple's reason mentions every field asked for"),
        ("", " · Apple gave no reason"),
        ("  \n", " · Apple gave no reason"),
    ])
    func appleNamedIsWholeFieldNames(detail: String, said: String) async throws {
        let harness = try await Self.harness(refusing: false)
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: detail, parameter: "fields[mdmServers]"))
        let line = try #require(await harness.client.acceptancePass().lines.first { $0.resource == "mdmServers" })
        #expect(line.note?.hasSuffix(said) == true, "\(line.note ?? "nil")")
    }

    /// No `detail` at all is no reason, too.
    @Test func aRefusalWithoutADetailGaveNoReason() async throws {
        let harness = try await Self.harness(refusing: false)
        harness.stub.queue(400, for: "/v1/mdmServers", body: #"{"errors":[{"status":"400","code":"PARAMETER_ERROR.INVALID","source":{"parameter":"fields[mdmServers]"}}]}"#)
        let line = try #require(await harness.client.acceptancePass().lines.first { $0.resource == "mdmServers" })
        #expect(line.note?.hasSuffix(" · Apple gave no reason") == true, "\(line.note ?? "nil")")
    }

    /// The stub answers a read without `fields[mdmServers]` as Apple's example does, whether or not the switch is on.
    @Test func aReadWithoutFieldsAnswersTheExamplesFourAttributes() async throws {
        let harness = try await Self.harness(refusing: false)
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "x", parameter: "fields[mdmServers]"))
        let pages = try await Self.read(harness.client)
        #expect(pages.flatMap(\.items).allSatisfy { Set($0.attributes.keys) == ["serverName", "serverType", "createdDateTime", "updatedDateTime"] })
        #expect(pages.last?.absent.contains("status") == true)
    }

    /// A refusal on a later page isn't the field list refused on the first read: the walk has yielded, so it is an error, not a
    /// second read of the first page (a retry would repeat page 1 for a screen to append twice).
    @Test func aRefusalOnALaterPageIsAnErrorNotARestart() async throws {
        let harness = try await Self.harness(refusing: false, services: AppleRead.pageLimit + 1)
        harness.stub.queue(400, for: "/v1/mdmServers?cursor=", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "x", parameter: "fields[mdmServers]"))
        var yielded = 0
        do {
            for try await page in harness.client.services() { yielded += page.items.count }
            Issue.record("the read ended without an error")
        } catch let error as AppleAPIError {
            guard case .badRequest(_, "fields[mdmServers]", _) = error else { Issue.record("\(error)"); return }
        }
        #expect(yielded == AppleRead.pageLimit, "page 1 was yielded \(yielded) services' worth")
        #expect(Self.listRequests(harness).count == 2, "\(Self.listRequests(harness))")
        #expect(await harness.client.servicesFieldRefusal == nil)
    }
}
