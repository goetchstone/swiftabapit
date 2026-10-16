import Foundation
import Security

public enum VaultError: Error, Equatable, Sendable {
    /// A Keychain call failed for any reason but "no such item". Never read as absence: a refused delete
    /// once read as success with the secret still stored (GamGUI failure-log 2026-10-01).
    case keychain(OSStatus)
    /// The org has no such item stored.
    case missing(VaultItem)
    case accessControlUnavailable
    /// The key bytes couldn't be turned into a Keychain key.
    case keyNotUsable
    /// A key handed where a secret belongs, or the other way round.
    case wrongKind(VaultItem.Kind)

    /// What the operator is told: what happened and what to do, never a secret, never a bare status.
    public var guidance: String {
        switch self {
        case .keychain(errSecMissingEntitlement):
            "This build can't use the Keychain. Sign it with your team (Config/Local.xcconfig and the team entitlements), "
                + "then build it once in Xcode."
        case .keychain(errSecInteractionNotAllowed):
            "The Keychain is locked. Unlock your Mac, then try again."
        case .keychain(errSecAuthFailed), .keychain(errSecUserCanceled):
            "Touch ID or the password wasn't confirmed, so nothing was read or changed."
        case .keychain(let status):
            "The Keychain refused (status \(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "no description")."
        case .missing(let item):
            "\(item.kind.displayName) isn't stored for this organization. Add it in Settings."
        case .accessControlUnavailable:
            "The Keychain couldn't set the Touch ID requirement on the item, so it wasn't stored."
        case .keyNotUsable:
            "That key couldn't be stored as a Keychain key."
        case .wrongKind(let kind):
            "\(kind.displayName) can't be stored that way."
        }
    }
}

extension VaultItem.Kind {
    public var displayName: String {
        switch self {
        case .appleKey: "The Apple API key"
        case .mosyleAccessToken: "The Mosyle access token"
        case .mosyleEmail: "The Mosyle admin email"
        case .mosylePassword: "The Mosyle admin password"
        case .mosyleLogsToken: "The Mosyle Logs Stream token"
        }
    }
}
