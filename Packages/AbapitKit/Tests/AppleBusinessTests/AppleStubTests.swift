import AppleBusiness
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport

/// The strict stub's own knowledge (invariant 5; failure-log 2026-10-16, "the mosyle stub agreed with the client"): its
/// parameter table is the contract's, written out, never the client's, and it refuses what the contract refuses.
@Suite("AppleStub against the contract", .serialized)
struct AppleStubTests {
    static func manifest(_ scope: Scope) throws -> [String: Any] {
        let url = Fixtures.contracts.appending(path: scope == .business ? "apple/business-2.6.json" : "apple/school-1.7.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Every GET's query parameters and allowed values, both scopes: School's are Business's where it has the endpoint.
    @Test(arguments: [Scope.business, .school])
    func theStubsParametersAreTheContracts(scope: Scope) throws {
        let gets = (try Self.manifest(scope)["endpoints"] as? [[String: Any]] ?? []).filter { $0["method"] as? String == "GET" }
        #expect(gets.count > 9)
        for endpoint in gets {
            let path = try #require(endpoint["path"] as? String)
            let table = try #require(AppleStub.parameters[path], "\(path) isn't in the stub's table")
            let query = (endpoint["parameters"] as? [[String: Any]] ?? []).filter { $0["in"] as? String == "query" }
            #expect(Set(table.keys) == Set(query.compactMap { $0["name"] as? String }), "\(path)")
            for parameter in query {
                let name = try #require(parameter["name"] as? String)
                #expect(table[name]??.sorted() == (parameter["allowedValues"] as? [String])?.sorted(), "\(path) \(name)")
                if name.hasPrefix("limit") { #expect(parameter["maximum"] as? String == "1000", "\(path) \(name)") }
            }
        }
        if scope == .business { #expect(Set(AppleStub.parameters.keys) == Set(gets.compactMap { $0["path"] as? String })) }
    }

    /// The endpoints that page are those whose answer has `PagedDocumentLinks`, by the contract's own objects.
    @Test func theStubPagesWhatTheContractPages() throws {
        let manifest = try Self.manifest(.business)
        let objects = try #require(manifest["objects"] as? [String: [String: Any]])
        var paged: Set<String> = []
        for endpoint in (manifest["endpoints"] as? [[String: Any]] ?? []) where endpoint["method"] as? String == "GET" {
            let ok = (endpoint["responses"] as? [[String: Any]] ?? []).first { $0["status"] as? Int == 200 }
            let name = try #require((ok?["type"] as? [String: Any])?["text"] as? String)
            let links = (objects[name]?["properties"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "links" }
            if (links?["type"] as? [String: Any])?["text"] as? String == "PagedDocumentLinks" { paged.insert(try #require(endpoint["path"] as? String)) }
        }
        #expect(paged.count > 10 && AppleStub.paged == paged, "\(paged.symmetricDifference(AppleStub.paged).sorted())")
        #expect(AppleStub.includeLimit < 1000)
    }

    /// The stub names nothing of the client's: no `AppleModels` import, no builder or client, no model's value list. Its
    /// include names, its audit types and its parameters are its own (Phase 7a's review H3, for the Mosyle stub).
    @Test func theAppleStubDoesNotAskTheClient() throws {
        let file = Fixtures.repoRoot.appending(path: "Packages/AbapitKit/Sources/TestSupport/AppleStub.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
        #expect(code.contains("public static let parameters: [String: [String: [String]?]] = ["))
        for name in ["import AppleModels", "AppleRead", "AppleClient", "AcceptancePass", "Blueprint.", "AuditEventType", "Relationship.allCases",
                     "ConfigurationType", "ResourceView", "KnownValues", ".fields"] {
            #expect(!code.contains(name), "AppleStub.swift names \(name)")
        }
    }

    /// A parameter an endpoint doesn't document, a value outside its list (an empty one too), a limit outside 1 to 1000
    /// and a cursor the stub never gave are each Apple's 400, naming the parameter; a documented `fields` value isn't.
    @Test func theStubRefusesWhatTheContractRefuses() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.add(try Harness.example("get-users"))
        let refusals: [(String, [(String, String)], String)] = [
            ("/v1/users", [("filter[status]", "ACTIVE")], "filter[status]"), ("/v1/users", [("limit", "0")], "limit"),
            ("/v1/users", [("limit", "1001")], "limit"), ("/v1/users", [("limit", "ten")], "limit"),
            ("/v1/users", [("fields[users]", "firstName,ssn")], "fields[users]"), ("/v1/users", [("fields[users]", "")], "fields[users]"),
            ("/v1/users/1234567890", [("limit", "1")], "limit"), ("/v1/users", [("cursor", "-1")], "cursor"), ("/v1/users", [("cursor", "01")], "cursor"),
            ("/v1/orgDevices/TESTD0000000/relationships/assignedServer", [("limit", "1")], "limit"),
            ("/v1/orgDevices/TESTD0000000/assignedServer", [("fields[mdmServers]", "deviceCount")], "fields[mdmServers]"),
            ("/v1/mdmDevices/MD1/details", [("fields[mdmDevices]", "serialNumber")], "fields[mdmDevices]"),
        ]
        for (path, query, parameter) in refusals {
            let answer = try await harness.raw(path, query)
            #expect(answer.status == 400 && answer.body?["errors"]?.array?.first?["source"]?["parameter"]?.string == parameter, "\(path) \(query)")
        }
        #expect(try await harness.raw("/v1/users", [("fields[users]", "firstName,phoneNumbers"), ("limit", "1000")]).status == 200)
        #expect(try await harness.raw("/v1/users", [("cursor", "1")]).status == 200)
        // An endpoint Apple doesn't document isn't served at all: abapit's `mdmDevices/{id}`, a School read of users.
        await #expect(throws: AppleStub.StubFailure.self) { _ = try await harness.raw("/v1/mdmDevices/MD1") }
        await #expect(throws: AppleStub.StubFailure.self) { _ = try await harness.raw("/v1/users/1234567890/relationships/userGroups") }
        let school = try await Harness(scope: .school)
        await #expect(throws: AppleStub.StubFailure.self) { _ = try await school.raw("/v1/users", host: .appleSchool) }
    }

    /// The stub's cursors really page, at the size asked, and its `total` is the list's when asked for.
    @Test func theStubsCursorsPage() async throws {
        let harness = try await Harness()
        harness.stub.add((0..<5).map { Resource(type: "apps", id: "A\($0)", attributes: ["name": .string("App \($0)")]) })
        harness.stub.reportTotals()
        let first = try await harness.raw("/v1/apps", [("limit", "2")])
        #expect(first.body?["data"]?.array?.compactMap { $0["id"]?.string } == ["A0", "A1"])
        #expect(first.body?["meta"]?["paging"]?["nextCursor"]?.string == "2" && first.body?["meta"]?["paging"]?["total"]?.int == 5)
        #expect(first.body?["links"]?["next"]?.string == "https://api-business.apple.com/v1/apps?cursor=2")
        let last = try await harness.raw("/v1/apps", [("limit", "2"), ("cursor", "4")])
        #expect(last.body?["data"]?.array?.compactMap { $0["id"]?.string } == ["A4"] && last.body?["links"]?["next"] == nil)
    }
}
