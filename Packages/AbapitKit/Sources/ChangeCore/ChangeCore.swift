import Foundation

/// The only write path: HeldPreview, Guard, the Executor actor and the audit log (plan §3.8; invariant 1).
///
/// Scaffold (Phase 0): the module exists so the dependency graph is fixed before any code lands; the
/// real types arrive in Phase 4.
package enum ChangeCoreModule {
    package static let purpose = "The only write path: HeldPreview, Guard, the Executor actor and the audit log (plan §3"
}
