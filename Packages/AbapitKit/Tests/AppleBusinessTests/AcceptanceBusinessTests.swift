@testable import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// The acceptance pass over the Business-only reads (plan §8, Phase 2: "the acceptance pass covers every read"): each
/// line is `ok` only for a read that ran and fully succeeded, the blueprint's include fallback is said, and every read
/// it walks is checked as it reads it.
@Suite("Acceptance pass, Business reads", .serialized)
struct AcceptanceBusinessTests {
    static func pass(_ arrange: (Harness) throws -> Void = { _ in }, pageCap: Int = AppleClient.defaultPageCap) async throws -> (Harness, AcceptanceReport) {
        let harness = try await Harness(devices: 2, pageCap: pageCap)
        for serial in AcceptancePassTests.firstSerials(2) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        try AcceptancePassTests.business(harness)
        try arrange(harness)
        return (harness, await harness.client.acceptancePass())
    }

    static func line(_ report: AcceptanceReport, _ resource: String) throws -> AcceptanceReport.Line {
        try #require(report.lines.first { $0.resource == resource }, "\(resource): \(report.text)")
    }

    /// Apple refused the include and the blueprint was read without it: the line is the refusal's status with what was
    /// read, never `ok`, and says the members weren't read (invariant 8). The six relationship reads still run.
    @Test(arguments: [(400, "error 400", "PARAMETER_ERROR.INVALID include"), (403, "forbidden", "FORBIDDEN_ERROR")])
    func aRefusedIncludeIsSaidNeverOk(status: Int, said: String, code: String) async throws {
        let (harness, report) = try await Self.pass { harness in
            harness.stub.forbid("/v1/users")
            harness.stub.refuseIncludes(with: status)
        }
        let line = try Self.line(report, "blueprints/{id}")
        #expect(!line.ok && line.count == 1)
        #expect(report.text.contains("\nblueprints/{id}: \(said), 1 item · unknown values status=PAUSED · "
                                     + "the include was refused, so the blueprint was read without its members · \(code)\n"), "\(report.text)")
        #expect(harness.reads.filter { $0.contains("/v1/blueprints/BP1") && !$0.contains("/relationships/") }.count == 2)
        #expect(try Self.line(report, "blueprints/{id}/relationships/apps").ok && Self.line(report, "blueprints/{id}/relationships/users").ok)
    }

    /// A relationship the include's limit cut is `truncated`, and so is one Apple asked for and didn't list, whose count
    /// is a dash: none was read, so none is said (it read 0).
    @Test func aRelationshipCutOrNotListedIsTruncated() async throws {
        let (_, cut) = try await Self.pass { $0.stub.relate("blueprints", "BP1", "orgDevices", to: (0..<1_001).map { String(format: "TESTD%07d", $0) }) }
        #expect(cut.text.contains("\nblueprints/{id}: truncated, 1 item · unknown values status=PAUSED · orgDevices cut at the include's limit · "
                                  + "apps 1, packages 1, configurations 1, orgDevices 1000, users 1, userGroups 1\n"), "\(cut.text)")
        #expect(cut.text.contains("\nblueprints/{id}/relationships/orgDevices: ok, 1001 items\n"))

        let (_, unlisted) = try await Self.pass { harness in
            harness.stub.queue(200, for: "/v1/blueprints/BP1?include=", body: #"""
                {"data":{"type":"blueprints","id":"BP1","attributes":{"name":"Marketing"},"relationships":{"apps":{"data":[]},"users":{"links":{}}}},
                 "links":{"self":"x"}}
                """#)
        }
        #expect(unlisted.text.contains("\nblueprints/{id}: truncated, 1 item · packages, configurations, orgDevices, users, userGroups not listed · "
                                       + "apps 0, packages -, configurations -, orgDevices -, users -, userGroups -\n"), "\(unlisted.text)")
    }

    /// The audit log is read cursor by cursor whole, with each page's filters; a repeated cursor is malformed with what
    /// came before it, and the page cap cuts it as any list.
    @Test func theAuditLogIsWalkedByCursor() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let events = (0..<1_500).map { Resource(type: "auditEvents", id: "X\($0)", attributes: ["eventDateTime": .string(recent), "type": .string("ROLE_CREATED")]) }
        let (harness, whole) = try await Self.pass { $0.stub.add(events) }
        #expect(whole.text.contains("\nauditEvents: ok, 1502 items · unknown keys eventDataFutureType · unknown values type=FUTURE_TYPE · "
                                    + "unknown payload keys newField · the last day\n"), "\(whole.text)")
        let audits = harness.reads.filter { $0.contains("/v1/auditEvents") && $0.contains("limit=1000") }
        #expect(audits.count == 2 && audits.allSatisfy { $0.contains("filter%5BstartTimestamp%5D") && $0.contains("filter%5BendTimestamp%5D") })

        let (_, looped) = try await Self.pass { $0.stub.repeatCursors(on: "/v1/auditEvents") }
        #expect(looped.text.contains("\nauditEvents: error malformed, 4 items · a repeated cursor on /v1/auditEvents\n"), "\(looped.text)")

        let (_, capped) = try await Self.pass({ $0.stub.add(events) }, pageCap: 1)
        #expect(try Self.line(capped, "auditEvents").status == .truncated && Self.line(capped, "auditEvents").count == 1_000)
    }

    /// A payload under the type's own key, where Apple named the contract's spelling (`Icloud` for `ICloud`), is read with
    /// its unknown fields counted, and the miss is said; so are an empty key and a payload that isn't an object. Never `ok`
    /// with nothing said (Phase 2a review M1: the pass printed `auditEvents: ok, 1 item · the last day` over an unread
    /// payload).
    @Test func aPayloadKeyThatMissedIsReadAndSaid() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let harness = try await Harness()
        harness.stub.add([
            Resource(type: "auditEvents", id: "X1", attributes: [
                "eventDateTime": .string(recent), "type": .string("SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED"),
                "eventDataPropertyKey": .string("eventDataSubjectHasIcloudStoragePurchaseAdded"),
                "eventDataSubjectHasICloudStoragePurchaseAdded": .object(["subscriptionId": .string("sub-1"), "brandNewField": .string("secret-ish")])]),
            Resource(type: "auditEvents", id: "X2", attributes: [
                "eventDateTime": .string(recent), "type": .string("SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED"), "eventDataPropertyKey": .string(""),
                "eventDataSubjectHasAppleCarePurchaseRemoved": .object(["subscriptionId": .string("sub-2"), "otherNewField": .string("secret-ish")])]),
            Resource(type: "auditEvents", id: "X3", attributes: [
                "eventDateTime": .string(recent), "type": .string("DEVICE_IS_ERASED"), "eventDataDeviceIsErased": .array([])]),
        ])
        let report = await harness.client.acceptancePass()
        #expect(report.text.contains("\nauditEvents: ok, 3 items · unknown payload keys brandNewField, otherNewField · payload key named but absent in 1 event · "
                                     + "payload key named empty in 1 event · payload not an object in 1 event · the last day\n"), "\(report.text)")
        #expect(!report.text.contains("secret-ish") && !report.text.contains("sub-"))
    }

    /// Keys inside the objects a view reads are counted under their attribute's name, each object's: a user's phone
    /// numbers and roles in the list and the single read, a custom setting's values, either audit role list. A key that
    /// isn't a word is `(not shown)` and forges no line (Phase 2a review L1: none was counted).
    @Test func keysInsideNestedObjectsAreCounted() async throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let harness = try await Harness()
        harness.stub.add([Resource(type: "users", id: "U9", attributes: [
            "firstName": .string("Ana"),
            "phoneNumbers": .array([.object(["phoneNumber": .string("+1 555 0100"), "type": .string("WORK"), "isPrimary": .bool(true)])]),
            "roleOuList": .array([.object(["roleName": .string("Admin"), "ouId": .string("OU1"), "scopeName": .string("all"),
                                           "x\nprobe users: ok": .string("secret-ish")])]),
        ])])
        harness.stub.add([Resource(type: "configurations", id: "C1", attributes: ["type": .string("CUSTOM_SETTING"), "customSettingsValues": .object([
            "configurationProfile": .string("<plist version=\"1.0\"><dict/></plist>"), "filename": .string("a.mobileconfig"), "signed": .bool(true)])])])
        harness.stub.add([
            Resource(type: "auditEvents", id: "E1", attributes: [
                "eventDateTime": .string(recent), "type": .string("ACCOUNT_ROLE_LOCATION_CHANGED"),
                "eventDataAccountRoleLocationChanged": .object(["accountRoleLocationList": .array([.object(["roleName": .string("R"), "scope": .string("all")])])])]),
            Resource(type: "auditEvents", id: "E2", attributes: [
                "eventDateTime": .string(recent), "type": .string("API_ACCOUNT_ROLE_LOCATION_CHANGED"),
                "eventDataApiAccountRoleLocationChanged": .object(["apiAccountRoleLocationList": .array([.object(["roleName": .string("R"), "expiry": .string("x")])])])]),
        ])
        let report = await harness.client.acceptancePass()
        for line in [
            "users: ok, 1 item · unknown keys phoneNumbers.isPrimary, roleOuList.(not shown), roleOuList.scopeName",
            "users/{id}: ok, 1 item · unknown keys phoneNumbers.isPrimary, roleOuList.(not shown), roleOuList.scopeName",
            "configurations: ok, 1 item",
            "configurations/{id}: ok, 1 item · unknown keys customSettingsValues.signed",
            "auditEvents: ok, 2 items · unknown payload keys accountRoleLocationList.scope, apiAccountRoleLocationList.expiry · the last day",
        ] { #expect(report.text.contains("\n\(line)\n"), "\(line)\n\(report.text)") }
        #expect(report.text.split(separator: "\n").count == 8 + AcceptancePassTests.businessLines + AppleSection.allCases.count, "no forged line")
        #expect(!report.text.contains("secret-ish") && !report.text.contains("Ana"))
    }

    /// Each Business section's failure is its own: a forbidden or failing list skips its detail and members saying why,
    /// and the other sections still read.
    @Test func eachSectionsFailureIsItsOwn() async throws {
        let (harness, report) = try await Self.pass { harness in
            harness.stub.forbid("/v1/userGroups")
            harness.stub.queue(500, for: "/v1/mdmDevices?limit=1000")
            harness.stub.queue(429, for: "/v1/apps?limit=1000", headers: ["Retry-After": "1"])
        }
        #expect(report.text.contains("""

            userGroups: forbidden, 0 items · FORBIDDEN_ERROR
            userGroups/{id}: skipped: no user group to read (userGroups forbidden)
            userGroups/{id}/relationships/users: skipped: no user group to read (userGroups forbidden)
            organizationalUnits: ok, 1 item

            """), "\(report.text)")
        #expect(report.text.contains("\nmdmDevices: error 500, 0 items\nmdmDevices/{id}/details: skipped: no Apple-managed device to read (mdmDevices error 500)\n"))
        #expect(try Self.line(report, "apps").ok && Self.line(report, "apps/{id}").ok, "a 429 waited out")
        #expect(!harness.reads.contains { $0.contains("/v1/userGroups/") || $0.contains("/v1/mdmDevices/") }, "a skipped read is never sent")
    }

    /// What the pass reads is checked as it reads it: a list of another type, a detail that isn't the item asked for, and
    /// a member list of another type are each malformed, never `ok`.
    @Test func anAnswerOfAnotherTypeOrItemIsMalformed() async throws {
        let (_, report) = try await Self.pass { harness in
            harness.stub.queue(200, for: "/v1/packages?limit=1000", body: #"{"data":[{"type":"apps","id":"361309726"}]}"#)
            harness.stub.queue(200, for: "/v1/users/1234567890", body: #"{"data":{"type":"users","id":"U2"}}"#)
            harness.stub.queue(200, for: "/v1/apps/361309726", body: #"{"data":{"type":"packages","id":"361309726"}}"#)
            harness.stub.queue(200, for: "/v1/organizationalUnits/OU789012/relationships/users", body: #"{"data":[{"type":"userGroups","id":"UG123456"}]}"#)
            harness.stub.queue(200, for: "/v1/mdmDevices/MD1/details", body: #"{"data":{"type":"mdmDevices","id":"MD1"}}"#)
            harness.stub.queue(200, for: "/v1/blueprints/BP1?include=", body: #"{"data":{"type":"blueprints","id":"BP2"},"links":{"self":"x"}}"#)
        }
        let expected = [
            "packages": "error malformed, 0 items · items of type packages", "users/{id}": "error malformed, 0 items · the users item asked for",
            "apps/{id}": "error malformed, 0 items · the apps item asked for",
            "organizationalUnits/{id}/relationships/users": "error malformed, 0 items · linkages of type users",
            "mdmDevices/{id}/details": "error malformed, 0 items · items of type mdmDeviceDetails",
            "blueprints/{id}": "error malformed, 0 items · the blueprints item asked for",
        ]
        for (resource, said) in expected { #expect(report.text.contains("\n\(resource): \(said)\n"), "\(resource): \(report.text)") }
        #expect(try Self.line(report, "packages/{id}").status == .skipped("no package to read (packages error malformed)"))
    }

    /// A list the page cap cut is `truncated` with what was read, and the detail is read from what was.
    @Test func aBusinessListCutAtThePageCapIsTruncated() async throws {
        let (_, report) = try await Self.pass({ harness in
            harness.stub.add((0..<1_000).map { Resource(type: "users", id: "UX\($0)", attributes: ["firstName": .string("X")]) })
        }, pageCap: 1)
        #expect(report.text.contains("\nusers: truncated, 1000 items · unknown keys pronouns · unknown values phoneNumbers.type=PAGER, status=SUSPENDED · "
                                     + "stopped at the page cap with more to come\nusers/{id}: ok, 1 item\n"), "\(report.text)")
    }

    /// Every member list the page cap cut says so, with what was read: the group's and the org unit's users and each of
    /// the blueprint's six relationships, each two pages long at the page cap of one (Phase 2a review L3: deleting the
    /// cut from the member check left all nine lines `ok`). The stub pages members at the client's `limit`, 1000.
    @Test func everyMemberListCutAtThePageCapIsTruncated() async throws {
        let members = (0..<1_001).map { String(format: "TESTM%07d", $0) }
        let (_, report) = try await Self.pass({ harness in
            harness.stub.relate("userGroups", "UG123456", "users", to: members)
            harness.stub.relate("organizationalUnits", "OU789012", "users", to: members)
            for relationship in Blueprint.Relationship.allCases { harness.stub.relate("blueprints", "BP1", relationship.rawValue, to: members) }
        }, pageCap: 1)
        let lines = ["userGroups/{id}/relationships/users", "organizationalUnits/{id}/relationships/users"]
            + Blueprint.Relationship.allCases.map { "blueprints/{id}/relationships/\($0.rawValue)" }
        for resource in lines {
            #expect(report.text.contains("\n\(resource): truncated, 1000 items · stopped at the page cap with more to come\n"), "\(resource): \(report.text)")
        }
        // A member list one page long reads whole at the same cap.
        let (_, whole) = try await Self.pass({ _ in }, pageCap: 1)
        for resource in lines { #expect(try Self.line(whole, resource).ok, "\(resource)") }
    }

    /// An id that can't go in a path is never sent and says what it is, for every detail and member read.
    @Test func anIDThatCantGoInAPathIsNeverSent() async throws {
        let (harness, report) = try await Self.pass { harness in
            harness.stub.queue(200, for: "/v1/userGroups?limit=1000", body: #"{"data":[{"type":"userGroups","id":"UG 1"}]}"#)
            harness.stub.queue(200, for: "/v1/blueprints?limit=1000", body: #"{"data":[{"type":"blueprints","id":"../BP1"}]}"#)
        }
        for resource in ["userGroups/{id}", "userGroups/{id}/relationships/users", "blueprints/{id}"]
            + Blueprint.Relationship.allCases.map({ "blueprints/{id}/relationships/\($0.rawValue)" }) {
            #expect(try Self.line(report, resource).status == .error("error malformed") && Self.line(report, resource).note == "an id that can go in a path",
                    "\(resource)")
        }
        #expect(!harness.reads.contains { $0.contains("/v1/userGroups/") || $0.contains("/v1/blueprints/") })
    }

    /// An org whose Business lists are empty skips every detail saying the list has none, and sends none of them.
    @Test func emptyListsSkipTheirDetails() async throws {
        let harness = try await Harness()
        let report = await harness.client.acceptancePass()
        #expect(try Self.line(report, "users").ok && Self.line(report, "users").count == 0)
        #expect(try Self.line(report, "users/{id}").status == .skipped("no user to read (users has none)"))
        #expect(try Self.line(report, "blueprints/{id}/relationships/apps").status == .skipped("no blueprint to read (blueprints has none)"))
        #expect(try Self.line(report, "auditEvents").ok && Self.line(report, "auditEvents").count == 0)
        #expect(!harness.reads.contains { $0.contains("/v1/users/") || $0.contains("/v1/blueprints/") })
    }
}
