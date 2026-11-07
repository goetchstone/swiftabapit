import Foundation

/// What every screen says the same way, written once (Phase 2b review L10: the "No organization yet" sentence was written
/// six times, Apple MDM's without "or Apple School Manager"; People alone said an empty list had nothing to export; three
/// day formatters).
public enum ScreenWords {
    public static let noOrganization = "No organization yet: add an Apple Business or Apple School Manager API account in Settings."

    /// Why nothing can be read, as a sentence: no org yet, or one this version can't use.
    @MainActor
    public static func unusable(_ orgs: OrgsModel) -> String {
        orgs.active == nil ? noOrganization : "This organization can't be used: \(orgs.unusableReason ?? "it has no Apple API account.")"
    }

    /// An item, a group or a device whose id `AppleRead.isPathSafe` refuses: nothing is sent, and it is never called "no
    /// such item", which the client's `.notFound` would say of an item Apple has just listed (Phase 2b review L1).
    public static let unsendableID = "This id can't be sent to Apple, so nothing was asked for."

    public static let nothingToExport = "There's nothing to export."

    /// Why a list's Export is off, in words, by one rule for every screen: still loading; partial (the `read` rows of a walk
    /// that failed or was refused are never exported as if whole: the file couldn't say so); or nothing `shown` to export.
    /// Nil when it exports: a list the page cap stopped exports, as its banner says "showing N of ≥M".
    static func exportBlocked(_ state: LoadState, read: Int, shown: Int, noun: String) -> String? {
        switch state {
        case .loading: return "The list is still loading."
        case .failed, .forbidden:
            if read > 0 { return "The list is partial: \(read.formatted()) \(noun) were read before the error. Refresh, then export." }
        default: break
        }
        return shown == 0 ? nothingToExport : nil
    }

    /// A day as the tables and the inspectors show it; a dash for none. `distantPast` is none too: the rows sort an undated
    /// item first by it.
    public static func day(_ date: Date?) -> String {
        guard let date, date != .distantPast else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
