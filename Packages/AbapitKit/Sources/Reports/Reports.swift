import Foundation

/// Pure reports over decoded data: stats, coverage, fleet age, Activation Lock, migration, reconciliation, timeline, posture, audit digests, the CSV writer.
///
/// Scaffold (Phase 0): the module exists so the dependency graph is fixed before any code lands; the
/// real types arrive in Phases 1–3, 7.
package enum ReportsModule {
    package static let purpose = "Pure reports over decoded data: stats, coverage, fleet age, Activation Lock, migration, reconciliation, timeline, posture, audit digests, the CSV writer"
}
