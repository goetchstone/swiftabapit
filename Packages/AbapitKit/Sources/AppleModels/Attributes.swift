import Foundation
import JSONAPI

/// Typed reads of a resource's attributes. A missing or mistyped attribute reads as nil: Apple adds and
/// nulls fields across versions, and the raw object keeps whatever came (invariant 10).
extension JSONObject {
    public func string(_ key: String) -> String? { self[key]?.string }
    public func bool(_ key: String) -> Bool? { self[key]?.bool }
    public func int(_ key: String) -> Int? { self[key]?.int }
    public func date(_ key: String) -> ISODate? { ISODate.parse(self[key]?.string) }
    public func open<Known: KnownValues>(_ key: String, as _: Known.Type = Known.self) -> OpenEnum<Known>? {
        self[key]?.string.map(OpenEnum.init)
    }

    /// A list whose every item reads as `item`; nil when the attribute is missing, isn't a list, or holds anything
    /// that doesn't read (a list holding something else isn't a list of these: never the items that happened to fit).
    /// The one list reader: Phase 1's `strings(_:)` kept the items that fit and read `[]` for a non-list, so two views
    /// read one shape two ways (Phase 2a review L6).
    public func list<Item>(_ key: String, _ item: (JSONValue) -> Item?) -> [Item]? {
        self[key]?.list(item)
    }

    /// The keys not among `fields`, compared by their bytes as the typed reads find them: `String ==` would call a
    /// lookalike spelling read while every typed read missed it.
    func keys(notIn fields: [String]) -> [String] {
        keys.filter { key in !fields.contains { $0.utf8.elementsEqual(key.utf8) } }
    }
}

extension JSONValue {
    /// The value as a list whose every item reads as `item`, as `JSONObject.list(_:_:)` reads an attribute.
    func list<Item>(_ item: (JSONValue) -> Item?) -> [Item]? {
        guard let values = array else { return nil }
        var items: [Item] = []
        for value in values {
            guard let read = item(value) else { return nil }
            items.append(read)
        }
        return items
    }
}

/// A typed view over a resource, which it keeps: the inspector shows every attribute, the CSV exports them
/// in Apple's order, and a snapshot stores them as they came.
public protocol ResourceView: Sendable, Identifiable where ID == String {
    /// The JSON:API type this view reads.
    static var resourceType: String { get }
    /// The attributes it reads by name, checked against the contract (`AppleModelsTests`).
    static var fields: [String] { get }
    /// What every public reader gets. A view whose resource holds a secret hands out a copy with it withheld, and keeps
    /// the resource as it came at `package` access (`Configuration`: a custom setting's profile, Phase 2a review M2).
    var resource: Resource { get }
    init(resource: Resource)
    /// Attributes Apple sent that this version doesn't read: counted by the acceptance pass, shown raw. A
    /// requirement, so a view whose read attributes depend on its values (an audit event's payload key) is asked
    /// the same way wherever it is used as a `ResourceView`.
    var unreadAttributes: [String] { get }
    /// Keys Apple sent inside the objects this view reads (`ObjectView`s: a user's phone numbers) that this version
    /// doesn't: counted by the acceptance pass too (Phase 2a review L1: only an audit payload's were). None by default.
    var unreadNested: [NestedKey] { get }
}

extension ResourceView {
    public var id: String { resource.id }
    public var attributes: JSONObject { resource.attributes }
    public var unreadAttributes: [String] { attributes.keys(notIn: Self.fields) }
    public var unreadNested: [NestedKey] { [] }
}

/// A key inside an object a view reads that this version doesn't: the attribute holding the object (this version's
/// name) and Apple's key, kept apart so the acceptance pass shows Apple's key only as a word (`phoneNumbers.isPrimary`).
public struct NestedKey: Sendable, Hashable {
    public let attribute: String
    public let key: String

    public init(attribute: String, key: String) {
        self.attribute = attribute
        self.key = key
    }
}

/// A typed view over an object nested in an attribute (a user's phone number, a configuration's custom settings),
/// which it keeps, as a `ResourceView` keeps its resource.
public protocol ObjectView: Sendable, Equatable {
    /// The keys it reads, checked against the contract (`AppleModelsTests`).
    static var fields: [String] { get }
    var object: JSONObject { get }
    init(_ object: JSONObject)
}

extension ObjectView {
    /// Keys Apple sent that this version doesn't read.
    public var unreadFields: [String] { object.keys(notIn: Self.fields) }

    /// The attribute as a list of these objects; nil as `JSONObject.list(_:_:)` says.
    static func list(_ key: String, in attributes: JSONObject) -> [Self]? {
        attributes.list(key) { $0.object.map(Self.init) }
    }

    /// Each of `objects`' unread fields, under `attribute`.
    static func unread(_ objects: [Self]?, in attribute: String) -> [NestedKey] {
        (objects ?? []).flatMap { $0.unreadFields.map { NestedKey(attribute: attribute, key: $0) } }
    }
}
