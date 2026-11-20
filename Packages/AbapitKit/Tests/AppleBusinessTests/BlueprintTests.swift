import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// A blueprint and its members (plan §8, Phase 2): read one relationship at a time, because Apple's live server refused
/// `include` on a blueprint (2026-11-19, 2026-11-20); a refusal or a cut said and never silent (invariant 8), and the six
/// relationship lists, each of its own type.
@Suite("Blueprints", .serialized)
struct BlueprintTests {
    static let all = Set(Blueprint.Relationship.allCases)

    /// A blueprint `BP1` with members in every relationship, each member a resource the stub holds.
    static func harness(pageCap: Int = AppleClient.defaultPageCap) async throws -> Harness {
        let harness = try await Harness(devices: 2, pageCap: pageCap)
        harness.stub.add(try Harness.example("get-users") + Harness.example("get-user-groups") + Harness.example("get-apps")
                         + Harness.example("get-packages") + Harness.example("get-configuration-information"))
        harness.stub.add([Resource(type: "blueprints", id: "BP1", attributes: ["name": .string("Marketing"), "status": .string("ACTIVE"),
                                                                               "appLicenseDeficient": .bool(false)])])
        let members = ["apps": ["361309726"], "packages": ["pkg-12345"], "configurations": ["config-12345"],
                       "orgDevices": ["TESTD0000000", "TESTD0000001"], "users": ["1234567890"], "userGroups": ["UG123456"]]
        for (relationship, ids) in members { harness.stub.relate("blueprints", "BP1", relationship, to: ids) }
        return harness
    }

    /// The members a read holds: only `.read` has any, so a test, like a screen, has to ask for that case.
    static func members(_ read: BlueprintRead) throws -> [Blueprint.Relationship: Blueprint.Related] {
        guard case .read(let related) = read.members else {
            Issue.record("the members were refused: \(read.members)")
            throw CancellationError()
        }
        return related
    }

    /// The stub refuses an `include` on a single blueprint by default, as Apple's live server did (400
    /// `PARAMETER_ERROR.ILLEGAL`, `source.parameter` `include`, 2026-11-19 and 2026-11-20), from a role that could read every
    /// relationship, whatever the include names; the bare read is served.
    @Test func theStubRefusesAnIncludeOnASingleBlueprintByDefault() async throws {
        let harness = try await Self.harness()
        for include in ["apps", "apps,packages,configurations,orgDevices,users,userGroups"] {
            let refused = try await harness.raw("/v1/blueprints/BP1", [("include", include)])
            #expect(refused.status == 400, "\(include)")
            let error = try #require(refused.body?["errors"]?.array?.first)
            #expect(error["code"]?.string == "PARAMETER_ERROR.ILLEGAL" && error["source"]?["parameter"]?.string == "include", "\(include)")
        }
        #expect(try await harness.raw("/v1/blueprints/BP1").status == 200)
    }

    /// What the app reads (`blueprintWithMembers`), after Apple's live server refused the include of all six on 2026-11-19 and
    /// 2026-11-20 (400 `PARAMETER_ERROR.ILLEGAL include`): the blueprint with no query at all, then each relationship's own
    /// list, and nothing refused first. Undone (the include sent again), the stub's refusal costs a second read, and a request
    /// carries `include`.
    @Test func aBlueprintWithMembersSendsNoIncludeAndReadsEachRelationship() async throws {
        let harness = try await Self.harness()
        let read = try await harness.client.blueprintWithMembers("BP1")
        let related = try Self.members(read)
        #expect(read.blueprint.name == "Marketing")
        #expect(Set(related.keys) == Self.all && related.values.allSatisfy { !$0.isTruncated })
        #expect(related[.orgDevices]?.linkages == [Linkage(type: "orgDevices", id: "TESTD0000000"), Linkage(type: "orgDevices", id: "TESTD0000001")])
        #expect(related[.apps] == Blueprint.Related(linkages: [Linkage(type: "apps", id: "361309726")], isTruncated: false))
        let reads = harness.reads
        #expect(reads.count == 7 && !reads.contains { $0.contains("include") }, "\(reads)")
        #expect(reads.filter { !$0.contains("/relationships/") }.count == 1 && !(reads.first?.contains("?") ?? true), "\(reads)")
        for name in Blueprint.Relationship.allCases { #expect(reads.contains { $0.contains("/v1/blueprints/BP1/relationships/\(name.rawValue)?") }, "\(name)") }
    }

    /// A relationship the page cap cut says so; the others don't.
    @Test func aRelationshipTheCapCutIsTruncatedWhenReadOneAtATime() async throws {
        let harness = try await Self.harness(pageCap: 1)
        harness.stub.relate("blueprints", "BP1", "orgDevices", to: (0..<1_001).map { String(format: "TESTD%07d", $0) })
        let related = try Self.members(try await harness.client.blueprintWithMembers("BP1"))
        #expect(related[.orgDevices]?.linkages.count == 1_000 && related[.orgDevices]?.isTruncated == true)
        #expect(related[.apps]?.isTruncated == false)
        // Without the cap every page is read.
        let uncapped = try await Self.harness()
        uncapped.stub.relate("blueprints", "BP1", "orgDevices", to: (0..<1_001).map { String(format: "TESTD%07d", $0) })
        let whole = try Self.members(try await uncapped.client.blueprintWithMembers("BP1"))
        #expect(whole[.orgDevices]?.linkages.count == 1_001 && whole[.orgDevices]?.isTruncated == false)
    }

    /// A relationship Apple refuses (a 403 for a role that can't read users, or a 400) makes the members `.refused`, said, and
    /// never a count of the rest; another failure is thrown, the blueprint's own too.
    @Test(arguments: [400, 403])
    func aRefusedRelationshipIsSaidAndCountsNothing(status: Int) async throws {
        let harness = try await Self.harness()
        if status == 403 { harness.stub.forbid("/v1/blueprints/BP1/relationships/users") } else { harness.stub.queue(400, for: "/v1/blueprints/BP1/relationships/users") }
        let read = try await harness.client.blueprintWithMembers("BP1")
        #expect(read.blueprint.name == "Marketing")
        guard case .refused(let refused) = read.members else {
            Issue.record("the refusal read as members: \(read.members)")
            return
        }
        #expect(refused == (status == 403 ? .forbidden(code: "FORBIDDEN_ERROR") : .badRequest(code: "QUEUED", parameter: nil, detail: "A failure the test queued.")))

        let failing = try await Self.harness()
        failing.stub.queue(500, for: "/v1/blueprints/BP1/relationships/apps")
        await #expect(throws: (any Error).self) { _ = try await failing.client.blueprintWithMembers("BP1") }
        let missing = try await Self.harness()
        await #expect(throws: AppleAPIError.notFound) { _ = try await missing.client.blueprintWithMembers("NOPE") }
        #expect(missing.reads.count == 1)
    }

    /// A relationship whose answer isn't linkages of its own type is malformed, never no members.
    @Test func aMalformedRelationshipListIsMalformed() async throws {
        let harness = try await Self.harness()
        harness.stub.queue(200, for: "/v1/blueprints/BP1/relationships/apps", body: #"{"data":[{"type":"users","id":"U1"}],"links":{"self":"x"}}"#)
        await #expect(throws: AppleAPIError.malformed("linkages of type apps")) { _ = try await harness.client.blueprintWithMembers("BP1") }
    }

    /// Apple's `meta.paging.total` past what came is a cut too, though no page was left to read.
    @Test func aTotalPastTheCountIsTruncated() async throws {
        let harness = try await Self.harness()
        harness.stub.queue(200, for: "/v1/blueprints/BP1/relationships/apps", body: #"{"data":[{"type":"apps","id":"361309726"}],"meta":{"paging":{"total":5}},"links":{"self":"x"}}"#)
        let related = try Self.members(try await harness.client.blueprintWithMembers("BP1"))
        #expect(related[.apps]?.linkages.count == 1 && related[.apps]?.isTruncated == true)
        #expect(related[.packages]?.isTruncated == false)
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
    /// under 1, an empty include, and a parameter the endpoint lacks (the list still takes `include`; the single read refuses it).
    @Test func theStubRefusesAnIncludeOrALimitTheContractDoesnt() async throws {
        let harness = try await Self.harness()
        #expect(try await Harness.all(harness.client.blueprints()).map(\.id) == ["BP1"])
        for query in [[("include", "devices")], [("include", "apps,")], [("include", "")], [("include", "apps"), ("limit[apps]", "1001")],
                      [("include", "apps"), ("limit[apps]", "0")], [("include", "apps"), ("limit[devices]", "5")], [("filter", "5")]] {
            #expect(try await harness.raw("/v1/blueprints", query).status == 400, "\(query)")
        }
        // Without `limit[<name>]` Apple's default applies (assumed small: check live).
        harness.stub.relate("blueprints", "BP1", "users", to: (0..<20).map { "U\($0)" })
        let small = try await harness.raw("/v1/blueprints", [("include", "users")])
        let users = small.body?["data"]?.array?.first?["relationships"]?["users"]
        #expect(small.status == 200 && users?["data"]?.array?.count == AppleStub.includeLimit)
        #expect(users?["meta"]?["paging"]?["nextCursor"] != nil)
    }
}
