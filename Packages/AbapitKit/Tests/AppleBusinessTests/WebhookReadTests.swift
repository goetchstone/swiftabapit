@testable import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import OSLog
import Orgs
import Testing
import TestSupport
import Wire

/// The webhook reads (Business 2.8) through the strict stub: the list, one webhook, and a webhook's deliveries with the
/// events they sent, filtered by Apple and paged by cursor; a School org sends none. A webhook's URL, a delivery's request
/// URL, its response body and error message and an event's payload never reach the acceptance pass's text or a log line,
/// and a secret Apple should never send is counted as an unknown key, never printed (invariant 11).
@Suite("Webhook reads", .serialized)
struct WebhookReadTests {
    static let noon = Date(timeIntervalSince1970: 1_792_152_000)   // 2026-10-16T12:00:00Z
    static let hour: TimeInterval = 3_600

    static func stamp(_ offset: TimeInterval, from base: Date = noon) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: base.addingTimeInterval(offset))
    }

    static func webhook(_ id: String, url: String = "https://hooks.example.com/in", extra: JSONObject = [:]) -> Resource {
        let attributes: JSONObject = ["name": .string("Device changes"), "enabled": .bool(true), "url": .string(url),
                                      "eventTypes": .array([.string("ORG_DEVICE_ATTRIBUTE_CHANGED")])]
        return Resource(type: "webhooks", id: id, attributes: attributes.merging(extra))
    }

    static func delivery(_ id: String, at offset: TimeInterval, state: String = "SUCCEEDED", event: String? = nil, base: Date = noon,
                         extra: JSONObject = [:]) -> Resource {
        let attributes: JSONObject = [
            "createdDateTime": .string(stamp(offset, from: base)), "deliveryState": .string(state), "redelivery": .bool(false),
            "request": .object(["url": .string("https://hooks.example.com/in")]), "response": .object(["httpStatusCode": .number("200")]),
        ]
        return Resource(type: "webhookDeliveries", id: id, attributes: attributes.merging(extra),
                        relationships: event.map { ["event": .object(["data": .object(["type": .string("webhookEvents"), "id": .string($0)])])] } ?? [:])
    }

    static func event(_ id: String, serial: String = "XABC123DEF4", payload: String? = nil) -> Resource {
        Resource(type: "webhookEvents", id: id, attributes: [
            "createdDateTime": .string(stamp(0)), "eventType": .string("ORG_DEVICE_ATTRIBUTE_CHANGED"), "isPingEvent": .bool(false),
            "payload": .string(payload ?? #"{"data":{"type":"orgDeviceAttributeChanged","id":"\#(id)-p","version":1,"attributes":{"orgDeviceSerialNumber":"\#(serial)"},"relationships":{"instance":{"data":{"type":"orgDevices","id":"\#(serial)"}}}}}"#),
        ])
    }

    /// The list and one webhook, as Apple's examples hold them: each shows its URL only as where it goes, and an attribute
    /// Apple documents as write-only (the secret) is withheld; an unknown webhook is Apple's 404.
    @Test func theWebhooksRead() async throws {
        let harness = try await Harness()
        harness.stub.add(try Harness.example("get-webhooks") + [Self.webhook("W2", url: "https://hooks.example.com/T0/CANARYURL",
                                                                               extra: ["secret": .string("CANARYSECRET")])])
        let webhooks = try await Harness.all(harness.client.webhooks())
        #expect(webhooks.map(\.id) == ["webhook-12345", "W2"])
        #expect(webhooks.map(\.destination) == ["https://example.com/… (tag \(WebhookURL.tag("https://example.com/webhooks/apple")))",
                                                 "https://hooks.example.com/… (tag \(WebhookURL.tag("https://hooks.example.com/T0/CANARYURL")))"])
        #expect(webhooks[1].attributes["secret"] == .string(Webhook.withheld) && webhooks[1].unreadAttributes == ["secret"])
        let one = try await harness.client.webhook("W2")
        #expect(one.name == "Device changes" && one.isEnabled == true && one.eventTypes == [.known(.orgDeviceAttributeChanged)])
        #expect(!"\(one)".contains("CANARY") && !"\(webhooks)".contains("CANARY"))
        await #expect(throws: AppleAPIError.notFound) { _ = try await harness.client.webhook("W9") }
        #expect(harness.reads.map { $0.replacingOccurrences(of: "api-business.apple.com", with: "") } == [
            "GET /v1/webhooks?limit=1000", "GET /v1/webhooks/W2", "GET /v1/webhooks/W9"])
    }

    /// A webhook's deliveries come with the events they sent, matched by id from `included`; one whose event Apple didn't
    /// include, or that names none, says which it named, never a wrong event. Each event's payload reads typed.
    @Test func aWebhooksDeliveriesComeWithTheirEvents() async throws {
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1"), Self.webhook("W2")])
        harness.stub.add([Self.delivery("D1", at: 0, event: "E1"), Self.delivery("D2", at: 1, event: "E9"), Self.delivery("D3", at: 2),
                          Self.delivery("D4", at: 3, event: "E2"), Self.delivery("D5", at: 4, event: "E1")])
        harness.stub.add([Self.event("E1", serial: "TESTD0000001"), Self.event("E2", serial: "TESTD0000002")])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["D1", "D2", "D3", "D4"])
        harness.stub.relate("webhooks", "W2", "deliveries", to: ["D5"])
        let deliveries = try await Harness.all(harness.client.webhookDeliveries("W1"))
        #expect(deliveries.map(\.id) == ["D1", "D2", "D3", "D4"])
        #expect(deliveries.map(\.eventID) == ["E1", "E9", nil, "E2"] && deliveries.map { $0.event?.id } == ["E1", nil, nil, "E2"])
        #expect(deliveries.map { $0.event?.payload?.serialNumber } == ["TESTD0000001", nil, nil, "TESTD0000002"])
        #expect(deliveries[0].event?.eventType == .known(.orgDeviceAttributeChanged) && deliveries[0].state == .known(.succeeded))
        #expect(deliveries[0].request?.destination == "https://hooks.example.com/… (tag \(WebhookURL.tag("https://hooks.example.com/in")))"
                && deliveries[0].response?.statusCode == 200)
        #expect(try await Harness.all(harness.client.webhookDeliveries("W2")).map { $0.event?.id } == ["E1"])
        // JSON:API includes a resource once however many name it (the stub too): W1's page names E1 and E2, and E9, which
        // isn't held, so it isn't included.
        harness.stub.relate("webhooks", "W2", "deliveries", to: ["D5", "D1", "D4", "D5"])
        let raw = try await harness.raw("/v1/webhooks/W2/deliveries", [("include", "event")])
        #expect(raw.body?["included"]?.array?.compactMap { $0["id"]?.string } == ["E1", "E2"])
        let page = try await harness.raw("/v1/webhooks/W1/deliveries", [("include", "event")])
        #expect(page.body?["included"]?.array?.compactMap { $0["id"]?.string } == ["E1", "E2"])
        #expect(try await harness.raw("/v1/webhooks/W1/deliveries").body?["included"] == nil, "only when asked")
        #expect(harness.reads.first == "GET api-business.apple.com/v1/webhooks/W1/deliveries?include=event&limit=1000")
        await #expect(throws: AppleAPIError.notFound) { _ = try await Harness.all(harness.client.webhookDeliveries("W9")) }
    }

    /// The query goes out as the contract names it, every page; Apple filters, so the stub really does: at or after the
    /// start, before the end, in a listed state.
    @Test func theDeliveriesFiltersGoOutAndAreApplied() async throws {
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        harness.stub.add([Self.delivery("D1", at: -2 * Self.hour, state: "FAILED"), Self.delivery("D2", at: -Self.hour, state: "SUCCEEDED"),
                          Self.delivery("D3", at: 0, state: "PENDING"), Self.delivery("D4", at: Self.hour, state: "FAILED"),
                          Resource(type: "webhookDeliveries", id: "D5", attributes: ["deliveryState": .string("FAILED")])])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["D1", "D2", "D3", "D4", "D5"])
        let cases: [(WebhookDeliveryQuery, [String])] = [
            (.all, ["D1", "D2", "D3", "D4", "D5"]),
            (try WebhookDeliveryQuery(createdAtOrAfter: Self.noon.addingTimeInterval(-Self.hour)), ["D2", "D3", "D4"]),
            (try WebhookDeliveryQuery(createdBefore: Self.noon), ["D1", "D2"]),
            (try WebhookDeliveryQuery(createdAtOrAfter: Self.noon.addingTimeInterval(-Self.hour), createdBefore: Self.noon.addingTimeInterval(Self.hour)),
             ["D2", "D3"]),
            (try WebhookDeliveryQuery(states: [OpenEnum(.failed)]), ["D1", "D4", "D5"]),
            (try WebhookDeliveryQuery(createdBefore: Self.noon.addingTimeInterval(2 * Self.hour), states: [OpenEnum(.pending), OpenEnum(.failed)]),
             ["D1", "D3", "D4"]),
        ]
        for (query, expected) in cases {
            #expect(try await Harness.all(harness.client.webhookDeliveries("W1", query)).map(\.id) == expected, "\(query)")
        }
        let read = try #require(AppleRead.webhookDeliveries(id: "W1", try WebhookDeliveryQuery(
            createdAtOrAfter: Self.noon.addingTimeInterval(0.7), createdBefore: Self.noon.addingTimeInterval(Self.hour),
            states: [OpenEnum(.failed), OpenEnum("SUCCEEDED"), OpenEnum(.failed)])))
        #expect(read.template == "/v1/webhooks/{id}/deliveries" && read.path == "/v1/webhooks/W1/deliveries" && read.host == .appleBusiness)
        #expect(read.query == [QueryItem("filter[createdDateTimeAtBefore]", "2026-10-16T13:00:00Z"),
                               QueryItem("filter[createdDateTimeAtOrAfter]", "2026-10-16T12:00:00Z"),
                               QueryItem("filter[deliveryState]", "FAILED,SUCCEEDED"), QueryItem("include", "event"), QueryItem("limit", "1000")])
        #expect(AppleRead.webhookDeliveries(id: "W1")?.query == [QueryItem("include", "event"), QueryItem("limit", "1000")])
    }

    /// The query is checked when made: whole seconds between 1970 and 9999, the start before the end after the cut, Apple's
    /// states only, each once. Each refusal in words that never repeat the value.
    @Test func aDeliveriesQueryIsCheckedWhenMade() throws {
        let latest = Date(timeIntervalSince1970: 253_402_300_799)
        for bad in [Date(timeIntervalSince1970: -1), latest.addingTimeInterval(1), Date(timeIntervalSince1970: .nan)] {
            #expect(throws: WebhookDeliveryQuery.Invalid.outOfRange) { try WebhookDeliveryQuery(createdAtOrAfter: bad) }
            #expect(throws: WebhookDeliveryQuery.Invalid.outOfRange) { try WebhookDeliveryQuery(createdBefore: bad) }
        }
        #expect(throws: WebhookDeliveryQuery.Invalid.emptyRange) { try WebhookDeliveryQuery(createdAtOrAfter: Self.noon, createdBefore: Self.noon) }
        #expect(throws: WebhookDeliveryQuery.Invalid.emptyRange) {
            try WebhookDeliveryQuery(createdAtOrAfter: Self.noon.addingTimeInterval(0.2), createdBefore: Self.noon.addingTimeInterval(0.9))
        }
        #expect(throws: WebhookDeliveryQuery.Invalid.emptyRange) { try WebhookDeliveryQuery(createdAtOrAfter: Self.noon, createdBefore: Self.noon.addingTimeInterval(-1)) }
        #expect(throws: Never.self) { _ = try WebhookDeliveryQuery(createdAtOrAfter: Self.noon, createdBefore: Self.noon.addingTimeInterval(1)) }
        #expect(throws: Never.self) { _ = try WebhookDeliveryQuery(createdAtOrAfter: Date(timeIntervalSince1970: 0), createdBefore: latest) }
        #expect(throws: WebhookDeliveryQuery.Invalid.unknownState("RETRYING")) { try WebhookDeliveryQuery(states: [OpenEnum(.failed), OpenEnum("RETRYING")]) }
        #expect(try WebhookDeliveryQuery(states: [OpenEnum(.pending), OpenEnum(.pending), OpenEnum(.succeeded)]).states == [.pending, .succeeded])
        #expect(WebhookDeliveryQuery.Invalid.unknownState("RETRYING").message
                == "This version doesn't know one of the delivery states asked for, so it can't filter on it.")
        #expect(WebhookDeliveryQuery.Invalid.emptyRange.message == "The range of deliveries ends before it starts, so none could match.")
        #expect(WebhookDeliveryQuery.Invalid.outOfRange.message == "A date to read deliveries from or to is before 1970 or after 9999.")
        let last = try WebhookDeliveryQuery.last(days: 1, now: Self.noon.addingTimeInterval(0.5))
        #expect(last.createdAtOrAfter == Self.noon.addingTimeInterval(-86_400) && last.createdBefore == nil && last.states.isEmpty)
        #expect(WebhookDeliveryQuery.all.createdAtOrAfter == nil && WebhookDeliveryQuery.all.createdBefore == nil && WebhookDeliveryQuery.all.states.isEmpty)
    }

    /// Past a page, each next page is the first read again with Apple's cursor: the filters and the include go with every
    /// page, and each page's events come with it. A cursor Apple gives twice is malformed; the page cap cuts the walk.
    @Test func theDeliveriesPageByCursorWithTheirFilters() async throws {
        let harness = try await Harness(pageCap: 3)
        harness.stub.add([Self.webhook("W1")])
        let ids = (0..<2_500).map { String(format: "D%05d", $0) }
        harness.stub.add(ids.enumerated().map { Self.delivery($1, at: Double($0), state: "FAILED", event: "E\($0 % 3)") })
        harness.stub.add((0..<3).map { Self.event("E\($0)") })
        harness.stub.relate("webhooks", "W1", "deliveries", to: ids)
        let query = try WebhookDeliveryQuery(createdAtOrAfter: Self.noon, states: [OpenEnum(.failed)])
        var pages: [Page<WebhookDelivery>] = []
        for try await page in harness.client.webhookDeliveries("W1", query) { pages.append(page) }
        #expect(pages.map(\.items.count) == [1_000, 1_000, 500] && pages.flatMap(\.items).allSatisfy { $0.event != nil })
        #expect(harness.reads == [1_000, 2_000].reduce(into: ["GET api-business.apple.com/v1/webhooks/W1/deliveries?filter%5BcreatedDateTimeAtOrAfter%5D="
                                                               + "2026-10-16T12%3A00%3A00Z&filter%5BdeliveryState%5D=FAILED&include=event&limit=1000"]) { reads, cursor in
            reads.append(reads[0] + "&cursor=\(cursor)")
        }, "\(harness.reads)")

        let capped = try await Harness(pageCap: 1)
        capped.stub.add([Self.webhook("W1")])
        capped.stub.add(ids.prefix(1_001).map { Self.delivery($0, at: 0) })
        capped.stub.relate("webhooks", "W1", "deliveries", to: Array(ids.prefix(1_001)))
        var cut: [Page<WebhookDelivery>] = []
        for try await page in capped.client.webhookDeliveries("W1") { cut.append(page) }
        #expect(cut.count == 1 && cut[0].truncated)

        let looped = try await Harness()
        looped.stub.add([Self.webhook("W1")])
        looped.stub.add(ids.prefix(1_001).map { Self.delivery($0, at: 0) })
        looped.stub.relate("webhooks", "W1", "deliveries", to: Array(ids.prefix(1_001)))
        looped.stub.repeatCursors(on: "/v1/webhooks/W1/deliveries")
        await #expect(throws: AppleAPIError.malformed("a repeated cursor on /v1/webhooks/{id}/deliveries")) {
            _ = try await Harness.all(looped.client.webhookDeliveries("W1"))
        }
    }

    /// What Apple includes is the contract's `[WebhookEvent]`: a resource of another type is malformed, never matched to a
    /// delivery; a page that isn't a list is malformed as every list's is.
    @Test func anIncludedResourceOfAnotherTypeIsMalformed() async throws {
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        harness.stub.queue(200, for: "/v1/webhooks/W1/deliveries", body: #"""
            {"data":[{"type":"webhookDeliveries","id":"D1","relationships":{"event":{"data":{"type":"webhookEvents","id":"E1"}}}}],
             "included":[{"type":"orgDevices","id":"E1","attributes":{}}],"links":{"self":"x"}}
            """#)
        await #expect(throws: AppleAPIError.malformed("included of type webhookEvents")) { _ = try await Harness.all(harness.client.webhookDeliveries("W1")) }
        // JSON:API includes a resource once: an event included twice is malformed, never one copy picked (the contract-2.8
        // review's L2: the first was taken, and a mutant taking the last survived).
        harness.stub.queue(200, for: "/v1/webhooks/W1/deliveries", body: #"""
            {"data":[{"type":"webhookDeliveries","id":"D1","relationships":{"event":{"data":{"type":"webhookEvents","id":"E1"}}}}],
             "included":[{"type":"webhookEvents","id":"E1","attributes":{"eventType":"ORG_DEVICE_ATTRIBUTE_CHANGED"}},
                         {"type":"webhookEvents","id":"E2","attributes":{}},
                         {"type":"webhookEvents","id":"E1","attributes":{"eventType":"ORG_DEVICE_RELATIONSHIP_WARRANTY_CHANGED"}}],
             "links":{"self":"x"}}
            """#)
        await #expect(throws: AppleAPIError.malformed("included webhookEvents twice")) { _ = try await Harness.all(harness.client.webhookDeliveries("W1")) }
        #expect(throws: AppleAPIError.malformed("included webhookEvents twice")) {
            _ = try AppleClient.deliveries([], included: [Resource(type: "webhookEvents", id: "E1"), Resource(type: "webhookEvents", id: "E1")])
        }
        // Two ids that are one only to `String ==` (NFC and NFD) are two resources, as JSON:API compares them.
        #expect(try AppleClient.deliveries([], included: [Resource(type: "webhookEvents", id: "\u{E9}"), Resource(type: "webhookEvents", id: "e\u{301}")])
                .isEmpty)
        harness.stub.queue(200, for: "/v1/webhooks/W1/deliveries", body: #"{"data":{"type":"webhookDeliveries","id":"D1"}}"#)
        await #expect(throws: AppleAPIError.malformed("a page of /v1/webhooks/{id}/deliveries")) {
            _ = try await Harness.all(harness.client.webhookDeliveries("W1"))
        }
        harness.stub.queue(200, for: "/v1/webhooks/W1", body: #"{"data":[]}"#)
        await #expect(throws: AppleAPIError.malformed("a single /v1/webhooks/{id}")) { _ = try await harness.client.webhook("W1") }
    }

    /// The stub refuses what the contract refuses: a state outside its list, an include other than `event`, a date that
    /// isn't ISO 8601, a bound given two.
    @Test func theStubRefusesWhatTheContractRefuses() async throws {
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        for (name, value) in [("filter[deliveryState]", "RETRYING"), ("include", "webhook"), ("filter[createdDateTimeAtBefore]", "today"),
                              ("filter[createdDateTimeAtOrAfter]", "2026-10-16T12:00:00Z,2026-10-17T12:00:00Z"), ("filter[status]", "FAILED")] {
            let answer = try await harness.raw("/v1/webhooks/W1/deliveries", [(name, value)])
            #expect(answer.status == 400 && answer.body?["errors"]?.array?.first?["source"]?["parameter"]?.string == name, "\(name)=\(value)")
        }
        #expect(try await harness.raw("/v1/webhooks", [("fields[webhooks]", "secret")]).status == 400)
        #expect(try await harness.raw("/v1/webhooks/W1/deliveries", [("fields[webhookEvents]", "payload"), ("include", "event")]).status == 200)
    }

    /// Each page includes only the events its own deliveries name, each once: an event another page names, or that no
    /// delivery names, isn't included (the stub as Apple's JSON:API does; mutant S5, the stub including every event it
    /// held, survived the review).
    @Test func eachPageIncludesOnlyTheEventsItNames() async throws {
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        harness.stub.add([Self.delivery("D1", at: 0, event: "E1"), Self.delivery("D2", at: 1, event: "E2"), Self.delivery("D3", at: 2, event: "E1")])
        harness.stub.add([Self.event("E1"), Self.event("E2"), Self.event("E3")])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["D1", "D2", "D3"])
        let first = try await harness.raw("/v1/webhooks/W1/deliveries", [("include", "event"), ("limit", "1")])
        #expect(first.body?["included"]?.array?.compactMap { $0["id"]?.string } == ["E1"])
        let second = try await harness.raw("/v1/webhooks/W1/deliveries", [("include", "event"), ("limit", "1"), ("cursor", "1")])
        #expect(second.body?["included"]?.array?.compactMap { $0["id"]?.string } == ["E2"])
        let whole = try await harness.raw("/v1/webhooks/W1/deliveries", [("include", "event")])
        #expect(whole.body?["included"]?.array?.compactMap { $0["id"]?.string } == ["E1", "E2"])
    }

    // MARK: the acceptance pass and the log

    /// The deliveries line reads the first webhook's last day, every page of it: a delivery older than a day isn't counted
    /// (mutant P1, reading every delivery, survived the review), and more than a page of recent ones is counted whole
    /// (mutant P3, stopping after the first page, survived too).
    @Test func theDeliveriesLineCountsTheLastDayEveryPage() async throws {
        let recent = Date().addingTimeInterval(-3_600)
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        let ids = (0..<1_001).map { String(format: "D%05d", $0) }
        harness.stub.add(ids.enumerated().map { Self.delivery($1, at: Double($0), event: "E1", base: recent) }
                         + [Self.delivery("OLD", at: 0, event: "E1", base: Date().addingTimeInterval(-2 * 86_400))])
        harness.stub.add([Self.event("E1")])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["OLD"] + ids)
        let report = await harness.client.acceptancePass()
        #expect(report.text.contains("\nwebhooks/{id}/deliveries: ok, 1001 items · the last day\n"), "\(report.text)")
        let reads = harness.reads.filter { $0.contains("/v1/webhooks/W1/deliveries?") }
        #expect(reads.count == 2 && reads[0].contains("filter%5BcreatedDateTimeAtOrAfter%5D=") && reads[1].contains("&cursor=1000"), "\(reads)")
    }

    /// A canary in every place a token or the receiver's words could hide (the webhook's URL, its secret, a delivery's
    /// request URL, response body, headers and error message, an event's payload and an unknown attribute) reaches
    /// neither the pass's text nor this process's log; the secret's key is counted as unknown. The log is read back, and
    /// a line of these reads is found in it, so the check isn't of an empty log.
    @Test func noURLBodyOrPayloadReachesThePassOrTheLog() async throws {
        let since = Date().addingTimeInterval(-1)
        let canary = "CANARY7Q"
        let recent = Date().addingTimeInterval(-60)
        let harness = try await Harness(devices: 1)
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        harness.stub.add([Self.webhook("W1", url: "https://\(canary).hooks.example.com/T0/\(canary)?token=\(canary)", extra: [
            "secret": .string(canary), "name": .string("\(canary) hook")])])
        harness.stub.add([Self.delivery("D1", at: 0, state: "FAILED", event: "E1", base: recent, extra: [
            "errorMessage": .string("Could not reach https://hooks.example.com/T0/\(canary)"),
            "request": .object(["url": .string("https://hooks.example.com/T0/\(canary)"), "headers": .object(["x-apple-signature": .string(canary)])]),
            "response": .object(["httpStatusCode": .number("500"), "body": .string("\(canary) stack trace")])])])
        harness.stub.add([Self.event("E1", serial: canary, payload: #"{"data":{"type":"orgDeviceAttributeChanged","id":"\#(canary)","version":1,"attributes":{"orgDeviceSerialNumber":"\#(canary)","note":"\#(canary)"}}}"#)])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["D1"])
        let report = await harness.client.acceptancePass()
        _ = try await Harness.all(harness.client.webhooks())
        _ = try await harness.client.webhook("W1")
        _ = try await Harness.all(harness.client.webhookDeliveries("W1"))
        #expect(!report.text.contains(canary), "\(report.text)")
        #expect(report.text.contains("\nwebhooks: ok, 1 item · unknown keys secret\n"), "\(report.text)")
        #expect(report.text.contains("\nwebhooks/{id}: ok, 1 item · unknown keys secret\n"), "\(report.text)")
        #expect(report.text.contains("\nwebhooks/{id}/deliveries: ok, 1 item · unknown keys request.headers · unknown payload keys attributes.note · the last day\n"),
                "\(report.text)")

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let lines = try store.getEntries(at: store.position(date: since),
                                         matching: NSPredicate(format: "subsystem == %@", "io.github.goetchstone.swiftabapit"))
            .compactMap { $0 as? OSLogEntryLog }.map(\.composedMessage)
        #expect(lines.contains { $0.contains("/v1/webhooks/{id}/deliveries") }, "the log holds the deliveries' reads: \(lines.suffix(5))")
        #expect(!lines.contains { $0.contains(canary) || $0.contains("hooks.example.com") }, "\(lines.filter { $0.contains(canary) })")
    }

    /// What didn't come is said with a count, never `ok` with nothing said (invariant 8): an event named and not included,
    /// a delivery naming none, a request or response that isn't an object, a payload that isn't a string or an event.
    @Test func whatDidntComeIsSaidWithACount() async throws {
        let recent = Date().addingTimeInterval(-60)
        let harness = try await Harness()
        harness.stub.add([Self.webhook("W1")])
        harness.stub.add([
            Self.delivery("D1", at: 0, event: "E8", base: recent), Self.delivery("D2", at: 1, event: "E9", base: recent),
            Self.delivery("D3", at: 2, base: recent, extra: ["request": .string("x"), "response": .array([])]),
            Self.delivery("D4", at: 3, event: "E1", base: recent), Self.delivery("D5", at: 4, event: "E2", base: recent),
            Self.delivery("D6", at: 5, event: "E3", base: recent),
        ])
        harness.stub.add([
            Resource(type: "webhookEvents", id: "E1", attributes: ["payload": .number("1")]),
            Resource(type: "webhookEvents", id: "E2", attributes: ["payload": .string("not json"), "eventType": .string("ORG_DEVICE_EXPLODED")]),
            Resource(type: "webhookEvents", id: "E3", attributes: ["payload": .string(#"{"type":"orgDeviceVanished"}"#), "replayed": .bool(true)]),
        ])
        harness.stub.relate("webhooks", "W1", "deliveries", to: ["D1", "D2", "D3", "D4", "D5", "D6"])
        let report = await harness.client.acceptancePass()
        #expect(report.text.contains("\nwebhooks/{id}/deliveries: ok, 6 items · unknown keys event.replayed · unknown values eventType=ORG_DEVICE_EXPLODED, "
                                     + "payloadType=orgDeviceVanished · event not included in 2 deliveries · no event named in 1 delivery · "
                                     + "request not an object in 1 delivery · response not an object in 1 delivery · payload not a string in 1 event · "
                                     + "payload not an event in 1 event · the last day\n"), "\(report.text)")
    }

    /// No webhook: the list is `ok` with none, and what reads its first item is skipped, saying why; refused, the same
    /// with the refusal. A School org sends none of the three.
    @Test func noWebhookOrARefusalIsSaid() async throws {
        let none = try await Harness()
        let empty = await none.client.acceptancePass()
        #expect(empty.text.contains("\nwebhooks: ok, 0 items\nwebhooks/{id}: skipped: no webhook to read (webhooks has none)\n"
                                    + "webhooks/{id}/deliveries: skipped: no webhook to read (webhooks has none)\n"), "\(empty.text)")
        let refused = try await Harness()
        refused.stub.forbid("/v1/webhooks")
        let report = await refused.client.acceptancePass()
        #expect(report.text.contains("\nwebhooks: forbidden, 0 items · FORBIDDEN_ERROR\nwebhooks/{id}: skipped: no webhook to read (webhooks forbidden)\n"
                                     + "webhooks/{id}/deliveries: skipped: no webhook to read (webhooks forbidden)\n"), "\(report.text)")
        let school = try await Harness(scope: .school)
        let skipped = await school.client.acceptancePass()
        for resource in ["webhooks", "webhooks/{id}", "webhooks/{id}/deliveries"] {
            #expect(skipped.lines.first { $0.resource == resource }?.status == .skipped("not in Apple School Manager's API"), "\(resource)")
        }
        #expect(!school.stub.requests.contains { $0.contains("webhook") })
    }
}
