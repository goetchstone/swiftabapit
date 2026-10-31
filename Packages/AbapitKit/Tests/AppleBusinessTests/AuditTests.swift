import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport
import Wire

/// The audit read (plan §2.1): a checked range and filters, Apple's filters only, cursor paging that keeps them, and a
/// repeated cursor refused.
@Suite("Audit events", .serialized)
struct AuditTests {
    static let noon = Date(timeIntervalSince1970: 1_792_152_000)   // 2026-10-16T12:00:00Z
    static let day: TimeInterval = 86_400

    static func event(_ id: String, at offset: TimeInterval, type: String = "DEVICE_ADDED_TO_ORG", actor: String = "A1", subject: String = "S1") -> Resource {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Resource(type: "auditEvents", id: id, attributes: [
            "eventDateTime": .string(format.string(from: noon.addingTimeInterval(offset))), "type": .string(type), "category": .string("DEVICE_INVENTORY"),
            "actorType": .string("API_USER"), "actorId": .string(actor), "subjectType": .string("DEVICE"), "subjectId": .string(subject),
            "outcome": .string("SUCCESS"), "eventDataPropertyKey": .string("eventDataDeviceAddedToOrg"),
            "eventDataDeviceAddedToOrg": .object(["serialNumber": .string(subject), "purchaseSourceType": .string("APPLE")]),
        ])
    }

    // MARK: the query

    /// Both bounds are whole seconds in UTC with `Z`; a fraction is cut, and the order is checked after the cut.
    @Test func theRangeIsWholeSecondsInUTC() throws {
        let query = try AuditQuery(start: Self.noon.addingTimeInterval(0.75), end: Self.noon.addingTimeInterval(Self.day + 0.25))
        let read = AppleRead.auditEvents(query)
        #expect(read.query.first == QueryItem("filter[startTimestamp]", "2026-10-16T12:00:00Z"))
        #expect(read.query.dropFirst().first == QueryItem("filter[endTimestamp]", "2026-10-17T12:00:00Z"))
        #expect(read.query.last == QueryItem("limit", "1000"))
        #expect(read.path == "/v1/auditEvents" && read.host == .appleBusiness)
        // 12:00:00.2 to 12:00:00.9 is one second cut to none.
        #expect(throws: AuditQuery.Invalid.emptyRange) {
            try AuditQuery(start: Self.noon.addingTimeInterval(0.2), end: Self.noon.addingTimeInterval(0.9))
        }
    }

    /// The range's bounds, each at its edge: the start must be a second before the end, and the span at most 365 days.
    @Test func theRangesBoundsHoldAtTheirEdges() throws {
        let start = Self.noon
        _ = try AuditQuery(start: start, end: start.addingTimeInterval(1))
        _ = try AuditQuery(start: start, end: start.addingTimeInterval(AuditQuery.longestSpan))
        #expect(AuditQuery.longestSpan == 365 * Self.day)
        #expect(throws: AuditQuery.Invalid.emptyRange) { try AuditQuery(start: start, end: start) }
        #expect(throws: AuditQuery.Invalid.emptyRange) { try AuditQuery(start: start, end: start.addingTimeInterval(-1)) }
        #expect(throws: AuditQuery.Invalid.tooLong) { try AuditQuery(start: start, end: start.addingTimeInterval(AuditQuery.longestSpan + 1)) }
        // Representable as `YYYY-MM-DDTHH:MM:SSZ`: 1970 to 9999.
        _ = try AuditQuery(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1))
        let latest = Date(timeIntervalSince1970: 253_402_300_799)
        _ = try AuditQuery(start: latest.addingTimeInterval(-1), end: latest)
        #expect(AppleRead.auditEvents(try AuditQuery(start: latest.addingTimeInterval(-1), end: latest)).query[1].value == "9999-12-31T23:59:59Z")
        #expect(throws: AuditQuery.Invalid.outOfRange) { try AuditQuery(start: latest, end: latest.addingTimeInterval(1)) }
        #expect(throws: AuditQuery.Invalid.outOfRange) { try AuditQuery(start: Date(timeIntervalSince1970: -1), end: Date(timeIntervalSince1970: 1)) }
        #expect(throws: AuditQuery.Invalid.outOfRange) { try AuditQuery(start: Date(timeIntervalSince1970: .nan), end: start) }
        #expect(throws: AuditQuery.Invalid.outOfRange) { try AuditQuery(start: start, end: Date(timeIntervalSince1970: .infinity)) }
        let last = try AuditQuery.last(days: 1, now: Self.noon)
        #expect(last.start == Self.noon.addingTimeInterval(-Self.day) && last.end == Self.noon)
    }

    /// `filter[type]` takes Apple's types only: an `.unknown` one throws before a read can be built, so it never goes out.
    /// Each type goes once, in the order given.
    @Test func onlyApplesTypesAreFilteredOn() throws {
        #expect(throws: AuditQuery.Invalid.unknownType("FUTURE_TYPE")) {
            try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1), types: [.known(.roleCreated), .unknown("FUTURE_TYPE")])
        }
        // A value read from an event, spelt as Apple spells a known type, is that type.
        let query = try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1),
                                   types: [OpenEnum("ROLE_UPDATED"), .known(.roleCreated), .known(.roleUpdated)])
        #expect(query.types == [.roleUpdated, .roleCreated])
        #expect(AppleRead.auditEvents(query).query.contains(QueryItem("filter[type]", "ROLE_UPDATED,ROLE_CREATED")))
        #expect(!AppleRead.auditEvents(try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1))).query.contains { $0.name == "filter[type]" })
        // A lookalike of a known type is unknown: compared byte for byte.
        #expect(throws: AuditQuery.Invalid.unknownType("ROLE_CREATE\u{1D403}")) {
            try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1), types: [OpenEnum("ROLE_CREATE\u{1D403}")])
        }
    }

    /// An actor or subject id is one identifier: anything that would read as another parameter, a second value or
    /// another character is refused before a read is built. What passes is still percent-encoded when the URL is made.
    @Test(arguments: ["A&filter[type]=ROLE_CREATED", "A=B", "A#B", "A%26B", "A B", "A\nB", "A\rB", "A,B", "Caf\u{E9}", "A\u{301}", "", "..", ".A",
                      String(repeating: "A", count: 129)])
    func anActorOrSubjectIDThatIsntOneIdentifierIsRefused(id: String) {
        #expect(throws: AuditQuery.Invalid.notAnID) { try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1), actorID: id) }
        #expect(throws: AuditQuery.Invalid.notAnID) { try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1), subjectID: id) }
    }

    @Test func anIdentifierIsSentAsItIsAndEveryQueryValueIsEncoded() throws {
        let query = try AuditQuery(start: Self.noon, end: Self.noon.addingTimeInterval(1), actorID: "BUSINESSAPI.a1-b_2", subjectID: "C02XK0AAJGH5")
        let read = AppleRead.auditEvents(query)
        #expect(read.query.contains(QueryItem("filter[actorId]", "BUSINESSAPI.a1-b_2")) && read.query.contains(QueryItem("filter[subjectId]", "C02XK0AAJGH5")))
        // The second line: the URL encodes every byte but RFC 3986's unreserved ones, in names and values alike.
        let url = try #require(URL.make(host: .appleBusiness, path: "/v1/auditEvents", query: [QueryItem("filter[actorId]", "a&b=c#d%e f\ng\u{E9},h")]))
        #expect(url.absoluteString == "https://api-business.apple.com/v1/auditEvents?filter%5BactorId%5D=a%26b%3Dc%23d%25e%20f%0Ag%C3%A9%2Ch")
    }

    // MARK: against the stub

    /// Apple filters, and the stub really does: the range, the types, the actor and the subject each cut the events, and
    /// the client keeps every event Apple sent (it filters nothing itself).
    @Test func applesFiltersCutTheEvents() async throws {
        let harness = try await Harness()
        harness.stub.add([
            Self.event("E1", at: -3600), Self.event("E2", at: -2 * Self.day), Self.event("E3", at: -60, type: "ROLE_CREATED"),
            Self.event("E4", at: -120, actor: "A2"), Self.event("E5", at: -180, subject: "S2"), Self.event("E6", at: 60),
        ])
        func ids(_ query: AuditQuery) async throws -> [String] { try await Harness.all(harness.client.auditEvents(query)).map(\.id) }
        let day = try AuditQuery.last(days: 1, now: Self.noon)
        #expect(try await ids(day) == ["E1", "E3", "E4", "E5"])
        #expect(try await ids(.last(days: 3, now: Self.noon)) == ["E1", "E2", "E3", "E4", "E5"])
        #expect(try await ids(.last(days: 1, now: Self.noon, types: [.known(.roleCreated)])) == ["E3"])
        #expect(try await ids(.last(days: 1, now: Self.noon, types: [.known(.roleCreated), .known(.deviceAddedToOrg)])) == ["E1", "E3", "E4", "E5"])
        #expect(try await ids(.last(days: 1, now: Self.noon, actorID: "A2")) == ["E4"])
        #expect(try await ids(.last(days: 1, now: Self.noon, subjectID: "S2")) == ["E5"])
        #expect(try await ids(.last(days: 1, now: Self.noon, actorID: "A1", subjectID: "S1")) == ["E1", "E3"])
        let read = try #require(harness.reads.last)
        #expect(read.contains("filter%5BactorId%5D=A1") && read.contains("filter%5BsubjectId%5D=S1"), "\(read)")
        let events = try await Harness.all(harness.client.auditEvents(day))
        #expect(events.first?.payload?.purchaseSourceType == .known(.apple))
    }

    /// Each next page is the first read again with Apple's cursor: the range and the filters go with every page (a next
    /// link carrying only the cursor, as Apple's examples do, would lose them and get a 400).
    @Test func everyPageKeepsTheRangeAndTheFilters() async throws {
        let harness = try await Harness()
        harness.stub.add((0..<2_500).map { Self.event("E\($0)", at: -Double($0)) })
        let query = try AuditQuery.last(days: 1, now: Self.noon, types: [.known(.deviceAddedToOrg)], actorID: "A1")
        var pages: [Page<AuditEvent>] = []
        for try await page in harness.client.auditEvents(query) { pages.append(page) }
        #expect(pages.map(\.items.count) == [1000, 1000, 500] && pages.allSatisfy { !$0.truncated })
        #expect(Set(pages.flatMap(\.items).map(\.id)).count == 2_500)
        let reads = harness.reads
        #expect(reads.count == 3)
        for read in reads {
            for part in ["filter%5BstartTimestamp%5D=2026-10-15T12%3A00%3A00Z", "filter%5BendTimestamp%5D=2026-10-16T12%3A00%3A00Z",
                         "filter%5Btype%5D=DEVICE_ADDED_TO_ORG", "filter%5BactorId%5D=A1", "limit=1000"] {
                #expect(read.contains(part), "\(read) lacks \(part)")
            }
        }
        #expect(reads.dropFirst().allSatisfy { $0.contains("cursor=") } && !reads[0].contains("cursor="))
        // What the stub's own next link says, followed as is: the range is gone, and Apple's 400 says which parameter.
        let next = try await harness.raw("/v1/auditEvents", [("cursor", "1000")])
        #expect(next.status == 400 && next.body?["errors"]?.array?.first?["source"]?["parameter"]?.string == "filter[startTimestamp]")
    }

    /// A cursor Apple gives twice is malformed: the walk stops at the second page, not at the cap 200 identical pages on.
    /// So for every list, on its next link or its cursor.
    @Test func aRepeatedCursorIsMalformedNotALoop() async throws {
        let harness = try await Harness(devices: 5)
        harness.stub.add((0..<5).map { Self.event("E\($0)", at: -Double($0)) })
        harness.stub.repeatCursors(on: "/v1/auditEvents")
        let query = try AuditQuery.last(days: 1, now: Self.noon)
        await #expect(throws: AppleAPIError.malformed("a repeated cursor on /v1/auditEvents")) { _ = try await Harness.all(harness.client.auditEvents(query)) }
        #expect(harness.reads.count == 2, "\(harness.reads)")

        harness.stub.repeatCursors(on: "/v1/orgDevices")
        await #expect(throws: AppleAPIError.malformed("a repeated cursor on /v1/orgDevices")) { _ = try await harness.allDevices() }
        #expect(harness.reads.filter { $0.contains("/v1/orgDevices") }.count == 2)

        // A cursor carried only by the next link counts too.
        let linked = try await Harness()
        linked.stub.add([Self.event("E1", at: -1)])
        let loop = #"{"data":[],"links":{"self":"x","next":"https://api-business.apple.com/v1/auditEvents?cursor=7"}}"#
        linked.stub.queue(200, for: "/v1/auditEvents", body: loop)
        linked.stub.queue(200, for: "/v1/auditEvents", body: loop)
        await #expect(throws: AppleAPIError.malformed("a repeated cursor on /v1/auditEvents")) { _ = try await Harness.all(linked.client.auditEvents(query)) }
        #expect(linked.reads.count == 2 && linked.reads[1].contains("cursor=7") && linked.reads[1].contains("filter%5BstartTimestamp%5D"))
    }

    /// A next page with no cursor to ask it by is malformed, never the end of the list; the page cap cuts a long log and
    /// says so.
    @Test func aNextPageWithoutACursorIsMalformedAndTheCapIsSaid() async throws {
        let harness = try await Harness()
        harness.stub.queue(200, for: "/v1/auditEvents", body: #"{"data":[],"links":{"self":"x","next":"https://api-business.apple.com/v1/auditEvents"}}"#)
        let query = try AuditQuery.last(days: 1, now: Self.noon)
        await #expect(throws: AppleAPIError.malformed("a next page of /v1/auditEvents without a cursor")) {
            _ = try await Harness.all(harness.client.auditEvents(query))
        }

        let capped = try await Harness(pageCap: 2)
        capped.stub.add((0..<2_001).map { Self.event("E\($0)", at: -Double($0)) })
        var last: Page<AuditEvent>?
        for try await page in capped.client.auditEvents(query) { last = page }
        #expect(last?.number == 2 && last?.truncated == true && capped.reads.count == 2)
    }

    /// The stub refuses what Apple's contract refuses: no range (each bound named), a type Apple doesn't list, a
    /// timestamp that isn't ISO 8601, a range that ends before it starts (assumed), and a parameter the endpoint lacks.
    @Test func theStubRefusesWhatTheContractRefuses() async throws {
        let harness = try await Harness()
        let start = ("filter[startTimestamp]", "2026-10-15T12:00:00Z"), end = ("filter[endTimestamp]", "2026-10-16T12:00:00Z")
        func refused(_ query: [(String, String)], code: String = "PARAMETER_ERROR.INVALID") async throws -> String? {
            let answer = try await harness.raw("/v1/auditEvents", query)
            let error = answer.body?["errors"]?.array?.first
            #expect(answer.status == 400 && error?["code"]?.string == code, "\(query)")
            return error?["source"]?["parameter"]?.string
        }
        // A missing bound is Apple's "required", not an invalid value.
        #expect(try await refused([], code: "PARAMETER_ERROR.REQUIRED") == "filter[startTimestamp]")
        #expect(try await refused([start], code: "PARAMETER_ERROR.REQUIRED") == "filter[endTimestamp]")
        #expect(try await refused([end], code: "PARAMETER_ERROR.REQUIRED") == "filter[startTimestamp]")
        #expect(try await refused([start, end, ("filter[type]", "FUTURE_TYPE")]) == "filter[type]")
        #expect(try await refused([start, end, ("filter[type]", "ROLE_CREATED,")]) == "filter[type]")
        #expect(try await refused([("filter[startTimestamp]", "yesterday"), end]) == "filter[startTimestamp]")
        #expect(try await refused([("filter[startTimestamp]", "2026-10-17T12:00:00Z"), end]) == "filter[endTimestamp]")
        #expect(try await refused([start, end, ("filter[deviceId]", "X")]) == "filter[deviceId]")
        #expect(try await refused([start, end, ("limit", "1001")]) == "limit")
        #expect(try await refused([start, end, ("cursor", "MDow")]) == "cursor")
        #expect(try await harness.raw("/v1/auditEvents", [start, end, ("filter[type]", "ROLE_CREATED,ROLE_UPDATED")]).status == 200)
    }

    /// A School org has no audit log: the read throws before anything is built, and nothing is sent.
    @Test func aSchoolOrgSendsNoAuditRead() async throws {
        let harness = try await Harness(scope: .school)
        await #expect(throws: AppleAPIError.notInScope(.auditEvents)) {
            _ = try await Harness.all(harness.client.auditEvents(.last(days: 1, now: Self.noon)))
        }
        #expect(harness.stub.requests.isEmpty)
    }
}
