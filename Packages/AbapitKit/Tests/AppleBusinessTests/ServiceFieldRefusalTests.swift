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

    /// The harness's services, each with the attributes `Harness.service` gives (five of the ten requested).
    static func harness(refusing: Bool, services: Int = 2) async throws -> Harness {
        let harness = try await Harness()
        harness.stub.add(services: (0..<services).map { Harness.service("SVC\($0)", name: "Service \($0)") })
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
        // `Harness.service` sends five of the ten requested attributes: the others are said as absent.
        let absent = "lastConnectedIp, defaultProductFamilies, enableMdmDisownFlag, createdDateTime, updatedDateTime"
        #expect(pages.last?.note == Self.said + ". Absent from every service: \(absent).", "\(pages.last?.note ?? "nil")")
        #expect(await harness.client.servicesFieldRefusal?.detail == "A value isn't allowed in fields[mdmServers].")
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

    @Test func theAcceptancePassLineCarriesTheNoteAndAppleSaid() async throws {
        let harness = try await Self.harness(refusing: true)
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(line.status == .ok && line.count == 2)
        #expect(line.note?.hasPrefix(Self.said) == true, "\(line.note ?? "nil")")
        #expect(line.note?.hasSuffix(" · Apple said: A value isn't allowed in fields[mdmServers].") == true, "\(line.note ?? "nil")")
        // The services' own device lists are still read.
        #expect(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" }?.status == .ok, "\(report.text)")
    }

    /// Apple's `detail` is shown cut and without control characters: nothing in it can forge a line.
    @Test func appleSaidIsBoundedAndHasNoControlCharacters() async throws {
        let harness = try await Self.harness(refusing: false)
        let detail = "bad\u{7}\nvalue\u{2028}here " + String(repeating: "x", count: 500)
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: detail, parameter: "fields[mdmServers]"))
        let report = await harness.client.acceptancePass()
        let line = try #require(report.lines.first { $0.resource == "mdmServers" })
        let note = try #require(line.note)
        let said = try #require(note.components(separatedBy: " · Apple said: ").last)
        #expect(said == String(("badvaluehere " + String(repeating: "x", count: 500)).prefix(FieldListRefusal.longestDetail)), "\(said)")
        #expect(!report.text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        #expect(report.text.split(separator: "\n").count == report.lines.count, "a line was forged: \(report.text)")
    }
}
