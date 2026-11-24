import AppleModels
import Foundation
import History
import JSONAPI
import Mosyle
import Observation
import Orgs
import Reports

/// The Needs-attention screen's model (plan §8.0, "Needs attention"; docs/domains/history.md, "The Needs-attention screen"): the
/// active client's twelve rules (`Reports/NeedsAttention.swift`) over what this app already reads, what each found, when each finding
/// was first seen, and the operator's Dismiss and Snooze, which are writes to the local history only.
///
/// - **Where each rule's data comes from** (`source(of:)`): one place per rule, never a live list mixed with a snapshot's.
///   - **Live**: the lists the Devices and Mosyle screens read (Apple's devices, the services and each one's device list, Mosyle's
///     devices). Missing from Mosyle, in Mosyle and not in Apple, Mosyle check-in, the quiet service and the migration deadline.
///   - **A sweep's snapshot**: the snapshot the Reports screen would use for that sweep (`ReportsModel.read`, its `unread` handling
///     through `ReportsModel.coverage`, `lockReads` and `detailReads`), with that snapshot's own list. AppleCare, Activation Lock, and
///     the Apple MDM details (check-in, FileVault, the firewall).
///   - **Apple MDM's list from a snapshot**, with that snapshot's own devices, services and service device lists: missing from Apple
///     MDM and enrolled in Apple MDM but not in Apple. This screen never starts the Apple MDM screen's read, whose 50 detail reads it
///     wouldn't use (the executor's decision).
/// - **Recorded only when judged whole** (the operator, 2026-11-20): a rule's subjects go to `SnapshotStore.seen` only when its verdict is
///   `.judged`; a partial run's findings are shown, marked partial, and not recorded; a skipped rule records nothing and says why.
/// - **Which org a finding is kept under** (the coordinating session's decision): every rule under the client's Apple org, the device's
///   home, but Mosyle check-in, which reads Mosyle alone, under the Mosyle org. Another client's findings are never read or written.
/// - **One client at a time**: a switch clears everything at once, and a read or an evaluation that returns after one is dropped.
@MainActor
@Observable
public final class NeedsAttentionModel {
    public typealias Rule = NeedsAttention.Rule

    // MARK: where each rule reads

    /// Where a rule's data comes from. Each rule reads one source.
    public enum Source: Hashable, Sendable {
        /// The Devices and Mosyle screens' live lists.
        case live
        /// A snapshot's per-device sweep, with that snapshot's own list.
        case sweep(Sweep)
        /// Apple MDM's device list from a snapshot, with that snapshot's devices, services and service device lists.
        case appleMDM
    }

    public static func source(of rule: Rule) -> Source {
        switch rule {
        case .missingFromAppleMDM, .appleMDMNotInApple: .appleMDM
        case .appleCareExpiring: .sweep(.appleCare)
        case .activationLock: .sweep(.activationLock)
        case .appleMDMCheckIn, .fileVaultOff, .firewallOff: .sweep(.mdmDetails)
        case .missingFromMosyle, .mosyleNotInApple, .mosyleCheckIn, .quietService, .migrationDeadline: .live
        }
    }

    /// The org a rule's findings are kept under.
    public enum Keeper: Sendable, Equatable {
        case apple, mosyle
    }

    /// The coordinating session's decision: a rule that spans the client's Apple and Mosyle orgs is kept under the Apple org (every
    /// such rule needs it, and it is where the device lives); a rule that reads Mosyle alone is kept under the Mosyle org.
    public static func keeper(of rule: Rule) -> Keeper { rule == .mosyleCheckIn ? .mosyle : .apple }

    /// What the history is read for: the three sweeps over their own lists, and Apple MDM's list with the lists it is compared with.
    nonisolated static let wanted: [ReportsModel.Wanted] = Sweep.allCases.map(ReportsModel.Wanted.sweep)
        + [ReportsModel.Wanted(SnapshotPolicy.mdmEnrolled.name, list: SnapshotPolicy.devices.name,
                               others: [SnapshotPolicy.services.name, SnapshotPolicy.assignments.name])]

    // MARK: what the screen shows

    public struct Finding: Identifiable, Sendable {
        public let id: String
        public let rule: Rule
        /// A serial number or an id, never a name.
        public let subject: String
        public let reason: String
        /// Found over a part read: shown, never kept.
        public let isPartial: Bool
        /// When it was first recorded; nil when it isn't kept.
        public let firstSeen: Date?
        public let dismissedAt: Date?
        public let snoozedUntil: Date?
        /// Dismissed, or snoozed to a date not reached: left out unless hidden findings are shown.
        public let isHidden: Bool
        /// Why Dismiss and Snooze can't act on it, in words; nil when they can.
        public let actionsBlocked: String?
    }

    /// One rule: its verdict, what it found and why it couldn't judge more, and where its data came from.
    public struct Line: Identifiable, Sendable {
        public let rule: Rule
        public let title: String
        public let verdict: NeedsAttention.Verdict
        /// Every finding, hidden ones included (`Finding.isHidden`).
        public let findings: [Finding]
        /// The rule's own words: what it found or why it was skipped, what a partial run left out, its notes.
        public let words: [String]
        /// Where its data came from, and how old it is.
        public let source: [String]
        public var id: String { rule.rawValue }

        /// The findings not dismissed or snoozed.
        public var open: [Finding] { findings.filter { !$0.isHidden } }
        public var hidden: Int { findings.count - open.count }
        public var isSkipped: Bool { if case .skipped = verdict { true } else { false } }
        public var isPartial: Bool { if case .partial = verdict { true } else { false } }

        /// The verdict in a few words, for a section's header and the Overview's card.
        public var verdictWords: String {
            switch verdict {
            case .judged: "judged"
            case .partial: "partial: not kept"
            case .skipped: "skipped"
            }
        }
    }

    /// One rule's evaluation: the rules' result, or why its source gave it nothing to judge.
    struct Evaluated: Sendable {
        let rule: Rule
        let result: NeedsAttention.RuleResult?
        /// Why the rule wasn't run, when `result` is nil.
        let skip: String?
        let source: [String]
    }

    /// The findings kept for later, by rule and subject (by bytes, as the store keys them).
    struct Key: Hashable, Sendable {
        let rule: String
        let subject: [UInt8]
    }

    // MARK: state

    /// The snapshot history's read.
    public private(set) var state: LoadState = .idle
    /// The last evaluation, one per rule in the rules' order; empty until the first.
    private var evaluated: [Evaluated] = []
    private var stored: [Key: SnapshotStore.Finding] = [:]
    /// When the last evaluation ran.
    public private(set) var evaluatedAt: Date?
    /// Why what was found isn't kept for later (the history can't be opened or written), in the store's own words; nil when it is.
    public private(set) var recordNote: String?
    /// What the last Dismiss or Snooze said, when it couldn't be done.
    public private(set) var actionNote: String?
    /// Why the Mosyle service setting wasn't saved.
    public private(set) var settingNote: String?
    /// Whether dismissed and snoozed findings are listed.
    public var showsHidden = false

    @ObservationIgnored package private(set) var sources: [String: ReportsModel.SweepSource] = [:]
    /// Bumped each time `sources` is set: part of the evaluation's key.
    private var sourcesStamp = 0
    @ObservationIgnored private var evaluatedKey: InputKey?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var evaluateToken = 0
    /// Loads and evaluations that have returned, kept or dropped: what the tests wait on.
    package private(set) var loadsFinished = 0
    package private(set) var evaluationsFinished = 0
    /// Run after a read's or an evaluation's await, before its guard, when set: the tests switch clients there. Stages: `load`, `evaluate`.
    @ObservationIgnored package var afterAwait: (@MainActor (String) async -> Void)?
    /// Awaited once, before the first load, when set: the demo's seeding finishes first.
    @ObservationIgnored public var beforeFirstLoad: (@MainActor () async -> Void)?
    @ObservationIgnored package var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored package var dates = ReportsModel.DateWords(timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent)

    private var settings: LocalSettings
    private let orgs: OrgsModel
    private let devices: DevicesModel
    private let mosyle: MosyleModel

    public static let mosyleWords = "This is a Mosyle Business organization. Needs attention runs from the client's Apple organization: make it active to see what needs attention."

    public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel) {
        self.orgs = orgs
        self.devices = devices
        self.mosyle = mosyle
        settings = orgs.folder.map(LocalSettings.load(from:)) ?? LocalSettings()
        orgs.onSwitch { [weak self] in self?.switched() }
    }

    /// A switch of client or org: nothing of the old one stays (the clients rule). A read or an evaluation in flight is dropped by its
    /// generation guard.
    private func switched() {
        let wasShowing = state != .idle
        state = .idle
        sources = [:]
        sourcesStamp += 1
        evaluated = []
        stored = [:]
        evaluatedAt = nil
        evaluatedKey = nil
        recordNote = nil
        actionNote = nil
        settingNote = nil
        showsHidden = false
        if wasShowing { refresh() }
    }

    /// The active org when it is an Apple org: every rule but Mosyle check-in is kept under it.
    private var appleOrg: OrgProfile? { orgs.active?.provider == .known(.apple) ? orgs.active : nil }

    // MARK: loading

    public func refresh() { Task { await load() } }

    /// Asks the Devices and Mosyle models for the lists the rules read live (the reads their screens make, never a sweep), reads the
    /// active org's history for the sweeps and Apple MDM's list, then evaluates.
    public func load() async {
        if let first = beforeFirstLoad {
            beforeFirstLoad = nil
            await first()
        }
        loadToken += 1
        let token = loadToken, generation = orgs.generation
        defer { loadsFinished += 1 }
        guard let profile = orgs.active else {
            state = .unusable(ScreenWords.noOrganization)
            return
        }
        guard profile.provider == .known(.apple) else {
            state = .unusable(Self.mosyleWords)
            return
        }
        readLive()
        state = .loading(count: 0)
        let outcome: Result<[String: ReportsModel.SweepSource], SnapshotStore.Failure>
        switch orgs.openHistory() {
        case .success(let store):
            do {
                outcome = .success(try await ReportsModel.read(store, org: profile, Self.wanted))
            } catch {
                outcome = .failure(error)
            }
        case .failure(let failure):
            outcome = .failure(failure)
        }
        await afterAwait?("load")
        guard token == loadToken, generation == orgs.generation else { return }
        switch outcome {
        case .success(let read):
            sources = read
            state = .loaded(at: Date())
        case .failure(let failure):
            sources = [:]
            state = .failed(failure.message)
        }
        sourcesStamp += 1
        await evaluate(force: true)
    }

    /// The live lists the rules read: the Devices screen's, and the Mosyle screen's devices when the client has a Mosyle org.
    package func readLive(force: Bool = false) {
        devices.load(force: force)
        if orgs.mosyleOrg != nil { mosyle.loadDevices(force: force) }
    }

    // MARK: evaluating

    /// What an evaluation was made from: when any of it changes, the screen evaluates again (`evaluate`). A finished read carries its
    /// time, so a Refresh that reads the same counts is a new key. A list still being read is one key however many pages have come
    /// (its rules are skipped until it ends), so the rules aren't run and recorded again for every page.
    public struct InputKey: Equatable, Sendable {
        let generation: Int
        let history: LoadState
        let sources: Int
        let devices: LoadState
        let deviceRows: Int
        let services: LoadState
        let serviceRows: Int
        let serviceLists: Int
        let mosyle: LoadState
        let mosyleRows: Int
        let setting: String?
        let thresholds: LocalSettings.Thresholds
    }

    public var inputKey: InputKey {
        func settled(_ state: LoadState, _ rows: Int) -> (LoadState, Int) { state.isLoading ? (.loading(count: 0), 0) : (state, rows) }
        let (apple, rows) = settled(devices.state, devices.rows.count), (services, serviceRows) = settled(devices.servicesState, devices.services.count)
        let (mosyleState, mosyleRows) = settled(mosyle.devices.state, mosyle.devices.rows.count)
        return InputKey(generation: orgs.generation, history: state.isLoading ? .loading(count: 0) : state, sources: sourcesStamp, devices: apple,
                        deviceRows: rows, services: services, serviceRows: serviceRows, serviceLists: devices.serviceDevices.count,
                        mosyle: mosyleState, mosyleRows: mosyleRows, setting: mosyleServiceID, thresholds: settings.thresholds)
    }

    /// Runs the rules over what is held now, records what was judged whole (`SnapshotStore.seen`, under each rule's keeper), and reads the
    /// findings kept for later. Does nothing when nothing it reads has changed since the last evaluation, unless `force`.
    public func evaluate(force: Bool = false) async {
        let key = inputKey
        guard force || key != evaluatedKey else { return }
        evaluateToken += 1
        let token = evaluateToken, generation = orgs.generation
        defer { evaluationsFinished += 1 }
        guard let apple = appleOrg else { return }
        let mosyleOrg = orgs.mosyleOrg
        let now = now()
        let made = evaluations(now: now)
        var problem: String?
        var kept: [Key: SnapshotStore.Finding] = [:]
        switch orgs.history {
        case .success(let store):
            for item in made {
                guard let subjects = item.result?.subjectsToRecord else { continue }
                guard let org = Self.keeper(of: item.rule) == .apple ? apple : mosyleOrg else { continue }
                do {
                    try await store.seen(org: org, rule: item.rule.rawValue, subjects: subjects, at: now)
                } catch {
                    problem = "What was found isn't kept for later (first seen, Dismiss, Snooze): \(error.message)"
                    break
                }
            }
            do {
                kept = try await Self.kept(store, apple: apple, mosyle: mosyleOrg)
            } catch {
                problem = problem ?? "The findings kept for later couldn't be read: \(error.message)"
            }
        case .failure(let failure):
            problem = "What was found isn't kept for later (first seen, Dismiss, Snooze): \(failure.message)"
        }
        await afterAwait?("evaluate")
        guard token == evaluateToken, generation == orgs.generation else { return }
        evaluated = made
        stored = kept
        recordNote = problem
        evaluatedAt = now
        evaluatedKey = key
    }

    /// The findings kept for the client: its Apple org's, and its Mosyle org's for the one rule kept there. Never another client's.
    private static func kept(_ store: SnapshotStore, apple: OrgProfile, mosyle: OrgProfile?) async throws(SnapshotStore.Failure) -> [Key: SnapshotStore.Finding] {
        var kept: [Key: SnapshotStore.Finding] = [:]
        for finding in try await store.state(org: apple) where Rule(rawValue: finding.rule).map({ keeper(of: $0) == .apple }) ?? false {
            kept[Key(rule: finding.rule, subject: Array(finding.subject.utf8))] = finding
        }
        if let mosyle {
            for finding in try await store.state(org: mosyle) where Rule(rawValue: finding.rule).map({ keeper(of: $0) == .mosyle }) ?? false {
                kept[Key(rule: finding.rule, subject: Array(finding.subject.utf8))] = finding
            }
        }
        return kept
    }

    var thresholds: NeedsAttention.Thresholds {
        let t = settings.thresholds
        return NeedsAttention.Thresholds(checkInDays: t.checkInDays, appleCareExpiringDays: t.appleCareExpiringDays,
                                         migrationDeadlineDays: t.migrationDeadlineDays, quietServiceDays: t.quietServiceDays)
    }

    /// Every rule over its own source, in the rules' order.
    func evaluations(now: Date) -> [Evaluated] {
        let thresholds = self.thresholds
        var runs: [Source: (input: NeedsAttention.Input?, skip: String?, source: [String])] = [:]
        runs[.live] = (liveInput(), nil, liveWords(now: now))
        for sweep in Sweep.allCases { runs[.sweep(sweep)] = sweepInput(sweep, now: now) }
        runs[.appleMDM] = appleMDMInput(now: now)
        var judged: [Source: NeedsAttention] = [:]
        for (source, run) in runs { if let input = run.input { judged[source] = NeedsAttention(input, thresholds: thresholds, now: now) } }
        return Rule.allCases.map { rule in
            let source = Self.source(of: rule), run = runs[source]
            return Evaluated(rule: rule, result: judged[source]?.result(rule), skip: run?.skip, source: run?.source ?? [])
        }
    }

    // MARK: the inputs

    /// The live lists: the Devices model's devices, services and each service's device list, and the Mosyle model's devices.
    func liveInput() -> NeedsAttention.Input {
        var input = NeedsAttention.Input()
        let live = ReportsModel.liveDevices(devices), services = ReportsModel.liveServices(devices)
        input.devices = .init(live.list.isNotRead ? [] : live.devices, read: live.list)
        input.services = .init(services.list.isNotRead ? [] : services.services, read: services.list, notSent: services.notSent)
        for (id, list) in devices.serviceDevices { input.serviceDevices[id] = .init(list.ids, read: list.read) }
        input.mosyle = mosyleInput()
        input.mosyleServiceID = mosyleServiceID
        return input
    }

    /// The Mosyle model's devices as the rules take them, or no Mosyle org. A column Mosyle refused or wasn't asked for is "not sent".
    func mosyleInput() -> NeedsAttention.MosyleInput {
        guard orgs.mosyleOrg != nil else { return .noMosyleOrg }
        let listing = mosyle.devices, rows = listing.rows.map(\.device)
        let read: ListRead = switch listing.state {
        case .idle: .notRead("Mosyle's devices haven't been read yet")
        case .loading: .notRead("Mosyle's devices are still being read")
        case .loaded: listing.truncated ? .partly("showing \(rows.count.formatted()) devices: the list stopped at the page limit") : .whole
        case .forbidden: rows.isEmpty ? .notRead("Mosyle refused the device list") : .partly("Mosyle refused the list after \(rows.count.formatted()) devices")
        case .failed(let why): rows.isEmpty ? .notRead(why) : .partly("the read failed after \(rows.count.formatted()) devices: \(why)")
        case .unusable(let why), .notInScope(let why): .notRead(why)
        }
        var notSent: Set<String> = []
        for column in (mosyle.columns?.refused ?? []) + (mosyle.columns?.untried ?? []) {
            if column == "serial_number" { notSent.insert("serialNumber") }
            if column == "date_last_beat" { notSent.insert("lastCheckIn") }
        }
        return .devices(.init(read.isNotRead ? [] : rows, read: read, notSent: notSent))
    }

    /// A sweep's snapshot over that snapshot's own list, or why there is none.
    func sweepInput(_ sweep: Sweep, now: Date) -> (input: NeedsAttention.Input?, skip: String?, source: [String]) {
        if sweep == .mdmDetails, appleOrg?.scope == .known(.school) { return (nil, Self.schoolWords, []) }
        let used: ReportsModel.Used
        switch snapshotSource(sweep.rule.name, title: sweep.title, next: "with \(sweep.title) ticked") {
        case .failure(let unavailable): return (nil, unavailable.why, [])
        case .success(let found): used = found
        }
        let takenAt = ISODate.parse(used.takenAt)?.date
        var input = NeedsAttention.Input()
        var source = snapshotWords(used, title: sweep.title, list: sweep == .mdmDetails ? "Apple MDM device list" : "device list", now: now)
        switch sweep {
        case .appleCare:
            input.devices = .init(used.deviceList.isNotRead ? [] : used.devices.map(OrgDevice.init(resource:)), read: used.deviceList, takenAt: takenAt)
            let (map, unattributed) = ReportsModel.coverage(used)
            input.coverage = .init(map.mapValues { read in
                switch read {
                case .read(let records): .read(records.map(AppleCareCoverage.init(resource:)))
                case .notRead(let why): .notRead(why)
                }
            }, takenAt: takenAt)
            if unattributed > 0 {
                source.append("\(unattributed) coverage record\(unattributed == 1 ? " has" : "s have") no serial number and can't be matched to a device: left out.")
            }
        case .activationLock:
            input.devices = .init(used.deviceList.isNotRead ? [] : used.devices.map(OrgDevice.init(resource:)), read: used.deviceList, takenAt: takenAt)
            input.activationLock = .init(ReportsModel.lockReads(used), takenAt: takenAt)
        case .mdmDetails:
            input.appleMDM = .init(used.deviceList.isNotRead ? [] : used.devices.map(MDMDevice.init(resource:)), read: used.deviceList, takenAt: takenAt)
            input.appleMDMDetails = .init(ReportsModel.detailReads(used), takenAt: takenAt)
            // Only for the FileVault and firewall rules' note that Mosyle reads no such value.
            input.mosyle = mosyleInput()
        }
        return (input, nil, source)
    }

    /// Apple MDM's list from a snapshot, with that snapshot's own devices, services and service device lists, or why there is none.
    func appleMDMInput(now: Date) -> (input: NeedsAttention.Input?, skip: String?, source: [String]) {
        if appleOrg?.scope == .known(.school) { return (nil, Self.schoolWords, []) }
        let title = "Apple MDM's device list"
        let used: ReportsModel.Used
        switch snapshotSource(SnapshotPolicy.mdmEnrolled.name, title: title, next: "(every snapshot reads it)") {
        case .failure(let unavailable): return (nil, unavailable.why, [])
        case .success(let found): used = found
        }
        let takenAt = ISODate.parse(used.takenAt)?.date
        var input = NeedsAttention.Input()
        input.appleMDM = .init(used.items.map(MDMDevice.init(resource:)),
                               read: used.part.map { .partly(ReportsModel.cutWords($0, title: title)) } ?? .whole, takenAt: takenAt)
        input.devices = .init(used.deviceList.isNotRead ? [] : used.devices.map(OrgDevice.init(resource:)), read: used.deviceList, takenAt: takenAt)
        let services = used.others[SnapshotPolicy.services.name] ?? ReportsModel.Listing(items: [], read: .notRead("the snapshot has no services list"))
        input.services = .init(services.read.isNotRead ? [] : services.items.map(MDMService.init(resource:)), read: services.read, takenAt: takenAt)
        // Each service's device list from the snapshot's `assignments` (a device id with its service's id). One read covers every
        // service, so each service's list is as whole as that read: a part read is every service's part read.
        let assignments = used.others[SnapshotPolicy.assignments.name] ?? ReportsModel.Listing(items: [], read: .notRead("the snapshot has no service device lists"))
        var ids: [String: [String]] = [:]
        for item in assignments.items { if let server = item.attributes["serverId"]?.string { ids[server, default: []].append(item.id) } }
        for service in input.services.items {
            input.serviceDevices[service.id] = .init(assignments.read.isNotRead ? [] : ids[service.id] ?? [], read: assignments.read, takenAt: takenAt)
        }
        var source = snapshotWords(used, title: title, list: "device list, services and service device lists", now: now)
        source[0] = "From the snapshot of \(dates.day(takenAt: used.takenAt)), \(ReportsModel.age(of: used.takenAt, now: now)): its Apple MDM device list with its own device list, services and service device lists; nothing is read from Apple now."
        return (input, nil, source)
    }

    /// The snapshot `resource` is read from, by the Reports screen's rule (`ReportsModel.read`), or why there is none, in words.
    private func snapshotSource(_ resource: String, title: String, next: String) -> Result<ReportsModel.Used, Unavailable> {
        switch state {
        case .idle, .loading: return .failure(Unavailable("Reading the snapshot history…"))
        case .failed(let why): return .failure(Unavailable("The snapshot history couldn't be read: \(why)"))
        case .unusable(let why), .notInScope(let why): return .failure(Unavailable(why))
        case .forbidden: return .failure(Unavailable("The snapshot history couldn't be read"))
        case .loaded: break
        }
        switch sources[resource] {
        case .used(let used)?: return .success(used)
        case .unavailable(let failure?)?:
            return .failure(Unavailable("\(ReportsModel.failureWords(failure, title: title, dates: dates)). No snapshot has read \(title), so this rule judges nothing"))
        case .unavailable(nil)?, nil:
            return .failure(Unavailable("No snapshot has read \(title), so this rule judges nothing. It isn't zero: nothing was read. Take one in Activity › Changes › Snapshot now \(next)"))
        }
    }

    private struct Unavailable: Error {
        let why: String
        init(_ why: String) { self.why = why }
    }

    /// Where a snapshot's data comes from, in words: its date and age, a part read, and a newer attempt that read none of it.
    private func snapshotWords(_ used: ReportsModel.Used, title: String, list: String, now: Date) -> [String] {
        var lines = ["From the snapshot of \(dates.day(takenAt: used.takenAt)), \(ReportsModel.age(of: used.takenAt, now: now)): its \(title) read with its own \(list); nothing is read from Apple now."]
        if let part = used.part {
            var words = "That snapshot read \(title) only in part: \(ReportsModel.cutWords(part, title: title))."
            switch used.unread {
            case let unread? where unread.trusted: words += " It records which devices it missed: those count as not read, and the rest are judged."
            case _?: words += " It names devices its own list doesn't hold, so a device with nothing recorded counts as not read too."
            case nil: words += " A device with nothing recorded counts as not read: a part read alone can't tell it from one the read didn't reach."
            }
            lines.append(words)
        }
        if let failure = used.failure {
            lines.append("\(ReportsModel.failureWords(failure, title: title, dates: dates)), so an earlier snapshot is used, from \(dates.day(takenAt: used.takenAt)).")
        }
        return lines
    }

    /// Where the live rules' data comes from, in words.
    private func liveWords(now: Date) -> [String] {
        var lines = [ReportsModel.liveDevices(devices).words(now: now, dates: dates), ReportsModel.liveServices(devices).words(now: now, dates: dates)]
        if orgs.mosyleOrg != nil {
            let listing = mosyle.devices
            switch listing.state {
            case .loaded(let at): lines.append("Mosyle's devices read live on \(dates.dayTime(at)), \(ReportsModel.age(since: at, now: now)).")
            case .idle, .loading: lines.append("Mosyle's devices: not read yet.")
            default: lines.append("Mosyle's devices: \(listing.state == .forbidden ? "refused" : "not read in full").")
            }
        }
        return lines
    }

    static let schoolWords = "Apple School Manager's API has no Apple MDM devices to read, so this rule doesn't apply to this organization"

    // MARK: the lines

    /// Every rule as the screen lists it, in the rules' order: empty until the first evaluation.
    public var lines: [Line] {
        let now = now()
        let writable: String? = switch orgs.history {
        case .success(let store):
            switch store.access {
            case .readWrite: nil
            case .readOnly(let version): SnapshotStore.Failure.readOnly(version: version).message
            case .notWritable(let version): SnapshotStore.Failure.notWritable(version: version).message
            }
        case .failure(let failure): failure.message
        }
        return evaluated.map { item in
            let title = item.result?.title ?? item.rule.title(thresholds)
            let verdict = item.result?.verdict ?? .skipped(item.skip ?? "not read")
            let words = item.result?.words ?? ["\(title): skipped. \(item.skip ?? "Not read")."]
            let findings = (item.result?.findings ?? []).enumerated().map { index, found in
                let kept = stored[Key(rule: item.rule.rawValue, subject: Array(found.subject.utf8))]
                let blocked: String? = if found.isPartial, kept == nil {
                    "Found over a part read: not kept, so it can't be dismissed or snoozed until the rule is judged whole."
                } else if !found.isTrackable {
                    "Its serial number or id isn't one this app can keep, so it can't be dismissed or snoozed."
                } else if kept == nil {
                    recordNote ?? writable ?? "Not kept yet."
                } else {
                    nil
                }
                return Finding(id: "\(item.rule.rawValue)|\(index)", rule: item.rule, subject: found.subject, reason: found.reason, isPartial: found.isPartial,
                               firstSeen: kept?.firstSeen, dismissedAt: kept?.dismissedAt, snoozedUntil: kept?.snoozedUntil,
                               isHidden: kept?.isHidden(at: now) ?? false, actionsBlocked: blocked)
            }
            return Line(rule: item.rule, title: title, verdict: verdict, findings: findings, words: words, source: item.source)
        }
    }

    /// The most findings a rule lists on screen; the CSV holds them all (invariant 7).
    @ObservationIgnored package var displayLimit = 200

    /// The findings `line` lists now: the open ones, or every one when hidden findings are shown, at most `displayLimit`, and the cap said.
    public func shown(_ line: Line) -> (findings: [Finding], capNote: String?) {
        let all = showsHidden ? line.findings : line.open
        let shown = Array(all.prefix(displayLimit))
        let cap = all.count > shown.count ? "Showing \(shown.count.formatted()) of \(all.count.formatted()): the rest are in the CSV export." : nil
        return (shown, cap)
    }

    /// What the Overview's card counts: the rules with open findings and how many, the rules skipped, and the rules with none open.
    public struct Summary: Sendable {
        public struct Row: Identifiable, Sendable {
            public let rule: Rule
            public let title: String
            public let open: Int
            /// Found over a part read: not kept.
            public let partial: Bool
            public var id: String { rule.rawValue }
        }

        public let rows: [Row]
        /// The rules skipped, by title.
        public let skipped: [String]
        /// The rules judged (whole or in part) with no open finding.
        public let clear: Int
        /// Open findings in all.
        public var open: Int { rows.reduce(0) { $0 + $1.open } }

        /// The line under the counts: how many rules were skipped, and where to see why; nil when none was.
        public var skippedWords: String? {
            skipped.isEmpty ? nil : "\(skipped.count) of \(NeedsAttention.Rule.allCases.count) rules skipped: open Needs Attention to see why."
        }
    }

    /// Nil until the first evaluation.
    public var summary: Summary? {
        guard !evaluated.isEmpty else { return nil }
        let lines = self.lines
        let rows = lines.filter { !$0.open.isEmpty }.map { Summary.Row(rule: $0.rule, title: $0.title, open: $0.open.count, partial: $0.isPartial) }
        return Summary(rows: rows, skipped: lines.filter(\.isSkipped).map(\.title), clear: lines.filter { !$0.isSkipped && $0.open.isEmpty }.count)
    }

    /// Why nothing is listed yet, in words; nil once there is an evaluation.
    public var waiting: String? {
        if case .unusable(let why) = state { return why }
        guard evaluated.isEmpty else { return nil }
        return orgs.active == nil ? ScreenWords.noOrganization : "Judging what needs attention…"
    }

    // MARK: dismiss and snooze

    /// How long Snooze offers to hide a finding for.
    public static let snoozeDays = [7, 30, 90]

    /// Hides `finding` until it clears (`SnapshotStore.dismiss`): a write to the local history only.
    public func dismiss(_ finding: Finding) async {
        await choose(finding, verb: "dismissed") { (store, org, rule, now) throws(SnapshotStore.Failure) in
            try await store.dismiss(org: org, rule: rule.rawValue, subject: finding.subject, at: now)
        }
    }

    /// Hides `finding` until `until` (`SnapshotStore.snooze`), which must be after now: a write to the local history only.
    public func snooze(_ finding: Finding, until: Date) async {
        guard until > now() else {
            actionNote = "Not snoozed: a snooze needs a date after now."
            return
        }
        await choose(finding, verb: "snoozed") { (store, org, rule, _) throws(SnapshotStore.Failure) in
            try await store.snooze(org: org, rule: rule.rawValue, subject: finding.subject, until: until)
        }
    }

    public func snooze(_ finding: Finding, days: Int) async {
        await snooze(finding, until: now().addingTimeInterval(Double(days) * 86_400))
    }

    private func choose(_ finding: Finding, verb: String,
                        _ write: @escaping (SnapshotStore, OrgProfile, Rule, Date) async throws(SnapshotStore.Failure) -> Void) async {
        let generation = orgs.generation
        if let blocked = finding.actionsBlocked {
            actionNote = "Not \(verb): \(blocked)"
            return
        }
        guard let apple = appleOrg, let org = Self.keeper(of: finding.rule) == .apple ? apple : orgs.mosyleOrg else {
            actionNote = "Not \(verb): this organization isn't the one it was found for."
            return
        }
        let store: SnapshotStore
        switch orgs.history {
        case .success(let opened): store = opened
        case .failure(let failure):
            actionNote = "Not \(verb): \(failure.message)"
            return
        }
        var note: String?
        var kept: [Key: SnapshotStore.Finding]?
        do {
            try await write(store, org, finding.rule, now())
            kept = try await Self.kept(store, apple: apple, mosyle: orgs.mosyleOrg)
        } catch {
            note = "Not \(verb): \(error.message)"
        }
        guard generation == orgs.generation else { return }
        actionNote = note
        if let kept { stored = kept }
    }

    // MARK: the Mosyle service setting (the operator's Q7)

    /// The service set as the active client's Mosyle org, by id; nil when none is (the default).
    public var mosyleServiceID: String? { orgs.activeClient.flatMap { settings.mosyleService(for: $0.id) } }

    /// The setting as Settings shows it; nil unless the active client has an Apple org and a Mosyle org.
    public struct ServiceSetting: Sendable {
        public struct Option: Identifiable, Sendable, Hashable {
            /// The service's id; empty for "Not set".
            public let id: String
            public let label: String
        }

        public let options: [Option]
        /// The stored id, or empty when none is set.
        public let selected: String
        public let words: String
    }

    public var serviceSetting: ServiceSetting? {
        guard let client = orgs.activeClient, client.apple != nil, let mdm = client.mdm, orgs.store[mdm]?.provider == .known(.mosyle) else { return nil }
        let id = settings.mosyleService(for: client.id)
        // The services are read from Apple each time: only the active Apple org's own read names them.
        let readable = orgs.active?.id == client.apple
        let services = readable ? ReportsModel.liveServices(devices) : nil
        var options = [ServiceSetting.Option(id: "", label: "Not set")]
        for service in services?.services ?? [] {
            options.append(.init(id: service.id, label: service.type.map { "\(service.name) (\($0.rawValue))" } ?? service.name))
        }
        let found = services?.services.first { $0.id.utf8.elementsEqual((id ?? "").utf8) }
        let words: String
        if let id {
            if let found {
                words = "Set: \(found.name). Only its id is kept, on this Mac; its name is read from Apple each time."
            } else if let services, services.list == .whole {
                options.append(.init(id: id, label: "Not among Apple's services: \(id)"))
                words = "The service set (id \(id)) isn't among the services Apple lists now, so “missing from Mosyle” is skipped. Choose another, or Not set."
            } else {
                options.append(.init(id: id, label: "Set: \(id)"))
                let why: String = switch services?.list {
                case .partly(let how)?: how
                case .notRead(let why)?: why
                default: "the client's Apple organization isn't the active one"
                }
                words = "Set to the service with id \(id). Its name isn't known until Apple's services are read whole: \(why)."
            }
        } else {
            words = "Not set, so “missing from Mosyle” is skipped. Choose the device management service in Apple that is this customer's Mosyle Business organization."
        }
        return ServiceSetting(options: options, selected: id ?? "", words: words)
    }

    /// Reads the services Settings names the choices by (the Devices screen's read), when the setting is shown.
    public func readServicesForSetting() {
        guard serviceSetting != nil, appleOrg != nil else { return }
        devices.load()
    }

    /// Sets the active client's Mosyle service (`id`, or none with nil or ""), and saves it (`settings.json`; in memory for the demo
    /// and the tests). Only the id is kept. A file that can't be written leaves the setting as it was, and says why.
    public func setMosyleService(_ id: String?) {
        guard let client = orgs.activeClient?.id else { return }
        var changed = settings
        changed.setMosyleService(id.flatMap { $0.isEmpty ? nil : $0 }, for: client)
        if let folder = orgs.folder {
            do {
                try changed.save(to: folder)
            } catch {
                settingNote = error.message
                return
            }
        } else if changed.mosyleServices.values.contains(where: { !LocalSettings.isServiceID($0) }) {
            settingNote = LocalSettings.Failure.notAServiceID.message
            return
        }
        settings = changed
        settingNote = nil
    }

    /// Why the settings file can't be changed, when it can't (it was left as it is).
    public var settingsBlocked: String? { settings.blocked?.message }

    // MARK: the CSV

    /// The file's name, naming the client only when the app shows clients (the clients rule), and the day (UTC) it was judged.
    public var exportFileName: String {
        ScreenWords.filename("needs attention \(ReportsModel.dayStamp(evaluatedAt ?? now())).csv", client: orgs.exportClient)
    }

    /// Why Export is off; nil when there is an evaluation to write.
    public var exportBlocked: String? { evaluated.isEmpty ? (waiting ?? ScreenWords.nothingToExport) : nil }

    /// What the Save panel says the file holds.
    public var exportWords: String {
        let who = orgs.active.map { "\"\($0.name.isEmpty ? $0.id : $0.name)\"" } ?? "this organization"
        let client = orgs.exportClient.map { " It is client \"\($0)\"'s data only." } ?? ""
        return "Saves what needs attention for \(who): a row per finding, dismissed and snoozed ones included with their state, and a row for "
            + "each rule that found none or wasn't judged. The first column says whether the rule was judged whole, in part (not kept), or "
            + "skipped, and why. Serial numbers and ids are in it, with this app's own words; no key or token is in it." + client
    }

    /// The evaluation as CSV (`ExportPolicy.needsAttention`): every finding, hidden ones included, and a row for each rule with none.
    public func csv() -> String {
        var items: [CSV.Item] = []
        for line in lines {
            let verdict: String = switch line.verdict {
            case .judged: "judged"
            case .partial(let why): "partial: \(why)"
            case .skipped(let why): "skipped: \(why)"
            }
            let from = line.source.first ?? ""
            let base: JSONObject = ["verdict": .string(verdict), "rule": .string(line.rule.rawValue), "title": .string(line.title), "dataFrom": .string(from)]
            if line.findings.isEmpty {
                let none = line.isSkipped ? "not judged" : "none found"
                items.append(CSV.Item(id: "", attributes: base.merging(["reason": .string(none)])))
                continue
            }
            for finding in line.findings {
                let status: String = if let dismissed = finding.dismissedAt {
                    "dismissed \(Self.iso(dismissed))"
                } else if let until = finding.snoozedUntil, finding.isHidden {
                    "snoozed until \(Self.iso(until))"
                } else if finding.firstSeen == nil {
                    "not kept"
                } else {
                    "open"
                }
                items.append(CSV.Item(id: finding.subject, attributes: base.merging([
                    "reason": .string(finding.reason), "status": .string(status),
                    "firstSeen": finding.firstSeen.map { .string(Self.iso($0)) } ?? .null,
                ])))
            }
        }
        return CSV.text(items, columns: ExportPolicy.needsAttention)
    }

    /// A time in a file: UTC, to the second, as the history writes `taken_at`.
    nonisolated static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)) }
}
