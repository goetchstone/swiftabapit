import Foundation
import JSONAPI

/// Typed reads of a resource's attributes. A missing or mistyped attribute reads as nil: Apple adds and
/// nulls fields across versions, and the raw object keeps whatever came (invariant 10).
extension JSONObject {
    public func string(_ key: String) -> String? { self[key]?.string }
    public func bool(_ key: String) -> Bool? { self[key]?.bool }
    public func int(_ key: String) -> Int? { self[key]?.int }
    public func date(_ key: String) -> ISODate? { ISODate.parse(self[key]?.string) }
    public func strings(_ key: String) -> [String] { self[key]?.array?.compactMap(\.string) ?? [] }
    public func open<Known: KnownValues>(_ key: String, as _: Known.Type = Known.self) -> OpenEnum<Known>? {
        self[key]?.string.map(OpenEnum.init)
    }
}

/// A typed view over a resource, which it keeps: the inspector shows every attribute, the CSV exports them
/// in Apple's order, and a snapshot stores them as they came.
public protocol ResourceView: Sendable, Identifiable where ID == String {
    /// The JSON:API type this view reads.
    static var resourceType: String { get }
    /// The attributes it reads by name, checked against the contract (`AppleModelsTests`).
    static var fields: [String] { get }
    var resource: Resource { get }
    init(resource: Resource)
}

extension ResourceView {
    public var id: String { resource.id }
    public var attributes: JSONObject { resource.attributes }
    /// Attributes Apple sent that this version doesn't read: counted by the acceptance pass, shown raw.
    public var unreadAttributes: [String] { attributes.keys.filter { !Self.fields.contains($0) } }
}
