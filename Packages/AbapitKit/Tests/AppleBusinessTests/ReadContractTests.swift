import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport
import Wire

/// Every read the client sends is an endpoint Apple documents, with parameters it documents and `fields`
/// values it allows (plan §3.10). School reads are checked against School's manifest.
@Suite("Apple reads against the contract")
struct ReadContractTests {
    static func endpoints(_ scope: Scope) -> [[String: Any]] {
        let url = Fixtures.contracts.appending(path: scope == .business ? "apple/business-2.6.json" : "apple/school-1.7.json")
        let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
        return manifest["endpoints"] as? [[String: Any]] ?? []
    }

    static func reads(_ scope: Scope) -> [ReadRequest] {
        var reads: [ReadRequest?] = [
            AppleRead.devices(scope), AppleRead.device(scope, serial: "C02X"), AppleRead.appleCare(scope, serial: "C02X"),
            AppleRead.activationLock(scope, serial: "C02X"), AppleRead.assignedService(scope, serial: "C02X"),
            AppleRead.assignedServiceID(scope, serial: "C02X"), AppleRead.services(scope), AppleRead.service(scope, id: "S1"),
            AppleRead.serviceDevices(scope, id: "S1"),
        ]
        for section in AppleSection.allCases where scope == .business || !section.businessOnly {
            reads.append(AppleRead.probe(scope, section: AppleSectionPath(path: section.path), now: Date()))
        }
        if scope == .business { reads += businessOnly }
        return reads.compactMap { $0 }
    }

    /// Every Business-only read, each filter and include used.
    static var businessOnly: [ReadRequest] {
        let query = try? AuditQuery(start: Date(timeIntervalSince1970: 1_792_000_000), end: Date(timeIntervalSince1970: 1_792_086_400),
                                    types: AuditEventType.allCases.map(OpenEnum.init), actorID: "BUSINESSAPI.a1", subjectID: "C02X")
        let reads: [ReadRequest?] = [
            AppleRead.users(), AppleRead.user(id: "U1"), AppleRead.userGroups(), AppleRead.userGroup(id: "G1"), AppleRead.userGroupMembers(id: "G1"),
            AppleRead.organizationalUnits(), AppleRead.organizationalUnit(id: "O1"), AppleRead.organizationalUnitMembers(id: "O1"),
            AppleRead.apps(), AppleRead.app(id: "361309726"), AppleRead.packages(), AppleRead.package(id: "P1"), AppleRead.blueprints(),
            AppleRead.blueprint(id: "B1"), AppleRead.blueprint(id: "B1", include: Set(Blueprint.Relationship.allCases)),
            AppleRead.configurations(), AppleRead.configuration(id: "C1"), AppleRead.mdmDevices(), AppleRead.mdmDeviceDetails(id: "D1"),
            query.map(AppleRead.auditEvents), try? AppleRead.auditEvents(.last(days: 1)),
        ] + Blueprint.Relationship.allCases.map { AppleRead.blueprintMembers(id: "B1", $0) }
        return reads.compactMap { $0 }
    }

    @Test(arguments: [Scope.business, .school])
    func everyReadIsADocumentedEndpointWithDocumentedParameters(scope: Scope) {
        let endpoints = Self.endpoints(scope)
        #expect(!endpoints.isEmpty)
        for read in Self.reads(scope) {
            let endpoint = endpoints.first { ($0["method"] as? String) == read.method.rawValue && ($0["path"] as? String) == read.template }
            #expect(endpoint != nil, "\(read.method.rawValue) \(read.template) isn't in the \(scope) contract")
            guard let endpoint else { continue }
            let parameters = (endpoint["parameters"] as? [[String: Any]] ?? []).filter { $0["in"] as? String == "query" }
            for item in read.query {
                let documented = parameters.first { $0["name"] as? String == item.name }
                #expect(documented != nil, "\(read.template): \(item.name) isn't a documented parameter")
                if let allowed = documented?["allowedValues"] as? [String] {
                    let given = item.value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    #expect(Set(given).isSubset(of: allowed), "\(read.template): \(item.name) has \(Set(given).subtracting(allowed).sorted())")
                }
                if let maximum = (documented?["maximum"] as? String).flatMap(Int.init) {
                    let value = Int(item.value)
                    #expect(value.map { (1...maximum).contains($0) } == true, "\(read.template): \(item.name) \(item.value) not 1 to \(maximum)")
                }
            }
            // A required parameter is always sent (the audit range).
            for required in parameters where required["required"] as? Bool == true {
                #expect(read.query.contains { $0.name == required["name"] as? String }, "\(read.template) misses \(required["name"] ?? "")")
            }
            // Each id went into the path where the template has `{id}`, and nowhere else.
            let parts = read.template.split(separator: "/"), sent = read.path.split(separator: "/")
            #expect(parts.count == sent.count && zip(parts, sent).allSatisfy { $0 == "{id}" || $0 == $1 }, "\(read.path) for \(read.template)")
        }
    }

    @Test func everyReadGoesToItsScopesHost() {
        #expect(Self.reads(.business).allSatisfy { $0.host == .appleBusiness })
        #expect(Self.reads(.school).allSatisfy { $0.host == .appleSchool })
        #expect(Self.businessOnly.allSatisfy { $0.host == .appleBusiness })
    }

    /// The Business-only reads are exactly the GETs School's contract lacks, so the client's gate is Apple's: none of them
    /// is in School's manifest, and every GET School has (but Phase 4's activity status) is one a School org sends.
    @Test func theBusinessOnlyReadsAreWhatSchoolLacks() {
        func gets(_ scope: Scope) -> Set<String> {
            Set(Self.endpoints(scope).filter { $0["method"] as? String == "GET" }.compactMap { $0["path"] as? String })
        }
        let school = gets(.school), business = gets(.business)
        for read in Self.businessOnly { #expect(!school.contains(read.template), "\(read.template) is in School's contract") }
        #expect(Set(Self.businessOnly.map(\.template)) == business.subtracting(school))
        #expect(Set(Self.reads(.school).map(\.template)) == school.subtracting(["/v1/orgDeviceActivities/{id}"]))
    }

    /// Every GET Apple documents has a read here, but the activity status (Phase 4's).
    @Test func everyDocumentedReadHasABuilder() {
        let documented = Set(Self.endpoints(.business).filter { $0["method"] as? String == "GET" }.compactMap { $0["path"] as? String })
        #expect(Set(Self.reads(.business).map(\.template)) == documented.subtracting(["/v1/orgDeviceActivities/{id}"]))
    }

    /// The include names come from the closed enum, in its order, each with Apple's maximum `limit[<name>]`; none asked,
    /// none sent.
    @Test func aBlueprintIncludesOnlyApplesRelationshipsAtTheirMaximum() throws {
        let read = try #require(AppleRead.blueprint(id: "B1", include: [.users, .apps]))
        #expect(read.query == [QueryItem("include", "apps,users"), QueryItem("limit[apps]", "1000"), QueryItem("limit[users]", "1000")])
        #expect(AppleRead.blueprint(id: "B1")?.query == [])
        #expect(Blueprint.Relationship.allCases.map(\.rawValue) == ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"])
    }

    /// Every id goes through `isPathSafe`: one that would steer the path builds nothing.
    @Test(arguments: ["../users", "A/B", "", ".hidden", "U1?limit=1", "x y", "U1#x", "U%2F1", "\u{212A}1", String(repeating: "A", count: 129)])
    func noBuilderTakesAnIDThatWouldSteerThePath(id: String) {
        let built: [ReadRequest?] = [
            AppleRead.user(id: id), AppleRead.userGroup(id: id), AppleRead.userGroupMembers(id: id), AppleRead.organizationalUnit(id: id),
            AppleRead.organizationalUnitMembers(id: id), AppleRead.app(id: id), AppleRead.package(id: id), AppleRead.blueprint(id: id),
            AppleRead.blueprint(id: id, include: [.apps]), AppleRead.configuration(id: id), AppleRead.mdmDeviceDetails(id: id),
        ] + Blueprint.Relationship.allCases.map { AppleRead.blueprintMembers(id: id, $0) }
        #expect(built.allSatisfy { $0 == nil }, "\(id.debugDescription)")
    }
}
