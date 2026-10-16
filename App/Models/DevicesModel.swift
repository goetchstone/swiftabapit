import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports
import Vault

/// Where a screen's data stands, in words a person reads (invariant 8: stale, truncated or forbidden is
/// never silent).
enum LoadState: Equatable {
    case idle
    case loading(count: Int)
    case loaded(at: Date)
    /// The probe or the read said 403: "your role can't read this".
    case forbidden
    case failed(String)

    var isLoading: Bool { if case .loading = self { true } else { false } }
}

/// One row of the Devices table: the device with its service's name, made once per load so sorting and
/// filtering don't re-read attributes.
nonisolated struct DeviceRow: Identifiable, Sendable {
    let device: OrgDevice
    let serial: String
    let model: String
    let family: String
    let status: String
    let service: String
    let added: Date?
    let ordered: Date?

    var id: String { device.id }

    init(_ device: OrgDevice, service: String?) {
        self.device = device
        serial = device.serialNumber
        model = device.deviceModel ?? ""
        family = device.productFamily?.rawValue ?? ""
        status = device.status?.rawValue ?? ""
        self.service = service ?? ""
        added = device.addedToOrgDate?.date
        ordered = device.orderDate?.date
    }
}

/// The active org's devices and services, read page by page (tables fill as pages arrive), with which
/// service each device is assigned to. Each load belongs to one org generation and is dropped if the org
/// changes under it.
@Observable
final class DevicesModel {
    private(set) var rows: [DeviceRow] = []
    private(set) var services: [MDMService] = []
    private(set) var deviceCount: [String: Int] = [:]
    private(set) var state: LoadState = .idle
    /// The page cap stopped the device list with more to come: "showing N of ≥M".
    private(set) var truncated = false
    private(set) var total: Int?

    var search = ""
    var family = ""
    var status = ""
    /// Serials sort as text, character by character: a numeric-aware sort put `DEMO1…` before `DEMO03…`.
    var sortOrder: [KeyPathComparator<DeviceRow>] = [KeyPathComparator(\DeviceRow.serial, comparator: String.StandardComparator.lexical)]

    private let orgs: OrgsModel
    private var loading: Task<Void, Never>?
    private var loadedGeneration = -1

    init(orgs: OrgsModel) { self.orgs = orgs }

    var devices: [OrgDevice] { rows.map(\.device) }

    /// The rows the table shows: searched (Find's rules) and filtered, then sorted.
    var shown: [DeviceRow] {
        var result = rows
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let found = Set(Find.matches(search, in: rows.map(\.device)).map(\.id))
            result = result.filter { found.contains($0.id) }
        }
        if !family.isEmpty { result = result.filter { $0.family == family } }
        if !status.isEmpty { result = result.filter { $0.status == status } }
        return result.sorted(using: sortOrder)
    }

    var families: [String] { Array(Set(rows.map(\.family))).filter { !$0.isEmpty }.sorted() }
    var statuses: [String] { Array(Set(rows.map(\.status))).filter { !$0.isEmpty }.sorted() }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R).
    func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || state == .idle else { return }
        loading?.cancel()
        guard let client = orgs.appleClient else {
            rows = []
            services = []
            state = .idle
            return
        }
        loadedGeneration = generation
        state = .loading(count: 0)
        truncated = false
        loading = Task { [weak self] in
            do {
                // Services first: the table names each device's service as its rows arrive.
                var services: [MDMService] = []
                for try await page in client.services() { services += page.items }
                var serviceOf: [String: String] = [:], counts: [String: Int] = [:]
                for service in services {
                    for try await page in client.serviceDeviceIDs(service.id) {
                        for serial in page.items { serviceOf[serial] = service.name }
                        counts[service.id, default: 0] += page.items.count
                    }
                }
                guard let self, self.orgs.generation == generation else { return }
                self.services = services
                self.deviceCount = counts
                var rows: [DeviceRow] = []
                for try await page in client.devices() {
                    guard self.orgs.generation == generation else { return }
                    rows += page.items.map { DeviceRow($0, service: serviceOf[$0.serialNumber]) }
                    self.rows = rows
                    self.truncated = page.truncated
                    self.total = page.total
                    self.state = .loading(count: rows.count)
                }
                self.state = .loaded(at: Date())
                if let id = self.orgs.active?.id { self.orgs.record(readsPerMinute: await client.learnedReadsPerMinute, for: id) }
            } catch is CancellationError {
            } catch AppleAPIError.forbidden {
                if let self, self.orgs.generation == generation { self.state = .forbidden }
            } catch {
                guard let self, self.orgs.generation == generation else { return }
                self.state = .failed(Self.message(error))
            }
        }
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case let error as AppleAPIError: error.message
        case let error as VaultError: error.guidance
        default: "\(error.localizedDescription)"
        }
    }

    /// The CSV of what the table shows, every attribute Apple sent that may leave the app, in Apple's order.
    func csv() -> String {
        CSV.text(shown.map { CSV.Item($0.device.resource) }, allowing: ExportPolicy.allowing())
    }
}
