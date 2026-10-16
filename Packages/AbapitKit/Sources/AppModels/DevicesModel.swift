import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports
import Vault

/// Where a screen's data stands, in words a person reads (invariant 8: stale, truncated or forbidden is
/// never silent).
public enum LoadState: Equatable, Sendable {
    /// Nothing has asked for it yet.
    case idle
    case loading(count: Int)
    case loaded(at: Date)
    /// The probe or the read said 403: "your role can't read this".
    case forbidden
    case failed(String)
    /// Nothing can be read: no organization, or one this version can't use, and why, as a sentence. Never idle
    /// zeros (Phase 1b review, LOW).
    case unusable(String)

    public var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// One row of the Devices table: the device with its service's name, made once per load (and once more when
/// the services arrive) so sorting and filtering don't re-read attributes.
public struct DeviceRow: Identifiable, Sendable {
    /// Which service the device is assigned to, as far as the services read could tell.
    public enum Assignment: Sendable, Equatable {
        /// The services haven't been read yet.
        case pending
        case unassigned
        case service(String)
        /// The services, or a service's device list, couldn't be read whole: unknown, never "unassigned".
        case unknown
    }

    public let device: OrgDevice
    public let serial: String
    public let model: String
    public let family: String
    public let status: String
    public let assignment: Assignment
    /// The Service column: the service's name; empty while unassigned or not read yet; "Unknown" when it can't be told.
    public let service: String
    public let added: Date?
    public let ordered: Date?

    public var id: String { device.id }

    public init(_ device: OrgDevice, assignment: Assignment) {
        self.device = device
        serial = device.serialNumber
        model = device.deviceModel ?? ""
        family = device.productFamily?.rawValue ?? ""
        status = device.status?.rawValue ?? ""
        self.assignment = assignment
        switch assignment {
        case .pending, .unassigned: service = ""
        case .service(let name): service = name
        case .unknown: service = "Unknown"
        }
        added = device.addedToOrgDate?.date
        ordered = device.orderDate?.date
    }
}

/// The active org's devices and services, read page by page (tables fill as pages arrive), with which
/// service each device is assigned to. Devices and services load side by side, each with its own state: a role
/// that can't read services still sees its devices (SwiftGamGui failure-log 2026-10-13, "load each panel as its
/// own Result"; Phase 1b review M3). Each load has a token: a load that was refreshed, superseded or cancelled
/// writes nothing, and an org switch clears everything at once and reads again (Phase 1b review H2).
@MainActor
@Observable
public final class DevicesModel {
    public private(set) var rows: [DeviceRow] = []
    public private(set) var state: LoadState = .idle
    /// The page cap stopped the device list with more to come: "showing N of ≥M".
    public private(set) var truncated = false
    public private(set) var total: Int?

    public private(set) var services: [MDMService] = []
    /// The services' own state: forbidden or failed here leaves the devices alone.
    public private(set) var servicesState: LoadState = .idle
    /// The page cap stopped the services list.
    public private(set) var servicesTruncated = false
    /// Devices per service, for each service whose device list was read whole.
    public private(set) var deviceCount: [String: Int] = [:]
    /// Why some devices' service shows as Unknown, in words; nil when every service's devices were read whole.
    public private(set) var serviceNote: String?

    public var search = ""
    public var family = ""
    public var status = ""
    /// Serials sort as text, character by character: a numeric-aware sort put `DEMO1…` before `DEMO03…`.
    public var sortOrder: [KeyPathComparator<DeviceRow>] = [KeyPathComparator(\DeviceRow.serial, comparator: String.StandardComparator.lexical)]

    /// What the services read has told so far about who holds which serial.
    private enum Assignments {
        case reading
        case read(names: [String: String], complete: Bool)
        case unreadable
    }

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current load's token: every write checks it, so a superseded load never lands.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    @ObservationIgnored private var assignments = Assignments.reading
    /// Read tasks (devices, services) that have returned, superseded ones included: what tests wait on instead of
    /// the clock. `package`: the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    public var devices: [OrgDevice] { rows.map(\.device) }

    /// The rows the table shows: searched (Find's rules) and filtered, then sorted.
    public var shown: [DeviceRow] {
        var result = rows
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = Set(Find.matches(search, in: rows.map(\.device)).map(\.id))
            result = result.filter { found.contains($0.id) }
        }
        if !family.isEmpty { result = result.filter { $0.family == family } }
        if !status.isEmpty { result = result.filter { $0.status == status } }
        return result.sorted(using: sortOrder)
    }

    public var families: [String] { Array(Set(rows.map(\.family))).filter { !$0.isEmpty }.sorted() }
    public var statuses: [String] { Array(Set(rows.map(\.status))).filter { !$0.isEmpty }.sorted() }

    /// The rows a walk read before it failed: shown, and said to be partial (Phase 1b review, LOW).
    public var partialCount: Int? {
        switch state {
        case .failed, .forbidden: rows.isEmpty ? nil : rows.count
        default: nil
        }
    }

    /// Why Export is off, in words; nil when the rows are a whole read. A partial list is never exported as if it
    /// were whole: the file couldn't say so. A list the page cap stopped exports, as the banner says "showing N of ≥M".
    public var exportBlocked: String? {
        switch state {
        case .loading: "The list is still loading."
        case .failed, .forbidden:
            rows.isEmpty ? nil : "The list is partial: \(rows.count.formatted()) devices were read before the error. Refresh, then export."
        default: nil
        }
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R) and cancels a load
    /// still running.
    public func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || state == .idle else { return }
        reset()
        loadedGeneration = generation
        guard let profile = orgs.active else {
            state = .unusable("No organization yet: add an Apple Business or Apple School Manager API account in Settings.")
            servicesState = state
            return
        }
        guard let client = orgs.appleClient else {
            state = .unusable("This organization can't be used: \(orgs.unusableReason ?? "it has no Apple API account.")")
            servicesState = state
            return
        }
        let token = token, org = profile.id
        state = .loading(count: 0)
        servicesState = .loading(count: 0)
        tasks = [
            Task { [weak self] in await self?.readDevices(client, token: token, org: org) },
            Task { [weak self] in await self?.readServices(client, token: token) },
        ]
    }

    /// The error in the operator's words.
    public static func message(_ error: any Error) -> String { OrgsModel.message(error) }

    /// The CSV of what the table shows, every attribute Apple sent that may leave the app, in Apple's order.
    public func csv() -> String {
        CSV.text(shown.map { CSV.Item($0.device.resource) }, allowing: ExportPolicy.allowing())
    }

    // MARK: loading

    /// The org changed: nothing of the old one stays on screen, in a CSV or in Find, and if anything was showing,
    /// the new org is read at once.
    private func orgChanged() {
        let wasShowing = state != .idle
        reset()
        state = .idle
        servicesState = .idle
        loadedGeneration = -1
        if wasShowing { load() }
    }

    /// Cancels the running load, retires its token, and drops what it read.
    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        assignments = .reading
        rows = []
        truncated = false
        total = nil
        services = []
        servicesTruncated = false
        deviceCount = [:]
        serviceNote = nil
    }

    /// Whether the load holding `token` may still write: not superseded, not cancelled. Checked after every await
    /// and every page, because a cancelled `AsyncThrowingStream` loop ends without throwing (Phase 1b review H2:
    /// a cancelled load said "loaded" over the old org's rows and saved its rate on the new org).
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func readDevices(_ client: AppleClient, token: Int, org: String) async {
        defer { readsFinished += 1 }
        do {
            for try await page in client.devices() {
                guard current(token) else { return }
                rows += page.items.map { DeviceRow($0, assignment: assignment(of: $0.serialNumber)) }
                truncated = page.truncated
                total = page.total
                state = .loading(count: rows.count)
            }
            guard current(token) else { return }
            state = .loaded(at: Date())
            let rate = await client.learnedReadsPerMinute
            // For the org this load was started for, and only while it is still that org's load.
            guard current(token) else { return }
            orgs.record(readsPerMinute: rate, for: org)
        } catch {
            guard current(token) else { return }
            state = Self.state(after: error)
        }
    }

    private func readServices(_ client: AppleClient, token: Int) async {
        defer { readsFinished += 1 }
        var list: [MDMService] = []
        do {
            for try await page in client.services() {
                guard current(token) else { return }
                list += page.items
                services = list
                servicesTruncated = page.truncated
                servicesState = .loading(count: list.count)
            }
        } catch {
            guard current(token) else { return }
            servicesState = Self.state(after: error)
            assignments = .unreadable
            rows = rows.map { DeviceRow($0.device, assignment: .unknown) }
            serviceNote = servicesState == .forbidden
                ? "Your role can't read device management services, so each device's service is unknown."
                : "The services couldn't be read (\(Self.message(error))), so each device's service is unknown."
            return
        }
        guard current(token) else { return }
        // One service's device list failing costs only what it would have told (Phase 1b review M3).
        var names: [String: String] = [:], counts: [String: Int] = [:], unread: [String] = []
        if servicesTruncated { unread.append("the list of services stopped at the page limit") }
        for service in list {
            var count = 0, cut = false
            do {
                for try await page in client.serviceDeviceIDs(service.id) {
                    guard current(token) else { return }
                    for serial in page.items { names[serial] = service.name }
                    count += page.items.count
                    cut = cut || page.truncated
                }
                guard current(token) else { return }
                if cut { unread.append("\(service.name)'s device list stopped at the page limit") } else { counts[service.id] = count }
            } catch {
                guard current(token) else { return }
                unread.append("\(service.name)'s devices couldn't be read (\(Self.message(error)))")
            }
        }
        deviceCount = counts
        assignments = .read(names: names, complete: unread.isEmpty)
        rows = rows.map { DeviceRow($0.device, assignment: assignment(of: $0.serial)) }
        serviceNote = unread.isEmpty ? nil
            : "A device not found in a service shows its service as Unknown: \(unread.joined(separator: "; "))."
        servicesState = .loaded(at: Date())
    }

    private func assignment(of serial: String) -> DeviceRow.Assignment {
        switch assignments {
        case .reading: .pending
        case .unreadable: .unknown
        case .read(let names, let complete): names[serial].map { .service($0) } ?? (complete ? .unassigned : .unknown)
        }
    }

    private static func state(after error: any Error) -> LoadState {
        if let error = error as? AppleAPIError, case .forbidden = error { return .forbidden }
        return .failed(message(error))
    }
}
