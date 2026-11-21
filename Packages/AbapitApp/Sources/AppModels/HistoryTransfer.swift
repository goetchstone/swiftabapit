import AppleModels
import Foundation
import History
import JSONAPI
import Observation
import Orgs

/// Moving history in and out (plan Phase 3; docs/domains/history.md, "Import and export"): copies abapit's `history.sqlite` into
/// this app's snapshot store, read-only, and exports a copy of the store for `sqlite3` or Datasette.
///
/// - **Read-only and one file the operator chose.** The file is opened by `AbapitHistory` (read-only, immutable, no link, abapit's
///   schema or a refusal in words); nothing is written beside it.
/// - **Mapped by client ID, never by name.** A snapshot goes to the Apple org of the active client whose client ID is the
///   snapshot's `org_client_id` (trimmed and lower-cased as `OrgsModel.clientKey` compares them). One no org here has, or
///   that more than one has, is skipped and counted (snapshots and accounts), never put under the active org: the id is
///   a customer's, and a name is only a label. The orgs are those of the client active when the import started; a switch of
///   org or client stops it (the clients rule), and what is on screen is cleared by it.
/// - **Through the snapshot policy.** Every item goes through `SnapshotPolicy.keep` for its resource, as a collected one does:
///   a resource the policy doesn't list is dropped whole, a Business-only one is dropped for a School org, and an attribute
///   off the allowlist is dropped (a package's `url`, a user's name and email, a device's IMEI) and counted. Error text is
///   never carried: only the resource it was for, as the code `abapit error` (`abapit partial` for AppleCare read in part).
/// - **`counts` filled**: each resource that has items in the snapshot is counted, so `SnapshotStore.latest` answers from
///   an imported snapshot. abapit stored no empty list, so a resource it read and found empty looks like one it didn't read:
///   left out of `counts`, never claimed.
/// - **No duplicates**: a snapshot of the org already recorded at the same `taken_at` by `abapit <version>` is the one imported
///   before (`SnapshotStore.recordImported`), counted as already here.
/// - **Oldest first**, in abapit's id order, so the store's ids keep the order the snapshots were taken in.
@MainActor
@Observable
public final class HistoryTransfer {
    /// What an import did.
    public struct Report: Equatable, Sendable {
        /// Snapshots written.
        public var imported = 0
        /// Organizations they were written for.
        public var orgs = 0
        /// Snapshots of an org already in the store (an earlier import of the same file).
        public var alreadyHere = 0
        /// Snapshots no org here has the client ID of, and how many accounts they belong to (never their ids).
        public var skipped = 0
        public var skippedAccounts = 0
        /// Snapshots a row of which didn't read.
        public var unreadable = 0
        /// Attribute values the policy left out of the items kept, and resources it left out whole (a snapshot's resource the
        /// policy doesn't list, or Business-only for a School org).
        public var attributesLeftOut = 0
        public var resourcesLeftOut = 0

        /// The line Settings shows.
        public var words: String {
            var parts = ["Imported \(imported) snapshot\(imported == 1 ? "" : "s") for \(orgs) organization\(orgs == 1 ? "" : "s")."]
            if alreadyHere > 0 { parts.append("\(alreadyHere) \(alreadyHere == 1 ? "was" : "were") already here.") }
            parts.append("\(skipped) skipped because no organization here has that client ID"
                         + (skippedAccounts > 0 ? " (\(skippedAccounts) account\(skippedAccounts == 1 ? "" : "s"))." : "."))
            if unreadable > 0 { parts.append("\(unreadable) couldn't be read.") }
            parts.append("\(attributesLeftOut) attribute\(attributesLeftOut == 1 ? "" : "s") left out by the snapshot policy"
                         + (resourcesLeftOut > 0 ? ", and \(resourcesLeftOut) resource\(resourcesLeftOut == 1 ? "" : "s") it doesn't keep." : "."))
            return parts.joined(separator: " ")
        }
    }

    public enum Outcome: Equatable, Sendable {
        case imported(Report)
        /// An org or client switch stopped it part way: what was written stays (and isn't repeated by importing again). Never
        /// shown, since the switch clears what was on screen.
        case stopped(Report)
        /// Nothing was read or written, and why.
        case refused(String)
    }

    public private(set) var isWorking = false
    /// What the last import or export did, in words; cleared by an org or client switch.
    public private(set) var summary: String?
    /// Why the last one was refused or failed; cleared by a switch.
    public private(set) var problem: String?

    private let orgs: OrgsModel

    static let busy = "An import or export is already running."

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        orgs.onSwitch { [weak self] in
            self?.summary = nil
            self?.problem = nil
        }
    }

    // MARK: import

    /// Imports `file` (abapit's `history.sqlite`) into the snapshot store; says how it ended in `summary` or `problem`.
    @discardableResult
    public func importHistory(from file: URL) async -> Outcome {
        guard !isWorking else { return .refused(Self.busy) }
        isWorking = true
        defer { isWorking = false }
        summary = nil
        problem = nil
        let generation = orgs.generation
        let outcome = await run(file)
        // A result is shown only under the org and client it was for: after a switch it is returned and nothing more.
        guard orgs.generation == generation else { return outcome }
        switch outcome {
        case .imported(let report): summary = report.words
        case .stopped(let report): summary = report.words
        case .refused(let words): problem = words
        }
        return outcome
    }

    private func run(_ file: URL) async -> Outcome {
        let store: SnapshotStore
        switch orgs.openHistory() {
        case .success(let opened): store = opened
        case .failure(let failure): return .refused(failure.message)
        }
        // The orgs and the generation as the import starts: nothing is mapped to an org the operator switched to meanwhile.
        let generation = orgs.generation
        let targets = Self.targets(orgs.clientOrgs)
        let source: AbapitHistory
        let headers: [AbapitHistory.Header]
        do {
            source = try AbapitHistory(file: file)
            headers = try await source.headers()
        } catch {
            return .refused(error.message)
        }
        var report = Report()
        var skippedAccounts: Set<String> = [], written: Set<String> = []
        for header in headers {
            guard orgs.generation == generation else { return .stopped(finish(report, skippedAccounts, written)) }
            guard let org = targets[OrgsModel.clientKey(header.clientID)] else {
                report.skipped += 1
                skippedAccounts.insert(OrgsModel.clientKey(header.clientID))
                continue
            }
            do {
                let snapshot = try await source.load(header)
                guard let taken = ISODate.parse(header.takenAt)?.date else {
                    report.unreadable += 1
                    continue
                }
                let kept = AbapitMapping.keep(snapshot, for: org)
                report.attributesLeftOut += kept.attributesLeftOut
                report.resourcesLeftOut += kept.resourcesLeftOut
                let id = try await store.recordImported(org: org, takenAt: taken, writtenBy: header.writtenBy, resources: kept.resources,
                                                        errors: kept.errors, notes: kept.notes)
                if id == nil {
                    report.alreadyHere += 1
                } else {
                    report.imported += 1
                    written.insert(org.id)
                }
            } catch is AbapitHistory.Failure {
                // One snapshot that doesn't read is counted, and the rest go on.
                report.unreadable += 1
            } catch let failure as SnapshotStore.Failure {
                // The store refused (read-only newer file, a full disk): every later write would fail the same way.
                return .refused(failure.message + " \(report.imported) snapshot\(report.imported == 1 ? " was" : "s were") imported before that.")
            } catch {
                report.unreadable += 1
            }
        }
        return .imported(finish(report, skippedAccounts, written))
    }

    private func finish(_ report: Report, _ skippedAccounts: Set<String>, _ written: Set<String>) -> Report {
        var report = report
        report.skippedAccounts = skippedAccounts.count
        report.orgs = written.count
        return report
    }

    /// The Apple orgs by client ID key. A client ID two orgs hold (`OrgStore` refuses it, but a hand-edited file could) maps to
    /// neither, and an empty one (a Mosyle org's) never matches.
    package static func targets(_ orgs: [OrgProfile]) -> [String: OrgProfile] {
        var found: [String: OrgProfile] = [:], ambiguous: Set<String> = []
        for org in orgs where org.provider == .known(.apple) {
            let key = OrgsModel.clientKey(org.clientID)
            guard !key.isEmpty else { continue }
            if found[key] != nil { ambiguous.insert(key) }
            found[key] = org
        }
        for key in ambiguous { found[key] = nil }
        return found
    }

    // MARK: export

    /// Writes a copy of the snapshot store at `destination` (see `SnapshotStore.exportCopy`); says how it went.
    public func exportCopy(to destination: URL) async {
        guard !isWorking else {
            problem = Self.busy
            return
        }
        isWorking = true
        defer { isWorking = false }
        summary = nil
        problem = nil
        switch orgs.openHistory() {
        case .failure(let failure): problem = failure.message
        case .success(let store):
            do {
                try await store.exportCopy(to: destination)
                summary = "Saved a copy of the snapshot history as \(destination.lastPathComponent)."
            } catch {
                problem = error.message
            }
        }
    }

    /// What the Save panel says the copy holds.
    public static let exportWords = SnapshotStore.exportCopyWords
}

/// What an imported snapshot keeps: the snapshot policy applied to abapit's rows.
enum AbapitMapping {
    struct Kept {
        var resources: [String: [Resource]] = [:]
        var errors: [String: String] = [:]
        var notes: [String: String] = [:]
        var attributesLeftOut = 0
        var resourcesLeftOut = 0
    }

    static let error = "abapit error"
    static let partial = "abapit partial"
    /// abapit's `errors` key for AppleCare read for some devices only (its items are kept, the error says they are part).
    static let applecarePartial = "applecare_partial"

    /// `snapshot` through `SnapshotPolicy` for `org`: only the resources the policy lists (compared by bytes), and of each item
    /// only the attributes it keeps. abapit's error text is never read: a resource it names becomes a code.
    static func keep(_ snapshot: AbapitHistory.Snapshot, for org: OrgProfile) -> Kept {
        let rules = Dictionary(SnapshotPolicy.all.map { (Array($0.name.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        func rule(_ name: String) -> SnapshotPolicy.Rule? {
            guard let rule = rules[Array(name.utf8)], !rule.businessOnly || org.scope == .known(.business) else { return nil }
            return rule
        }
        var kept = Kept()
        for (name, items) in snapshot.resources {
            guard let rule = rule(name) else {
                kept.resourcesLeftOut += 1
                continue
            }
            var masked = 0, left = 0
            kept.resources[rule.name] = items.map { item in
                // A custom setting's profile is withheld first (operator, 2026-10-31): abapit stored the single read's profile, which
            // holds Wi-Fi and VPN passwords, and the policy's `customSettingsValues` is kept for the list read, which sends null.
            let one = SnapshotPolicy.keep(rule.name == SnapshotPolicy.configurations.name ? Configuration(resource: item).resource : item, rule)
                left += item.attributes.count - one.item.attributes.count
                if one.masked { masked += 1 }
                return one.item
            }
            kept.attributesLeftOut += left
            var notes: [String] = []
            if left > 0 { notes.append("\(left) attribute value\(left == 1 ? "" : "s") left out by the snapshot policy") }
            if masked > 0 { notes.append("an address was masked in \(masked) item\(masked == 1 ? "" : "s")") }
            if !notes.isEmpty { kept.notes[rule.name] = notes.joined(separator: "; ") }
        }
        for key in snapshot.errorKeys {
            let isPartial = Array(key.utf8) == Array(applecarePartial.utf8)
            guard let rule = rule(isPartial ? SnapshotPolicy.appleCare.name : key) else {
                kept.resourcesLeftOut += 1
                continue
            }
            // A partial read keeps the stronger code if the resource also failed outright.
            if !isPartial || kept.errors[rule.name] == nil { kept.errors[rule.name] = isPartial ? partial : error }
        }
        return kept
    }
}
