import Foundation
import JSONAPI

/// Which API an organization is reached through.
public enum Provider: String, KnownValues {
    case apple, mosyle
}

/// Apple Business or Apple School Manager: the host and the token scope follow from it.
public enum Scope: String, KnownValues {
    case business, school

    public var displayName: String {
        switch self {
        case .business: "Apple Business"
        case .school: "Apple School Manager"
        }
    }
}

/// One organization's profile: everything about it that is **not** a secret (plan §3.7). Secrets are in the
/// Vault under `id`. The profile is held as the JSON object it was read from, so a field a newer version
/// of the app wrote survives an edit and a save here (plan §2.3 defect 14: abapit's strict `Org(**json)`
/// broke on new fields); the typed properties read and write that object.
public struct OrgProfile: Sendable, Equatable, Identifiable {
    public private(set) var raw: JSONObject

    public init(raw: JSONObject) { self.raw = raw }

    /// A new profile. `id` comes from `OrgStore.uniqueID(for:)`.
    public init(id: String, name: String, provider: Provider) {
        raw = ["id": .string(id), "name": .string(name), "provider": .string(provider.rawValue)]
    }

    /// The slug the Vault and the history key this org by. Never changes after the org is added.
    public var id: String { raw["id"]?.string ?? "" }

    public var name: String {
        get { raw["name"]?.string ?? "" }
        set { set("name", newValue) }
    }

    public var provider: OpenEnum<Provider> { OpenEnum(raw["provider"]?.string ?? "") }

    // MARK: Apple

    public var scope: OpenEnum<Scope> {
        get { OpenEnum(raw["scope"]?.string ?? Scope.business.rawValue) }
        set { set("scope", newValue.rawValue) }
    }

    /// `BUSINESSAPI.…` or `SCHOOLAPI.…`: the API account's client ID. Unique across orgs (it identifies the
    /// account to Apple; two orgs sharing one would mix tokens).
    public var clientID: String {
        get { raw["client_id"]?.string ?? "" }
        set { set("client_id", newValue) }
    }

    public var keyID: String {
        get { raw["key_id"]?.string ?? "" }
        set { set("key_id", newValue) }
    }

    /// Optional; the assertion's `iss` falls back to the client ID (abapit's rule). Settable and clearable
    /// (defect 14: abapit couldn't set it).
    public var teamID: String {
        get { raw["team_id"]?.string ?? "" }
        set { set("team_id", newValue) }
    }

    /// The account's Apple Business role, as the operator wrote it: bookkeeping only. The probes are the truth.
    public var role: String {
        get { raw["role"]?.string ?? "" }
        set { set("role", newValue) }
    }

    /// What the last Permissions check found, section by section (`ok`, `forbidden`, `error 500`, …).
    public var capabilities: [String: String] {
        get {
            var found: [String: String] = [:]
            for (key, value) in raw["capabilities"]?.object ?? [:] { found[key] = value.string }
            return found
        }
        set {
            var object = JSONObject()
            for key in newValue.keys.sorted() { object[key] = .string(newValue[key]!) }
            raw["capabilities"] = .object(object)
        }
    }

    public var probedAt: String {
        get { raw["probed_at"]?.string ?? "" }
        set { set("probed_at", newValue) }
    }

    /// Sections a probe found forbidden: shown locked, "your role can't read this" (invariant 8).
    public var deniedSections: Set<String> { Set(capabilities.filter { $0.value == "forbidden" }.keys) }

    /// The org of the other provider Device 360 merges with, chosen by the operator (defect 17).
    public var pairedOrg: String {
        get { raw["paired_org"]?.string ?? "" }
        set { set("paired_org", newValue) }
    }

    /// Requests per minute the rate limiter learned for this org's reads (plan §3.3); 0 when not learned.
    public var learnedReadsPerMinute: Double {
        get { raw["learned_reads_per_minute"]?.double.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        // Never NaN or infinity: JSON can't hold them, and a NaN rate never waits (Phase 1a's review).
        set { raw["learned_reads_per_minute"] = newValue.isFinite && newValue > 0 ? .number(String(newValue)) : nil }
    }

    /// The assertion's issuer: the team ID when set, else the client ID.
    public var issuer: String { teamID.isEmpty ? clientID : teamID }

    /// An empty value removes the key, so "clear" really clears (defect 14).
    private mutating func set(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        raw[key] = trimmed.isEmpty ? nil : .string(trimmed)
    }

    /// What's wrong with the profile for its provider, in the operator's words; nil when it's usable.
    public var problem: String? {
        switch provider {
        case .known(.apple):
            if scope.known == nil { return "The scope \"\(scope.rawValue)\" isn't one this version knows." }
            if clientID.isEmpty { return "The client ID is missing." }
            if keyID.isEmpty { return "The key ID is missing." }
            return nil
        case .known(.mosyle):
            return nil
        case .unknown(let raw):
            return "The provider \"\(raw)\" isn't one this version knows; a newer version of abapit added it."
        }
    }
}
