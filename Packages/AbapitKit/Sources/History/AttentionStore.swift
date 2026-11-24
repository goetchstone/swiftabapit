import Foundation
import JSONAPI
import Orgs
import Reports

/// What "Needs attention" keeps (plan §8.0: "Stored: only what can't be read again, which is when a finding first appeared
/// and whether it was dismissed or snoozed"). Methods on `SnapshotStore`, not a second store, because the table lives in
/// the same file (`Schema.attention`, version 2) and so has the same file safety: the same `openat` walk, modes and
/// refusals, and the same read-only access for a file from a newer version. A separate file would need all of that again.
///
/// A finding is `(org, rule, subject)`: the rule is a short identifier the report names (`check_in`, `applecare_expiring`),
/// the subject an identifier (a serial number, a service or an activity id), never a name. What a finding says is computed
/// from the latest snapshot each time and isn't kept here. **No secret and no name is ever stored**; the sensitive-key leave-out
/// that snapshot attributes go through has nothing to act on, because nothing here is an attribute.
///
/// Semantics (the coordinating session's proposals, for the operator to confirm; the 30 days is the operator's decision,
/// 2026-11-20: "Yes, forget after 30 days (Recommended)"):
/// - `seen` is called with every subject a rule found in one run. A new subject gets `first_seen`; `first_seen` is never
///   written again for a row that is there, whatever the clock says. `last_seen` moves forward.
/// - A dismissal holds while the finding is there. When it is not seen, the row (dismissal and all) is kept for
///   `Self.forgetAfter` (30 days) of not being seen, so one failed or partial read doesn't lose it, then deleted. A
///   finding that comes back after that is new: its `first_seen` is the new one, undismissed.
/// - A snooze hides the finding until its date, then it shows again with its original `first_seen`.
/// - The latest choice wins: a dismissal clears a snooze, and a snooze clears a dismissal.
extension SnapshotStore {
    /// How long a finding may go unseen before its row is forgotten: the operator's decision, 2026-11-20 ("Yes, forget after
    /// 30 days (Recommended)").
    public static let forgetAfter: TimeInterval = 30 * 24 * 60 * 60

    /// One stored finding.
    public struct Finding: Sendable, Equatable, Hashable {
        public let rule: String
        public let subject: String
        public let firstSeen: Date
        public let lastSeen: Date
        public let dismissedAt: Date?
        public let snoozedUntil: Date?

        /// Whether the list leaves it out at `now`: dismissed, or snoozed to a time not yet reached.
        public func isHidden(at now: Date) -> Bool {
            dismissedAt != nil || (snoozedUntil.map { $0 > now } ?? false)
        }
    }

    /// Records the findings a run of `rule` found for `org` at `at`: `subjects` is all of them, none included. New ones
    /// get `first_seen`; ones already there keep it. Then every finding of **this rule** of the org not seen for
    /// `forgetAfter` is deleted; another rule's rows are never aged by this call.
    ///
    /// **The caller's contract:** call `seen` only for a run that judged the rule over a complete read, `[]` included
    /// (the read was complete and found nothing). For a rule skipped as not read, or a read that was partial (cut at a
    /// page cap, a resource that failed), don't call `seen` at all, not even with `[]`: an empty list would age every
    /// finding of the rule. `at` is the current time; a clock far ahead would age the rule's rows early.
    ///
    /// `rule` and `subject` must be identifiers (`isIdentifier`), so a name can't be stored; else `.notAnIdentifier`.
    public func seen(org: OrgProfile, rule: String, subjects: some Collection<String>, at: Date) throws(Failure) {
        try writable()
        let orgID = try Self.id(of: org)
        guard Self.isIdentifier(rule, limit: NeedsAttention.ruleLimit), subjects.allSatisfy({ Self.isIdentifier($0, limit: NeedsAttention.subjectLimit) }) else { throw .notAnIdentifier }
        let now = Schema.takenAt(at), cutoff = Schema.takenAt(at.addingTimeInterval(-Self.forgetAfter))
        try Self.guarded {
            try database.transaction {
                // `first_seen` is in the INSERT only: the conflict clause never names it.
                let upsert = try database.prepare("""
                    INSERT INTO attention (org_id, rule, subject, first_seen, last_seen) VALUES (?, ?, ?, ?, ?) \
                    ON CONFLICT (org_id, rule, subject) DO UPDATE SET last_seen = MAX(last_seen, excluded.last_seen)
                    """)
                // Not a `Set`: Swift treats canonically equivalent strings (precomposed and decomposed "é") as one, and the
                // table keys by bytes. A duplicate is the upsert's no-op.
                for subject in subjects {
                    try upsert.run([.text(orgID), .text(rule), .text(subject), .text(now), .text(now)])
                }
                try database.run("DELETE FROM attention WHERE org_id = ? AND rule = ? AND last_seen < ?",
                                 [.text(orgID), .text(rule), .text(cutoff)])
            }
        }
    }

    /// Whether `text` can be a rule or a subject: `NeedsAttention.isIdentifier`, the one rule the findings are checked by
    /// too, so a finding the rules call trackable is one this store keeps.
    static func isIdentifier(_ text: String, limit: Int) -> Bool { NeedsAttention.isIdentifier(text, limit: limit) }

    /// The operator dismissed the finding. It must have been recorded by `seen`.
    public func dismiss(org: OrgProfile, rule: String, subject: String, at: Date) throws(Failure) {
        try choose(org: org, rule: rule, subject: subject, set: "dismissed_at = ?, snoozed_until = NULL", Schema.takenAt(at))
    }

    /// The operator snoozed the finding until `until`. It must have been recorded by `seen`.
    public func snooze(org: OrgProfile, rule: String, subject: String, until: Date) throws(Failure) {
        try choose(org: org, rule: rule, subject: subject, set: "snoozed_until = ?, dismissed_at = NULL", Schema.takenAt(until))
    }

    private func choose(org: OrgProfile, rule: String, subject: String, set: String, _ value: String) throws(Failure) {
        try writable()
        let orgID = try Self.id(of: org)
        let changed = try Self.guarded {
            try database.transaction {
                try database.run("UPDATE attention SET \(set) WHERE org_id = ? AND rule = ? AND subject = ?",
                                 [.text(value), .text(orgID), .text(rule), .text(subject)])
                return database.changes
            }
        }
        guard changed == 1 else { throw .noFinding(rule: rule, subject: subject) }
    }

    /// Every finding stored for `org`, by rule and then subject (by bytes). Another org's are never here.
    public func state(org: OrgProfile) throws(Failure) -> [Finding] {
        let orgID = try Self.id(of: org)
        guard hasAttention else { return [] }
        return try Self.guarded {
            try database.rows("""
                SELECT rule, subject, first_seen, last_seen, dismissed_at, snoozed_until FROM attention WHERE org_id = ? \
                ORDER BY rule, subject
                """, [.text(orgID)]) { row in
                guard let first = ISODate.parse(try row.text(2) ?? "")?.date, let last = ISODate.parse(try row.text(3) ?? "")?.date else {
                    throw Failure.corrupt("a finding's dates")
                }
                func optional(_ column: Int32) throws -> Date? {
                    guard let text = try row.text(column) else { return nil }
                    guard let date = ISODate.parse(text)?.date else { throw Failure.corrupt("a finding's dates") }
                    return date
                }
                return Finding(rule: try row.text(0) ?? "", subject: try row.text(1) ?? "", firstSeen: first, lastSeen: last,
                               dismissedAt: try optional(4), snoozedUntil: try optional(5))
            }
        }
    }
}
