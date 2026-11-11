import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport
import Wire

/// The device list's filters (Business 2.7, School 1.8): checked when made, as the audit query is, so nothing typed into
/// one reaches a query unchecked and a filter no device could match is refused in words; sent as the contract names them;
/// filtered by Apple (the strict stub really filters) and paged by cursor, the filters on every page.
@Suite("Device filters", .serialized)
struct DeviceFilterTests {
    static let noon = Date(timeIntervalSince1970: 1_792_152_000)   // 2026-10-16T12:00:00Z
    static let day: TimeInterval = 86_400
    typealias DateFilter = DeviceFilter.DateFilter

    static func device(_ serial: String, status: String = "ASSIGNED", family: String = "Mac", source: String = "APPLE", order: String = "O1",
                       added: TimeInterval = 0, ordered: TimeInterval = -30 * 86_400) -> Resource {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "status": .string(status), "productFamily": .string(family), "purchaseSourceType": .string(source),
            "orderNumber": .string(order), "addedToOrgDateTime": .string(format.string(from: noon.addingTimeInterval(added))),
            "orderDateTime": .string(format.string(from: noon.addingTimeInterval(ordered))),
        ])
    }

    /// Every filter set, in the contract's order of attributes, each list joined by commas, every date whole seconds in
    /// UTC with `Z`, then the limit; with nothing set, the limit alone, as before 2.7.
    @Test func everyFilterGoesOutAsTheContractNamesIt() throws {
        let filter = try DeviceFilter(
            serialNumbers: ["C02A", "C02B"], orderNumbers: ["O-1"], statuses: [OpenEnum(.unassigned)], productFamilies: [OpenEnum(.mac), OpenEnum(.iPad)],
            purchaseSourceTypes: [OpenEnum(.reseller)],
            addedToOrg: DateFilter(exactly: [Self.noon.addingTimeInterval(0.6)], lower: .atOrAfter(Self.noon.addingTimeInterval(-Self.day)),
                                   upper: .before(Self.noon.addingTimeInterval(Self.day))),
            ordered: DateFilter(lower: .after(Self.noon.addingTimeInterval(-2 * Self.day)), upper: .atOrBefore(Self.noon)))
        for scope in [Scope.business, .school] {
            let read = AppleRead.devices(scope, matching: filter)
            #expect(read.path == "/v1/orgDevices" && read.host == (scope == .business ? .appleBusiness : .appleSchool))
            #expect(read.query == [
                QueryItem("filter[serialNumber]", "C02A,C02B"), QueryItem("filter[status]", "UNASSIGNED"), QueryItem("filter[productFamily]", "Mac,iPad"),
                QueryItem("filter[purchaseSourceType]", "RESELLER"), QueryItem("filter[orderNumber]", "O-1"),
                QueryItem("filter[addedToOrgDateTime]", "2026-10-16T12:00:00Z"), QueryItem("filter[addedToOrgDateTime][GTE]", "2026-10-15T12:00:00Z"),
                QueryItem("filter[addedToOrgDateTime][LT]", "2026-10-17T12:00:00Z"), QueryItem("filter[orderDateTime][GT]", "2026-10-14T12:00:00Z"),
                QueryItem("filter[orderDateTime][LTE]", "2026-10-16T12:00:00Z"), QueryItem("limit", "1000"),
            ])
        }
        #expect(AppleRead.devices(.business).query == [QueryItem("limit", "1000")])
        let none = try DeviceFilter()
        #expect(DeviceFilter.all.isEmpty && !filter.isEmpty && none == .all)
        // The other side of each bound.
        let other = try DeviceFilter(addedToOrg: DateFilter(lower: .after(Self.noon), upper: .atOrBefore(Self.noon.addingTimeInterval(1))),
                                     ordered: DateFilter(lower: .atOrAfter(Self.noon), upper: .before(Self.noon.addingTimeInterval(1))))
        #expect(AppleRead.devices(.business, matching: other).query.map(\.name) == [
            "filter[addedToOrgDateTime][GT]", "filter[addedToOrgDateTime][LTE]", "filter[orderDateTime][GTE]", "filter[orderDateTime][LT]", "limit"])
    }

    /// Every name the filter can send is one the contract documents for the device list, both scopes, and the filter
    /// covers all fifteen.
    @Test func theFilterSendsExactlyTheContractsFilters() throws {
        let every = try DeviceFilter(
            serialNumbers: ["C02A"], orderNumbers: ["O1"], statuses: [OpenEnum(.assigned)], productFamilies: [OpenEnum(.iPod)],
            purchaseSourceTypes: [OpenEnum(.apple)], addedToOrg: DateFilter(exactly: [Self.noon], lower: .atOrAfter(Self.noon)),
            ordered: DateFilter(exactly: [Self.noon], lower: .atOrAfter(Self.noon)))
        let more = try DeviceFilter(addedToOrg: DateFilter(lower: .after(Self.noon), upper: .before(Self.noon.addingTimeInterval(9))),
                                    ordered: DateFilter(lower: .after(Self.noon), upper: .before(Self.noon.addingTimeInterval(9))))
        let last = try DeviceFilter(addedToOrg: DateFilter(upper: .atOrBefore(Self.noon)), ordered: DateFilter(upper: .atOrBefore(Self.noon)))
        let sent = Set([every, more, last].flatMap { AppleRead.devices(.business, matching: $0).query.map(\.name) })
        for scope in [Scope.business, .school] {
            let endpoint = try #require(ReadContractTests.endpoints(scope).first { $0["path"] as? String == "/v1/orgDevices" && $0["method"] as? String == "GET" })
            let filters = Set((endpoint["parameters"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.filter { $0.hasPrefix("filter[") })
            #expect(filters.count == 15 && sent.subtracting(["limit"]) == filters, "\(scope): \(filters.symmetricDifference(sent).sorted())")
        }
    }

    /// A serial or order number is one identifier of `isPathSafe`'s shape: a comma (a second value), `&`, `=`, `#`, `%`, a
    /// blank, a line break, anything non-ASCII, a leading dot, nothing or more than 128 characters is refused, and the
    /// words say what's allowed without repeating what was typed.
    @Test(arguments: ["C02A,C02B", "C02A&limit=1", "a=b", "C02#", "C02%2C", "C02 A", "C02\nA", "C02\u{212A}", "\u{FF23}02", ".hidden", "",
                      String(repeating: "A", count: 129)])
    func anIdentifierThatIsntOneIsRefused(id: String) {
        #expect(throws: DeviceFilter.Invalid.notAnIdentifier(.serialNumber)) { try DeviceFilter(serialNumbers: ["C02OK", id]) }
        #expect(throws: DeviceFilter.Invalid.notAnIdentifier(.orderNumber)) { try DeviceFilter(orderNumbers: [id]) }
        let words = DeviceFilter.Invalid.notAnIdentifier(.serialNumber).message
        #expect(words == "A serial number to filter on can only be letters, digits, -, _ and . (not first), 1 to 128 of them: one per entry, never joined by commas.")
        #expect(DeviceFilter.Invalid.notAnIdentifier(.orderNumber).message.hasPrefix("An order number to filter on can only be"))
        #expect(throws: Never.self) { _ = try DeviceFilter(serialNumbers: [String(repeating: "A", count: 128), "A-1_b.2"], orderNumbers: ["O-1.a_2"]) }
    }

    /// At most 100 serial numbers, and 100 order numbers, each counted once, until Apple's own limit is checked live: one
    /// more is refused in words that never repeat a value (the contract-2.8 review's L6: any number went into one URL).
    @Test func aFilterTakesAtMostAHundredOfEachIdentifier() throws {
        let hundred = (0..<100).map { String(format: "C02%05d", $0) }
        #expect(DeviceFilter.maximumIdentifiers == 100)
        #expect(try DeviceFilter(serialNumbers: hundred, orderNumbers: hundred).serialNumbers.count == 100)
        #expect(try DeviceFilter(serialNumbers: hundred + [hundred[0], hundred[99]]).serialNumbers == hundred, "a repeat isn't another")
        #expect(throws: DeviceFilter.Invalid.tooMany(.serialNumber)) { try DeviceFilter(serialNumbers: hundred + ["C02X"]) }
        #expect(throws: DeviceFilter.Invalid.tooMany(.orderNumber)) { try DeviceFilter(orderNumbers: hundred + ["O-1"]) }
        #expect(throws: DeviceFilter.Invalid.notAnIdentifier(.serialNumber), "the shape is checked first") {
            try DeviceFilter(serialNumbers: hundred + ["C02X", "a,b"])
        }
        #expect(DeviceFilter.Invalid.tooMany(.serialNumber).message
                == "At most 100 different serial numbers can be filtered on at once: filter on fewer, or on something else.")
        #expect(DeviceFilter.Invalid.tooMany(.orderNumber).message
                == "At most 100 different order numbers can be filtered on at once: filter on fewer, or on something else.")
    }

    /// Where Apple's next link and `meta.paging.nextCursor` name different cursors, the cursor is `nextCursor`'s, the field
    /// Apple documents as the cursor; with only a link, the link's (mutant C5, the link's preferred, survived the review).
    @Test func theCursorIsMetaPagingsWhereTheNextLinkDiffers() async throws {
        for (paging, link, cursor) in [(#","meta":{"paging":{"limit":1000,"nextCursor":"1"}}"#, "2", "1"), ("", "1", "1")] {
            let harness = try await Harness(devices: 3)
            harness.stub.queue(200, for: "/v1/orgDevices", body: #"""
                {"data":[{"type":"orgDevices","id":"TESTD0000000","attributes":{"serialNumber":"TESTD0000000"}}],
                 "links":{"self":"https://api-business.apple.com/v1/orgDevices","next":"https://api-business.apple.com/v1/orgDevices?cursor=\#(link)"}\#(paging)}
                """#)
            #expect(try await Self.ids(harness, .all) == ["TESTD0000000", "TESTD0000001", "TESTD0000002"], "\(paging)")
            #expect(harness.reads.filter { $0.contains("/v1/orgDevices?") }.last == "GET api-business.apple.com/v1/orgDevices?limit=1000&cursor=\(cursor)")
        }
    }

    /// Apple's values only: an `.unknown` one (read from a device, say) throws, never goes out; each value once, in the order
    /// given, and identifiers each once by their bytes.
    @Test func onlyApplesValuesGoOutEachOnce() throws {
        #expect(throws: DeviceFilter.Invalid.unknownValue(.status, "PENDING_RELEASE")) { try DeviceFilter(statuses: [OpenEnum("PENDING_RELEASE")]) }
        #expect(throws: DeviceFilter.Invalid.unknownValue(.productFamily, "Glasses")) { try DeviceFilter(productFamilies: [OpenEnum(.mac), OpenEnum("Glasses")]) }
        #expect(throws: DeviceFilter.Invalid.unknownValue(.purchaseSourceType, "GIFT")) { try DeviceFilter(purchaseSourceTypes: [OpenEnum("GIFT")]) }
        // A lookalike of Apple's value is no value of Apple's (`OpenEnum` matches bytes).
        #expect(throws: DeviceFilter.Invalid.unknownValue(.productFamily, "\u{FF2D}ac")) { try DeviceFilter(productFamilies: [OpenEnum("\u{FF2D}ac")]) }
        #expect(DeviceFilter.Invalid.unknownValue(.status, "PENDING_RELEASE").message
                == "This version doesn't know one of the values asked for as the status, so it can't filter on it.")
        let filter = try DeviceFilter(serialNumbers: ["B", "A", "B"], orderNumbers: ["O2", "O1", "O2"],
                                      statuses: [OpenEnum("UNASSIGNED"), OpenEnum(.assigned), OpenEnum(.unassigned)],
                                      productFamilies: [OpenEnum(.vision), OpenEnum(.vision), OpenEnum(.appleTV)],
                                      purchaseSourceTypes: [OpenEnum(.manuallyAdded), OpenEnum(.manuallyAdded)])
        #expect(filter.serialNumbers == ["B", "A"] && filter.orderNumbers == ["O2", "O1"])
        #expect(filter.statuses == [.unassigned, .assigned] && filter.productFamilies == [.vision, .appleTV] && filter.purchaseSourceTypes == [.manuallyAdded])
    }

    /// Each date is cut to whole seconds and must be one `YYYY-MM-DDTHH:MM:SSZ` can say, 1970 to 9999, in every place a
    /// date goes; duplicates of an exact instant go after the cut.
    @Test func everyDateIsWholeSecondsFrom1970To9999() throws {
        let latest = Date(timeIntervalSince1970: 253_402_300_799)
        let bad = [Date(timeIntervalSince1970: -1), latest.addingTimeInterval(1), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)]
        for date in bad {
            for (field, make) in [(DeviceFilter.Field.addedToOrgDateTime, { (f: DateFilter) in try DeviceFilter(addedToOrg: f) }),
                                  (.orderDateTime, { (f: DateFilter) in try DeviceFilter(ordered: f) })] as [(DeviceFilter.Field, (DateFilter) throws -> DeviceFilter)] {
                for filter in [DateFilter(exactly: [date]), DateFilter(lower: .after(date)), DateFilter(lower: .atOrAfter(date)),
                               DateFilter(upper: .before(date)), DateFilter(upper: .atOrBefore(date))] {
                    #expect(throws: DeviceFilter.Invalid.outOfRange(field), "\(date) \(filter)") { try make(filter) }
                }
            }
        }
        let edges = try DeviceFilter(addedToOrg: DateFilter(exactly: [Date(timeIntervalSince1970: 0), latest, Date(timeIntervalSince1970: 0.9)]))
        #expect(edges.addedToOrg.exactly == [Date(timeIntervalSince1970: 0), latest])
        #expect(AppleRead.devices(.business, matching: edges).query.first == QueryItem("filter[addedToOrgDateTime]", "1970-01-01T00:00:00Z,9999-12-31T23:59:59Z"))
        #expect(DeviceFilter.Invalid.outOfRange(.orderDateTime).message == "An order date to filter on is before 1970 or after 9999.")
        #expect(DeviceFilter.Invalid.outOfRange(.addedToOrgDateTime).message == "A date added to the organization to filter on is before 1970 or after 9999.")
    }

    /// Bounds no device could fall between are refused, in words: a lower bound past the upper one, or at it while either
    /// leaves that instant out; the same instant at both ends, both taken in, is one instant and fine. Checked after the
    /// cut to whole seconds.
    @Test func boundsThatContradictEachOtherAreRefused() throws {
        let at = Self.noon, before = Self.noon.addingTimeInterval(-1)
        let empty: [DateFilter] = [
            DateFilter(lower: .after(at), upper: .before(at)), DateFilter(lower: .atOrAfter(at), upper: .before(at)),
            DateFilter(lower: .after(at), upper: .atOrBefore(at)), DateFilter(lower: .atOrAfter(at), upper: .atOrBefore(before)),
            DateFilter(lower: .after(at), upper: .before(before)), DateFilter(lower: .after(at), upper: .atOrBefore(before)),
            DateFilter(lower: .atOrAfter(at.addingTimeInterval(0.2)), upper: .before(at.addingTimeInterval(0.9))),
        ]
        for filter in empty {
            #expect(throws: DeviceFilter.Invalid.emptyRange(.addedToOrgDateTime), "\(filter)") { try DeviceFilter(addedToOrg: filter) }
            #expect(throws: DeviceFilter.Invalid.emptyRange(.orderDateTime), "\(filter)") { try DeviceFilter(ordered: filter) }
        }
        for filter in [DateFilter(lower: .atOrAfter(at), upper: .atOrBefore(at)), DateFilter(lower: .after(before), upper: .before(at.addingTimeInterval(1))),
                       DateFilter(lower: .atOrAfter(before), upper: .before(at)), DateFilter(lower: .after(before), upper: .atOrBefore(at))] {
            #expect(throws: Never.self, "\(filter)") { _ = try DeviceFilter(addedToOrg: filter) }
        }
        #expect(DeviceFilter.Invalid.emptyRange(.addedToOrgDateTime).message
                == "The range of the date added to the organization ends before it starts, so no device could match.")
    }

    /// An instant asked for exactly must be inside the bounds given with it, at each bound's edge as each says; else it
    /// could never match, and that is refused in words.
    @Test func anExactInstantOutsideItsBoundsIsRefused() throws {
        let at = Self.noon
        let outside: [DateFilter] = [
            DateFilter(exactly: [at], lower: .after(at)), DateFilter(exactly: [at], upper: .before(at)),
            DateFilter(exactly: [at.addingTimeInterval(-1)], lower: .atOrAfter(at)), DateFilter(exactly: [at.addingTimeInterval(1)], upper: .atOrBefore(at)),
            DateFilter(exactly: [at, at.addingTimeInterval(5)], lower: .atOrAfter(at), upper: .before(at.addingTimeInterval(5))),
        ]
        for filter in outside {
            #expect(throws: DeviceFilter.Invalid.outsideItsRange(.orderDateTime), "\(filter)") { try DeviceFilter(ordered: filter) }
        }
        for filter in [DateFilter(exactly: [at], lower: .atOrAfter(at)), DateFilter(exactly: [at], upper: .atOrBefore(at)),
                       DateFilter(exactly: [at], lower: .after(at.addingTimeInterval(-1)), upper: .before(at.addingTimeInterval(1)))] {
            #expect(throws: Never.self, "\(filter)") { _ = try DeviceFilter(ordered: filter) }
        }
        #expect(DeviceFilter.Invalid.outsideItsRange(.orderDateTime).message
                == "An order date asked for exactly is outside the range given with it, so it could never match.")
    }

    // MARK: through the strict stub

    static func harness(scope: Scope = .business) async throws -> Harness {
        let harness = try await Harness(scope: scope)
        harness.stub.add(devices: [
            device("D1", status: "ASSIGNED", family: "Mac", source: "APPLE", order: "O1", added: -3 * day, ordered: -40 * day),
            device("D2", status: "UNASSIGNED", family: "iPad", source: "RESELLER", order: "O2", added: -2 * day, ordered: -20 * day),
            device("D3", status: "UNASSIGNED", family: "iPhone", source: "MANUALLY_ADDED", order: "O2", added: -1 * day, ordered: -10 * day),
            device("D4", status: "ASSIGNED", family: "iPod", source: "APPLE", order: "O3", added: 0, ordered: 0),
            Resource(type: "orgDevices", id: "D5", attributes: ["serialNumber": .string("D5")]),
        ])
        return harness
    }

    static func ids(_ harness: Harness, _ filter: DeviceFilter) async throws -> [String] {
        try await Harness.all(harness.client.devices(matching: filter)).map(\.id)
    }

    /// Apple filters, so the stub really does: each of the fifteen narrows the list as its description says, a device
    /// without the attribute passes none, a list's values widen each other, and filters narrow each other.
    @Test func theStubFiltersByEachFilter() async throws {
        let harness = try await Self.harness()
        let day = Self.day, noon = Self.noon
        let cases: [(DeviceFilter, [String])] = [
            (.all, ["D1", "D2", "D3", "D4", "D5"]),
            (try DeviceFilter(serialNumbers: ["D2", "D4", "D9"]), ["D2", "D4"]),
            (try DeviceFilter(orderNumbers: ["O2"]), ["D2", "D3"]),
            (try DeviceFilter(statuses: [OpenEnum(.unassigned)]), ["D2", "D3"]),
            (try DeviceFilter(productFamilies: [OpenEnum(.iPod), OpenEnum(.mac)]), ["D1", "D4"]),
            (try DeviceFilter(purchaseSourceTypes: [OpenEnum(.reseller)]), ["D2"]),
            (try DeviceFilter(addedToOrg: DateFilter(exactly: [noon.addingTimeInterval(-2 * day)])), ["D2"]),
            (try DeviceFilter(addedToOrg: DateFilter(lower: .after(noon.addingTimeInterval(-2 * day)))), ["D3", "D4"]),
            (try DeviceFilter(addedToOrg: DateFilter(lower: .atOrAfter(noon.addingTimeInterval(-2 * day)))), ["D2", "D3", "D4"]),
            (try DeviceFilter(addedToOrg: DateFilter(upper: .before(noon.addingTimeInterval(-2 * day)))), ["D1"]),
            (try DeviceFilter(addedToOrg: DateFilter(upper: .atOrBefore(noon.addingTimeInterval(-2 * day)))), ["D1", "D2"]),
            (try DeviceFilter(ordered: DateFilter(exactly: [noon.addingTimeInterval(-10 * day), noon])), ["D3", "D4"]),
            (try DeviceFilter(ordered: DateFilter(lower: .after(noon.addingTimeInterval(-20 * day)))), ["D3", "D4"]),
            (try DeviceFilter(ordered: DateFilter(lower: .atOrAfter(noon.addingTimeInterval(-20 * day)))), ["D2", "D3", "D4"]),
            (try DeviceFilter(ordered: DateFilter(upper: .before(noon.addingTimeInterval(-20 * day)))), ["D1"]),
            (try DeviceFilter(ordered: DateFilter(upper: .atOrBefore(noon.addingTimeInterval(-20 * day)))), ["D1", "D2"]),
            (try DeviceFilter(orderNumbers: ["O2"], statuses: [OpenEnum(.unassigned)], productFamilies: [OpenEnum(.iPad)]), ["D2"]),
            (try DeviceFilter(statuses: [OpenEnum(.assigned)], addedToOrg: DateFilter(lower: .atOrAfter(noon.addingTimeInterval(-1 * day)))), ["D4"]),
        ]
        for (filter, expected) in cases {
            #expect(try await Self.ids(harness, filter) == expected, "\(filter)")
        }
    }

    /// The filtered list pages by cursor: each later page is the first read again with Apple's cursor, so the filter goes
    /// with every page and the list never widens past it, though the stub's next link carries the cursor alone (as Apple's
    /// unfiltered example does).
    @Test func aFilteredListKeepsItsFilterOnEveryPage() async throws {
        let harness = try await Harness()
        harness.stub.add(devices: (0..<2_500).map { Self.device(String(format: "TESTF%07d", $0), status: $0 % 5 == 0 ? "ASSIGNED" : "UNASSIGNED") })
        let unassigned = try await Self.ids(harness, try DeviceFilter(statuses: [OpenEnum(.unassigned)]))
        #expect(unassigned.count == 2_000 && Set(unassigned).count == 2_000)
        let reads = harness.reads.filter { $0.contains("/v1/orgDevices?") }
        #expect(reads == ["GET api-business.apple.com/v1/orgDevices?filter%5Bstatus%5D=UNASSIGNED&limit=1000",
                          "GET api-business.apple.com/v1/orgDevices?filter%5Bstatus%5D=UNASSIGNED&limit=1000&cursor=1000"], "\(reads)")
        // Unfiltered, the same walk: the first read again, a cursor at a time.
        #expect(try await harness.allDevices().count == 2_500)
        #expect(harness.reads.filter { $0.contains("/v1/orgDevices?limit=1000") }.suffix(3) == [
            "GET api-business.apple.com/v1/orgDevices?limit=1000", "GET api-business.apple.com/v1/orgDevices?limit=1000&cursor=1000",
            "GET api-business.apple.com/v1/orgDevices?limit=1000&cursor=2000"])
    }

    /// A School org's device list takes the same filters (School 1.8), on its own host.
    @Test func aSchoolOrgFiltersItsDevicesToo() async throws {
        let harness = try await Self.harness(scope: .school)
        #expect(try await Self.ids(harness, try DeviceFilter(statuses: [OpenEnum(.unassigned)])) == ["D2", "D3"])
        #expect(harness.reads.contains("GET api-school.apple.com/v1/orgDevices?filter%5Bstatus%5D=UNASSIGNED&limit=1000"))
    }

    /// The stub refuses what Apple's contract says only in prose: a value outside a filter's described list (an empty one
    /// too), a date that isn't ISO 8601, and a bound given two dates. Each a 400 naming the parameter.
    @Test func theStubRefusesWhatTheDescriptionsRefuse() async throws {
        let harness = try await Self.harness()
        let refusals: [(String, String)] = [
            ("filter[status]", "PENDING"), ("filter[status]", ""), ("filter[status]", "ASSIGNED,"), ("filter[productFamily]", "mac"),
            ("filter[productFamily]", "Glasses"), ("filter[purchaseSourceType]", "GIFT"), ("filter[addedToOrgDateTime]", "2025-01-01"),
            ("filter[addedToOrgDateTime][GT]", "yesterday"), ("filter[orderDateTime][LTE]", "2025-01-01T00:00:00Z,2025-02-01T00:00:00Z"),
            ("filter[orderDateTime]", "2025-01-01T00:00:00Z,soon"),
        ]
        for (name, value) in refusals {
            let answer = try await harness.raw("/v1/orgDevices", [(name, value)])
            #expect(answer.status == 400 && answer.body?["errors"]?.array?.first?["source"]?["parameter"]?.string == name, "\(name)=\(value)")
        }
        for (name, value) in [("filter[productFamily]", "iPod,AppleTV"), ("filter[orderDateTime]", "2025-01-01T00:00:00Z,2025-02-01T00:00:00.5Z"),
                              ("filter[serialNumber]", "D1,D2"), ("filter[addedToOrgDateTime][GTE]", "2025-01-01T00:00:00.000Z")] {
            #expect(try await harness.raw("/v1/orgDevices", [(name, value)]).status == 200, "\(name)=\(value)")
        }
    }
}
