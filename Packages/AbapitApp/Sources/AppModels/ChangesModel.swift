import AppleBusiness
import AppleModels
import Foundation
import History
import JSONAPI
import Observation
import Orgs
import Reports

/// The Changes screen's model (plan Phase 3; docs/domains/history.md, "The Changes screen"): the active org's snapshots, newest
/// first, two of them compared with `SnapshotDiff`, "Snapshot now" over `SnapshotCollector`, and the comparison as a CSV.
///
/// - **A side that wasn't read is never a removal.** A resource is compared only when both snapshots read it in full (it is in
///   the snapshot's `counts` and not in its `errors`). One side not read (not in `counts`: it failed before any item, or the run
///   didn't ask) leaves the resource out, in words that name the side. One side read in part (in both `counts` and `errors`: a
///   page cap, a failure part-way) is marked "partial" and shows only what that side can vouch for: a newer snapshot read in
///   part never shows what the older one has and it lacks as removed, an older one read in part never shows what the newer has
///   and it lacks as added, and each says how many it held back. A changed item (in both) is always real.
/// - **Local history**: readable in a School org and with the audit log refused. Another org's snapshots are never shown: every
///   query is for the captured org, and an org or client switch clears the screen (`onSwitch`); a result that returns after
///   one is dropped.
/// - **Snapshot now** is the collector's run for the active org, its sweeps opt-in for that one run (each is one read per device,
///   shown with the collector's estimate). A Mosyle Business org has no collector yet, said in words. Nothing of a run going for
///   another org is shown (`isRunning`, `reading`, `progress`).
@MainActor
@Observable
public final class ChangesModel {
    // MARK: what is shown

    /// One snapshot, for the list.
    public struct SnapshotRow: Equatable, Sendable, Identifiable {
        public let id: Int64
        /// As the store writes it, UTC to the second.
        public let takenAt: String
        public let date: Date?
        public let devices: Int
        public let writtenBy: String
        /// Resources read in part, by name ("Devices (page cap)").
        public let partial: [String]
        /// Resources that failed before any item was read ("People (HTTP 403)").
        public let notRead: [String]
        /// What was read only in part or left out: the snapshot's notes, per resource ("Devices: left out 2 attributes …").
        public let notes: [String]

        /// "partial: Devices (page cap)" and "not read: People (HTTP 403)", in words; empty when every resource was read in full.
        public var marks: [String] {
            (partial.isEmpty ? [] : ["partial: " + partial.joined(separator: ", ")]) + (notRead.isEmpty ? [] : ["not read: " + notRead.joined(separator: ", ")])
        }
    }

    /// An added or removed item: its id and its label (`SnapshotDiff.label`, else the id).
    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
    }

    public struct FieldChange: Equatable, Sendable {
        public let field: String
        /// As shown (`SnapshotDiff.shown`): secrets withheld.
        public let old: String
        public let new: String
    }

    public struct ChangedEntry: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let fields: [FieldChange]
    }

    /// What differs in one resource, over what both snapshots can vouch for.
    public struct ResourceChange: Equatable, Sendable, Identifiable {
        public let resource: String
        public let title: String
        /// One side or both was read in part.
        public let partial: Bool
        public let added: [Entry]
        public let removed: [Entry]
        public let changed: [ChangedEntry]
        /// What a part read held back, in words ("3 items in the older snapshot aren't in the newer, which was read in part …").
        public let withheld: [String]
        public var id: String { resource }

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        /// "2 added, 1 removed, 3 changed"; "no change among the items read" when nothing differs.
        public var counts: String {
            let parts = [added.isEmpty ? nil : "\(added.count) added", removed.isEmpty ? nil : "\(removed.count) removed",
                         changed.isEmpty ? nil : "\(changed.count) changed"].compactMap { $0 }
            return parts.isEmpty ? "no change among the items read" : parts.joined(separator: ", ")
        }
    }

    /// A resource left out of the comparison, and why. A resource neither snapshot has a word about (a sweep not chosen, a School
    /// org's Business-only list) is not listed: there is nothing to say of it.
    public struct Skipped: Equatable, Sendable, Identifiable {
        public let resource: String
        public let title: String
        /// In words: "not read in the newer snapshot (HTTP 403), so no change is shown."
        public let why: String
        public var id: String { resource }
    }

    /// Two snapshots compared.
    public struct Comparison: Equatable, Sendable {
        public let older: SnapshotRow
        public let newer: SnapshotRow
        /// The resources with a change, or read in part (so never silent), in code-point order.
        public let changes: [ResourceChange]
        public let skipped: [Skipped]
        /// Resources read in full on both sides with nothing different.
        public let unchanged: [String]
        /// What the CSV and the screen's counts are made from: `changes` as `SnapshotDiff` yields them, after a part read's
        /// held-back items are taken out.
        package let deltas: [SnapshotDiff.Delta]

        public var hasChanges: Bool { changes.contains { !$0.isEmpty } }
    }

    // MARK: state

    public private(set) var state: LoadState = .idle
    public private(set) var rows: [SnapshotRow] = []
    /// The pair compared: the newest and the one before by default (`rows` is newest first). `choose` sets them.
    public private(set) var olderID: Int64?
    public private(set) var newerID: Int64?
    public private(set) var comparison: Comparison?
    /// Why there is no comparison: fewer than two snapshots, the same one twice, or a snapshot that wouldn't read.
    public private(set) var comparisonProblem: String?
    /// The sweeps the next Snapshot now runs, chosen for that one run: empty after each.
    public private(set) var sweeps: Set<Sweep> = []
    /// Each available sweep's estimate, made from the newest snapshot's device counts at the org's rate now. Nil per sweep until made.
    public private(set) var estimates: [Sweep: Sweep.Estimate] = [:]
    /// What the estimates were counted from, in words; nil when the history has no device count.
    public private(set) var estimateBasis: String?
    /// How the last Snapshot now ended, in words; cleared by a new run and by a switch.
    public private(set) var result: String?
    /// Loads that have returned: what the tests wait on.
    package private(set) var loadsFinished = 0

    private let orgs: OrgsModel
    private let collector: SnapshotCollector
    /// Newest snapshot's counts, for the estimates.
    @ObservationIgnored private var newestCounts: [String: Int]?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var compareToken = 0

    public static let mosyleWords = "Snapshots of a Mosyle Business organization aren't built yet: this version takes Apple Business and Apple School Manager snapshots only. Nothing was read from Mosyle."
    static let needTwo = "Take a second snapshot to compare: a comparison needs two."
    static let needDifferent = "Choose two different snapshots."

    public init(orgs: OrgsModel, collector: SnapshotCollector) {
        self.orgs = orgs
        self.collector = collector
        orgs.onSwitch { [weak self] in self?.switched() }
    }

    /// An org or client switch: nothing of the old org stays (the clients rule), and a load or comparison in flight is dropped.
    private func switched() {
        let wasShowing = state != .idle
        loadToken += 1
        compareToken += 1
        state = .idle
        rows = []
        olderID = nil
        newerID = nil
        comparison = nil
        comparisonProblem = nil
        sweeps = []
        estimates = [:]
        estimateBasis = nil
        newestCounts = nil
        result = nil
        // The screen on show reads the new org's history, as the other screens do.
        if wasShowing { refresh() }
    }

    // MARK: the run, as the screen shows it

    /// A Mosyle Business org: no collector yet.
    public var isMosyle: Bool { orgs.active?.provider == .known(.mosyle) }

    /// Whether a snapshot of the active org is being taken. A run going for the org before a switch is not: it is stopping, and
    /// the screen says nothing of it but that (`startBlocked`).
    public var isRunning: Bool { collector.isRunningForActiveOrg }

    /// The resource being read, in words; nil unless a run for this org goes.
    public var reading: String? { isRunning ? collector.reading.map(Self.title(of:)) : nil }

    /// The sweep running, devices answered of devices covered; nil unless a run for this org goes.
    public var progress: String? { isRunning ? collector.sweepProgress?.words : nil }

    /// The estimate the run made once its lists were read, for the sweeps it chose; nil unless a run for this org goes.
    public var runEstimate: String? { isRunning ? collector.sweepEstimate?.words : nil }

    /// Why a call was refused while a run went, in words (the collector's), nil once the run ends or an org switch comes.
    public var refusal: String? { collector.refusal }

    /// Why Snapshot now is off: no org, a Mosyle org, a run going, or a run of the previous org still stopping. Nil when it can start.
    public var startBlocked: String? {
        if orgs.active == nil { return ScreenWords.noOrganization }
        if isMosyle { return Self.mosyleWords }
        if isRunning { return "A snapshot is being taken." }
        if collector.isRunning { return SnapshotCollector.windingDown }
        return nil
    }

    /// The sweeps this org can run: Apple MDM's details are Business-only.
    public var availableSweeps: [Sweep] {
        guard let profile = orgs.active, !isMosyle else { return [] }
        return Sweep.allCases.filter { !$0.rule.businessOnly || profile.scope == .known(.business) }
    }

    public func set(_ sweep: Sweep, on: Bool) {
        guard availableSweeps.contains(sweep) else { return }
        if on { sweeps.insert(sweep) } else { sweeps.remove(sweep) }
    }

    /// One sweep's line before the run: its title and the collector's estimate (which says it is one), or why there is none yet.
    public func estimateLine(_ sweep: Sweep) -> String {
        guard let estimate = estimates[sweep] else {
            return "\(sweep.title): the time can't be estimated yet. It needs a device count, which the first snapshot's device list gives."
        }
        return "\(sweep.title): \(estimate.words)"
    }

    /// Takes a snapshot of the active org, with the sweeps chosen, which are then cleared (each run asks again). Refuses a Mosyle
    /// org in words. The outcome is in `result` while the org is still on screen; one that returns after a switch is dropped.
    @discardableResult
    public func snapshotNow() async -> SnapshotCollector.Outcome? {
        guard orgs.active != nil else {
            result = ScreenWords.noOrganization
            return nil
        }
        guard !isMosyle else {
            result = Self.mosyleWords
            return nil
        }
        // A call while a run goes is refused by the collector, whose `refusal` says so until that run ends.
        let busy = collector.isRunning
        if !busy { result = nil }
        let chosen = sweeps.intersection(availableSweeps)
        if !busy { sweeps = [] }
        let generation = orgs.generation
        let outcome = await collector.run(sweeps: chosen)
        if busy || generation != orgs.generation { return outcome }
        result = Self.words(outcome)
        if case .recorded = outcome { await load() }
        return outcome
    }

    /// Stops the run going: nothing is written.
    public func cancel() { collector.cancel() }

    static func words(_ outcome: SnapshotCollector.Outcome) -> String {
        switch outcome {
        case .recorded: "Snapshot taken."
        case .cancelled: "Cancelled: nothing was written."
        case .notRun(let why): "No snapshot was taken: \(why)"
        case .notRecorded(let why): "Apple was read, but the snapshot wasn't recorded: \(why)"
        }
    }

    // MARK: loading

    /// Reads the history again (⌘R, the toolbar): the local file, never Apple.
    public func refresh() { Task { await load() } }

    /// Reads the active org's snapshots from the history, newest first, keeps the pair chosen if both are still there (else the
    /// newest and the one before), and compares them.
    public func load() async {
        loadToken += 1
        let token = loadToken, generation = orgs.generation
        defer { loadsFinished += 1 }
        guard let profile = orgs.active else {
            state = .unusable(ScreenWords.noOrganization)
            return
        }
        state = .loading(count: 0)
        let store: SnapshotStore
        switch orgs.openHistory() {
        case .success(let opened): store = opened
        case .failure(let failure):
            rows = []
            state = .failed(failure.message)
            return
        }
        let summaries: [SnapshotStore.Summary]
        do {
            summaries = try await store.snapshots(org: profile)
        } catch {
            guard token == loadToken, generation == orgs.generation else { return }
            rows = []
            state = .failed(error.message)
            return
        }
        guard token == loadToken, generation == orgs.generation else { return }
        rows = summaries.map(Self.row)
        newestCounts = summaries.first?.counts
        state = .loaded(at: Date())
        let ids = Set(rows.map(\.id))
        if let older = olderID, let newer = newerID, ids.contains(older), ids.contains(newer) {
            // The pair stays.
        } else {
            newerID = rows.first?.id
            olderID = rows.count > 1 ? rows[1].id : nil
        }
        await compare()
        await refreshEstimates()
    }

    /// Chooses the two snapshots to compare. Either order: the older of the two is the older (`rows` is newest first).
    public func choose(older: Int64?, newer: Int64?) async {
        var older = older, newer = newer
        if let a = older, let b = newer, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == b }), i < j {
            swap(&older, &newer)
        }
        olderID = older
        newerID = newer
        await compare()
    }

    /// Compares the pair chosen, off the main actor (a fleet's two snapshots are thousands of items each).
    public func compare() async {
        compareToken += 1
        let token = compareToken, generation = orgs.generation
        guard let profile = orgs.active, let older = olderID, let newer = newerID, older != newer else {
            comparison = nil
            comparisonProblem = rows.count < 2 ? Self.needTwo : Self.needDifferent
            return
        }
        guard case .success(let store) = orgs.openHistory() else { return }
        let first: SnapshotStore.Snapshot, second: SnapshotStore.Snapshot
        do {
            first = try await store.load(older, org: profile)
            second = try await store.load(newer, org: profile)
        } catch {
            guard token == compareToken, generation == orgs.generation else { return }
            comparison = nil
            comparisonProblem = error.message
            return
        }
        let made = await Task.detached { Self.compare(older: first, newer: second) }.value
        guard token == compareToken, generation == orgs.generation else { return }
        comparison = made
        comparisonProblem = nil
    }

    /// The estimates for the sweeps this org can run, from the newest snapshot's device counts at the org's rate now.
    private func refreshEstimates() async {
        let generation = orgs.generation
        guard let counts = newestCounts, let devices = counts["devices"] else {
            estimates = [:]
            estimateBasis = nil
            return
        }
        let managed = counts["mdm_enrolled"] ?? 0
        var made: [Sweep: Sweep.Estimate] = [:]
        for sweep in availableSweeps {
            if let estimate = await collector.estimate([sweep], devices: devices, appleManaged: managed) { made[sweep] = estimate }
        }
        guard generation == orgs.generation else { return }
        estimates = made
        estimateBasis = "Counted from the newest snapshot: \(devices) device\(devices == 1 ? "" : "s")"
            + (availableSweeps.contains(.mdmDetails) ? ", \(managed) managed by Apple MDM." : ".")
    }

    // MARK: the comparison

    /// Compares two snapshots (a pure function: the tests hold it). See the type's note for what is never shown as a removal.
    nonisolated static func compare(older: SnapshotStore.Snapshot, newer: SnapshotStore.Snapshot) -> Comparison {
        enum Read: Equatable {
            case whole
            case partial(String?)
            case notRead(String?)
        }
        func read(_ snapshot: SnapshotStore.Snapshot, _ resource: String) -> Read {
            let summary = snapshot.summary
            guard summary.counts[resource] != nil else { return .notRead(summary.errors[resource]) }
            return summary.errors[resource].map(Read.partial) ?? .whole
        }
        var names = Set<String>()
        for snapshot in [older, newer] {
            names.formUnion(snapshot.summary.counts.keys)
            names.formUnion(snapshot.summary.errors.keys)
            names.formUnion(snapshot.resources.keys)
        }
        var skipped: [Skipped] = [], comparable: [String] = [], reads: [String: (Read, Read)] = [:]
        for resource in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let before = read(older, resource), after = read(newer, resource)
            let title = Self.title(of: resource)
            func why(_ side: String, _ read: Read) -> String {
                if case .notRead(let code?) = read { return "not read in the \(side) snapshot (\(code))" }
                return "not read in the \(side) snapshot"
            }
            switch (before, after) {
            case (.notRead, .notRead):
                skipped.append(Skipped(resource: resource, title: title, why: "not read in either snapshot, so no change is shown."))
            case (.notRead, _):
                skipped.append(Skipped(resource: resource, title: title, why: why("older", before) + ", so no change is shown."))
            case (_, .notRead):
                skipped.append(Skipped(resource: resource, title: title, why: why("newer", after) + ", so no change is shown."))
            default:
                comparable.append(resource)
                reads[resource] = (before, after)
            }
        }
        func snapshot(_ source: SnapshotStore.Snapshot) -> SnapshotDiff.Snapshot {
            SnapshotDiff.Snapshot(rows: comparable.flatMap { resource in
                (source.resources[resource] ?? []).map { (resource: resource, id: $0.id, attributes: $0.attributes) }
            })
        }
        let found = Dictionary(uniqueKeysWithValues: SnapshotDiff.diff(old: snapshot(older), new: snapshot(newer)).map { ($0.resource, $0) })
        var changes: [ResourceChange] = [], deltas: [SnapshotDiff.Delta] = [], unchanged: [String] = []
        for resource in comparable {
            let (before, after) = reads[resource] ?? (.whole, .whole)
            let delta = found[resource] ?? SnapshotDiff.Delta(resource: resource, added: [], removed: [], changed: [])
            var withheld: [String] = []
            var added = delta.added, removed = delta.removed
            if case .partial(let code) = after, !removed.isEmpty {
                withheld.append("\(Self.items(removed.count)) in the older snapshot \(removed.count == 1 ? "isn't" : "aren't") in the newer, which was read in part"
                                + (code.map { " (\($0))" } ?? "") + ": not shown as removed, since it may only not have been read.")
                removed = []
            }
            if case .partial(let code) = before, !added.isEmpty {
                withheld.append("\(Self.items(added.count)) in the newer snapshot \(added.count == 1 ? "isn't" : "aren't") in the older, which was read in part"
                                + (code.map { " (\($0))" } ?? "") + ": not shown as added, since it may only not have been read.")
                added = []
            }
            let partial = before != .whole || after != .whole
            if !partial && delta.added.isEmpty && delta.removed.isEmpty && delta.changed.isEmpty {
                unchanged.append(Self.title(of: resource))
                continue
            }
            let shown = SnapshotDiff.Delta(resource: resource, added: added, removed: removed, changed: delta.changed)
            if !(added.isEmpty && removed.isEmpty && delta.changed.isEmpty) { deltas.append(shown) }
            changes.append(ResourceChange(
                resource: resource, title: Self.title(of: resource), partial: partial,
                added: added.map { Entry(id: $0.id, label: Self.label($0.attributes, $0.id)) },
                removed: removed.map { Entry(id: $0.id, label: Self.label($0.attributes, $0.id)) },
                changed: delta.changed.map { change in
                    ChangedEntry(id: change.id, label: Self.label(change.attributes, change.id), fields: change.fields.map {
                        FieldChange(field: $0.field, old: SnapshotDiff.shown($0.old, field: $0.field), new: SnapshotDiff.shown($0.new, field: $0.field))
                    })
                },
                withheld: withheld))
        }
        return Comparison(older: row(older.summary), newer: row(newer.summary), changes: changes, skipped: skipped, unchanged: unchanged, deltas: deltas)
    }

    private nonisolated static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    private nonisolated static func label(_ attributes: JSONObject, _ id: String) -> String {
        let label = SnapshotDiff.label(attributes)
        return label.isEmpty ? id : label
    }

    nonisolated static func row(_ summary: SnapshotStore.Summary) -> SnapshotRow {
        let byName = { (a: String, b: String) in a.utf8.lexicographicallyPrecedes(b.utf8) }
        func code(_ resource: String) -> String { summary.errors[resource].map { " (\($0))" } ?? "" }
        let partial = summary.counts.keys.filter { summary.errors[$0] != nil }.sorted(by: byName).map { title(of: $0) + code($0) }
        let notRead = summary.errors.keys.filter { summary.counts[$0] == nil }.sorted(by: byName).map { title(of: $0) + code($0) }
        let notes = summary.notes.keys.sorted(by: byName).map { "\(title(of: $0)): \(summary.notes[$0] ?? "")" }
        return SnapshotRow(id: summary.id, takenAt: summary.takenAt, date: summary.date, devices: summary.deviceCount, writtenBy: summary.writtenBy,
                           partial: partial, notRead: notRead, notes: notes)
    }

    /// A resource's name as a person reads it; one this version doesn't know keeps the store's name.
    public nonisolated static func title(of resource: String) -> String {
        switch resource {
        case "devices": "Devices"
        case "mdm_servers": "Device management services"
        case "assignments": "Assignments"
        case "users": "People"
        case "user_groups": "User groups"
        case "apps": "Apps"
        case "packages": "Packages"
        case "blueprints": "Blueprints"
        case "configurations": "Configurations"
        case "mdm_enrolled": "Apple MDM devices"
        case "applecare": "AppleCare coverage"
        case "activation_lock": "Activation Lock"
        case "mdm_details": "Apple MDM details"
        default: resource
        }
    }

    // MARK: the CSV

    /// Why Export is off; nil when there is a comparison to write.
    public var exportBlocked: String? {
        comparison == nil ? (comparisonProblem ?? "Choose two snapshots to compare first.") : nil
    }

    /// The file's name, naming the client only when the app shows clients (the clients rule).
    public var exportFileName: String {
        guard let comparison else { return ScreenWords.filename("changes.csv", client: orgs.exportClient) }
        return ScreenWords.filename("changes \(Self.stamp(comparison.older.takenAt)) to \(Self.stamp(comparison.newer.takenAt)).csv", client: orgs.exportClient)
    }

    /// What the Save panel says the file holds.
    public var exportWords: String {
        let who = orgs.active.map { "\"\($0.name.isEmpty ? $0.id : $0.name)\"" } ?? "this organization"
        let client = orgs.exportClient.map { " It is client \"\($0)\"'s data only." } ?? ""
        let when = comparison.map { " taken \($0.older.takenAt) and \($0.newer.takenAt)" } ?? ""
        return "Saves what differs between two snapshots of \(who)\(when): a row for each item added or removed and each field changed, "
            + "with serial numbers, labels and the attributes snapshots keep, and a row for each resource not compared and why. "
            + "A value under a secret's name is withheld. No key or token is in it." + client
    }

    /// The comparison as CSV (`ExportHistory.snapshotDiff`): empty text when there is none.
    public func csv() -> String {
        guard let comparison else { return "" }
        var skipped = comparison.skipped.map { ExportHistory.NotCompared(resource: $0.resource, why: $0.why) }
        for change in comparison.changes { for words in change.withheld { skipped.append(ExportHistory.NotCompared(resource: change.resource, why: words)) } }
        return ExportHistory.snapshotDiff(older: comparison.older.takenAt, newer: comparison.newer.takenAt, deltas: comparison.deltas, notCompared: skipped)
    }

    /// `2026-11-20T08:00:00Z` as `20261120T080000Z`: a file name holds no colon.
    nonisolated static func stamp(_ takenAt: String) -> String { takenAt.filter { $0 != "-" && $0 != ":" } }
}
