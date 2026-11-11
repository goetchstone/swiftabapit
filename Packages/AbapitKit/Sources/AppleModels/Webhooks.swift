import Foundation
import JSONAPI

// Business 2.8's webhooks: where Apple sends an organization's device changes, what it sent and when. Read only here;
// the writes (create, update, delete, ping, redeliver) are the write phases' (plan §8.0). A webhook's URL is the
// operator's own and can carry the receiver's token; a delivery's response body is the receiver's own words; the
// webhook's secret signs every delivery and is write-only at Apple. So each public value shows a URL only as
// `WebhookURL.shown` does (its destination and tag) and withholds the rest, and what Apple sent is kept at `package` (invariant 11;
// Phase 2a review M2's rule: a view whose resource holds a secret hands out a copy with it withheld).

/// What this app shows of a webhook's URL: its scheme, host and port, never its user, password, path, query or fragment,
/// any of which can carry the receiver's token (`https://hooks.example.com/T0/B0/token`). The parts kept are listed, not
/// the parts that hide a secret (RULE-FEEDBACK 2026-11-03: a mask written shape by shape kept leaking), so anything that
/// isn't an `http` or `https` URL with a plain host is withheld whole. Not caught: a token in the host itself.
///
/// Every value that holds a masked URL shows it as `shown` does: the destination, then a short tag of the whole URL, so
/// two URLs on one host (a webhook repointed on a shared receiver) don't look alike. A tag compares only within one run of
/// the app: its key is made at random once per process, held in memory only, never stored or logged.
public enum WebhookURL {
    /// What stands where a URL can't be shown even in part.
    public static let withheld = "(withheld: a webhook URL may hold a token)"

    /// `https://hooks.example.com/… (tag a1b2c3d4)`: the URL's destination, then its tag. What every webhook, delivery and
    /// audit value holds where Apple sent a URL as a string.
    public static func shown(_ url: String) -> String { "\(destination(url)) (tag \(tag(url)))" }

    /// The first 8 hex digits of HMAC-SHA256 of the URL's bytes, as Apple sent them, under `tagKey`: the same URL gives the
    /// same tag in this run, two URLs differ but for a 1 in 2^32 chance, and nothing of the URL can be read from it.
    public static func tag(_ url: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = TagHash.hmac(key: tagKey, Array(url.utf8)).prefix(4).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 32 random bytes, made the first time a tag is asked for: in memory only, so a tag means nothing outside this run.
    private static let tagKey: [UInt8] = {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }()

    /// `text` with every URL in it shown as `shown` shows one, the rest as it came: Apple's words that may quote a URL (a
    /// delivery's `errorMessage`, an audit event's `subjectName` and `actorName`, a string in an audit payload). A URL starts
    /// at a scheme (letters, digits, `+`, `-`, `.`) whose `:` is followed by `/` or `\` (`https://`, and the `https:/` and
    /// `https:\\` a browser reads as one), at an `http` or `https` scheme followed by `:` alone (`https:hooks.example.com/…`),
    /// or at a scheme-relative `//` that doesn't follow a scheme's character or a `/` (`url=//hooks.example.com/…`), and runs
    /// to the next ASCII blank; what is glued before it (`url=`, `(`) is kept. Errs toward hiding: punctuation after a URL
    /// is masked with it, and a URL of another scheme (or none) is withheld whole, with its tag. Read as UTF-8 bytes, so a
    /// combining mark can't join a delimiter into another character (failure-log 2026-10-16). Not caught: a URL with no
    /// scheme and no `//` (`hooks.example.com/token`), a `//` glued to a word (`a//hooks.example.com/token`), another scheme
    /// with `:` alone, and what follows a blank inside a URL. `aGeneratedURLNeverSurvivesTheMask` holds it to a grammar.
    public static func maskingURLs(in text: String) -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard !blanks.contains(bytes[index]) else {
                out.append(bytes[index])
                index += 1
                continue
            }
            let end = bytes[index...].firstIndex(where: blanks.contains) ?? bytes.count
            let run = bytes[index..<end]
            if let start = urlStart(run) {
                out += run[..<start]
                out += Array(shown(String(decoding: run[start...], as: UTF8.self)).utf8)
            } else {
                out += run
            }
            index = end
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Where a URL starts in a run of text between blanks, or nil when the run holds none (`maskingURLs`): the first start
    /// from the left, so a later URL in the run is masked with the first.
    private static func urlStart(_ run: ArraySlice<UInt8>) -> Int? {
        let slash = UInt8(ascii: "/")
        for index in run.indices {
            let next = index + 1 < run.endIndex ? run[index + 1] : nil
            if run[index] == slash, next == slash, index == run.startIndex || !(isSchemeByte(run[index - 1]) || run[index - 1] == slash) {
                return index
            }
            guard run[index] == UInt8(ascii: ":") else { continue }
            var start = index
            while start > run.startIndex, isSchemeByte(run[start - 1]) { start -= 1 }
            guard start < index else { continue }
            let scheme = run[start..<index].map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
            if next == slash || next == UInt8(ascii: "\\") || scheme.elementsEqual("http".utf8) || scheme.elementsEqual("https".utf8) {
                return start
            }
        }
        return nil
    }

    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        letters.contains(byte) || digits.contains(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    /// ASCII blanks: a URL holds none, so they split text into runs, and are kept as they came.
    private static let blanks: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]

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
/// shows `url` as `WebhookURL.shown` does and withholds the value of every attribute this version doesn't read
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
    /// Where Apple sends the deliveries, as `WebhookURL.shown` shows it: the destination and the URL's tag.
    public var destination: String? { attributes.string("url") }
    public var created: ISODate? { attributes.date("createdDateTime") }
    public var updated: ISODate? { attributes.date("updatedDateTime") }
    public var misreadLists: [String] { misread(["eventTypes": eventTypes == nil]) }

    /// `resource` with its `url` as `WebhookURL.shown` shows it (withheld whole when it isn't a string) and every other
    /// attribute this version doesn't read withheld; `null` stays as it came.
    static func withholding(_ resource: Resource) -> Resource {
        var attributes = resource.attributes
        for (key, value) in resource.attributes where value != .null {
            if key.utf8.elementsEqual("url".utf8) {
                attributes[key] = .string(value.string.map(WebhookURL.shown) ?? WebhookURL.withheld)
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
/// `request.url` as `WebhookURL.shown` does and withholds `response.body` (the receiver's own words, which Apple keeps only
/// for an answer that isn't 2xx), every key of either object this version doesn't read (the request's could be its
/// headers, and its signature with them) and every attribute it doesn't read (`requestHeaders`, a signature: as
/// `Webhook` withholds its own). `errorMessage` is Apple's words for a receiver that never answered, which may quote the
/// URL, token and all (check live): every URL in it is shown as `WebhookURL.maskingURLs` shows one, and one that isn't a
/// string is withheld whole. The delivery as Apple sent it is `asSent`, `package`; `event` is the event it sent, when the
/// read included it.
public struct WebhookDelivery: ResourceView, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let resourceType = "webhookDeliveries"
    public static let fields = ["createdDateTime", "deliveryState", "errorMessage", "redelivery", "request", "response", "sentDateTime"]
    /// What stands where the receiver's words, a key of the request or response, or an attribute this version doesn't read,
    /// are withheld.
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
        ["request", "response"].filter { key in attributes[key].map { $0 != .null && $0.object == nil } ?? false }
    }

    /// `resource` with `request.url` as `WebhookURL.shown` shows it, `response.body` and every unread key of either
    /// withheld, either withheld whole when it isn't an object, every URL in `errorMessage` masked (the message withheld
    /// whole when it isn't a string), and every attribute this version doesn't read withheld; `null` stays as it came.
    static func withholding(_ resource: Resource) -> Resource {
        var attributes = resource.attributes
        for (key, value) in resource.attributes where value != .null {
            let request = key.utf8.elementsEqual("request".utf8)
            if request || key.utf8.elementsEqual("response".utf8) {
                attributes[key] = withholding(value, keeping: request ? ["url"] : ["httpStatusCode"], request: request)
            } else if key.utf8.elementsEqual("errorMessage".utf8) {
                attributes[key] = .string(value.string.map(WebhookURL.maskingURLs(in:)) ?? withheld)
            } else if !fields.contains(where: { $0.utf8.elementsEqual(key.utf8) }) {
                attributes[key] = .string(withheld)
            }
        }
        return Resource(type: resource.type, id: resource.id, attributes: attributes, relationships: resource.relationships)
    }

    /// A request or a response: its keys but `kept` withheld (a request's `url` as `WebhookURL.shown` shows it), the whole
    /// withheld when it isn't an object.
    private static func withholding(_ value: JSONValue, keeping kept: [String], request: Bool) -> JSONValue {
        guard var object = value.object else { return .string(withheld) }
        for (field, inner) in object where inner != .null {
            if request, field.utf8.elementsEqual("url".utf8) {
                object[field] = .string(inner.string.map(WebhookURL.shown) ?? WebhookURL.withheld)
            } else if !kept.contains(where: { $0.utf8.elementsEqual(field.utf8) }) {
                object[field] = .string(withheld)
            }
        }
        return .object(object)
    }

    public var description: String { "WebhookDelivery(\(resource), event: \(event?.id ?? "none"))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["resource": resource, "event": event?.id as Any]) }
}

/// `WebhookDelivery.Attributes.Request`: the request Apple sent. Its URL is shown as its destination and tag only.
public struct WebhookDeliveryRequest: ObjectView {
    public static let fields = ["url"]
    public let object: JSONObject
    public init(_ object: JSONObject) { self.object = object }

    /// Where the delivery went, as `WebhookURL.shown` shows it.
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
            // Apple's guide shows each event wrapped in `data`, as the POST body is, and describes it unwrapped: either. What
            // sits beside `data` is unread, and counted.
            switch object["data"] {
            case nil: return (WebhookPayload(object), nil)
            case .object(let event)?: return (WebhookPayload(event, besideData: object.keys(notIn: ["data"])), nil)
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
    /// The keys a payload wrapped in `data` held beside it (`meta`, say): unread, so counted as `payload.<key>`.
    public let besideData: [String]

    public init(_ object: JSONObject, besideData: [String] = []) {
        self.object = object
        self.besideData = besideData
    }

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

    /// What this version doesn't read: keys beside a wrapped event's `data` and at the event's top level, attributes and
    /// relationships its type doesn't document (none for a type this version doesn't know: the type itself is what's
    /// unknown).
    public var unreadKeys: [NestedKey] {
        var unread = (besideData + object.keys(notIn: Self.fields)).map { NestedKey(attribute: "payload", key: $0) }
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
