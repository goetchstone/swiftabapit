import Foundation
import JSONAPI

// Business 2.8's webhooks: where Apple sends an organization's device changes, what it sent and when. Read only here;
// the writes (create, update, delete, ping, redeliver) are the write phases' (plan §8.0). A webhook's URL is the
// operator's own and can carry the receiver's token; a delivery's response body is the receiver's own words; the
// webhook's secret signs every delivery and is write-only at Apple. So each public value shows a URL only as
// `WebhookURL.destination` does and withholds the rest, and what Apple sent is kept at `package` (invariant 11;
// Phase 2a review M2's rule: a view whose resource holds a secret hands out a copy with it withheld).

/// What this app shows of a webhook's URL: its scheme, host and port, never its user, password, path, query or fragment,
/// any of which can carry the receiver's token (`https://hooks.example.com/T0/B0/token`). The parts kept are listed, not
/// the parts that hide a secret (RULE-FEEDBACK 2026-11-03: a mask written shape by shape kept leaking), so anything that
/// isn't an `http` or `https` URL with a plain host is withheld whole. Not caught: a token in the host itself.
public enum WebhookURL {
    /// What stands where a URL can't be shown even in part.
    public static let withheld = "(withheld: a webhook URL may hold a token)"

    /// `https://hooks.example.com/…`: the scheme in lower case, the host as written (an international one in its `xn--`
    /// form, so a lookalike shows as what it is), the port when given, and `/…` when anything else was there (a user, a
    /// path past `/`, a query, a fragment), so the screen says something was withheld.
    public static func destination(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.encodedHost, isPlainHost(host) else { return withheld }
        let more = parts.percentEncodedUser != nil || parts.percentEncodedPassword != nil || parts.percentEncodedQuery != nil
            || parts.percentEncodedFragment != nil || !(parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/")
        return "\(scheme)://\(host)\(parts.port.map { ":\($0)" } ?? "")\(more ? "/…" : "")"
    }

    /// A host name of ASCII letters, digits, `-` and `.`, or an IPv6 address in brackets: nothing percent-encoded, no
    /// blank, no `@`, at most 253 bytes. Read as bytes, never as `Character`s (failure-log 2026-10-16).
    static func isPlainHost(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard (1...253).contains(bytes.count) else { return false }
        if bytes.first == UInt8(ascii: "["), bytes.last == UInt8(ascii: "]"), bytes.count > 2 {
            return bytes.dropFirst().dropLast().allSatisfy { hex.contains($0) || $0 == UInt8(ascii: ":") || $0 == UInt8(ascii: ".") }
        }
        return bytes.allSatisfy { letters.contains($0) || digits.contains($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".") }
    }

    /// Whether `key` names a URL: `url`, or a key ending in it, in any ASCII case (`url`, `webhookUrl`, `targetURL`).
    static func namesAURL(_ key: String) -> Bool {
        let folded = key.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        return folded.count >= 3 && folded.suffix(3).elementsEqual("url".utf8)
    }

    private static let digits = Set("0123456789".utf8), letters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let hex = digits.union("abcdefABCDEF".utf8)
}

/// `webhooks`: one webhook, its name, whether it is on, what it is subscribed to and where it sends. Every public value
/// shows `url` as `WebhookURL.destination` does and withholds the value of every attribute this version doesn't read
/// (keys kept, so the acceptance pass counts them), `secret` among them: Apple documents it as write-only, and an
/// attribute it adds may be the secret under another name. The resource as Apple sent it is `asSent`, `package`.
public struct Webhook: ResourceView, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let resourceType = "webhooks"
    public static let fields = ["name", "enabled", "eventTypes", "url", "createdDateTime", "updatedDateTime"]
    /// What stands where the value of an attribute this version doesn't read is withheld.
    public static let withheld = "(withheld: it may be the webhook's secret)"

    /// The webhook as anyone outside AbapitKit sees it: `url` as its destination, unread attributes withheld.
    public let resource: Resource
    /// The webhook as Apple sent it: its URL whole, and a secret, should Apple ever send one.
    package let asSent: Resource

    public init(resource: Resource) {
        asSent = resource
        self.resource = Self.withholding(resource)
    }

    public var name: String? { attributes.string("name") }
    public var isEnabled: Bool? { attributes.bool("enabled") }
    public var eventTypes: [OpenEnum<WebhookEventType>]? { attributes.list("eventTypes") { $0.open() } }
    /// Where Apple sends the deliveries, as `WebhookURL.destination` shows it.
    public var destination: String? { attributes.string("url") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
    public var misreadLists: [String] { misread(["eventTypes": eventTypes == nil]) }

    /// `resource` with its `url` as its destination (withheld whole when it isn't a string) and every other attribute this
    /// version doesn't read withheld; `null` stays as it came.
    static func withholding(_ resource: Resource) -> Resource {
        var attributes = resource.attributes
        for (key, value) in resource.attributes where value != .null {
            if key.utf8.elementsEqual("url".utf8) {
                attributes[key] = .string(value.string.map(WebhookURL.destination) ?? WebhookURL.withheld)
            } else if !fields.contains(where: { $0.utf8.elementsEqual(key.utf8) }) {
                attributes[key] = .string(withheld)
            }
        }
        return Resource(type: resource.type, id: resource.id, attributes: attributes, relationships: resource.relationships)
    }

    // What prints and reflects is the withheld resource: a struct's default description and mirror show every stored
    // property, `package` ones included (as `Configuration`'s, Phase 2a review M2).
    public var description: String { "Webhook(\(resource))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["resource": resource]) }
}

/// `webhookDeliveries`: one try at sending an event to a webhook, and how the receiver answered. Every public value shows
/// `request.url` as `WebhookURL.destination` does and withholds `response.body` (the receiver's own words, which Apple
/// keeps only for an answer that isn't 2xx) and every key of either object this version doesn't read: the request's
/// could be its headers, and its signature with them. `errorMessage` is Apple's words for a receiver that never answered
/// and is shown as it comes (check live whether it quotes the URL; a screen shows it through the address mask). The
/// delivery as Apple sent it is `asSent`, `package`; `event` is the event it sent, when the read included it.
public struct WebhookDelivery: ResourceView, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let resourceType = "webhookDeliveries"
    public static let fields = ["createdDateTime", "deliveryState", "errorMessage", "redelivery", "request", "response", "sentDateTime"]
    /// What stands where the receiver's words, or a key of the request or response this version doesn't read, are withheld.
    public static let withheld = "(withheld: the receiver's words)"

    public let resource: Resource
    package let asSent: Resource
    /// The event this delivery sent, matched by id from the read's `included`; nil when it wasn't asked for or Apple
    /// didn't include it (`eventID` then says which it named).
    public let event: WebhookEvent?

    public init(resource: Resource) { self.init(resource: resource, event: nil) }

    package init(resource: Resource, event: WebhookEvent?) {
        asSent = resource
        self.resource = Self.withholding(resource)
        self.event = event
    }

    public var created: ISODate? { attributes.date("createdDateTime") }
    public var sent: ISODate? { attributes.date("sentDateTime") }
    public var state: OpenEnum<WebhookDeliveryState>? { attributes.open("deliveryState") }
    public var errorMessage: String? { attributes.string("errorMessage") }
    public var isRedelivery: Bool? { attributes.bool("redelivery") }
    public var request: WebhookDeliveryRequest? { attributes["request"]?.object.map(WebhookDeliveryRequest.init) }
    public var response: WebhookDeliveryResponse? { attributes["response"]?.object.map(WebhookDeliveryResponse.init) }

    /// The event the delivery names: its `event` relationship's `webhookEvents` linkage, compared by bytes; nil when it
    /// names none, or something else.
    public var eventID: String? {
        guard let linkage = resource.linkage("event"), linkage.type.utf8.elementsEqual(WebhookEvent.resourceType.utf8),
              !linkage.id.isEmpty else { return nil }
        return linkage.id
    }

    public var unreadNested: [NestedKey] {
        WebhookDeliveryRequest.unread(request.map { [$0] }, in: "request") + WebhookDeliveryResponse.unread(response.map { [$0] }, in: "response")
    }

    /// `request` or `response` sent, not as `null`, in a shape this version can't read: withheld whole, and said by the
    /// acceptance pass, never read as no request (invariant 8).
    public var misreadObjects: [String] {
        ["request", "response"].filter { key in asSent.attributes[key].map { $0 != .null && $0.object == nil } ?? false }
    }

    /// `resource` with `request.url` as its destination, `response.body` and every unread key of either withheld, and
    /// either withheld whole when it isn't an object; `null` stays as it came.
    static func withholding(_ resource: Resource) -> Resource {
        var attributes = resource.attributes
        for (key, kept) in [("request", ["url"]), ("response", ["httpStatusCode"])] {
            guard let value = attributes[key], value != .null else { continue }
            guard var object = value.object else {
                attributes[key] = .string(withheld)
                continue
            }
            for (field, inner) in object where inner != .null {
                if key == "request", field.utf8.elementsEqual("url".utf8) {
                    object[field] = .string(inner.string.map(WebhookURL.destination) ?? WebhookURL.withheld)
                } else if !kept.contains(where: { $0.utf8.elementsEqual(field.utf8) }) {
                    object[field] = .string(withheld)
                }
            }
            attributes[key] = .object(object)
        }
        return Resource(type: resource.type, id: resource.id, attributes: attributes, relationships: resource.relationships)
    }

    public var description: String { "WebhookDelivery(\(resource), event: \(event?.id ?? "none"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["resource": resource, "event": event?.id as Any]) }
}

/// `WebhookDelivery.Attributes.Request`: the request Apple sent. Its URL is shown as its destination only.
public struct WebhookDeliveryRequest: ObjectView {
    public static let fields = ["url"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    public var destination: String? { object.string("url") }
}

/// `WebhookDelivery.Attributes.Response`: how the receiver answered. Its body is withheld; whether there was one is said.
public struct WebhookDeliveryResponse: ObjectView {
    public static let fields = ["body", "httpStatusCode"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    public var statusCode: Int? { object.int("httpStatusCode") }
    /// Whether the receiver said something, which Apple keeps only for an answer that isn't 2xx.
    public var hasBody: Bool { object["body"].map { $0 != .null } ?? false }
}

/// `webhookEvents`: what a delivery sent. `payload` is the event itself as a JSON string, read as `WebhookPayload`: it
/// names a device by its serial, the organization's own data as an audit event's is, so it stays public; the acceptance
/// pass says only its vocabulary, never a value.
public struct WebhookEvent: ResourceView {
    public static let resourceType = "webhookEvents"
    public static let fields = ["createdDateTime", "eventType", "isPingEvent", "payload"]

    public let resource: Resource
    public init(resource: Resource) { self.resource = resource }

    public var created: ISODate? { attributes.date("createdDateTime") }
    /// What changed. A ping has no subscribable type: Apple sends it on request.
    public var eventType: OpenEnum<WebhookEventType>? { attributes.open("eventType") }
    public var isPing: Bool? { attributes.bool("isPingEvent") }
    /// The payload, parsed; nil when there is none or it can't be read (`payloadProblem` says which).
    public var payload: WebhookPayload? { read.payload }
    /// What was wrong with the payload: never "no payload" with nothing said (invariant 8).
    public var payloadProblem: PayloadProblem? { read.problem }

    public enum PayloadProblem: String, CaseIterable, Sendable {
        /// `payload` is neither a string nor null.
        case notAString = "payload not a string"
        /// The string isn't a JSON object, or its `data` isn't one.
        case notAnEvent = "payload not an event"
    }

    private var read: (payload: WebhookPayload?, problem: PayloadProblem?) {
        switch attributes["payload"] {
        case nil, .null?: return (nil, nil)
        case .string(let text)?:
            guard let object = JSONValue.parse(text)?.object else { return (nil, .notAnEvent) }
            // Apple's guide shows each event wrapped in `data`, as the POST body is, and describes it unwrapped: either.
            switch object["data"] {
            case nil: return (WebhookPayload(object), nil)
            case .object(let event)?: return (WebhookPayload(event), nil)
            case _?: return (nil, .notAnEvent)
            }
        case _?: return (nil, .notAString)
        }
    }
}

/// A webhook event's payload, the event itself. Apple's guide ("Understanding webhook events", read 2026-11-11) gives
/// every event one shape (`type`, `id`, `version`, `attributes`, `relationships`, the `instance` relationship always the
/// resource that changed) and each type's attributes: a field is read only where its type documents it, as an audit
/// payload's is, and the rest is counted (`unreadKeys`).
public struct WebhookPayload: Sendable, Equatable {
    public static let fields = ["type", "id", "version", "attributes", "relationships"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    /// The payload's own name for its type (`orgDeviceAttributeChanged`), matching the event's `eventType`.
    public var type: OpenEnum<WebhookPayloadType>? { object.open("type") }
    public var id: String? { object.string("id") }
    /// The version of the type's schema.
    public var version: Int? { object.int("version") }
    public var attributes: JSONObject? { object["attributes"]?.object }

    /// The device that changed.
    public var serialNumber: String? { field("orgDeviceSerialNumber") }
    /// The service the device is now assigned to.
    public var newServiceID: String? { field("newMdmServerId") }
    /// The AppleCare coverage that changed.
    public var appleCareCoverageID: String? { field("appleCareCoverageId") }
    /// A ping's time.
    public var created: ISODate? { ISODate.parse(field("createdDateTime")) }
    /// The resource that changed: an `orgDevices` linkage for every device event.
    public var instance: Linkage? { relationship("instance") }
    /// The service a device is now assigned to, as a linkage.
    public var newAssignedServer: Linkage? { relationship("newAssignedServer") }

    /// What this version doesn't read: keys at the event's top level, attributes and relationships its type doesn't
    /// document (none for a type this version doesn't know: the type itself is what's unknown).
    public var unreadKeys: [NestedKey] {
        var unread = object.keys(notIn: Self.fields).map { NestedKey(attribute: "payload", key: $0) }
        if let known = type?.known {
            unread += (attributes?.keys(notIn: known.fields) ?? []).map { NestedKey(attribute: "attributes", key: $0) }
            unread += (object["relationships"]?.object?.keys(notIn: known.relationships) ?? []).map { NestedKey(attribute: "relationships", key: $0) }
        }
        return unread
    }

    private func field(_ name: String) -> String? {
        guard let known = type?.known, known.fields.contains(where: { $0.utf8.elementsEqual(name.utf8) }) else { return nil }
        return attributes?.string(name)
    }

    private func relationship(_ name: String) -> Linkage? {
        guard let known = type?.known, known.relationships.contains(where: { $0.utf8.elementsEqual(name.utf8) }) else { return nil }
        return object["relationships"]?[name]?["data"].flatMap(Linkage.init)
    }
}

/// A webhook payload's `type`, from Apple's guide: one per `WebhookEventType`, in the payload's own spelling, and the ping
/// Apple sends on request, which no webhook subscribes to.
public enum WebhookPayloadType: String, KnownValues {
    case orgDeviceAttributeChanged, orgDeviceAttributeMigrationDetailsChanged, orgDeviceRelationshipAssignedServerChanged,
         orgDeviceRelationshipWarrantyChanged, webhookPingCreated

    /// The attributes the guide documents for the type.
    public var fields: [String] {
        switch self {
        case .orgDeviceAttributeChanged, .orgDeviceAttributeMigrationDetailsChanged: ["orgDeviceSerialNumber"]
        case .orgDeviceRelationshipAssignedServerChanged: ["orgDeviceSerialNumber", "newMdmServerId"]
        case .orgDeviceRelationshipWarrantyChanged: ["orgDeviceSerialNumber", "appleCareCoverageId"]
        case .webhookPingCreated: ["createdDateTime"]
        }
    }

    /// The relationships the guide documents for the type.
    public var relationships: [String] {
        switch self {
        case .orgDeviceRelationshipAssignedServerChanged: ["instance", "newAssignedServer"]
        case .orgDeviceAttributeChanged, .orgDeviceAttributeMigrationDetailsChanged, .orgDeviceRelationshipWarrantyChanged: ["instance"]
        case .webhookPingCreated: []
        }
    }

    /// The subscribable type it is, in the event's spelling; nil for a ping.
    public var eventType: WebhookEventType? {
        switch self {
        case .orgDeviceAttributeChanged: .orgDeviceAttributeChanged
        case .orgDeviceAttributeMigrationDetailsChanged: .orgDeviceAttributeMigrationDetailsChanged
        case .orgDeviceRelationshipAssignedServerChanged: .orgDeviceRelationshipAssignedServerChanged
        case .orgDeviceRelationshipWarrantyChanged: .orgDeviceRelationshipWarrantyChanged
        case .webhookPingCreated: nil
        }
    }
}
