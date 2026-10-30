import Foundation
import JSONAPI
import Testing
import TestSupport
@testable import Reports

/// abapit's `reports.audit_digest` and its two type sets, held to `Tests/Fixtures/parity/reports.json`
/// (invariant 6); the Access & Security set and the views' cover of Apple's types, held to
/// `Contracts/apple/business-2.6.json`; and the dashboard's recent events.
@Suite("Audit digest")
struct AuditDigestTests {
    static func ids(_ rows: [Resource]) -> [[UInt8]] { rows.map { Array($0.id.utf8) } }
    static func ids(_ value: JSONValue?) -> [[UInt8]] { (value?.array ?? []).compactMap { $0["id"]?.string }.map { Array($0.utf8) } }

    static func tallies(_ value: JSONValue?) -> [Tally] {
        (value?.array ?? []).compactMap { pair in
            guard let name = pair.array?.first?.string, let count = pair.array?.last?.int else { return nil }
            return Tally(name: name, count: count)
        }
    }

    static func types(named name: String?) -> [String]? {
        switch name {
        case "SUBSCRIPTION_EVENTS": AuditView.subscriptions.types
        case "DEVICE_LIFECYCLE_EVENTS": AuditView.deviceLifecycle.types
        default: nil
        }
    }

    static func event(_ id: String, _ type: String?, _ stamp: String?) -> Resource {
        var attributes: JSONObject = [:]
        if let type { attributes = attributes.merging(["type": .string(type)]) }
        if let stamp { attributes = attributes.merging(["eventDateTime": .string(stamp)]) }
        return Resource(type: "auditEvents", id: id, attributes: attributes)
    }

    /// 15 drawn lists (every stamp UTC), then the hand-written ones: mixed offsets, fractional seconds, every way
    /// to lack a date, attributes and types of other shapes, types outside the set and future ones, and ties. The
    /// deviations are listed: abapit sorted the `eventDateTime` strings (a drawn `not a date` went first), and
    /// raised on attributes that aren't an object, a type that isn't hashable and a date that isn't a string.
    @Test func auditDigestMatchesTheGolden() throws {
        let cases = try ReportsParityTests.cases("reports", "audit_digest")
        #expect(cases.count == 26)
        #expect(cases.indices.filter { cases[$0]["abapit"] != nil } == [6, 15, 16, 17, 18, 20, 21, 24])
        for (index, item) in cases.enumerated() {
            let input = try #require(item["input"])
            let events = ReportsParityTests.resources(input["events"])
            try #require(events.count == input["events"]?.array?.count, "case \(index): every event is a resource, so scanned is the golden's")
            let types = try #require(Self.types(named: input["types"]?.string), "case \(index)")
            let digest = AuditDigest(events, types: types)
            let expected = try #require(item["expected"]?["ok"], "case \(index)")
            #expect(Self.ids(digest.rows) == Self.ids(expected["rows"]), "case \(index)")
            #expect(ReportsParityTests.bytes(digest.counts) == ReportsParityTests.bytes(Self.tallies(expected["counts"])), "case \(index)")
            #expect(digest.total == expected["total"]?.int, "case \(index)")
            #expect(digest.scanned == expected["scanned"]?.int, "case \(index)")
        }
    }

    /// Where abapit returned, the deviation is the order alone: the same rows, the same counts, another order.
    /// Where it raised, the corrected digest reads the list.
    @Test func everyAuditDeviationIsOrderOrARefusal() throws {
        for item in try ReportsParityTests.cases("reports", "audit_digest") where item["abapit"] != nil {
            let abapit = try #require(item["abapit"]), expected = try #require(item["expected"]?["ok"])
            guard let ok = abapit["ok"] else {
                #expect(abapit["error"]?.string == "TypeError" || abapit["error"]?.string == "AttributeError")
                continue
            }
            #expect(Set(Self.ids(ok["rows"])) == Set(Self.ids(expected["rows"])))
            #expect(Self.ids(ok["rows"]) != Self.ids(expected["rows"]))
            #expect(Set(ReportsParityTests.bytes(Self.tallies(ok["counts"]))) == Set(ReportsParityTests.bytes(Self.tallies(expected["counts"]))))
        }
    }

    /// abapit's `SUBSCRIPTION_EVENTS` and `DEVICE_LIFECYCLE_EVENTS` at the pin, in its order, byte for byte.
    @Test func theTwoViewsAreAbapitsSets() throws {
        let golden = try #require(try Fixtures.parityValue("reports")["audit_types"])
        func bytes(_ list: [String]) -> [[UInt8]] { list.map { Array($0.utf8) } }
        let subscriptions = (golden["SUBSCRIPTION_EVENTS"]?.array ?? []).compactMap(\.string)
        let lifecycle = (golden["DEVICE_LIFECYCLE_EVENTS"]?.array ?? []).compactMap(\.string)
        #expect(subscriptions.count == 7 && lifecycle.count == 5)
        #expect(bytes(AuditView.subscriptions.types) == bytes(subscriptions))
        #expect(bytes(AuditView.deviceLifecycle.types) == bytes(lifecycle))
    }

    /// Apple's `AuditEventType`, read from the contract.
    static func contractTypes() throws -> [String] {
        let data = try Data(contentsOf: Fixtures.contracts.appending(path: "apple/business-2.6.json"))
        let manifest = try #require(JSONValue.parse(String(decoding: data, as: UTF8.self)))
        return try #require(manifest["enums"]?["AuditEventType"]?["values"]?.array).compactMap(\.string)
    }

    /// Every one of Apple's 50 types is in exactly one view's set or in `otherTypes`, and every listed type is
    /// Apple's: a type Apple adds fails here until it is placed, so it can't vanish from every view unseen.
    @Test func everyContractTypeIsPlacedOnce() throws {
        let contract = try Self.contractTypes()
        #expect(contract.count == 50)
        let lists = AuditView.allCases.map(\.types) + [AuditView.otherTypes]
        for type in contract {
            let places = lists.map { $0.filter { $0.utf8.elementsEqual(type.utf8) }.count }.reduce(0, +)
            #expect(places == 1, "\(type) is placed \(places) times")
        }
        let known = Set(contract.map { Array($0.utf8) })
        for type in lists.joined() {
            #expect(known.contains(Array(type.utf8)), "\(type) isn't one of Apple's types")
        }
        #expect(lists.map(\.count) == [7, 5, 29, 9])
    }

    /// The new view's decisions: terms accepted and Apple-services settings are in (an administrator's account
    /// binding the organization, and what its Managed Apple Accounts may sign in to); configurations, collections
    /// and account pictures are out.
    @Test func accessAndSecurityHoldsTheDecidedTypes() {
        let access = Set(AuditView.accessAndSecurity.types)
        for type in ["TERMS_ACCEPTED", "APPLE_SERVICES_SETTINGS_UPDATED", "API_ACCOUNT_KEY_REVOKED", "ROLE_CREATED",
                     "DOMAIN_FEDERATION_ENABLED", "IDP_ACCOUNT_SYNC_DISABLED", "BATCH_PASSWORD_RESET_INITIATED",
                     "EXTERNAL_ACCOUNT_INVITED", "ACCOUNT_PASSWORD_CHANGED"] {
            #expect(access.contains(type), "\(type)")
        }
        let other = Set(AuditView.otherTypes)
        for type in ["CONFIG_SETTINGS_CREATED", "CONFIG_SETTINGS_UPDATED", "CONFIG_SETTINGS_DELETED", "COLLECTION_CREATED",
                     "COLLECTION_UPDATED", "COLLECTION_DELETED", "ACCOUNT_IMAGE_SET", "ACCOUNT_IMAGE_REPLACED", "ACCOUNT_IMAGE_REMOVED"] {
            #expect(other.contains(type), "\(type)")
        }
    }

    /// A view's digest is the digest of its set; a type matches byte for byte, as Python's `in` compares code points.
    /// U+212A KELVIN SIGN is canonically equivalent to `K`, so `String ==` and `Set<String>` take
    /// `API_ACCOUNT_\u{212A}EY_REVOKED` for Apple's type.
    @Test func aViewMatchesItsTypesByteForByte() {
        let kelvin = "API_ACCOUNT_\u{212A}EY_REVOKED"
        #expect(kelvin == "API_ACCOUNT_KEY_REVOKED", "the trap: Swift's String equality folds it")
        let events = [Self.event("a", "API_ACCOUNT_KEY_REVOKED", "2026-10-14T10:00:00Z"), Self.event("b", kelvin, "2026-10-14T11:00:00Z"),
                      Self.event("c", "ROLE_CREATED", "2026-10-14T09:00:00Z"), Self.event("d", "ACCOUNT_IMAGE_SET", "2026-10-14T12:00:00Z"),
                      Self.event("e", "TERMS_ACCEPTED", nil), Self.event("f", nil, "2026-10-14T13:00:00Z"),
                      Self.event("g", "SUBSCRIPTION_CREATED", "2026-10-14T14:00:00Z")]
        let digest = AuditDigest(events, view: .accessAndSecurity)
        #expect(digest.rows.map(\.id) == ["a", "c", "e"])
        #expect(ReportsParityTests.bytes(digest.counts) == ReportsParityTests.bytes([Tally(name: "API_ACCOUNT_KEY_REVOKED", count: 1),
                                                                                     Tally(name: "ROLE_CREATED", count: 1),
                                                                                     Tally(name: "TERMS_ACCEPTED", count: 1)]))
        #expect(digest.total == 3 && digest.scanned == 7)
        for view in AuditView.allCases {
            let byView = AuditDigest(events, view: view), byTypes = AuditDigest(events, types: view.types)
            #expect(byView.rows.map(\.id) == byTypes.rows.map(\.id) && byView.counts == byTypes.counts, "\(view)")
        }
        #expect(AuditDigest(events, view: .subscriptions).rows.map(\.id) == ["g"])
    }

    /// The dashboard's recent events: the newest ten by instant, whatever order the API sent them in (it has no
    /// `sort`), with the undated after the dated.
    @Test func recentIsTheNewestTenByInstant() {
        // Oldest first, as an API order might be, and in mixed offsets: `2026-10-11T09:00:00-05:00` is 14:00 UTC, the
        // newest, and by string it would rank below `2026-10-11T10:00:00Z`.
        var events = (0..<11).map { Self.event("d\($0)", "ROLE_UPDATED", String(format: "2026-10-%02dT10:00:00Z", $0 + 1)) }
        events.insert(Self.event("late", "ROLE_UPDATED", "2026-10-11T09:00:00-05:00"), at: 0)
        events.insert(Self.event("undated", "ROLE_UPDATED", nil), at: 0)
        let recent = AuditDigest.recent(events)
        #expect(AuditDigest.recentLimit == 10)
        #expect(recent.map(\.id) == ["late", "d10", "d9", "d8", "d7", "d6", "d5", "d4", "d3", "d2"])
        // Fewer than ten: every one, the undated last; one instant spelled two ways keeps its order (by string,
        // `T10:00:00+02:00` would go before `T08:00:00Z`).
        let few = [Self.event("u", nil, nil), Self.event("t2", "X", "2026-10-01T08:00:00Z"), Self.event("t1", "X", "2026-10-01T10:00:00+02:00"),
                   Self.event("n", "X", "2026-10-02T00:00:00Z")]
        #expect(AuditDigest.recent(few).map(\.id) == ["n", "t2", "t1", "u"])
        #expect(AuditDigest.recent([]).isEmpty)
    }
}
