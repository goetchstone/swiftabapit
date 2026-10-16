import Foundation

/// Credential bytes that never print, log, encode or `dump` their contents (invariant 3). The bytes are
/// `package`: code outside AbapitKit can create a secret and hand it to the Vault, but never read one.
/// Adapted from SwiftGamGui Packages/GamKit/Sources/Vault/Credential.swift:51-62 @ bfdb494.
public struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    package let bytes: Data

    public init(_ bytes: Data) {
        self.bytes = bytes
    }

    public init(_ text: String) {
        self.bytes = Data(text.utf8)
    }

    public var isEmpty: Bool { bytes.isEmpty }
    public var description: String { "<secret: \(bytes.count) bytes>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// One thing the Vault keeps for an organization. The org is its profile's id (a slug: `[a-z0-9-]`, at
/// most 64 characters), so a Keychain account name can't be steered by an org's display name.
public struct VaultItem: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, CaseIterable, Sendable, Comparable {
        /// The Apple API account's P-256 key: a Keychain key item, used to sign, never read out.
        case appleKey = "apple-key"
        /// Mosyle Business: the API access token, the admin's email and password, and the optional Logs
        /// Stream token (plan §3.5).
        case mosyleAccessToken = "mosyle-access-token"
        case mosyleEmail = "mosyle-email"
        case mosylePassword = "mosyle-password"
        case mosyleLogsToken = "mosyle-logs-token"

        public var isKey: Bool { self == .appleKey }

        /// Removal order: what can change the tenant first, so a refusal part-way never leaves the most
        /// dangerous item behind with the lesser ones gone (GamGUI failure-log 2026-10-01).
        public static let removalOrder: [Kind] = [.appleKey, .mosylePassword, .mosyleAccessToken, .mosyleEmail, .mosyleLogsToken]

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let org: String
    public let kind: Kind

    public init?(org: String, kind: Kind) {
        guard Self.isValidOrg(org) else { return nil }
        self.org = org
        self.kind = kind
    }

    public static func isValidOrg(_ org: String) -> Bool {
        (1...64).contains(org.utf8.count) && org.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The Keychain account (generic passwords) or application tag (keys).
    var account: String { "\(org)/\(kind.rawValue)" }

    public var description: String { account }
}
