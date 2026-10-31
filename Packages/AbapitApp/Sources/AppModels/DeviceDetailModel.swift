import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// A panel's own result: one panel failing (a role that can't read AppleCare) never blanks the others
/// (SwiftGamGui failure-log 2026-10-13, "load each panel as its own Result").
public enum Panel<Value> {
    case loading
    case loaded(Value)
    case forbidden
    case failed(String)
}

extension Panel {
    /// The panel a read's error leaves, through `LoadState(after:)`, so a panel says each error as a screen's list does:
    /// a 403 is "your role can't read this", anything else (not in scope included) in its words.
    @MainActor
    init(after error: any Error) {
        switch LoadState(after: error) {
        case .forbidden: self = .forbidden
        case .failed(let why), .notInScope(let why), .unusable(let why): self = .failed(why)
        case .idle, .loading, .loaded: self = .failed(OrgsModel.message(error))
        }
    }
}

/// Device 360's ABM timeline (plan Phase 2: "Device 360's ABM timeline uses `filter[subjectId]`"): the device's audit
/// events over the last `DeviceDetailModel.timelineDays` days, newest first, as Apple filtered them by subject; or why
/// there are none to read. Apple School Manager has no audit log: said, never an empty timeline (invariant 8).
public enum DeviceTimeline: Sendable {
    case read(rows: [ActivityRow], truncated: Bool)
    case notInScope(String)

    /// What the panel says besides its rows, in words; nil when the rows are all there is to say.
    public var note: String? {
        switch self {
        case .notInScope(let why): why
        case .read(let rows, true): "Showing \(rows.count.formatted()) event\(rows.count == 1 ? "" : "s"): the list stopped at the page limit."
        case .read(let rows, false): rows.isEmpty ? "No audit event names this device in the last \(DeviceDetailModel.timelineDays) days." : nil
        }
    }
}

/// The Device inspector's ABM half (plan §4): the device with every attribute, its AppleCare, its
/// Activation Lock, its assigned service and its audit timeline, each read on its own. An org switch empties it at once.
@MainActor
@Observable
public final class DeviceDetailModel {
    /// How far back the timeline reads: abapit's device page read 30 days.
    public nonisolated static let timelineDays = 30

    public private(set) var serial: String?
    public private(set) var device: Panel<OrgDevice> = .loading
    public private(set) var coverage: Panel<[AppleCareCoverage]> = .loading
    public private(set) var lock: Panel<ActivationLockStatus> = .loading
    public private(set) var service: Panel<MDMService?> = .loading
    /// Its own panel: a role that can't read the audit log is told so here, and only here.
    public private(set) var timeline: Panel<DeviceTimeline> = .loading
    /// The query the timeline was asked with; nil until it is. `package`: only the tests read it (Phase 2b review L10).
    package private(set) var timelineQuery: AuditQuery?

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current request's token: a read for a device shown before, even the same serial, never lands.
    @ObservationIgnored private var token = 0
    /// Panel reads that have returned, superseded ones included: what tests wait on instead of the clock. `package`:
    /// the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0
    /// Timeline reads that have returned, counted apart so the four panels' count stays theirs.
    @ObservationIgnored package private(set) var timelineReadsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        orgs.onSwitch { [weak self] in self?.show(nil) }
    }

    public func show(_ serial: String?) {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        self.serial = serial
        (device, coverage, lock, service, timeline) = (.loading, .loading, .loading, .loading, .loading)
        timelineQuery = nil
        guard let serial else { return }
        guard let client = orgs.appleClient else {
            // Never a spinner that can't end: why, in words (invariant 8).
            let why = ScreenWords.unusable(orgs)
            (device, coverage, lock, service, timeline) = (.failed(why), .failed(why), .failed(why), .failed(why), .failed(why))
            return
        }
        let token = token
        func run<T>(_ read: @escaping @Sendable () async throws -> T, _ assign: @escaping (Panel<T>) -> Void) {
            tasks.append(Task { [weak self] in
                defer { self?.readsFinished += 1 }
                let result: Panel<T>
                do {
                    result = .loaded(try await read())
                } catch is CancellationError {
                    return
                } catch AppleAPIError.forbidden {
                    result = .forbidden
                } catch {
                    result = .failed(OrgsModel.message(error))
                }
                guard let self, self.token == token, !Task.isCancelled else { return }
                assign(result)
            })
        }
        run({ try await client.device(serial) }) { [weak self] in self?.device = $0 }
        run({ try await client.appleCare(serial) }) { [weak self] in self?.coverage = $0 }
        run({ try await client.activationLock(serial) }) { [weak self] in self?.lock = $0 }
        run({ try await client.assignedService(serial) }) { [weak self] in self?.service = $0 }
        readTimeline(client, serial, token: token)
    }

    /// The timeline: Apple's `filter[subjectId]` with the serial, every page, then one write, which checks the token (a
    /// cancelled loop ends without throwing, so the end of the loop proves nothing). A School org's read throws before
    /// anything is sent, and says so in the panel.
    private func readTimeline(_ client: AppleClient, _ serial: String, token: Int) {
        let query: AuditQuery
        do {
            query = try AuditQuery.last(days: Self.timelineDays, subjectID: serial)
        } catch {
            // An identifier's shape only: a serial that isn't one is never sent.
            timeline = .failed("This serial can't be asked of the audit log.")
            timelineReadsFinished += 1
            return
        }
        timelineQuery = query
        tasks.append(Task { [weak self] in
            defer { self?.timelineReadsFinished += 1 }
            let result: Panel<DeviceTimeline>
            do {
                var events: [AuditEvent] = [], cut = false
                for try await page in client.auditEvents(query) {
                    events += page.items
                    cut = page.truncated
                }
                let rows = AuditDigest.newestFirst(events.map(\.resource)).enumerated().map { ActivityRow(AuditEvent(resource: $0.element), id: $0.offset) }
                result = .loaded(.read(rows: rows, truncated: cut))
            } catch is CancellationError {
                return
            } catch AppleAPIError.forbidden {
                result = .forbidden
            } catch AppleAPIError.notInScope(let section) {
                result = .loaded(.notInScope(AppleAPIError.notInScope(section).message))
            } catch {
                result = .failed(OrgsModel.message(error))
            }
            guard let self, self.token == token, !Task.isCancelled else { return }
            timeline = result
        })
    }
}
