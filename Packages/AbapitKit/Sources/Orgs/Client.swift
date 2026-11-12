import Foundation
import JSONAPI

/// A client: the organizations one customer's devices are read through, and nothing else on screen at once (plan §8.0,
/// "Clients"). One Apple org (Apple Business or Apple School Manager) and an optional MDM org (Mosyle Business) now; a
/// Google Workspace domain later. Each org belongs to exactly one client, and a client has at least one org. Held as the
/// JSON object it was read from, as `OrgProfile` is, so a field a newer version wrote survives a save here.
public struct Client: Sendable, Equatable, Identifiable {
    public private(set) var raw: JSONObject

    public init(raw: JSONObject) { self.raw = raw }

    init(id: String, name: String, apple: String?, mdm: String?) {
        raw = ["id": .string(id), "name": .string(name)]
        self.apple = apple
        self.mdm = mdm
    }

    public var id: String { raw["id"]?.string ?? "" }

    public var name: String {
        get { raw["name"]?.string ?? "" }
        set { raw["name"] = .string(newValue) }
    }

    /// The client's Apple org's id (Business or School); nil when it has none.
    public var apple: String? {
        get { raw["apple"]?.string }
        set { raw["apple"] = newValue.map(JSONValue.string) }
    }

    /// The client's MDM org's id (Mosyle Business, or an org of a provider a newer version knows); nil when it has none.
    public var mdm: String? {
        get { raw["mdm"]?.string }
        set { raw["mdm"] = newValue.map(JSONValue.string) }
    }

    /// The client's orgs: its Apple org first.
    public var orgs: [String] { [apple, mdm].compactMap { $0 } }

    public func holds(_ org: String) -> Bool { orgs.contains(org) }

    /// The place an org takes in a client: an Apple org is its Apple org; any other is its MDM org.
    public enum Slot: Sendable, Equatable {
        case apple, mdm

        public init(_ profile: OrgProfile) { self = profile.provider == .known(.apple) ? .apple : .mdm }
    }

    public func has(_ slot: Slot) -> Bool { (slot == .apple ? apple : mdm) != nil }

    mutating func set(_ slot: Slot, _ org: String?) {
        if slot == .apple { apple = org } else { mdm = org }
    }
}
