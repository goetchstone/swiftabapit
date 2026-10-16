import Foundation

/// A fully built request as data: WireOperation (writes) and ReadRequest (reads), with the host they go to. Pure, so Planners can build one without the transport (RULE-FEEDBACK 2026-10-16).
///
/// Scaffold (Phase 0): the module exists so the dependency graph is fixed before any code lands; the
/// real types arrive in Phases 1, 4.
package enum WireModule {
    package static let purpose = "A fully built request as data: WireOperation (writes) and ReadRequest (reads), with the host they go to"
}
