import Foundation

/// The Keychain store, the 600 s Vault session, Secret, P-256 key import and ES256 signing (plan §3.4; invariant 3).
///
/// Scaffold (Phase 0): the module exists so the dependency graph is fixed before any code lands; the
/// real types arrive in Phase 1.
package enum VaultModule {
    package static let purpose = "The Keychain store, the 600 s Vault session, Secret, P-256 key import and ES256 signing (plan §3"
}
