import Foundation
import JSONAPI
import Observation
import Reports

/// Apple Business against Mosyle Business (plan Phase 7; abapit's `/reports/reconciliation`): the active Apple org's devices,
/// from the Devices screen's read, joined by serial to its paired Mosyle org's, from the Mosyle screen's read; one read each,
/// shared, as the Dashboard counts the Devices read. The report is made only from two lists read whole: a list cut at the
/// page cap, still loading or failed would put devices it didn't read in the wrong bucket, so it says why instead
/// (invariant 8). An Apple org with no Mosyle org paired says Mosyle isn't in scope.
@MainActor
@Observable
public final class ReconciliationModel {
    /// A row as the table shows it, its words made once.
    public struct Row: Identifiable, Sendable {
        public let row: Reconciliation.Row
        public let serial: String
        public let model: String
        public let family: String
        public let appleStatus: String
        public let mosyleStatus: String
        public let os: String
        public let lastCheckIn: Date?
        public let user: String

        public var id: String { row.id }
        public var lastCheckInSort: Date { lastCheckIn ?? .distantPast }

        init(_ row: Reconciliation.Row) {
            self.row = row
            serial = row.serial
            model = MosyleModel.text(row.deviceModel)
            family = MosyleModel.text(row.productFamily)
            appleStatus = MosyleModel.text(row.appleStatus)
            mosyleStatus = MosyleModel.text(row.mosyleStatus)
            os = MosyleModel.text(row.osVersion)
            lastCheckIn = ISODate.parse(row.lastCheckIn.string)?.date
            user = MosyleModel.text(row.currentUser)
        }
    }

    public var presence: Reconciliation.Presence = .appleOnly
    public var search = ""
    public var order = [KeyPathComparator(\Row.serial)]

    private let orgs: OrgsModel
    private let devices: DevicesModel
    private let mosyle: MosyleModel
    /// The report and the reads it was made from: each list's state (a finished read's carries its time, so a Refresh that
    /// reads the same count is a new key) and its count.
    @ObservationIgnored private var cache: (key: Key, report: Reconciliation)?

    struct Key: Equatable {
        let generation: Int, apple: LoadState, appleCount: Int, mosyle: LoadState, mosyleCount: Int
    }

    public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel) {
        self.orgs = orgs
        self.devices = devices
        self.mosyle = mosyle
    }

    /// Reads both lists unless they are read; `force` (Refresh) reads both again.
    public func load(force: Bool = false) {
        guard orgs.reconciles else { return }
        devices.load(force: force)
        mosyle.loadDevices(force: force)
    }

    /// The report, once both lists are read whole; nil until then, and `note` says why.
    public var report: Reconciliation? {
        guard orgs.reconciles, devices.devicesReadWhole, mosyle.devices.isWhole else { return nil }
        let key = Key(generation: orgs.generation, apple: devices.state, appleCount: devices.rows.count, mosyle: mosyle.devices.state,
                      mosyleCount: mosyle.devices.rows.count)
        if let cache, cache.key == key { return cache.report }
        let report = Reconciliation(apple: devices.devices.map(\.resource), mosyle: mosyle.devices.rows.map(\.device))
        cache = (key, report)
        return report
    }

    /// Why there is no report, in words; nil when there is one.
    public var note: String? {
        if !orgs.reconciles {
            return orgs.mosyleUnavailable?.why ?? "Reconciliation runs from an Apple organization paired with a Mosyle Business one."
        }
        if let why = Self.why(devices.state, truncated: devices.truncated, count: devices.rows.count, source: "Apple Business") { return why }
        return Self.why(mosyle.devices.state, truncated: mosyle.devices.truncated, count: mosyle.devices.rows.count, source: "Mosyle")
    }

    /// Whether the report can't be made for a reason only pairing fixes: shown as "not in scope", not as a failure.
    public var isNotInScope: Bool { !orgs.reconciles && orgs.mosyleUnavailable?.notInScope == true }

    static func why(_ state: LoadState, truncated: Bool, count: Int, source: String) -> String? {
        switch state {
        case .idle: "Reading \(source)'s devices…"
        case .loading(let read): "Reading \(source)'s devices… \(read.formatted()) so far."
        case .loaded where truncated:
            "\(source)'s device list stopped at the page limit (\(count.formatted()) devices read): a reconciliation would put the devices past it in the wrong column."
        case .loaded: nil
        case .forbidden: "\(source)'s devices can't be read: your role can't read them."
        case .failed(let why), .notInScope(let why), .unusable(let why): "\(source)'s devices couldn't be read: \(why)"
        }
    }

    /// The bucket on screen, searched by serial, model or user, then sorted.
    public var shown: [Row] {
        guard let report else { return [] }
        let rows: [Reconciliation.Row] = switch presence {
        case .appleOnly: report.appleOnly
        case .both: report.both
        case .mosyleOnly: report.mosyleOnly
        }
        let query = MosyleModel.query(search)
        let made = rows.map(Row.init)
        let found = query.isEmpty ? made : made.filter { row in [row.serial, row.model, row.user].contains { $0.localizedStandardContains(query) } }
        return found.sorted(using: order)
    }

    /// The summary line: how many in each bucket and the share enrolled; nil without a report.
    public var summary: String? {
        guard let report else { return nil }
        return "\(report.both.count.formatted()) in both, \(report.appleOnly.count.formatted()) in Apple Business only, "
            + "\(report.mosyleOnly.count.formatted()) in Mosyle only: \(report.enrollmentRate.formatted())% of "
            + "\(report.totalUnique.formatted()) serials enrolled."
    }

    /// A bucket's title with its count, for the picker.
    public func title(_ presence: Reconciliation.Presence) -> String {
        let name = switch presence {
        case .appleOnly: "Apple only"
        case .both: "In both"
        case .mosyleOnly: "Mosyle only"
        }
        guard let report else { return name }
        let count = switch presence {
        case .appleOnly: report.appleOnly.count
        case .both: report.both.count
        case .mosyleOnly: report.mosyleOnly.count
        }
        return "\(name) (\(count.formatted()))"
    }

    /// Every bucket, as abapit's export wrote it, searched as the table is: the whole report, not the bucket on screen.
    public func csv() -> String {
        guard let report else { return "" }
        let query = MosyleModel.query(search)
        let rows = query.isEmpty ? report.rows : report.rows.filter { row in
            [row.serial, MosyleModel.text(row.deviceModel), MosyleModel.text(row.currentUser)].contains { $0.localizedStandardContains(query) }
        }
        return Reconciliation.csv(rows)
    }

    /// Why Export is off; nil when it exports. No report, nothing to export.
    public var exportBlocked: String? {
        guard report != nil else { return note ?? ScreenWords.nothingToExport }
        return csv().split(separator: "\r\n").count > 1 ? nil : ScreenWords.nothingToExport
    }
}
