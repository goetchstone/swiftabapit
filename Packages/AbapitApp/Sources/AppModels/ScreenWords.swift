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

    /// An export's file name: the client's name before it when the app shows clients, so a file says whose data it holds
    /// (plan §8.0, "Clients": no export mixes clients, and each names its own). A `/` or `:` in the name, which a file name
    /// can't hold, is a `-`.
    public static func filename(_ base: String, client: String?) -> String {
        guard let client, !client.isEmpty else { return base }
        let safe = String(String.UnicodeScalarView(client.unicodeScalars.map { $0 == "/" || $0 == ":" ? "-" : $0 }))
        return "\(safe) - \(base)"
    }

    /// What every School screen and Settings say until a school has tested the app (the operator, 2026-11-12).
    public static let schoolUnverified = "Apple School Manager support is built from Apple's published documentation and isn't verified on a live tenant yet."

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
