import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// A blueprint and its members (plan §8, Phase 2): `include` and `limit[<name>]`, abapit's fallback when Apple refuses an
/// include, said and never silent (invariant 8), and the six relationship lists, each of its own type.
@Suite("Blueprints", .serialized)
struct BlueprintTests {
    static let all = Set(Blueprint.Relationship.allCases)

    /// A blueprint `BP1` with members in every relationship, each member a resource the stub holds.
    static func harness() async throws -> Harness {
        let harness = try await Harness(devices: 2)
        harness.stub.add(try Harness.example("get-users") + Harness.example("get-user-groups") + Harness.example("get-apps")
                         + Harness.example("get-packages") + Harness.example("get-configuration-information"))
        harness.stub.add([Resource(type: "blueprints", id: "BP1", attributes: ["name": .string("Marketing"), "status": .string("ACTIVE"),
                                                                               "appLicenseDeficient": .bool(false)])])
        let members = ["apps": ["361309726"], "packages": ["pkg-12345"], "configurations": ["config-12345"],
                       "orgDevices": ["TESTD0000000", "TESTD0000001"], "users": ["1234567890"], "userGroups": ["UG123456"]]
        for (relationship, ids) in members { harness.stub.relate("blueprints", "BP1", relationship, to: ids) }
        return harness
    }

    /// With everything included, each relationship lists its members and their resources come along; nothing was cut,
    /// nothing refused, and each relationship was asked for at Apple's maximum.
    @Test func aBlueprintWithEverythingIncludedListsItsMembers() async throws {
        let harness = try await Self.harness()
        let read = try await harness.client.blueprint("BP1", include: Self.all)
        #expect(read.blueprint.name == "Marketing" && read.includeRefused == nil)
        #expect(read.related[.orgDevices]?.linkages.map(\.id) == ["TESTD0000000", "TESTD0000001"])
        #expect(read.related[.apps] == Blueprint.Related(linkages: [Linkage(type: "apps", id: "361309726")], isTruncated: false))
        #expect(Set(read.related.keys) == Self.all && read.related.values.allSatisfy { !$0.isTruncated })
        #expect(Set(read.included.map(\.type)) == ["apps", "packages", "configurations", "orgDevices", "users", "userGroups"] && read.included.count == 7)
        let sent = try #require(harness.reads.last)
        #expect(sent.contains("include=apps%2Cpackages%2Cconfigurations%2CorgDevices%2Cusers%2CuserGroups"), "\(sent)")
        for name in Blueprint.Relationship.allCases { #expect(sent.contains("limit%5B\(name.rawValue)%5D=1000"), "\(name)") }
        // Without an include, links only: nothing is said of the members.
        let bare = try await harness.client.blueprint("BP1")
        #expect(bare.related.isEmpty && bare.included.isEmpty && bare.includeRefused == nil)
        #expect(try bare.blueprint.related(.apps) == nil)
    }

    /// A relationship the include's limit cut says so ("showing N of ≥M"), by Apple's next cursor or its total.
    @Test func aRelationshipTheLimitCutIsTruncated() async throws {
        let harness = try await Self.harness()
        harness.stub.relate("blueprints", "BP1", "orgDevices", to: (0..<1_001).map { String(format: "TESTD%07d", $0) })
        let read = try await harness.client.blueprint("BP1", include: [.orgDevices, .apps])
        #expect(read.related[.orgDevices]?.linkages.count == 1_000 && read.related[.orgDevices]?.isTruncated == true)
        #expect(read.related[.apps]?.isTruncated == false)
        #expect(Set(read.related.keys) == [.orgDevices, .apps], "only what was asked")
    }

    /// Apple refuses the whole read when the role can't read an included relationship (abapit saw a 400): read once more
    /// without the include, with the refusal said, and the members never read as none. A 403 the same way.
    @Test(arguments: [400, 403])
    func aRefusedIncludeIsReadAgainWithoutItAndSaysSo(status: Int) async throws {
        let harness = try await Self.harness()
        harness.stub.forbid("/v1/users")
        harness.stub.refuseIncludes(with: status)
        let read = try await harness.client.blueprint("BP1", include: Self.all)
        #expect(read.blueprint.name == "Marketing")
        #expect(read.related.isEmpty && read.included.isEmpty)
        let refused = try #require(read.includeRefused)
        #expect(status == 400 ? refused == .badRequest(code: "PARAMETER_ERROR.INVALID", parameter: "include", detail: "An included relationship can't be read.")
            : refused == .forbidden(code: "FORBIDDEN_ERROR"))
        let reads = harness.reads
        #expect(reads.count == 2 && reads[0].contains("include=") && !reads[1].contains("?"), "\(reads)")
        // An include the role can read isn't refused.
        let apps = try await harness.client.blueprint("BP1", include: [.apps])
        #expect(apps.includeRefused == nil && apps.related[.apps]?.linkages.count == 1)
    }

    /// Only a 400 or a 403 on an include is retried, once: a 404, a 422, a 500 or a 400 when nothing was included is
    /// thrown with one read sent, and a failure of the second read is thrown too.
    @Test func onlyARefusedIncludeIsRetriedAndOnlyOnce() async throws {
        for status in [404, 500, 422] {
            let harness = try await Self.harness()
            harness.stub.queue(status, for: "/v1/blueprints/BP1?include=")
            await #expect(throws: (any Error).self) { _ = try await harness.client.blueprint("BP1", include: Self.all) }
            #expect(harness.reads.count == 1, "\(status): \(harness.reads)")
        }
        let missing = try await Self.harness()
        await #expect(throws: AppleAPIError.notFound) { _ = try await missing.client.blueprint("NOPE", include: Self.all) }
        #expect(missing.reads.count == 1)

        let bare = try await Self.harness()
        bare.stub.queue(400, for: "/v1/blueprints/BP1")
        await #expect(throws: AppleAPIError.badRequest(code: "QUEUED", parameter: nil, detail: "A failure the test queued.")) {
            _ = try await bare.client.blueprint("BP1")
        }
        #expect(bare.reads.count == 1)

        let twice = try await Self.harness()
        twice.stub.queue(400, for: "/v1/blueprints/BP1?include=")
        twice.stub.queue(500, for: "/v1/blueprints/BP1")
        await #expect(throws: AppleAPIError.server(status: 500)) { _ = try await twice.client.blueprint("BP1", include: [.apps]) }
        #expect(twice.reads.count == 2)

        let again = try await Self.harness()
        again.stub.queue(403, for: "/v1/blueprints/BP1?include=")
        again.stub.queue(403, for: "/v1/blueprints/BP1")
        await #expect(throws: AppleAPIError.forbidden(code: "QUEUED")) { _ = try await again.client.blueprint("BP1", include: [.apps]) }
        #expect(again.reads.count == 2, "never a third")
    }

    /// An included relationship whose `data` isn't a list of linkages of its own type is malformed, never no members.
    @Test(arguments: [#"{"data":{}}"#, #"{"data":[{"type":"users","id":"U1"}]}"#, #"{"data":null}"#, #""apps""#])
    func aMalformedIncludedRelationshipIsMalformed(relationship: String) async throws {
        let harness = try await Self.harness()
        harness.stub.queue(200, for: "/v1/blueprints/BP1?include=", body: #"""
            {"data":{"type":"blueprints","id":"BP1","attributes":{"name":"Marketing"},"relationships":{"apps":\#(relationship)}},"links":{"self":"x"}}
            """#)
        await #expect(throws: AppleAPIError.malformed("the blueprint's apps")) { _ = try await harness.client.blueprint("BP1", include: [.apps]) }
    }

    /// Each relationship's own list: its members' ids, linkages of its own type only; another type is malformed.
    @Test func eachRelationshipListsItsOwnMembers() async throws {
        let harness = try await Self.harness()
        let expected: [Blueprint.Relationship: [String]] = [.apps: ["361309726"], .packages: ["pkg-12345"], .configurations: ["config-12345"],
                                                            .orgDevices: ["TESTD0000000", "TESTD0000001"], .users: ["1234567890"], .userGroups: ["UG123456"]]
        for (relationship, ids) in expected {
            #expect(try await Harness.all(harness.client.blueprintMemberIDs("BP1", relationship)) == ids, "\(relationship)")
        }
        #expect(harness.reads.allSatisfy { $0.contains("/relationships/") && $0.contains("limit=1000") })
        for relationship in Blueprint.Relationship.allCases {
            let other = relationship == .apps ? "packages" : "apps"
            harness.stub.queue(200, for: "/v1/blueprints/BP1/relationships/\(relationship.rawValue)", body: #"{"data":[{"type":"\#(other)","id":"X1"}]}"#)
            await #expect(throws: AppleAPIError.malformed("linkages of type \(relationship.resourceType)")) {
                _ = try await Harness.all(harness.client.blueprintMemberIDs("BP1", relationship))
            }
        }
        await #expect(throws: AppleAPIError.notFound) { _ = try await Harness.all(harness.client.blueprintMemberIDs("NOPE", .apps)) }
    }

    /// The list of blueprints, and the stub's own refusals: an include name Apple doesn't list, a limit past 1000 or
    /// under 1, an empty include, and a parameter the endpoint lacks.
    @Test func theStubRefusesAnIncludeOrALimitTheContractDoesnt() async throws {
        let harness = try await Self.harness()
        #expect(try await Harness.all(harness.client.blueprints()).map(\.id) == ["BP1"])
        for query in [[("include", "devices")], [("include", "apps,")], [("include", "")], [("include", "apps"), ("limit[apps]", "1001")],
                      [("include", "apps"), ("limit[apps]", "0")], [("include", "apps"), ("limit[devices]", "5")], [("limit", "5")]] {
            #expect(try await harness.raw("/v1/blueprints/BP1", query).status == 400, "\(query)")
        }
        // Without `limit[<name>]` Apple's default applies (assumed small: check live).
        harness.stub.relate("blueprints", "BP1", "users", to: (0..<20).map { "U\($0)" })
        let small = try await harness.raw("/v1/blueprints/BP1", [("include", "users")])
        #expect(small.status == 200 && small.body?["data"]?["relationships"]?["users"]?["data"]?.array?.count == AppleStub.includeLimit)
        #expect(small.body?["data"]?["relationships"]?["users"]?["meta"]?["paging"]?["nextCursor"] != nil)
    }
}
