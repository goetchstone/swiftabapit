@testable import AppleModels
import Foundation
import JSONAPI
import Testing

/// Business 2.8's webhooks: what a webhook, a delivery and an event show, and what they withhold. A webhook's URL can carry
/// the receiver's token, a delivery's response body is the receiver's own words, and the secret is write-only at Apple, so
/// each public value shows a URL only as `WebhookURL.destination` does (invariant 11); and an event's payload, read from
/// Apple's guide's own examples, never reads as "no payload" with nothing said (invariant 8).
@Suite("Webhooks")
struct WebhookTests {
    /// Every way a URL can hide a token, and what the mask keeps: only the scheme, the host and the port, with `/…` when
    /// anything else was there. Anything that isn't an `http` or `https` URL with a plain host is withheld whole.
    @Test func aURLShowsOnlyItsSchemeHostAndPort() {
        let cases: [(String, String)] = [
            ("https://example.com/webhooks/apple", "https://example.com/…"),
            ("https://example.com", "https://example.com"),
            ("https://example.com/", "https://example.com"),
            ("HTTPS://Hooks.Example.com:8443/x?token=CANARY#CANARY", "https://Hooks.Example.com:8443/…"),
            ("http://10.0.0.5:8080/in", "http://10.0.0.5:8080/…"),
            ("https://CANARY:CANARY@example.com", "https://example.com/…"),
            ("https://:CANARY@example.com", "https://example.com/…"),
            ("https://@example.com", "https://example.com/…"),
            ("https://example.com?token=CANARY", "https://example.com/…"),
            ("https://example.com#CANARY", "https://example.com/…"),
            ("https://example.com/;CANARY", "https://example.com/…"),
            ("https://[::1]:8443/CANARY", "https://[::1]:8443/…"),
            ("https://xn--bcher-kva.example/CANARY", "https://xn--bcher-kva.example/…"),
            // An international host shows in its `xn--` form, so a lookalike shows as what it is.
            ("https://b\u{FC}cher.example/CANARY", "https://xn--bcher-kva.example/…"),
            ("https://ex\u{E4}mple.com/CANARY", "https://xn--exmple-cua.com/…"),
        ]
        for (url, shown) in cases { #expect(WebhookURL.destination(url) == shown, "\(url)") }
        let withheld = ["ftp://example.com/CANARY", "example.com/CANARY", "//example.com/CANARY", "https:/example.com/CANARY", "https:example.com",
                        "https://exa mple.com/CANARY", "https://%43ANARY.example.com", "https://example.com;CANARY",
                        "https://example.com\n/CANARY", "javascript:CANARY", "", "https://", "https:///CANARY", "https://[CANARY]/",
                        "https://" + String(repeating: "a", count: 254)]
        for url in withheld { #expect(WebhookURL.destination(url) == WebhookURL.withheld, "\(url.debugDescription)") }
    }

    /// The host's bytes, never `Character`s: a combining mark or a lookalike can't pass as a plain host.
    @Test func aPlainHostIsASCII() {
        for host in ["example.com", "a-b.example", "[::1]", "[fe80::1]", "10.0.0.1"] { #expect(WebhookURL.isPlainHost(host), "\(host)") }
        for host in ["", "exa%41mple.com", "e\u{301}xample.com", "\u{212A}.example", "a b", "a@b", "[]", "[::1", "a;b", "a_b"] {
            #expect(!WebhookURL.isPlainHost(host), "\(host.debugDescription)")
        }
        for key in ["url", "URL", "webhookUrl", "callbackURL", "curl"] { #expect(WebhookURL.namesAURL(key), "\(key)") }
        for key in ["ur", "urls", "uri", "u\u{301}rl", "name"] { #expect(!WebhookURL.namesAURL(key), "\(key)") }
    }

    static func webhook(_ attributes: JSONObject) -> Webhook { Webhook(resource: Resource(type: "webhooks", id: "W1", attributes: attributes)) }

    /// Every public value of a webhook shows its URL as where it goes and withholds every attribute this version doesn't
    /// read, a `secret` (write-only at Apple) and one under another name alike, keys kept so the pass counts them; what
    /// Apple sent is `asSent`, `package`. Its description, mirror and dump show the withheld copy only.
    @Test func aWebhookWithholdsItsURLAndItsSecret() {
        let webhook = Self.webhook(["name": .string("Device changes"), "enabled": .bool(true), "url": .string("https://hooks.example.com/T0/CANARYURL"),
                                    "secret": .string("CANARYSECRET"), "signingKey": .object(["k": .string("CANARYKEY")]), "retired": .null,
                                    "eventTypes": .array([.string("ORG_DEVICE_ATTRIBUTE_CHANGED")])])
        #expect(webhook.destination == "https://hooks.example.com/…" && webhook.name == "Device changes" && webhook.isEnabled == true)
        #expect(webhook.attributes["secret"] == .string(Webhook.withheld) && webhook.attributes["signingKey"] == .string(Webhook.withheld))
        #expect(webhook.attributes["retired"] == .null)
        #expect(webhook.unreadAttributes == ["secret", "signingKey", "retired"])
        var dumped = ""
        dump(webhook, to: &dumped)
        for text in [JSONValue.dumps(.object(webhook.attributes)), "\(webhook)", String(reflecting: webhook), dumped,
                     "\(Mirror(reflecting: webhook).children.map(\.value))"] {
            #expect(!text.contains("CANARY"), "\(text)")
        }
        #expect(webhook.asSent.attributes["secret"] == .string("CANARYSECRET"))
        #expect(webhook.asSent.attributes["url"] == .string("https://hooks.example.com/T0/CANARYURL"))
        // A URL of another shape is withheld whole; an event type this version doesn't know survives raw; a list that
        // isn't one is said.
        #expect(Self.webhook(["url": .object(["href": .string("CANARY")])]).destination == WebhookURL.withheld)
        #expect(Self.webhook(["eventTypes": .array([.string("ORG_DEVICE_FUTURE")])]).eventTypes == [.unknown("ORG_DEVICE_FUTURE")])
        #expect(Self.webhook(["eventTypes": .string("ORG_DEVICE_ATTRIBUTE_CHANGED")]).misreadLists == ["eventTypes"])
        #expect(Self.webhook(["eventTypes": .null]).misreadLists.isEmpty)
    }

    /// A webhook stores its withheld resource and the one Apple sent, and nothing else; a delivery those and its event. A
    /// stored property added beside them is a new holder of the URL, the body or a secret, which no scan of `asSent` sees
    /// (`let original = resource`): it fails here until someone decides what it holds (as `Configuration`'s, Phase 2a
    /// verifier round 2).
    @Test func whatAWebhookAndADeliveryStoreIsTheTwoCopies() {
        #expect(MemoryLayout<Webhook>.size == MemoryLayout<(Resource, Resource)>.size)
        #expect(MemoryLayout<WebhookDelivery>.size == MemoryLayout<(Resource, Resource, WebhookEvent?)>.size)
    }

    /// Neither is `Equatable`: the `==` Swift writes would compare `asSent`, an oracle for a guessed token or body (Phase 2a
    /// verifier round 3, `Configuration`'s). One that is needed compares the withheld copy, and this test changes with it.
    @Test func neitherComparesWhatAppleSent() {
        #expect(!(Webhook.self is any Equatable.Type) && !(WebhookDelivery.self is any Equatable.Type))
        #expect(!(Webhook.self is any Hashable.Type) && !(WebhookDelivery.self is any Hashable.Type))
    }

    static func delivery(_ attributes: JSONObject, event: JSONValue? = nil) -> WebhookDelivery {
        WebhookDelivery(resource: Resource(type: "webhookDeliveries", id: "D1", attributes: attributes,
                                           relationships: event.map { ["event": .object(["data": $0])] } ?? [:]))
    }

    /// A delivery's request URL shows where it went, the receiver's body is withheld (that there was one is said), and
    /// every key of the request or response this version doesn't read is withheld and counted; a request or response
    /// that isn't an object is withheld whole and named, never read as none.
    @Test func aDeliveryWithholdsItsURLAndTheReceiversWords() {
        let delivery = Self.delivery([
            "deliveryState": .string("FAILED"), "errorMessage": .string("The host didn't answer."),
            "request": .object(["url": .string("https://hooks.example.com/in?token=CANARYURL"), "headers": .object(["x-apple-signature": .string("CANARYSIG")])]),
            "response": .object(["httpStatusCode": .number("500"), "body": .string("CANARYBODY"), "headers": .string("CANARYHEADER")]),
        ], event: .object(["type": .string("webhookEvents"), "id": .string("E1")]))
        #expect(delivery.state == .known(.failed) && delivery.errorMessage == "The host didn't answer." && delivery.eventID == "E1")
        #expect(delivery.request?.destination == "https://hooks.example.com/…")
        #expect(delivery.response?.statusCode == 500 && delivery.response?.hasBody == true)
        #expect(delivery.unreadNested == [NestedKey(attribute: "request", key: "headers"), NestedKey(attribute: "response", key: "headers")])
        var dumped = ""
        dump(delivery, to: &dumped)
        for text in [JSONValue.dumps(.object(delivery.attributes)), "\(delivery)", String(reflecting: delivery), dumped] {
            #expect(!text.contains("CANARY"), "\(text)")
        }
        #expect(delivery.asSent.attributes["response"]?["body"] == .string("CANARYBODY"))
        // A body Apple left out, or sent as null, is no body.
        #expect(Self.delivery(["response": .object(["httpStatusCode": .number("204")])]).response?.hasBody == false)
        #expect(Self.delivery(["response": .object(["body": .null])]).response?.hasBody == false)
        // Another shape: withheld whole and said.
        let odd = Self.delivery(["request": .string("CANARYURL"), "response": .array([.string("CANARYBODY")])])
        #expect(odd.misreadObjects == ["request", "response"] && odd.request == nil && odd.response == nil)
        #expect(!JSONValue.dumps(.object(odd.attributes)).contains("CANARY"))
        #expect(Self.delivery(["request": .null]).misreadObjects.isEmpty)
        // An event named by something that isn't a `webhookEvents` linkage is no event named.
        for event in [.object(["type": .string("orgDevices"), "id": .string("E1")]), .object(["type": .string("webhookEvents"), "id": .string("")]),
                      .null, .string("E1")] as [JSONValue] {
            #expect(Self.delivery([:], event: event).eventID == nil, "\(event)")
        }
    }

    /// Apple's guide's five example events ("Understanding webhook events", read 2026-11-11, placeholder values): the
    /// payload, wrapped in `data` as the guide shows each POST body.
    static let guide: [String] = [
        #"{"data":{"type":"orgDeviceAttributeChanged","id":"813ef0fa-ce41-4c3f-88dc-b97096670b26","version":1,"attributes":{"orgDeviceSerialNumber":"XABC123DEF4"},"relationships":{"instance":{"data":{"type":"orgDevices","id":"XABC123DEF4"},"links":{"self":"https://api-business.apple.com/v1/orgDevices/XABC123DEF4"}}}}}"#,
        #"{"data":{"type":"orgDeviceAttributeMigrationDetailsChanged","id":"e00313e9-d0ee-41d4-b13f-f23a23495941","version":1,"attributes":{"orgDeviceSerialNumber":"XABC123DEF4"},"relationships":{"instance":{"data":{"type":"orgDevices","id":"XABC123DEF4"},"links":{"self":"https://api-business.apple.com/v1/orgDevices/XABC123DEF4"}}}}}"#,
        #"{"data":{"type":"orgDeviceRelationshipAssignedServerChanged","id":"812ada8f-d313-4148-b9db-2f0b50a7b009","version":1,"attributes":{"orgDeviceSerialNumber":"XABC123DEF4","newMdmServerId":"1F97349736CF4614A94F624E705841AD"},"relationships":{"instance":{"data":{"type":"orgDevices","id":"XABC123DEF4"},"links":{"self":"https://api-business.apple.com/v1/orgDevices/XABC123DEF4"}},"newAssignedServer":{"data":{"type":"mdmServers","id":"1F97349736CF4614A94F624E705841AD"},"links":{"self":"https://api-business.apple.com/v1/mdmServers/1F97349736CF4614A94F624E705841AD"}}}}}"#,
        #"{"data":{"type":"orgDeviceRelationshipWarrantyChanged","id":"7de7d1dd-5830-4104-b03e-d861faa1fd1a","version":1,"attributes":{"orgDeviceSerialNumber":"XABC123DEF4","appleCareCoverageId":"H2WN4ZX7QK"},"relationships":{"instance":{"data":{"type":"orgDevices","id":"XABC123DEF4"},"links":{"self":"https://api-business.apple.com/v1/orgDevices/XABC123DEF4"}}}}}"#,
        #"{"data":{"type":"webhookPingCreated","id":"9be761ff-131c-4652-9df8-b779e8adee29","version":1,"attributes":{"createdDateTime":"2026-10-14T17:24:54.096092003Z"}}}"#,
    ]

    static func event(_ payload: JSONValue?, type: String? = nil) -> WebhookEvent {
        var attributes: JSONObject = ["createdDateTime": .string("2026-10-14T17:24:54Z")]
        if let payload { attributes["payload"] = payload }
        if let type { attributes["eventType"] = .string(type) }
        return WebhookEvent(resource: Resource(type: "webhookEvents", id: "E1", attributes: attributes))
    }

    /// The guide's examples read typed, wrapped in `data` or not: the device, the service it moved to, the coverage that
    /// changed, a ping's time, each payload type the `WebhookEventType` it matches, and nothing unread.
    @Test func theGuidesEventsReadTyped() throws {
        var payloads: [WebhookPayload] = []
        for text in Self.guide {
            let wrapped = try #require(Self.event(.string(text)).payload, "\(text)")
            let bare = try #require(JSONValue.parse(text)?["data"]).jsonText
            #expect(Self.event(.string(bare)).payload == wrapped)
            #expect(wrapped.unreadKeys.isEmpty && wrapped.version == 1 && wrapped.id?.isEmpty == false, "\(text)")
            payloads.append(wrapped)
        }
        #expect(payloads.map(\.type) == WebhookPayloadType.allCases.map { Optional(OpenEnum($0)) })
        #expect(payloads.map { $0.type?.known?.eventType } == WebhookEventType.allCases.map(Optional.some) + [nil])
        #expect(payloads.dropLast().allSatisfy { $0.serialNumber == "XABC123DEF4" && $0.instance == Linkage(type: "orgDevices", id: "XABC123DEF4") })
        #expect(payloads[2].newServiceID == "1F97349736CF4614A94F624E705841AD"
                && payloads[2].newAssignedServer == Linkage(type: "mdmServers", id: "1F97349736CF4614A94F624E705841AD"))
        #expect(payloads[3].appleCareCoverageID == "H2WN4ZX7QK" && payloads[3].newServiceID == nil)
        #expect(payloads[4].created == ISODate.parse("2026-10-14T17:24:54.096092003Z") && payloads[4].serialNumber == nil && payloads[4].instance == nil)
    }

    /// A field is read only where its type documents it, and the rest is counted under where it was: an attribute, a
    /// relationship, a key beside the event's own. A type this version doesn't know keeps its payload raw, its own
    /// attributes uncounted (the type itself is what's unknown).
    @Test func aPayloadFieldIsReadOnlyWhereItsTypeDocumentsIt() throws {
        let odd = try #require(Self.event(.string(#"""
            {"type":"orgDeviceAttributeChanged","attributes":{"orgDeviceSerialNumber":"X1","newMdmServerId":"S1","color":"red"},
             "relationships":{"instance":{"data":{"type":"orgDevices","id":"X1"}},"newAssignedServer":{"data":{"type":"mdmServers","id":"S1"}}},
             "signature":"abc"}
            """#)).payload)
        #expect(odd.serialNumber == "X1" && odd.newServiceID == nil && odd.newAssignedServer == nil)
        #expect(odd.unreadKeys == [NestedKey(attribute: "payload", key: "signature"), NestedKey(attribute: "attributes", key: "newMdmServerId"),
                                   NestedKey(attribute: "attributes", key: "color"), NestedKey(attribute: "relationships", key: "newAssignedServer")])
        let future = try #require(Self.event(.string(#"{"type":"orgDeviceExploded","attributes":{"orgDeviceSerialNumber":"X1"},"extra":1}"#)).payload)
        #expect(future.type == .unknown("orgDeviceExploded") && future.serialNumber == nil)
        #expect(future.unreadKeys == [NestedKey(attribute: "payload", key: "extra")])
    }

    /// A payload that can't be read is said, never read as none: one that isn't a string, a string that isn't a JSON
    /// object, and a `data` that isn't an object. A payload Apple left out, or sent as null, is no payload and no problem.
    @Test func aPayloadThatCantBeReadIsSaid() {
        for (payload, problem) in [
            (.number("1"), .notAString), (.object(["type": .string("orgDeviceAttributeChanged")]), .notAString), (.array([]), .notAString),
            (.string("not json"), .notAnEvent), (.string("[1]"), .notAnEvent), (.string(#"{"data":5}"#), .notAnEvent), (.string(#"{"data":null}"#), .notAnEvent),
            (.string(""), .notAnEvent),
        ] as [(JSONValue, WebhookEvent.PayloadProblem)] {
            let event = Self.event(payload)
            #expect(event.payload == nil && event.payloadProblem == problem, "\(payload)")
        }
        for event in [Self.event(nil), Self.event(.null)] { #expect(event.payload == nil && event.payloadProblem == nil) }
        let ping = Self.event(.string(Self.guide[4]), type: "WEBHOOK_PING")
        #expect(ping.eventType == .unknown("WEBHOOK_PING") && ping.payload?.type == .known(.webhookPingCreated))
        #expect(Self.event(nil, type: "ORG_DEVICE_ATTRIBUTE_CHANGED").eventType == .known(.orgDeviceAttributeChanged))
    }
}
