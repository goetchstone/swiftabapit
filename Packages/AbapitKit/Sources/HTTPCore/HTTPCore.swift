import Foundation

/// Transport, host allowlist, rate limiter, retry policy, paginator, and send(_:ticket:) — the one door a write goes through (plan §3.3; invariants 1, 4).
///
/// Scaffold (Phase 0): the module exists so the dependency graph is fixed before any code lands; the
/// real types arrive in Phases 1, 4.
package enum HTTPCoreModule {
    package static let purpose = "Transport, host allowlist, rate limiter, retry policy, paginator, and send(_:ticket:) — the one door a write goes through (plan §3"
}
