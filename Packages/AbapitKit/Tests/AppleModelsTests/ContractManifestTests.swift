import Foundation
import Testing
import TestSupport

/// The contract manifests generated from Apple's DocC JSON (plan §3.10) are present, complete and
/// well formed. Phases 1–2 add the per-model checks: every model decodes every example, every enum's
/// known cases equal Apple's `allowedValues`, every endpoint the client calls is listed here.
@Suite("Apple contract manifests")
struct ContractManifestTests {
    static func manifest(_ name: String) throws -> [String: Any] {
        let url = Fixtures.contracts.appending(path: "apple/\(name).json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func endpoints(_ manifest: [String: Any]) throws -> [[String: Any]] {
        try #require(manifest["endpoints"] as? [[String: Any]])
    }

    /// Apple Business API 2.6 has 57 endpoints and Apple School Manager API 1.7 has 11 (plan §8, Phase 0).
    /// A version bump renames the file; the drift job says so first.
    @Test(arguments: [("business-2.6", "2.6", 57), ("school-1.7", "1.7", 11)])
    func theManifestHasEveryEndpoint(name: String, version: String, count: Int) throws {
        let manifest = try Self.manifest(name)
        #expect(manifest["version"] as? String == version)
        let endpoints = try Self.endpoints(manifest)
        #expect(endpoints.count == count)
        for endpoint in endpoints {
            let method = endpoint["method"] as? String ?? "", path = endpoint["path"] as? String ?? ""
            #expect(["GET", "POST", "PATCH", "DELETE"].contains(method), "\(method) \(path)")
            #expect(path.hasPrefix("/v1/"), "\(method) \(path)")
            let statuses = (endpoint["responses"] as? [[String: Any]] ?? []).compactMap { $0["status"] as? Int }
            #expect(statuses.contains { (200..<300).contains($0) }, "\(method) \(path) lists no success status")
            #expect(statuses.contains(429), "\(method) \(path): Apple documents 429 on every call")
        }
    }

    /// School is a strict subset of Business's paths, with no people or content endpoints (plan §2.4).
    @Test func schoolIsASubsetOfBusiness() throws {
        func paths(_ name: String) throws -> Set<String> {
            Set(try Self.endpoints(Self.manifest(name)).map { "\($0["method"] ?? "") \($0["path"] ?? "")" })
        }
        let school = try paths("school-1.7"), business = try paths("business-2.6")
        #expect(school.isSubset(of: business), "\(school.subtracting(business))")
        #expect(!school.contains { $0.contains("/users") || $0.contains("/blueprints") || $0.contains("/auditEvents") })
    }

    /// Every activity type the plan builds is one Apple lists (plan Appendix A).
    @Test func theActivityTypesAreApples() throws {
        let enums = try #require(try Self.manifest("business-2.6")["enums"] as? [String: Any])
        let activity = try #require(enums["OrgDeviceActivityType"] as? [String: Any])
        #expect(activity["values"] as? [String] == ["ASSIGN_DEVICES", "UNASSIGN_DEVICES", "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE",
                                                    "UPDATE_MDM_MIGRATION_DEADLINE", "CANCEL_MDM_MIGRATION", "RELEASE_DEVICES"])
    }

    /// A page with several examples keeps them all: the activity page has one request body per activity type,
    /// the shapes Phases 4 and 6 build (Phase 0's review: the crawler kept only the last).
    @Test func everyActivityTypeHasItsExampleRequest() throws {
        let folder = Fixtures.docc.appending(path: "business")
        var types: Set<String> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
        where name.hasPrefix("create-an-orgdeviceactivity.request") {
            let body = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: name))) as? [String: Any])
            let attributes = ((body["data"] as? [String: Any])?["attributes"] as? [String: Any]) ?? [:]
            if let type = attributes["activityType"] as? String { types.insert(type) }
        }
        #expect(types == ["ASSIGN_DEVICES", "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE", "UPDATE_MDM_MIGRATION_DEADLINE",
                          "CANCEL_MDM_MIGRATION", "RELEASE_DEVICES"])
    }

    /// Every example Apple wrote parses as JSON: the decode tests of Phases 1–2 read these files.
    @Test func everyDocCExampleIsJSON() throws {
        var count = 0
        for scope in ["business", "school"] {
            let folder = Fixtures.docc.appending(path: scope)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".json") {
                _ = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: name)))
                count += 1
            }
        }
        #expect(count >= 60)
    }
}
