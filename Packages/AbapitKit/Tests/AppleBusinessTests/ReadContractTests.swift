import AppleBusiness
import AppleModels
import Foundation
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
                    let given = item.value.split(separator: ",").map(String.init)
                    #expect(Set(given).isSubset(of: allowed), "\(read.template): \(item.name) has \(Set(given).subtracting(allowed).sorted())")
                }
                if let maximum = (documented?["maximum"] as? String).flatMap(Int.init), let value = Int(item.value) {
                    #expect(value <= maximum, "\(read.template): \(item.name) \(value) over \(maximum)")
                }
            }
        }
    }

    @Test func everyReadGoesToItsScopesHost() {
        #expect(Self.reads(.business).allSatisfy { $0.host == .appleBusiness })
        #expect(Self.reads(.school).allSatisfy { $0.host == .appleSchool })
    }
}
