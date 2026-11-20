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
///   generation, `OrgsModel.onSwitch`) or `cancel()` stops it: it checks after every page and every await, and records
///   nothing. So nothing read for one org is ever written under another, and a run stopped before it recorded writes
///   nothing at all (the clients rule: nothing mixes clients).
/// - **Per resource, never all or nothing** (abapit's `_collect`): a resource that fails is recorded as an error code
///   (`SnapshotPolicy.code`: never Apple's text or a URL), with whatever it read before failing, and the run goes on; a
///   failure of the key, the token or the account stops the asking (`SnapshotPolicy.stopsTheRun`), and every resource not
///   read after it says so. `notes` say what was read only in part: a list cut at the page cap, fields Apple didn't send,
///   attributes left out because this version doesn't know them, addresses masked. Every resource tried is in `counts`
///   (the store's), so "read and found none" isn't "not read".
/// - **Apple School Manager** has no people, content or Apple MDM reads: a School org's snapshot doesn't try them.
/// - **Bounded** (invariant 7): every list stops at the client's page cap and says so; every read waits on the org's rate
///   limiter (the client's, shared with the screens); a run is one task, cancellable, and only one runs at a time.
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
    /// The resource being read (the store's name), while a run goes.
    public private(set) var reading: String?
    public private(set) var lastOutcome: Outcome?

    private let orgs: OrgsModel
    private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Outcome, Never>?
    /// The current run's token: a run checks it after every page and await, so a cancelled or superseded run writes nothing.
    @ObservationIgnored private var token = 0
    /// Runs that have returned: what the tests wait on. `package`: the app never sees it.
    @ObservationIgnored package private(set) var runsFinished = 0

    static let alreadyRunning = "A snapshot is already being taken."

    public init(orgs: OrgsModel, now: @escaping @Sendable () -> Date = { Date() }) {
        self.orgs = orgs
        self.now = now
        orgs.onSwitch { [weak self] in self?.cancel() }
    }

    /// Takes a snapshot of the active org and records it; returns how it ended. One run at a time.
    @discardableResult
    public func run() async -> Outcome {
        guard !isRunning else { return .notRun(Self.alreadyRunning) }
        let store: SnapshotStore
        switch orgs.history {
        case .success(let opened): store = opened
        case .failure(let failure): return finish(.notRun(failure.message))
        }
        guard let profile = orgs.active, let client = orgs.appleClient else { return finish(.notRun(ScreenWords.unusable(orgs))) }
        token += 1
        let run = Run(org: profile, client: client, generation: orgs.generation, token: token, takenAt: now())
        isRunning = true
        let task = Task { await self.collect(run, into: store) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        isRunning = false
        reading = nil
        return finish(outcome)
    }

    /// Stops the run going, if any: it records nothing. An org or client switch calls this.
    public func cancel() {
        token += 1
        task?.cancel()
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        lastOutcome = outcome
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
        /// Apple School Manager's API has none of the Business-only reads (plan §2.4): a School org's run doesn't try them.
        func tries(_ rule: SnapshotPolicy.Rule) -> Bool { !rule.businessOnly || org.scope == .known(.business) }
    }

    /// What a run has read so far.
    private struct Collected {
        var resources: [String: [Resource]] = [:]
        var errors: [String: String] = [:]
        var notes: [String: [String]] = [:]
        /// The code of the failure that stopped the asking (the key, the token, the account); nil while reads go on.
        var stopped: String?

        mutating func note(_ rule: SnapshotPolicy.Rule, _ words: String) { notes[rule.name, default: []].append(words) }
    }

    /// Whether the run may go on: its token holds, its task isn't cancelled, and the orgs are still on its generation.
    private func current(_ run: Run) -> Bool { run.token == token && !Task.isCancelled && orgs.generation == run.generation }

    private func collect(_ run: Run, into store: SnapshotStore) async -> Outcome {
        var collected = Collected()
        let client = run.client
        _ = await read(SnapshotPolicy.devices, run, &collected) { client.devices() }
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
        // The list, never `configuration(_:)`: the list sends a custom setting's profile as null, and what is kept is
        // `Configuration.resource`, the profile withheld (operator, 2026-10-31).
        _ = await read(SnapshotPolicy.configurations, run, &collected) { client.configurations() }
        guard current(run) else { return .cancelled }
        _ = await read(SnapshotPolicy.mdmEnrolled, run, &collected) { client.mdmDevices() }
        guard current(run) else { return .cancelled }
        // The per-device sweeps (`SnapshotPolicy.sweeps`: AppleCare, Activation Lock, the Apple MDM details) go here, over the
        // devices read above, at the limiter's rate and cancellable (plan §3.6). Not run yet: a snapshot has them in neither
        // `counts` nor `errors`, so `SnapshotStore.latest` passes over it for them.
        reading = nil
        guard current(run) else { return .cancelled }
        let notes = collected.notes.mapValues { $0.joined(separator: "; ") }
        do {
            // Under the profile captured at the start, never `orgs.active`.
            return .recorded(try await store.record(org: run.org, takenAt: run.takenAt, resources: collected.resources,
                                                    errors: collected.errors, notes: notes))
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
            if last.truncated { collected.note(rule, Self.cut(views.count, total: last.total)) }
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
        reading = rule.name
        var items: [Resource] = [], failure: (any Error)?, failed = 0, cut = 0, unsendable = 0
        for service in services.views {
            // An id that can't go in a path is never sent: the client would call a service Apple has just listed "no such item".
            guard AppleRead.isPathSafe(service.id) else {
                unsendable += 1
                continue
            }
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
                if SnapshotPolicy.stopsTheRun(error) { break }
            }
        }
        if failure == nil || !items.isEmpty { keep(items, rule, &collected) }
        if services.cut { collected.note(rule, "covers only the services read: their list stopped at the page limit") }
        if cut > 0 { collected.note(rule, "\(Self.services(cut)) device list\(cut == 1 ? "" : "s") stopped at the page limit") }
        if unsendable > 0 {
            collected.note(rule, "\(Self.services(unsendable)) id\(unsendable == 1 ? " isn't" : "s aren't") one Apple can be asked for, "
                           + "so \(unsendable == 1 ? "its" : "their") devices weren't read")
        }
        if failed > 0 { collected.note(rule, "\(failed) of \(services.views.count) services' device lists couldn't be read") }
        if let failure {
            fail(rule, failure, &collected)
        } else if unsendable > 0 {
            collected.errors[rule.name] = "unsendable id"
        }
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
