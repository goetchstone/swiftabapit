import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// Overview › Dashboard (plan §8 Phase 2; Appendix B): counts by family and status, added per month, per service,
/// unassigned, services not connected in N days, recent audit events. It counts what the Devices screen reads: the
/// device list is read once for both, and its states (`devicesReadWhole`, `unassignedCount`, `servicesUnread`) are the
/// ones Phase 1's review rounds made honest, so a dash is never a zero here either. It reads only what that screen
/// doesn't: the last seven days of the audit log, Business only, whose refusal, failure or School scope its card says
/// and no other card feels. Each card has its words: why it can't count (`…Words`, from the state of what it counts),
/// or what is worth saying of what it counts; its data is nil unless the list it counts was read whole (invariant 8).
@MainActor
@Observable
public final class DashboardModel {
    /// The devices and services the dashboard counts: the Devices screen's own model, not a copy.
    public let devices: DevicesModel

    /// The audit card's own state, apart from the devices'.
    public private(set) var auditState: LoadState = .idle
    /// The newest `AuditDigest.recentLimit` events of the last `auditDays` days, newest first by instant; empty unless the
    /// read ended (whole, or cut at the page cap and said): the newest of a failed read's part aren't the newest.
    public private(set) var recentEvents: [AuditEvent] = []
    /// The recent events as the card lists them: type, actor, subject and outcome in Activity's words (`ActivityRow`), an
    /// actor or a subject Apple named only by id shown by its id, never a dash (Phase 2b review L3: the card showed
    /// `actorName ?? "—"` and the type raw, decided in the view).
    public var recentRows: [ActivityRow] { recentEvents.enumerated().map { ActivityRow($0.element, id: $0.offset) } }
    /// How many events the read returned.
    public private(set) var auditRead = 0
    /// The page cap stopped the audit read.
    public private(set) var auditTruncated = false

    /// The N of "services not connected in N days", chosen in the view; a new N counts again what is here.
    public var quietDays = QuietServices.defaultDays
    public static let quietDayChoices = [1, 7, 14, 30, 60, 90]
    /// abapit's dashboard read the last seven days of the audit log.
    public static let auditDays = 7
    /// abapit's dashboard listed the first 30 unassigned serials.
    public static let unassignedListed = 30

    /// One service's bar: its devices, or nil when its device list wasn't read whole (never 0).
    public struct ServiceCount: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let count: Int?

        public init(id: String, name: String, count: Int?) {
            self.id = id
            self.name = name
            self.count = count
        }
    }

    private let orgs: OrgsModel
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The audit read's token: every write checks it, so a superseded read never lands.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    /// Audit reads that have returned, superseded ones included: what tests wait on. `package`: the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel, devices: DevicesModel) {
        self.orgs = orgs
        self.devices = devices
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R), the devices too, and
    /// cancels a read still running.
    public func load(force: Bool = false) {
        devices.load(force: force)
        loadAudit(force: force)
    }

    // MARK: the fleet

    /// Why the device counts aren't shown, in words; nil once the device list is read whole.
    public var fleetUnread: String? {
        switch devices.state {
        case .idle: return "Reading the devices…"
        case .loading(let count): return count == 0 ? "Reading the devices…" : "Reading the devices… \(count.formatted()) so far."
        case .loaded:
            guard devices.truncated else { return nil }
            let read = devices.rows.count.formatted()
            return "Not counted: the device list stopped at the page limit after \(read) of \(devices.total.map { $0.formatted() } ?? "more than \(read)") devices."
        case .forbidden: return "Your role can't read devices."
        case .failed(let why): return "The devices couldn't be read: \(why)"
        case .unusable(let why), .notInScope(let why): return why
        }
    }

    /// The fleet cards' words: why nothing is counted, or that there is nothing to count.
    public var fleetWords: String? { fleetUnread ?? (devices.rows.isEmpty ? "This organization has no devices." : nil) }

    /// abapit's `device_stats` at `now`, over a device list read whole; nil otherwise, never the counts of a part.
    public func stats(now: Date = Date()) -> DeviceStats? {
        devices.devicesReadWhole ? DeviceStats(devices.devices.map(\.resource), now: now) : nil
    }

    // MARK: the services

    /// Devices per service, in Apple's order, once the services are read whole; a service whose own device list wasn't
    /// is in it with no count.
    public var perService: [ServiceCount]? {
        guard devices.servicesUnread == nil else { return nil }
        return devices.services.map { ServiceCount(id: $0.id, name: $0.name, count: devices.deviceCount[$0.id]) }
    }

    /// The per-service card's words: why nothing is counted, that there are no services, or which aren't counted.
    public var servicesWords: String? {
        if let why = devices.servicesUnread { return why }
        if devices.services.isEmpty { return "This organization has no device management services." }
        let uncounted = devices.services.filter { devices.deviceCount[$0.id] == nil }.map(\.name)
        return uncounted.isEmpty ? nil : "Not counted, as their device lists weren't read whole: \(uncounted.joined(separator: ", "))."
    }

    /// The serials no service holds, by code point (abapit's `assignment_summary`); nil unless the devices, the services
    /// and every service's device list were read whole (`DevicesModel.unassignedCount`): unknown is never unassigned.
    public var unassigned: [String]? {
        guard devices.unassignedCount != nil else { return nil }
        return devices.rows.filter { $0.assignment == .unassigned }.map(\.serial)
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// The unassigned card's words: why nothing is counted, that every device is assigned, or how many are listed.
    public var unassignedWords: String? {
        guard let serials = unassigned else { return fleetUnread ?? devices.servicesUnread ?? devices.serviceNote ?? "Not counted." }
        if serials.isEmpty { return "Every device is assigned to a service." }
        return serials.count > Self.unassignedListed ? "The first \(Self.unassignedListed) of \(serials.count.formatted()), by serial." : nil
    }

    /// The services not connected in `quietDays` at `now`, by Reports' rule (`QuietServices`: deleted ones skipped, never
    /// connected and unreadable first, then the oldest); nil unless the services were read whole, so "every service has
    /// connected" is never said of a list nobody read.
    public func quiet(now: Date = Date()) -> [QuietServices.Row]? {
        guard devices.servicesUnread == nil else { return nil }
        return QuietServices(devices.services, now: now, days: quietDays).rows
    }

    /// The quiet-services card's words: why nothing is counted, or that none is quiet.
    public func quietWords(now: Date = Date()) -> String? {
        if let why = devices.servicesUnread { return why }
        return quiet(now: now)?.isEmpty == true ? "Every service has connected in the last \(quietDays.formatted()) days, deleted ones aside." : nil
    }

    /// When a quiet service last connected, in words: never, a date this app can't read (shown raw), or whole days ago, as
    /// the Services screen says it (`DevicesModel.lastConnected`).
    public static func lastConnected(_ row: QuietServices.Row, now: Date) -> String {
        DevicesModel.lastConnected(row.lastConnected, of: row.service, now: now)
    }

    // MARK: recent audit events

    /// The audit card's words: loading, refused, failed, not in scope or unusable; once read, how many events, or that
    /// the page cap cut the read, whose newest ten may then not be the newest (Apple documents no order for the log).
    public var auditWords: String? {
        let days = Self.auditDays
        switch auditState {
        case .idle, .loading(count: 0): return "Reading the last \(days) days of the audit log…"
        case .loading(let count): return "Reading the last \(days) days of the audit log… \(count.formatted()) events so far."
        case .loaded:
            if auditTruncated {
                return "Showing the newest \(recentEvents.count) of the \(auditRead.formatted()) events read: the audit log stopped at the page limit, "
                    + "and Apple documents no order for it, so newer events may be missing."
            }
            if auditRead == 0 { return "No audit events in the last \(days) days." }
            if auditRead > recentEvents.count { return "The newest \(recentEvents.count) of \(auditRead.formatted()) events in the last \(days) days." }
            return "\(auditRead.formatted()) event\(auditRead == 1 ? "" : "s") in the last \(days) days."
        case .forbidden: return "Your role can't read the audit log."
        case .failed(let why): return "The audit log couldn't be read: \(why)"
        case .unusable(let why), .notInScope(let why): return why
        }
    }

    // MARK: summaries a screen reader reads

    /// A chart's bars as one sentence: each name and its count, in the chart's order.
    public static func summary(_ tallies: [Tally]) -> String {
        tallies.isEmpty ? "none" : tallies.map { "\($0.name) \($0.count.formatted())" }.joined(separator: ", ")
    }

    /// The per-service chart's bars, a service not counted said as such.
    public static func summary(_ counts: [ServiceCount]) -> String {
        counts.isEmpty ? "none" : counts.map { "\($0.name) \($0.count.map { $0.formatted() } ?? "not counted")" }.joined(separator: ", ")
    }

    // MARK: reading the audit log

    private func loadAudit(force: Bool) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || auditState == .idle else { return }
        reset()
        loadedGeneration = generation
        guard let client = orgs.appleClient else {
            auditState = .unusable(ScreenWords.unusable(orgs))
            return
        }
        let query: AuditQuery
        do {
            query = try AuditQuery.last(days: Self.auditDays)
        } catch {
            auditState = .failed("The audit log's range couldn't be made (\(error)).")
            return
        }
        let token = token
        auditState = .loading(count: 0)
        task = Task { [weak self] in await self?.readAudit(client, query, token: token) }
    }

    /// The org changed: nothing of the old one's audit log stays, and if the card was showing, the new org's is read. The
    /// devices see the switch themselves.
    private func orgChanged() {
        let wasShowing = auditState != .idle
        reset()
        auditState = .idle
        loadedGeneration = -1
        if wasShowing { loadAudit(force: false) }
    }

    /// Cancels the running read, retires its token, and drops what it read.
    private func reset() {
        task?.cancel()
        task = nil
        token += 1
        recentEvents = []
        auditRead = 0
        auditTruncated = false
    }

    /// Whether the read holding `token` may still write: checked after every await and every page, because a cancelled
    /// `AsyncThrowingStream` loop ends without throwing and can still be handed a page already answered.
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func readAudit(_ client: AppleClient, _ query: AuditQuery, token: Int) async {
        defer { readsFinished += 1 }
        var events: [AuditEvent] = [], truncated = false
        do {
            for try await page in client.auditEvents(query) {
                guard current(token) else { return }
                events += page.items
                truncated = page.truncated
                auditState = .loading(count: events.count)
            }
            guard current(token) else { return }
            recentEvents = AuditDigest.recent(events.map(\.resource)).map { AuditEvent(resource: $0) }
            auditRead = events.count
            auditTruncated = truncated
            auditState = .loaded(at: Date())
        } catch {
            guard current(token) else { return }
            auditState = LoadState(after: error)
        }
    }
}
