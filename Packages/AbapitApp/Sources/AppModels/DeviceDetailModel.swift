import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
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
    /// The timeline's audit events as Apple sent them, for the timeline from both sources.
    private var auditEvents: [Resource] = []

    private let orgs: OrgsModel
    /// Device 360's Mosyle half reads the Mosyle screen's device list: one read for both.
    private let mosyle: MosyleModel?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current request's token: a read for a device shown before, even the same serial, never lands.
    @ObservationIgnored private var token = 0
    /// Panel reads that have returned, superseded ones included: what tests wait on instead of the clock. `package`:
    /// the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0
    /// Timeline reads that have returned, counted apart so the four panels' count stays theirs.
    @ObservationIgnored package private(set) var timelineReadsFinished = 0

    public init(orgs: OrgsModel, mosyle: MosyleModel? = nil) {
        self.orgs = orgs
        self.mosyle = mosyle
        orgs.onSwitch { [weak self] in self?.show(nil) }
    }

    /// Device 360's Mosyle half (plan Phase 7, defect 17): the device as the Mosyle org in view lists it.
    public enum MosyleSide: Sendable {
        /// No Mosyle org is paired with this one, or none can be read: why, in words.
        case notInScope(String)
        case reading
        case found(MosyleModel.DeviceRow)
        /// Mosyle's list doesn't hold the serial, in words: whole, or cut at the page cap.
        case notFound(String)
        case failed(String)
    }

    /// The shown device in Mosyle, found by serial as abapit's `_find_serial` found it (stripped and upper-cased, so
    /// Mosyle's casing doesn't matter) in the Mosyle screen's device list, which it asks for when the device is shown.
    public var mosyleSide: MosyleSide {
        guard let mosyle, let serial else { return .reading }
        guard orgs.mosyleOrg != nil else { return .notInScope(orgs.mosyleUnavailable?.why ?? "No Mosyle Business organization is paired with this one.") }
        let key = Reconciliation.key(serial)
        if !key.isEmpty, let row = mosyle.devices.rows.first(where: { Reconciliation.key($0.device.id) == key }) { return .found(row) }
        switch mosyle.devices.state {
        case .idle, .loading: return .reading
        case .loaded where mosyle.devices.truncated:
            return .notFound("Not among the \(mosyle.devices.rows.count.formatted()) devices read before Mosyle's list stopped at the page limit.")
        case .loaded: return .notFound("Mosyle Business doesn't list this serial: it isn't enrolled there.")
        case .forbidden: return .failed("Mosyle refused the device list.")
        case .failed(let why), .notInScope(let why), .unusable(let why): return .failed(why)
        }
    }

    /// The device's dates from both sources, newest first (abapit's `device_timeline`): Apple's order and arrival, its audit
    /// events once read, and Mosyle's enrolment and check-ins once found. Each source adds what it has read so far.
    public var bothTimeline: [MergedTimeline.Item] {
        let apple: JSONObject? = if case .loaded(let device) = device { device.resource.attributes } else { nil }
        let found: JSONObject? = if case .found(let row) = mosyleSide { row.device.attributes } else { nil }
        return MergedTimeline.items(apple: apple, mosyle: found, audit: auditEvents)
    }

    public func show(_ serial: String?) {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        self.serial = serial
        (device, coverage, lock, service, timeline) = (.loading, .loading, .loading, .loading, .loading)
        timelineQuery = nil
        auditEvents = []
        guard let serial else { return }
        if orgs.mosyleOrg != nil { mosyle?.loadDevices() }
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
        if AppleRead.isPathSafe(serial) {
            run({ try await client.device(serial) }) { [weak self] in self?.device = $0 }
            run({ try await client.appleCare(serial) }) { [weak self] in self?.coverage = $0 }
            run({ try await client.activationLock(serial) }) { [weak self] in self?.lock = $0 }
            run({ try await client.assignedService(serial) }) { [weak self] in self?.service = $0 }
        } else {
            // A serial that can't go in a path is never sent, and never "no such item", the client's word for a read it
            // refused to build, of a device Apple has just listed (Phase 2b verifier round 1: review L1's class, here).
            let why = ScreenWords.unsendableID
            (device, coverage, lock, service) = (.failed(why), .failed(why), .failed(why), .failed(why))
        }
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
            var read: [Resource] = []
            do {
                var events: [AuditEvent] = [], cut = false
                for try await page in client.auditEvents(query) {
                    events += page.items
                    cut = page.truncated
                }
                read = events.map(\.resource)
                let rows = AuditDigest.newestFirst(read).enumerated().map { ActivityRow(AuditEvent(resource: $0.element), id: $0.offset) }
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
            if case .loaded(.read) = result { auditEvents = read }
        })
    }
}
