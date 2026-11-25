import Foundation
import Observation
import Reports

/// Waits, bounded and cancellable, for the live lists a screen reads, so an intent can answer from them (the operator, 2026-11-24:
/// an intent may start the screen's own live read, never a sweep, and wait up to a time limit; a read under 15 minutes old is
/// reused, and its age is said).
///
/// - **The screen's own read, never another.** A wanted list that is idle, stopped on an error (refused included), or older than
///   `fresh` is read again with its model's `load(force: true)` (the Devices model's, or the Mosyle model's `loadDevices(force:
///   true)`), as Refresh reads it: never a sweep, never a per-device read. At most one such read per model per request: a read
///   that fails is said, not tried again. A model whose read is under way is never restarted: the request waits on that read, so
///   two requests, or a request and a screen, share one.
/// - **A held read is reused**: a list read whole or cut at the page cap, under `fresh` old, is answered as it is, with its time.
/// - **Bounded and cancellable.** The wait watches the models' states and ends when every wanted list has ended, at `bound` on the
///   injected clock, at a switch of org or client, or when its task is cancelled. Ending the wait never stops the read: the
///   screens share it, and it lands there.
/// - **A switch answers nothing**: when the org generation changed, nothing of either client is answered (`.switched`).
@MainActor
public final class LiveWait {
    /// The live lists an answer can wait on.
    public enum List: String, CaseIterable, Sendable {
        /// Apple's device list (the Devices screen's).
        case appleDevices
        /// Apple's device management services, with each service's device list (the Services screen's).
        case appleServices
        /// The Mosyle org's devices, when the client has one (the Mosyle screen's).
        case mosyleDevices
    }

    /// How one list ended, in code's words: never more than was read.
    public enum End: Equatable, Sendable {
        /// Every page was read, at `at`.
        case whole(at: Date)
        /// Some of it: the page cap ("showing N of ≥M"), or a failure after rows. `at` is when that read ended.
        case partly(String, at: Date)
        /// None of it, and why: a 403 is "your role can't read …"; a failure; not in scope; no Mosyle org.
        case notRead(String)
        /// Still being read when the bound ran out. The read goes on, for the screens.
        case stillReading(after: Duration)

        /// The end in a few words, with the read's age at `now`: "read in full 5 minutes ago".
        public func words(now: Date) -> String {
            switch self {
            case .whole(let at): "read in full \(LiveWait.age(since: at, now: now))"
            case .partly(let how, let at): "read in part \(LiveWait.age(since: at, now: now)): \(how)"
            case .notRead(let why): "not read: \(why)"
            case .stillReading(let after): "still being read after \(after.components.seconds.formatted()) seconds"
            }
        }
    }

    /// How a request ended.
    public enum Outcome: Equatable, Sendable {
        /// Each wanted list's end.
        case lists([List: End])
        /// The request's task was cancelled: nothing is answered.
        case cancelled
        /// The org or client changed while it waited: nothing of either is answered.
        case switched
    }

    /// The longest a request waits (the planner's proposal, pending the operator's live check of Siri's and Shortcuts' own limit).
    public static let bound: Duration = .seconds(25)
    /// A held read younger than this is reused (the operator, 2026-11-24).
    public static let fresh: Duration = .seconds(15 * 60)

    private let orgs: OrgsModel
    private let devices: DevicesModel
    private let mosyle: MosyleModel
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Runs once the reads a request needs are started, before it waits: where a test switches the org or cancels mid-wait.
    package var afterStart: (@MainActor () async -> Void)?

    /// `sleep` is the bound's clock; `now` is what a held read's age is measured against.
    public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel, now: @escaping @MainActor () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.orgs = orgs
        self.devices = devices
        self.mosyle = mosyle
        self.now = now
        self.sleep = sleep
    }

    /// Reads what `wanted` needs (`fresh`: how old a held read may be), waits up to `bound` for every wanted list to end, and says
    /// how each ended.
    public func lists(_ wanted: Set<List>, bound: Duration = LiveWait.bound, fresh: Duration = LiveWait.fresh) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        let generation = orgs.generation
        start(wanted, fresh: fresh)
        await afterStart?()
        await wait(wanted, generation: generation, bound: bound)
        if Task.isCancelled { return .cancelled }
        guard orgs.generation == generation else { return .switched }
        let seen = now()
        var ends: [List: End] = [:]
        for list in wanted { ends[list] = end(of: list, bound: bound, seen: seen) }
        return .lists(ends)
    }

    // MARK: reading

    /// Starts the screens' own reads the wanted lists need, before anything waits: synchronously, so a second request made at once
    /// finds the read under way and shares it.
    private func start(_ wanted: Set<List>, fresh: Duration) {
        let now = now()
        func needsRead(_ state: LoadState) -> Bool {
            switch state {
            case .idle, .failed, .forbidden: true
            case .loaded(let at): Duration.seconds(now.timeIntervalSince(at)) > fresh
            // Under way: shared, never restarted. Can't be read here at all: said as it is.
            case .loading, .unusable, .notInScope: false
            }
        }
        // The Devices model reads its devices and services together: one read for either, never while one is under way.
        var apple: [LoadState] = []
        if wanted.contains(.appleDevices) { apple.append(devices.state) }
        if wanted.contains(.appleServices) { apple.append(devices.servicesState) }
        if !devices.state.isLoading, !devices.servicesState.isLoading, apple.contains(where: needsRead) { devices.load(force: true) }
        // No Mosyle org: nothing to read, and the Mosyle model is left as it is.
        if wanted.contains(.mosyleDevices), orgs.mosyleOrg != nil, needsRead(mosyle.devices.state) { mosyle.loadDevices(force: true) }
    }

    /// Waits until every wanted list has ended or the generation changed, the bound passed, or the task was cancelled; whichever
    /// comes first ends the other. Neither ends a read.
    private func wait(_ wanted: Set<List>, generation: Int, bound: Duration) async {
        let sleep = sleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.settled(wanted, generation: generation) }
            group.addTask { try? await sleep(bound) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Returns once every wanted list has ended or the generation changed, as the models' states say, or when cancelled.
    private func settled(_ wanted: Set<List>, generation: Int) async {
        let changes = Observations { [self] in orgs.generation != generation || wanted.allSatisfy(ended) }
        for await done in changes where done { return }
    }

    /// Whether `list`'s read has ended: not idle, not under way. A Mosyle list with no Mosyle org has nothing to read.
    private func ended(_ list: List) -> Bool {
        func ended(_ state: LoadState) -> Bool { state != .idle && !state.isLoading }
        switch list {
        case .appleDevices: return ended(devices.state)
        case .appleServices: return ended(devices.servicesState)
        case .mosyleDevices: return orgs.mosyleOrg == nil || ended(mosyle.devices.state)
        }
    }

    // MARK: how each list ended

    /// `list`'s end, in the words its screen uses: still being read when its read hasn't ended. `seen` stands in for a part read's
    /// time only where its model kept none.
    private func end(of list: List, bound: Duration, seen: Date) -> End {
        guard ended(list) else { return .stillReading(after: bound) }
        switch list {
        case .appleDevices:
            let live = ReportsModel.liveDevices(devices)
            return Self.end(live.list, at: live.readAt ?? seen)
        case .appleServices:
            let live = ReportsModel.liveServices(devices)
            var parts: [String] = []
            switch live.list {
            case .notRead(let why): return .notRead(why)
            case .partly(let how): parts.append(how)
            case .whole: break
            }
            // Each service's device list: once the services read ended whole or at the cap, every listed service has one.
            if case .loaded = devices.servicesState {
                let lists = devices.serviceDevices.values, short = lists.filter { $0.read != .whole }.count
                if short > 0 {
                    parts.append(short == 1 ? "the device list of 1 of \(lists.count.formatted()) services wasn't read whole"
                        : "the device lists of \(short.formatted()) of \(lists.count.formatted()) services weren't read whole")
                }
            }
            return Self.end(parts.isEmpty ? .whole : .partly(parts.joined(separator: "; ")), at: live.readAt ?? seen)
        case .mosyleDevices:
            guard orgs.mosyleOrg != nil else { return .notRead(orgs.mosyleUnavailable?.why ?? "No Mosyle Business organization is set up with this one.") }
            let listing = mosyle.devices, rows = listing.rows.count
            switch listing.state {
            case .idle, .loading: return .stillReading(after: bound)
            case .loaded(let at):
                return listing.truncated ? .partly("showing \(rows.formatted()) devices: the list stopped at the page limit", at: at) : .whole(at: at)
            case .forbidden:
                return rows == 0 ? .notRead("Mosyle refused the device list")
                    : .partly("Mosyle refused the list after \(rows.formatted()) devices", at: mosyle.devicesStoppedAt ?? seen)
            case .failed(let why):
                return rows == 0 ? .notRead(why) : .partly("the read failed after \(rows.formatted()) devices: \(why)", at: mosyle.devicesStoppedAt ?? seen)
            case .unusable(let why), .notInScope(let why): return .notRead(why)
            }
        }
    }

    private static func end(_ read: ListRead, at: Date) -> End {
        switch read {
        case .whole: .whole(at: at)
        case .partly(let how): .partly(how, at: at)
        case .notRead(let why): .notRead(why)
        }
    }

    /// A read's age in words: "less than a minute ago", "5 minutes ago", "2 hours ago", "3 days ago". A time ahead of `now` (the
    /// clock moved back) is under a minute.
    nonisolated static func age(since date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        func count(_ n: Int, _ unit: String) -> String { "\(n.formatted()) \(unit)\(n == 1 ? "" : "s") ago" }
        if minutes < 1 { return "less than a minute ago" }
        if minutes < 60 { return count(minutes, "minute") }
        if minutes < 48 * 60 { return count(minutes / 60, "hour") }
        return count(minutes / (24 * 60), "day")
    }
}
