import Foundation

/// One JSON:API resource as Apple returns it: `type`, `id`, its attributes in Apple's order, and its
/// relationships. A linkage (`{type, id}` alone, as `relationships/devices` lists) is a resource with
/// no attributes.
public struct Resource: Sendable, Equatable {
    public let type: String
    public let id: String
    public let attributes: JSONObject
    public let relationships: JSONObject

    public init(type: String, id: String, attributes: JSONObject = [:], relationships: JSONObject = [:]) {
        self.type = type
        self.id = id
        self.attributes = attributes
        self.relationships = relationships
    }

    /// Nil unless `value` is an object with string `type` and `id` (an empty `id` included: abapit keeps it).
    public init?(_ value: JSONValue) {
        guard let object = value.object, let type = object["type"]?.string, let id = object["id"]?.string else { return nil }
        self.init(type: type, id: id, attributes: object["attributes"]?.object ?? [:],
                  relationships: object["relationships"]?.object ?? [:])
    }

    /// The `{type, id}` a relationship names, when it names one.
    public func linkage(_ relationship: String) -> Linkage? {
        relationships[relationship]?["data"].flatMap(Linkage.init)
    }

    /// abapit's JSON:API item, `{"type", "id", "attributes"}`: what its reports and CSV read.
    public var asJSON: JSONValue {
        .object(["type": .string(type), "id": .string(id), "attributes": .object(attributes)])
    }
}

public struct Linkage: Sendable, Hashable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    public init?(_ value: JSONValue) {
        guard let type = value["type"]?.string, let id = value["id"]?.string else { return nil }
        self.init(type: type, id: id)
    }
}

/// A response document: its primary data, the next page (a `links.next` URL, or the audit endpoint's
/// `meta.paging.nextCursor`), and the paging total when Apple gives one.
public struct Document: Sendable {
    public let data: JSONValue?
    public let included: [Resource]
    public let next: String?
    public let nextCursor: String?
    public let total: Int?

    public enum Failure: Error, Equatable, Sendable {
        /// Not JSON, or JSON that isn't an object: said with the byte count only, never the body.
        case notJSON(bytes: Int)
        case noData
    }

    /// The bytes Apple sent, read as JSON:API. A body that isn't a JSON object throws; a 204's empty body
    /// is the caller's to skip.
    public static func parse(_ body: Data) throws(Failure) -> Document {
        guard let value = JSONValue.parse(String(decoding: body, as: UTF8.self)), let object = value.object else {
            throw .notJSON(bytes: body.count)
        }
        let paging = object["meta"]?["paging"]
        return Document(data: object["data"],
                        included: (object["included"]?.array ?? []).compactMap(Resource.init),
                        next: object["links"]?["next"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                        nextCursor: paging?["nextCursor"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                        total: paging?["total"]?.int)
    }

    /// The primary data as resources: a list, or the single resource. Items that aren't resources are
    /// skipped, as abapit's `body.get("data", [])` iteration skipped nothing but also read nothing from them.
    public var resources: [Resource] {
        switch data {
        case .array(let items)?: items.compactMap(Resource.init)
        case .object?: data.flatMap(Resource.init).map { [$0] } ?? []
        default: []
        }
    }

    /// The single primary resource (a `GET …/{id}`), or nil when `data` is null or a list.
    public var resource: Resource? {
        guard case .object? = data else { return nil }
        return data.flatMap(Resource.init)
    }
}

/// Apple's `ErrorResponse`: `{"errors": [{id, status, code, title, detail, source: {pointer | parameter},
/// links, meta}]}`. Errors are classified on the HTTP status plus the dot-separated `code`, never on the
/// prose (plan §3.3).
public struct ErrorBody: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let id: String?
        public let status: String?
        public let code: String?
        public let title: String?
        public let detail: String?
        public let pointer: String?
        public let parameter: String?
    }

    public let errors: [Item]

    public init?(_ body: Data) {
        guard let value = JSONValue.parse(String(decoding: body, as: UTF8.self)), let list = value["errors"]?.array else { return nil }
        errors = list.compactMap { item in
            guard item.object != nil else { return nil }
            return Item(id: item["id"]?.string, status: item["status"]?.string, code: item["code"]?.string,
                        title: item["title"]?.string, detail: item["detail"]?.string,
                        pointer: item["source"]?["pointer"]?.string, parameter: item["source"]?["parameter"]?.string)
        }
    }

    /// abapit's `_error_message`: the first error's `title: detail`, trimmed of the joining punctuation.
    public var summary: String? {
        guard let first = errors.first else { return nil }
        let joined = "\(first.title ?? "API error"): \(first.detail ?? "")"
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }
}
