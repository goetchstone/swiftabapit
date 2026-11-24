import AppleBusiness
import AppleModels
import Foundation
import History
import JSONAPI
import Observation
import Orgs

/// Takes a snapshot of the active Apple org: reads each resource `SnapshotPolicy` lists through `AppleClient`'s public reads,
/// keeps only what the policy keeps, and records it with `SnapshotStore.record`, the only write (plan Phase 3; docs/domains/
/// history.md, "The Apple collector").
///
/// - **One org, captured.** A run captures the org's profile, its client and the orgs' `generation` when it starts, reads
///   only through that client and records under that profile. An org or client switch (anything that bumps the
///   generation, `OrgsModel.onSwitch`) or `cancel()` stops it: it checks after every page and every await, so a run stopped
///   before its write writes nothing. A switch during the write lets it finish under the org it started for, and its
///   outcome is not shown under the new org: a switch clears `lastOutcome` and `refusal`, and a run that finishes after one
///   leaves them clear. So nothing read for one org is ever written or shown under another (the clients rule).
/// - **Per resource, never all or nothing** (abapit's `_collect`): a resource that fails is recorded as an error code
///   (`SnapshotPolicy.code`: never Apple's text or a URL), with whatever it read before failing, and the run goes on; a
///   failure of the key, the token or the account stops the asking (`SnapshotPolicy.stopsTheRun`), and every resource not
///   read after it says so. A list the page cap cut is a part read too: its items with the error `page cap`
///   (`SnapshotPolicy.pageCap`), so `SnapshotStore.latest` never takes it for a whole read. `notes` say what was read only in
///   part: a list cut at the page cap, fields Apple didn't send, attributes left out because this version doesn't know them,
///   addresses masked. Every resource read is in `counts` (the store's), so "read and found none" isn't "not read".
/// - **Apple School Manager** has no people, content or Apple MDM reads: a School org's snapshot doesn't try them.
/// - **Bounded** (invariant 7): every list stops at the client's page cap and says so; every read waits on the org's rate
///   limiter (the client's, shared with the screens); a run is one task, cancellable, and only one runs at a time.
/// - **The per-device sweeps** (`Sweep`: AppleCare, Activation Lock, the Apple MDM details) run only when a run asks for
///   them, after the lists, at most `Sweep.inFlight` reads at once, then one retry pass; a device not read makes the sweep a
///   part read, never a good copy (docs/domains/history.md, "The sweeps").
@MainActor
@Observable
public final class SnapshotCollector {
    /// How a run ended.
    public enum Outcome: Equatable, Sendable {
        /// Recorded as the store's snapshot with this id.
        case recorded(Int64)
        /// An org or client switch, or `cancel()`, stopped it before it recorded: nothing was written.
        case cancelled
        /// Nothing was read, and why, in words: no org, one that can't be read, no history, a run already going.
        case notRun(String)
        /// The reads ran and the store didn't record them: its words.
        case notRecorded(String)
    }

    public private(set) var isRunning = false
    /// Whether the run going started for the org and client on screen now. After a switch `isRunning` stays true until the
    /// stopped run returns (a second run is refused meanwhile); a screen shows this, never `isRunning`, so nothing of the
    /// previous org's run is said under the new one.
    public var isRunningForActiveOrg: Bool { isRunning && runningGeneration == orgs.generation }
    /// The resource being read (the store's name), while a run goes.
    public private(set) var reading: String?
    /// How the last run for the orgs' current generation ended; nil after a switch.
    public private(set) var lastOutcome: Outcome?
    /// Why the last `run()` was refused while another run went, in words; nil once a run starts, and after a switch.
    public private(set) var refusal: String?
    /// The sweeps' time, an estimate made once the lists are read and before the first sweep's first read; nil when the run
    /// asked for none, and once it ends.
    public private(set) var sweepEstimate: Sweep.Estimate?
    /// The sweep running: devices answered of the devices it covers; nil when none runs.
    public private(set) var sweepProgress: Sweep.Progress?

    private let orgs: OrgsModel
    private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Outcome, Never>?
    /// The current run's token: a run checks it after every page and await, so a cancelled or superseded run writes nothing.
    @ObservationIgnored private var token = 0
    /// The generation the running run started for; nil when none runs.
    @ObservationIgnored private var runningGeneration: Int?
    /// Run after a run's last check and before its write, when set: the tests switch orgs there, as a switch can come while
    /// the store writes. `package`: the app never sets it.
    @ObservationIgnored package var beforeWrite: (@MainActor () async -> Void)?
    /// Runs that have returned: what the tests wait on. `package`: the app never sees it.
    @ObservationIgnored package private(set) var runsFinished = 0

    static let alreadyRunning = "A snapshot is already being taken."
    static let windingDown = "A snapshot of the previous organization is still stopping. Try again in a moment."

    public init(orgs: OrgsModel, now: @escaping @Sendable () -> Date = { Date() }) {
        self.orgs = orgs
        self.now = now
        orgs.onSwitch { [weak self] in self?.switched() }
    }

    /// Takes a snapshot of the active org and records it; returns how it ended. `sweeps` are the per-device sweeps to run
    /// after the lists (none unless asked: each is one read per device, at the org's rate). One run at a time: a call while
    /// one runs is refused, and the refusal stays in `refusal` for a screen to say.
    public func run(sweeps: Set<Sweep> = []) async -> Outcome {
        if isRunning {
            // After a switch the run still going is the previous org's, stopping: said as that, not as a snapshot being taken.
            let words = runningGeneration == orgs.generation ? Self.alreadyRunning : Self.windingDown
            refusal = words
            return .notRun(words)
        }
        refusal = nil
        let store: SnapshotStore
        switch orgs.openHistory() {
        case .success(let opened): store = opened
        case .failure(let failure): return finish(.notRun(failure.message), for: orgs.generation)
        }
        guard let profile = orgs.active, let client = orgs.appleClient else {
            return finish(.notRun(ScreenWords.unusable(orgs)), for: orgs.generation)
        }
        token += 1
        let run = Run(org: profile, client: client, generation: orgs.generation, token: token, takenAt: now(), sweeps: sweeps)
        isRunning = true
        runningGeneration = run.generation
        let task = Task { await self.collect(run, into: store) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        isRunning = false
        runningGeneration = nil
        reading = nil
        sweepEstimate = nil
        sweepProgress = nil
        // A refusal was about the run that was going: it ends with it, never outliving it.
        refusal = nil
        return finish(outcome, for: run.generation)
    }

    /// The sweeps' time before a run, an estimate: `devices` in Apple's device list and `appleManaged` Apple-managed devices
    /// (what the screens have read), at the active org's rate now. nil without an org this version can read.
    /// An org switch during its await makes it nil: the rate read was the old org's.
    public func estimate(_ sweeps: Set<Sweep>, devices: Int, appleManaged: Int) async -> Sweep.Estimate? {
        guard let profile = orgs.active, let client = orgs.appleClient else { return nil }
        let generation = orgs.generation
        let reads = sweeps.reduce(0) { reads, sweep in
            guard !sweep.rule.businessOnly || profile.scope == .known(.business) else { return reads }
            return reads + max(0, sweep == .mdmDetails ? appleManaged : devices)
        }
        let rate = await client.learnedReadsPerMinute
        guard orgs.generation == generation else { return nil }
        return Sweep.Estimate(reads: reads, readsPerMinute: rate)
    }

    /// Stops the run going, if any: a run stopped before its write records nothing.
    public func cancel() {
        token += 1
        task?.cancel()
    }

    /// An org or client switch: the run stops, and nothing said of the old org stays.
    private func switched() {
        lastOutcome = nil
        refusal = nil
        // What a run says while it goes is the old org's too: a stopping run never sets them again (it checks `current`).
        reading = nil
        sweepEstimate = nil
        sweepProgress = nil
        cancel()
    }

    /// `outcome` becomes `lastOutcome` only while the orgs are on the generation it was for: a run that a switch stopped, or
    /// whose write finished after one, is never shown under the new org.
    private func finish(_ outcome: Outcome, for generation: Int) -> Outcome {
        if generation == orgs.generation { lastOutcome = outcome }
        runsFinished += 1
        return outcome
    }

    // MARK: a run

    /// What a run read for: captured when it started, never looked up again.
    private struct Run {
        let org: OrgProfile
        let client: AppleClient
        let generation: Int
        let token: Int
        let takenAt: Date
        /// The per-device sweeps asked for.
        let sweeps: Set<Sweep>
        /// Apple School Manager's API has none of the Business-only reads (plan §2.4): a School org's run doesn't try them.
        func tries(_ rule: SnapshotPolicy.Rule) -> Bool { !rule.businessOnly || org.scope == .known(.business) }
    }

    /// What a run has read so far.
    private struct Collected {
        var resources: [String: [Resource]] = [:]
        var errors: [String: String] = [:]
        var notes: [String: [String]] = [:]
        /// Per sweep that ran, the ids of the devices it didn't read (`SnapshotStore.Summary.unread`): those its note counts as
        /// "not read", and those whose own list the page cap cut. A sweep that wasn't run, or never asked for a device (its list
        /// failed, or the run stopped before it), has no key.
        var unread: [String: [String]] = [:]
        /// The code of the failure that stopped the asking (the key, the token, the account); nil while reads go on.
        var stopped: String?

        mutating func note(_ rule: SnapshotPolicy.Rule, _ words: String) { notes[rule.name, default: []].append(words) }
    }

    /// Whether the run may go on: its token holds, its task isn't cancelled, and the orgs are still on its generation.
    private func current(_ run: Run) -> Bool { run.token == token && !Task.isCancelled && orgs.generation == run.generation }

    private func collect(_ run: Run, into store: SnapshotStore) async -> Outcome {
        var collected = Collected()
        let client = run.client
        let devices = await read(SnapshotPolicy.devices, run, &collected) { client.devices() }
        guard current(run) else { return .cancelled }
        let services = await read(SnapshotPolicy.services, run, &collected) { client.services() }
        guard current(run) else { return .cancelled }
        await assignments(services, run, &collected)
        guard current(run) else { return .cancelled }
        _ = await read(SnapshotPolicy.users, run, &collected) { client.users() }
        guard current(run) else { return .cancelled }
        _ = await read(SnapshotPolicy.userGroups, run, &collected) { client.userGroups() }
        guard current(run) else { return .cancelled }
        _ = await read(SnapshotPolicy.apps, run, &collected) { client.apps() }
        guard current(run) else { return .cancelled }
        _ = await read(SnapshotPolicy.packages, run, &collected) { client.packages() }
        guard current(run) else { return .cancelled }
        // The list only: never a blueprint's members (`blueprintWithMembers`, `blueprintMemberIDs`).
        _ = await read(SnapshotPolicy.blueprints, run, &collected) { client.blueprints() }
        guard current(run) else { return .cancelled }
        // The list, never `configuration(_:)`: the list sends a custom setting's profile as null, and what is kept is
        // `Configuration.resource`, the profile withheld (operator, 2026-10-31).
        _ = await read(SnapshotPolicy.configurations, run, &collected) { client.configurations() }
        guard current(run) else { return .cancelled }
        let managed = await read(SnapshotPolicy.mdmEnrolled, run, &collected) { client.mdmDevices() }
        guard current(run) else { return .cancelled }
        // The per-device sweeps the run asked for, over the devices read above (plan §3.6). One not asked for is in neither
        // `counts` nor `errors`, so `SnapshotStore.latest` passes over this snapshot for it.
        await sweeps(devices: devices, managed: managed, run, &collected)
        reading = nil
        guard current(run) else { return .cancelled }
        let notes = collected.notes.mapValues { $0.joined(separator: "; ") }
        let unread = collected.unread
        // The last check: from here the write goes on under the org the run started for, even if a switch comes while the
        // store writes (what was read is that org's), and `finish` keeps its outcome off the new org.
        if let beforeWrite { await beforeWrite() }
        do {
            // Under the profile captured at the start, never `orgs.active`.
            return .recorded(try await store.record(org: run.org, takenAt: run.takenAt, resources: collected.resources,
                                                    errors: collected.errors, notes: notes, unread: unread))
        } catch {
            return .notRecorded(error.message)
        }
    }

    /// One list as a run read it to its end.
    private struct Listed<View> {
        let views: [View]
        /// The page cap stopped it with more to come.
        let cut: Bool
    }

    /// Reads one list, every page to the client's cap, and keeps what `rule` keeps. Returns what was read when the list was
    /// read to its end (cut at the cap included, which the note says); nil when it failed or the run was stopped, which the
    /// caller tells apart with `current`. A list that failed after some pages keeps them, with the error, so the store never
    /// takes it for a whole read; one that failed before any is an error only.
    private func read<View: ResourceView>(_ rule: SnapshotPolicy.Rule, _ run: Run, _ collected: inout Collected,
                                          _ stream: () -> AsyncThrowingStream<Page<View>, any Error>) async -> Listed<View>? {
        guard run.tries(rule) else { return nil }
        if let stopped = collected.stopped {
            collected.errors[rule.name] = Self.notAsked(after: stopped)
            return nil
        }
        guard current(run) else { return nil }
        reading = rule.name
        var views: [View] = [], last: Page<View>?
        var failure: (any Error)?
        do {
            for try await page in stream() {
                guard current(run) else { return nil }
                views += page.items
                last = page
            }
        } catch {
            failure = error
        }
        guard current(run) else { return nil }
        if failure == nil || !views.isEmpty { keep(views.map(\.resource), rule, &collected) }
        if let last {
            if last.truncated {
                // A part read: its items, and an error, so the history never takes it for a whole one.
                collected.note(rule, Self.cut(views.count, total: last.total))
                if failure == nil { collected.errors[rule.name] = SnapshotPolicy.pageCap }
            }
            if last.note != nil {
                // Apple refused the field list (the services, 2026-11-19) and the read took Apple's default fields: which kept
                // attributes no item came back with, as data (`Page.absent`), never Apple's words.
                let absent = rule.kept.filter { last.absent.contains($0) }
                collected.note(rule, "read with Apple's default fields (Apple refused the field list)"
                               + (absent.isEmpty ? "" : "; not sent for any item: \(absent.joined(separator: ", "))"))
            }
        }
        if let failure {
            fail(rule, failure, &collected)
            return nil
        }
        return Listed(views: views, cut: last?.truncated ?? false)
    }

    /// Which service holds which device (abapit's `assignments`): each service's device list, every page, one item per
    /// serial with the service's id and name. Not read when the services weren't; one service's list failing leaves the
    /// rest, recorded with the error, so the store never takes it for a whole read.
    private func assignments(_ services: Listed<MDMService>?, _ run: Run, _ collected: inout Collected) async {
        let rule = SnapshotPolicy.assignments
        if let stopped = collected.stopped {
            collected.errors[rule.name] = Self.notAsked(after: stopped)
            return
        }
        guard let services else {
            collected.errors[rule.name] = "not read: \(SnapshotPolicy.services.name) failed"
            return
        }
        guard current(run) else { return }
        reading = rule.name
        // An id that can't go in a path is never sent: the client would call a service Apple has just listed "no such item".
        let sendable = services.views.filter { AppleRead.isPathSafe($0.id) }
        let unsendable = services.views.count - sendable.count
        var items: [Resource] = [], failure: (any Error)?, failed = 0, cut = 0, notAsked = 0
        for (index, service) in sendable.enumerated() {
            let name = service.attributes["serverName"] ?? .string(service.id)
            do {
                for try await page in run.client.serviceDeviceIDs(service.id) {
                    guard current(run) else { return }
                    items += page.items.map { Resource(type: rule.name, id: $0, attributes: ["serverId": .string(service.id), "serverName": name]) }
                    if page.truncated { cut += 1 }
                }
                guard current(run) else { return }
            } catch {
                guard current(run) else { return }
                failed += 1
                // The first failure is the one recorded, unless a later one stops the asking: that one is said.
                if failure == nil || SnapshotPolicy.stopsTheRun(error) { failure = error }
                if SnapshotPolicy.stopsTheRun(error) {
                    notAsked = sendable.count - index - 1
                    break
                }
            }
        }
        if failure == nil || !items.isEmpty { keep(items, rule, &collected) }
        if services.cut { collected.note(rule, "covers only the services read: their list stopped at the page limit") }
        if cut > 0 { collected.note(rule, "\(Self.services(cut)) device list\(cut == 1 ? "" : "s") stopped at the page limit") }
        if unsendable > 0 {
            collected.note(rule, "\(Self.services(unsendable)) id\(unsendable == 1 ? " isn't" : "s aren't") one Apple can be asked for, "
                           + "so \(unsendable == 1 ? "its" : "their") devices weren't read")
        }
        if failed > 0 {
            collected.note(rule, "\(failed) of \(services.views.count) services' device lists couldn't be read"
                           + (notAsked > 0 ? "; \(notAsked) \(notAsked == 1 ? "wasn't" : "weren't") asked after the sign-in failed" : ""))
        }
        // Anything short of every service's whole list is a part read, said with an error so the history never takes it whole.
        if let failure {
            fail(rule, failure, &collected)
        } else if unsendable > 0 {
            collected.errors[rule.name] = "unsendable id"
        } else if services.cut || cut > 0 {
            collected.errors[rule.name] = SnapshotPolicy.pageCap
        }
    }

    // MARK: the sweeps

    /// The devices one sweep reads: the ids of the list it covers, the serials the details are checked against, and whether
    /// the page cap cut that list.
    private struct Source {
        let ids: [String]
        let serials: [String: String]
        let cut: Bool
    }

    /// The sweeps the run asked for, in `Sweep`'s order: AppleCare and Activation Lock over Apple's device list, the details
    /// over Apple MDM's (Business only). The estimate is made before the first sweep's first read. After them, the rate the
    /// limiter learned is recorded for the org, as a screen's load records it, so the next estimate starts there.
    private func sweeps(devices: Listed<OrgDevice>?, managed: Listed<MDMDevice>?, _ run: Run, _ collected: inout Collected) async {
        let chosen = Sweep.allCases.filter { run.sweeps.contains($0) && run.tries($0.rule) }
        guard !chosen.isEmpty else { return }
        func source(_ sweep: Sweep) -> Source? {
            switch sweep {
            case .appleCare, .activationLock:
                return devices.map { Source(ids: $0.views.map(\.id), serials: [:], cut: $0.cut) }
            case .mdmDetails:
                return managed.map { list in
                    var serials: [String: String] = [:]
                    for device in list.views { if let serial = device.serialNumber { serials[device.id] = serial } }
                    return Source(ids: list.views.map(\.id), serials: serials, cut: list.cut)
                }
            }
        }
        let rate = await run.client.learnedReadsPerMinute
        guard current(run) else { return }
        let reads = collected.stopped == nil ? chosen.reduce(0) { $0 + (source($1)?.ids.count ?? 0) } : 0
        sweepEstimate = Sweep.Estimate(reads: reads, readsPerMinute: rate)
        for sweep in chosen {
            await self.sweep(sweep, over: source(sweep), run, &collected)
            guard current(run) else { return }
        }
        sweepProgress = nil
        let learned = await run.client.learnedReadsPerMinute
        guard current(run) else { return }
        orgs.record(readsPerMinute: learned, for: run.org.id)
    }

    /// One sweep over `source`'s devices (`Sweep.run`), kept as its rule keeps it. A device not read (failed twice, an id
    /// that can't be sent, not asked after the sweep stopped) or a list the page cap cut makes it a part read: its items with
    /// an error, and the note says how many devices weren't read and why. A 403 stops this sweep; a failure of the key, the
    /// token or the account stops the run.
    private func sweep(_ sweep: Sweep, over source: Source?, _ run: Run, _ collected: inout Collected) async {
        let rule = sweep.rule, list = sweep == .mdmDetails ? SnapshotPolicy.mdmEnrolled : SnapshotPolicy.devices
        if let stopped = collected.stopped {
            collected.errors[rule.name] = Self.notAsked(after: stopped)
            return
        }
        guard let source else {
            collected.errors[rule.name] = "not read: \(list.name) failed"
            return
        }
        guard current(run) else { return }
        reading = rule.name
        let swept = await Sweep.run(source.ids, read: sweep.reader(run.client, serials: source.serials), going: { current(run) }) { done, total in
            // A stopped run never says anything under the org that replaced it.
            if current(run) { sweepProgress = Sweep.Progress(sweep: sweep, done: done, total: total) }
        }
        guard current(run) else { return }
        let stop = swept.stop.map(Sweep.code)
        if let stop, let error = swept.stop, SnapshotPolicy.stopsTheRun(error) { collected.stopped = stop }
        // A coverage id more than one device carries is kept as `serial:id` (`Sweep.keyedBySerialWhereShared`): nothing lost.
        var items = swept.items, shared = 0
        if sweep == .appleCare { (items, shared) = Sweep.keyedBySerialWhereShared(items) }
        // Two records with one id left (one device's list holding it twice): the store keeps the last, so a record could go
        // unseen. Said, and a part read.
        var ids: Set<[UInt8]> = [], duplicates = 0
        for item in items where !ids.insert(Array(item.id.utf8)).inserted { duplicates += 1 }
        let error = stop ?? swept.failed.first ?? (swept.unsendable > 0 ? "unsendable id" : nil) ?? (duplicates > 0 ? "duplicate id" : nil)
            ?? (source.cut || swept.cut > 0 ? SnapshotPolicy.pageCap : nil) ?? (swept.notAsked > 0 ? "not asked" : nil)
        // Read and found nothing is an answer (counted); nothing read and an error is the error alone.
        if error == nil || swept.read > 0 { keep(items, rule, &collected) }
        var why: [String] = []
        if !swept.failed.isEmpty {
            var codes: [String] = []
            for code in swept.failed where !codes.contains(code) { codes.append(code) }
            why.append("\(swept.failed.count) failed twice (\(codes.joined(separator: ", ")))")
        }
        if swept.unsendable > 0 { why.append("\(swept.unsendable) \(swept.unsendable == 1 ? "has an id" : "have ids") Apple can't be asked for") }
        if swept.notAsked > 0 { why.append(stop.map { "\(swept.notAsked) left when the sweep stopped at \($0)" } ?? "\(swept.notAsked) not asked") }
        let total = swept.read + swept.failed.count + swept.unsendable + swept.notAsked, missing = total - swept.read
        // The devices behind the note's count, and the ones whose own list was cut: ids only, never a name. A sweep that ran and missed
        // none records an empty list ("recorded: none missed"), so the key is "not recorded" only when it wasn't run. The list can't be
        // longer than the list the sweep covers, so no longer than the snapshot's devices (Apple's device list, or Apple MDM's).
        collected.unread[rule.name] = swept.notReadIDs + swept.cutIDs
        if missing > 0 { collected.note(rule, "\(missing) of \(Sweep.devices(total)) not read: \(why.joined(separator: "; "))") }
        if source.cut { collected.note(rule, "covers only the devices listed: \(list.name) stopped at the page limit") }
        if swept.cut > 0 {
            collected.note(rule, "the page limit cut \(swept.cut == 1 ? "1 device's" : "\(swept.cut) devices'") records: the rest not read")
        }
        if shared > 0 {
            collected.note(rule, "\(shared) record\(shared == 1 ? "" : "s") shared an id with another device's: kept as serial:id")
        }
        if swept.notFound > 0 {
            collected.note(rule, "\(swept.notFound) answered 404, read as no details on record (Apple's meaning unconfirmed)")
        }
        if duplicates > 0 {
            collected.note(rule, "\(duplicates) record\(duplicates == 1 ? "" : "s") had the id of another read: the history keeps one of each")
        }
        if let error { collected.errors[rule.name] = error }
    }

    /// Keeps `items` as `rule` keeps them, under its name (every resource read is in the store's `counts`, none found
    /// included), and notes what was left out or masked.
    private func keep(_ items: [Resource], _ rule: SnapshotPolicy.Rule, _ collected: inout Collected) {
        var kept: [Resource] = [], unknown: Set<[UInt8]> = [], masked = 0
        for item in items {
            let one = SnapshotPolicy.keep(item, rule)
            kept.append(one.item)
            unknown.formUnion(one.unknown)
            if one.masked { masked += 1 }
        }
        collected.resources[rule.name] = kept
        if !unknown.isEmpty {
            collected.note(rule, "left out \(unknown.count) attribute\(unknown.count == 1 ? "" : "s") Apple sent that this version doesn't keep until reviewed")
        }
        if masked > 0 { collected.note(rule, "an address was masked in \(masked) item\(masked == 1 ? "" : "s")") }
    }

    /// Records `rule`'s failure as a code; a failure of the key, the token or the account stops the asking.
    private func fail(_ rule: SnapshotPolicy.Rule, _ error: any Error, _ collected: inout Collected) {
        let code = SnapshotPolicy.code(error)
        collected.errors[rule.name] = code
        if SnapshotPolicy.stopsTheRun(error) { collected.stopped = code }
    }

    /// A list the page cap stopped: how many were read, of Apple's total when it gave one.
    static func cut(_ read: Int, total: Int?) -> String {
        if let total, total > read { return "stopped at the page limit: \(read) of \(total) read" }
        return "stopped at the page limit: \(read) read, more not read"
    }

    static func notAsked(after code: String) -> String { "not asked after \(code)" }

    private static func services(_ count: Int) -> String { count == 1 ? "1 service's" : "\(count) services'" }
}
