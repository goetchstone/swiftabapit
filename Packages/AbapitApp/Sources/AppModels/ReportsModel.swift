import AppleBusiness
import AppleModels
import Foundation
import History
import JSONAPI
import Observation
import Orgs
import Reports

/// The Reports screen's model (plan Phase 3; docs/domains/history.md, "The Reports screen"): six reports over the active Apple
/// org, each built by Reports' own code from data this app already holds, and its CSV.
///
/// - **Where each report's data comes from** (the coordinating session's decisions).
///   - The reports that need a per-device sweep (Coverage, Out of warranty, Activation Lock, and Fleet age's coverage column)
///     read **the newest snapshot that read that sweep** (`SnapshotStore.latest`) and **that same snapshot's own device list**:
///     a live device list is never mixed with a snapshot's sweep. The snapshot's date and age are said on screen and in the
///     CSV's file name. A newest attempt that failed (or read only part of the sweep) is said with its code, and the last good
///     copy is used, with its own date; with none, the report judges nothing and says how to take one.
///   - Fleet age with no AppleCare snapshot uses the live device list with no coverage data, and says so.
///   - MDM migration and Device management service health use the live lists `DevicesModel` holds, read whole or said not to be.
///     The services' device counts are the ones `DevicesModel` read; a service whose list wasn't read whole is "not read".
///   - **This screen never starts a sweep or a snapshot**: it reads the local history, and the Devices model's own lists.
/// - **One function builds a report**: `build(_:tokens:)`, from the catalog's tokens, so a later Siri intent calls the same code
///   the screen does (plan §5, "Reports by voice"). A token that doesn't resolve is a problem in words and the report isn't run.
/// - **One org at a time**: a switch clears everything at once, and a read that returns after one is dropped.
@MainActor
@Observable
public final class ReportsModel {
    // MARK: the reports

    public enum Report: String, CaseIterable, Identifiable, Sendable {
        case coverage
        case fleetAge = "fleet-age"
        case activationLock = "activation-lock"
        case migration
        case serviceHealth = "service-health"
        case outOfWarranty = "out-of-warranty"

        public var id: Self { self }

        /// The catalog's entry, for the four it lists.
        public var catalogID: ReportCatalog.ID? {
            switch self {
            case .coverage, .fleetAge: nil
            case .activationLock: .activationLock
            case .migration: .migration
            case .serviceHealth: .serviceHealth
            case .outOfWarranty: .outOfWarranty
            }
        }

        public var title: String {
            switch self {
            case .coverage: "AppleCare coverage ending"
            case .fleetAge: "Fleet age"
            default: ReportCatalog.entry(catalogID!).title
            }
        }

        public var summary: String {
            switch self {
            case .coverage: "Active AppleCare coverage that ends within a number of days, soonest first, and how many devices have none."
            case .fleetAge: "Devices by age from their order date, and the refresh candidates: the devices a number of years old or more."
            default: ReportCatalog.entry(catalogID!).summary
            }
        }

        /// The Apple reads the report makes live or reads from a snapshot of: what a School org can't read is refused in words.
        public var reads: [AppleSection] {
            switch self {
            case .serviceHealth: [.mdmServers, .devices]
            default: [.devices]
            }
        }
    }

    /// One row, as the screen lists it.
    public struct Line: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        /// The row's display group (`lock:USER`, `status:other`, `no-record`, …): a group this version doesn't know is its raw name.
        public let group: String
    }

    /// A group the filter accepts, with how many rows it holds.
    public struct GroupCount: Equatable, Sendable, Identifiable {
        public let key: String
        public let count: Int
        public var id: String { key }
    }

    /// What a report says, over the data it was given. `built` is nil when nothing was judged.
    public struct Output: Sendable {
        public let report: Report
        public let title: String
        /// The filters as they applied, in words.
        public let filters: [String]
        /// Where the data came from and how old it is, in words; never empty for a report that read something.
        public let source: [String]
        /// Tokens that didn't resolve, in words. A report with problems isn't run.
        public let problems: [String]
        /// Why nothing was judged; nil when the report ran.
        public let judgesNothing: String?
        /// The report's own words: the list's read state first, then the counts.
        public let summary: [String]
        /// The groups the filter accepts, with their counts over the whole report; empty for a report with no group filter.
        public let groups: [GroupCount]
        /// The rows shown: the filter's, at most `ReportsModel.displayLimit`.
        public let lines: [Line]
        /// The rows the filter matched.
        public let matching: Int
        /// Said when the cap cuts the rows.
        public let capNote: String?
        /// Out of warranty only: the assumption behind every estimate.
        public let estimateNote: String?
        /// What the CSV holds, in words, beyond the rows (for the Save panel and the screen).
        public let exportNote: String
        /// The file's name without the client, or nil when there is nothing to export.
        public let fileBase: String?
        package let built: Built?

        public var canExport: Bool { built != nil }
    }

    package enum Built: Sendable {
        case coverage(CoverageReport)
        case fleetAge(FleetAgeReport)
        case activationLock(ActivationLockReport)
        case migration(MigrationReport)
        case serviceHealth(ServiceHealth)
        case outOfWarranty(WarrantyReport)
    }

    // MARK: where a sweep's data comes from

    /// A newest attempt that read none of the sweep: when, the code it failed with and the collector's note.
    package struct Failure: Equatable, Sendable {
        package let takenAt: String
        package let code: String
        package let note: String?
        package init(takenAt: String, code: String, note: String?) {
            self.takenAt = takenAt
            self.code = code
            self.note = note
        }
    }

    /// A sweep the snapshot read only in part (in its `counts` and its `errors` both: a device failed twice, couldn't be sent, wasn't
    /// asked, or its list was cut): the code and the collector's note. Its items are used, with its own device list.
    package struct SweepPart: Equatable, Sendable {
        package let code: String
        package let note: String?
    }

    /// A snapshot's sweep with that same snapshot's device list.
    package struct Used: Equatable, Sendable {
        package let id: Int64
        package let takenAt: String
        package let devices: [Resource]
        /// How much of that snapshot's device list was read.
        package let deviceList: ListRead
        /// The sweep's items in that snapshot: one per record (AppleCare) or one per device (Activation Lock).
        package let items: [Resource]
        /// The newer attempt that read none of the sweep, when this is the last good copy (an older, whole one).
        package let failure: Failure?
        /// Set when this snapshot read the sweep only in part.
        package let part: SweepPart?
    }

    package enum SweepSource: Equatable, Sendable {
        case used(Used)
        /// Nothing read the sweep, or the newest attempt read none of it and no earlier snapshot read it whole.
        case unavailable(Failure?)
    }

    /// Dates as the Changes screen shows them: the local time zone and the user's locale, through one cached format style each
    /// (`Date.formatted(date: .abbreviated, …)`). The tests inject a zone and a locale. File names keep a fixed UTC stamp (`dayStamp`).
    package struct DateWords: Sendable {
        private let dayStyle: Date.FormatStyle
        private let timeStyle: Date.FormatStyle

        package init(timeZone: TimeZone, locale: Locale) {
            dayStyle = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone)
            timeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        }

        package func day(_ date: Date) -> String { date.formatted(dayStyle) }
        package func dayTime(_ date: Date) -> String { date.formatted(timeStyle) }
        /// A snapshot's `takenAt` as a day; text the store holds that isn't a date as it is.
        package func day(takenAt: String) -> String { ISODate.parse(takenAt).map { day($0.date) } ?? takenAt }
    }

    // MARK: state

    /// The snapshot history's read: the sweeps' latest snapshots.
    public private(set) var state: LoadState = .idle
    public private(set) var report: Report = .coverage
    /// The group filter, nil for every group. Reset when the report changes.
    public private(set) var group: String?
    /// Coverage: expiring within this many days (1...1825). Fleet age: devices this many years old (1...10). Service health:
    /// quiet after this many days (1...1825).
    public var coverageDays = ReportsModel.defaultCoverageDays
    public var fleetYears = ReportsModel.defaultFleetYears
    public var quietDays = ReportsModel.defaultQuietDays
    /// The defaults a missing token takes in `build` (an intent's), never the screen's stepper values.
    public nonisolated static let defaultCoverageDays = 90
    public nonisolated static let defaultFleetYears = 4
    public nonisolated static let defaultQuietDays = QuietServices.defaultDays
    /// Reports built since launch: what a test holds "one build per redraw" with.
    @ObservationIgnored package private(set) var builds = 0
    @ObservationIgnored package private(set) var sources: [Sweep: SweepSource] = [:]
    /// Loads that have returned: what the tests wait on.
    package private(set) var loadsFinished = 0
    /// The most rows a report lists on screen; the CSV holds them all.
    @ObservationIgnored package var displayLimit = 200
    /// Run in the middle of a read, after its await and before its guard, when set: the tests switch orgs there. Stage: `load`.
    @ObservationIgnored package var afterRead: (@MainActor (String) async -> Void)?
    /// Awaited once, before the first load, when set: the demo's seeding of its fake snapshots finishes first, so the screen never
    /// draws half a history. The app sets it for the demo only.
    @ObservationIgnored public var beforeFirstLoad: (@MainActor () async -> Void)?
    /// The clock, so a test holds "3 days old".
    @ObservationIgnored package var now: @MainActor () -> Date = { Date() }
    /// The time zone and locale dates are worded in: the user's, as Changes shows them.
    @ObservationIgnored package var dates = DateWords(timeZone: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    @ObservationIgnored private var loadToken = 0

    private let orgs: OrgsModel
    private let devices: DevicesModel

    public static let mosyleWords = "This is a Mosyle Business organization. These reports read Apple Business and Apple School Manager data, and nothing was read from Mosyle."
    /// The tokens' bounds: the report types hold them too (`CoverageReport.maximumDays`, `FleetAgeReport.maximumYears`).
    public nonisolated static let daysRange = 1...CoverageReport.maximumDays
    public nonisolated static let yearsRange = 1...FleetAgeReport.maximumYears

    public init(orgs: OrgsModel, devices: DevicesModel) {
        self.orgs = orgs
        self.devices = devices
        orgs.onSwitch { [weak self] in self?.switched() }
    }

    /// An org or client switch: nothing of the old org stays (the clients rule). A read in flight is dropped by its generation guard
    /// (`load`), not by the token: the token only retires a load a newer load superseded, so each guard stands on its own.
    private func switched() {
        let wasShowing = state != .idle
        state = .idle
        sources = [:]
        report = .coverage
        group = nil
        coverageDays = Self.defaultCoverageDays
        fleetYears = Self.defaultFleetYears
        quietDays = Self.defaultQuietDays
        if wasShowing { refresh() }
    }

    public var isMosyle: Bool { orgs.active?.provider == .known(.mosyle) }

    // MARK: choosing

    public func select(_ chosen: Report) {
        guard chosen != report else { return }
        report = chosen
        group = nil
        readLive()
    }

    public func setGroup(_ key: String?) {
        guard let key else {
            group = nil
            return
        }
        guard let id = report.catalogID, ReportCatalog.entry(id).filters.contains(where: { $0.name == "group" && $0.values.contains(key) }) else { return }
        group = key
    }

    /// The tokens the filters on screen stand for, as `build` takes them.
    public var tokens: [String: String] {
        var tokens: [String: String] = [:]
        switch report {
        case .coverage: tokens["days"] = String(coverageDays)
        case .fleetAge: tokens["years"] = String(fleetYears)
        case .serviceHealth: tokens["days"] = String(quietDays)
        default: break
        }
        if let group { tokens["group"] = group }
        return tokens
    }

    /// The report on screen.
    public var current: Output { build(report, tokens: tokens) }

    // MARK: loading

    public func refresh() { Task { await load() } }

    /// Reads the active org's history for the latest snapshot of each sweep, and its device list: the local file, never Apple.
    /// Then asks the Devices model for its lists if the report on screen needs them live.
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
        guard !isMosyle else {
            state = .unusable(Self.mosyleWords)
            return
        }
        state = .loading(count: 0)
        let store: SnapshotStore
        switch orgs.openHistory() {
        case .success(let opened): store = opened
        case .failure(let failure):
            sources = [:]
            state = .failed(failure.message)
            readLive()
            return
        }
        let outcome: Result<[Sweep: SweepSource], SnapshotStore.Failure>
        do {
            outcome = .success(try await Self.read(store, org: profile))
        } catch {
            outcome = .failure(error)
        }
        await afterRead?("load")
        guard token == loadToken, generation == orgs.generation else { return }
        switch outcome {
        case .success(let read):
            sources = read
            state = .loaded(at: Date())
        case .failure(let failure):
            sources = [:]
            state = .failed(failure.message)
        }
        readLive()
    }

    /// Asks the Devices model for its lists when the report on screen reads them live: the migration and service health reports,
    /// and Fleet age when no snapshot gave it AppleCare. Reads only (what the Devices screen reads); never a sweep.
    func readLive() {
        guard orgs.active != nil, !isMosyle, usesLiveList(report) else { return }
        devices.load()
    }

    func usesLiveList(_ report: Report) -> Bool {
        switch report {
        case .migration, .serviceHealth: return true
        case .fleetAge:
            if case .used = source(.appleCare) { return false }
            // While the history is being read, nothing is known: not a reason to read Apple.
            return state != .idle && !state.isLoading
        default: return false
        }
    }

    /// The latest snapshot of each sweep with its own device list. One load per snapshot, though two sweeps may share it.
    /// - The newest attempt read the whole sweep: it is used.
    /// - It read some of it (in `counts` and `errors` both): **it is used, marked part**, with its own device list, never another
    ///   snapshot's.
    /// - It read none of it (`errors` only): the newest snapshot that read any of it is used (`SnapshotStore.newestRead`: whole, or a part
    ///   read, marked so) with its own date and device list, and the failure said; unavailable only when no snapshot read any of it.
    private static func read(_ store: SnapshotStore, org: OrgProfile) async throws(SnapshotStore.Failure) -> [Sweep: SweepSource] {
        var read: [Sweep: SweepSource] = [:]
        var held: [Int64: (devices: [Resource], list: ListRead, sweeps: [String: [Resource]])] = [:]
        func load(_ id: Int64) async throws(SnapshotStore.Failure) -> (devices: [Resource], list: ListRead, sweeps: [String: [Resource]]) {
            if let have = held[id] { return have }
            let snapshot = try await store.load(id, org: org)
            let names = [Sweep.appleCare, .activationLock].map { $0.rule.name }
            let made = (devices: snapshot.resources["devices"] ?? [], list: deviceList(snapshot.summary),
                        sweeps: Dictionary(uniqueKeysWithValues: names.map { ($0, snapshot.resources[$0] ?? []) }))
            held[id] = made
            return made
        }
        for sweep in [Sweep.appleCare, .activationLock] {
            let name = sweep.rule.name
            guard let latest = try await store.latest(name, org: org) else {
                read[sweep] = .unavailable(nil)
                continue
            }
            switch latest {
            case .read(let whole):
                let snapshot = try await load(whole.summary.id)
                read[sweep] = .used(Used(id: whole.summary.id, takenAt: whole.summary.takenAt, devices: snapshot.devices, deviceList: snapshot.list,
                                         items: whole.items, failure: nil, part: nil))
            case .failed(let attempt, let error, let newest):
                if attempt.counts[name] != nil {
                    // Some of it was read: that part is used, over the attempt's own device list.
                    let snapshot = try await load(attempt.id)
                    read[sweep] = .used(Used(id: attempt.id, takenAt: attempt.takenAt, devices: snapshot.devices, deviceList: snapshot.list,
                                             items: snapshot.sweeps[name] ?? [], failure: nil, part: SweepPart(code: error, note: attempt.notes[name])))
                } else {
                    // It read none of it: the newest snapshot that read any of it is used (whole, or part and marked so), with its own
                    // device list, and the newer failure is kept to be said. Nothing is "unavailable" unless no snapshot read any.
                    let failure = Failure(takenAt: attempt.takenAt, code: error, note: attempt.notes[name])
                    _ = newest
                    guard let some = try await store.newestRead(name, org: org) else {
                        read[sweep] = .unavailable(failure)
                        continue
                    }
                    let snapshot = try await load(some.summary.id)
                    let part = some.summary.errors[name].map { SweepPart(code: $0, note: some.summary.notes[name]) }
                    read[sweep] = .used(Used(id: some.summary.id, takenAt: some.summary.takenAt, devices: snapshot.devices, deviceList: snapshot.list,
                                             items: some.items, failure: failure, part: part))
                }
            }
        }
        return read
    }

    /// How much of a snapshot's device list was read: in `counts` and `errors` both is a part read.
    package nonisolated static func deviceList(_ summary: SnapshotStore.Summary) -> ListRead {
        guard summary.counts["devices"] != nil else {
            return .notRead(summary.errors["devices"].map { "the snapshot's device list wasn't read (\($0))" } ?? "the snapshot has no device list")
        }
        guard let code = summary.errors["devices"] else { return .whole }
        return .partly("the snapshot's device list was cut: \(code)" + (summary.notes["devices"].map { " (\($0))" } ?? ""))
    }

    // MARK: building a report

    /// Builds `report` with `tokens` from the active org's data: the one function the screen and, later, a Siri intent call
    /// (plan §5). Tokens are resolved by the catalog (`ReportCatalog.resolve`) for the four it lists, and by the same rules for
    /// coverage (`days`, 1...1825) and fleet age (`years`, 1...10); a token that doesn't resolve is a problem in words and the
    /// report isn't run. Never reads Apple or starts a sweep: it builds over what the history and the Devices model hold now.
    /// A missing token is the report's default (`defaultCoverageDays`, `defaultFleetYears`, `defaultQuietDays`), never the screen's value;
    /// the screen passes its own explicitly (`tokens`). **A live report built before the Devices model has read says "Not read from Apple
    /// yet"**: an intent will need a way to await that read (not built; `build` starts none).
    public func build(_ report: Report, tokens: [String: String]) -> Output {
        builds += 1
        let (resolved, problems) = Self.resolve(report, tokens)
        let title = report.title
        func nothing(_ why: String, source: [String] = [], filters: [String] = []) -> Output {
            Output(report: report, title: title, filters: filters, source: source, problems: problems, judgesNothing: why, summary: [], groups: [], lines: [],
                   matching: 0, capNote: nil, estimateNote: report == .outOfWarranty ? WarrantyReport.assumption : nil,
                   exportNote: "Nothing to export: this report judged nothing.", fileBase: nil, built: nil)
        }
        guard problems.isEmpty else { return nothing("The filters weren't understood, so the report wasn't run.") }
        guard let profile = orgs.active else { return nothing(ScreenWords.noOrganization) }
        if isMosyle { return nothing(Self.mosyleWords) }
        if let refusal = Self.refusal(report.reads, scope: profile.scope.known) { return nothing(refusal) }
        let when = now(), dates = self.dates
        let days = resolved["days"].flatMap(Int.init), years = resolved["years"].flatMap(Int.init), key = resolved["group"]
        var filters: [String] = []
        if let key { filters.append("Group: \(key)") }
        switch report {
        case .coverage:
            let source = self.source(.appleCare)
            guard case .used(let used) = source else { return nothing(unavailable(.appleCare, source)) }
            let days = days ?? Self.defaultCoverageDays
            let (map, unattributed) = Self.coverage(used)
            let built = CoverageReport(devices: used.devices, coverage: map, days: days, now: when, list: Self.listRead(used, sweep: .appleCare))
            var lines = built.expiring.enumerated().map { index, item in
                Line(id: "\(index)|" + item.device, title: item.device,
                     detail: Self.join([Self.text(item.attributes["description"]), "ends \(Self.text(item.attributes["endDateTime"]))",
                                        "\(item.daysLeft) day\(item.daysLeft == 1 ? "" : "s") left"]), group: "expiring")
            }
            for (index, (record, device)) in zip(built.unreadableEnd, built.unreadableEndDevices).enumerated() {
                lines.append(Line(id: "unreadable|\(index)|" + device + "|" + record.id, title: device,
                                  detail: "active coverage, end date not readable: \(Self.text(record.attributes["endDateTime"]))", group: "unreadable end date"))
            }
            return finish(report, filters: ["Ending within \(built.days) days"], source: Self.sourceWords(used, sweep: .appleCare, now: when, unattributed: unattributed, dates: dates),
                          summary: built.words, groups: [], lines: lines, group: nil, built: .coverage(built),
                          note: "The file holds the active coverages ending within \(built.days) days. Active coverages with an end date this app can't read, devices with no coverage and devices whose coverage wasn't read are counted on screen, not in the file.",
                          base: "coverage ending within \(built.days) days (snapshot \(ChangesModel.stamp(used.takenAt)))")
        case .fleetAge:
            let years = years ?? Self.defaultFleetYears
            var source: [String] = []
            let built: FleetAgeReport
            let base: String
            switch self.source(.appleCare) {
            case .used(let used):
                let (map, unattributed) = Self.coverage(used)
                built = FleetAgeReport(devices: used.devices, coverage: map, years: years, now: when, list: Self.listRead(used, sweep: .appleCare))
                source = Self.sourceWords(used, sweep: .appleCare, now: when, unattributed: unattributed, dates: dates)
                base = "fleet age \(built.years)+ years (snapshot \(ChangesModel.stamp(used.takenAt)))"
            case .unavailable(let failure):
                if state == .idle || state.isLoading { return nothing("Reading the snapshot history…", filters: ["Candidates: \(years)+ years old"]) }
                let live = liveDevices()
                built = FleetAgeReport(devices: live.resources, coverage: nil, years: years, now: when, list: live.list)
                let why: String
                if case .failed(let message) = state {
                    why = "The snapshot history couldn't be read (\(message))."
                } else if let failure {
                    why = "\(Self.failureWords(failure, sweep: .appleCare, dates: dates)). No snapshot has read AppleCare coverage."
                } else {
                    why = "No snapshot has read AppleCare coverage. This screen doesn't read it: take a snapshot with AppleCare coverage ticked (Activity › Changes › Snapshot now)."
                }
                source = [live.words(now: when, dates: dates), "The AppleCare column is empty. \(why)"]
                base = "fleet age \(built.years)+ years (\(live.stampWords))"
            }
            let lines = built.candidates.map { candidate in
                Line(id: candidate.serial, title: candidate.serial,
                     detail: Self.join([Self.text(candidate.model), Self.text(candidate.family), "ordered \(Self.text(candidate.ordered))",
                                        "\(String(format: "%.1f", candidate.ageYears)) years",
                                        "AppleCare: " + (candidate.notRead ? "not read" : candidate.covered.map { $0 ? "active" : "none active" } ?? "not read by this screen")]),
                     group: "candidate")
            }
            var summary = built.words
            summary += built.buckets.map { "\($0.label): \($0.count)" }
            return finish(report, filters: ["Candidates: \(built.years)+ years old"], source: source, summary: summary, groups: [], lines: lines, group: nil,
                          built: .fleetAge(built), note: "The file holds the refresh candidates, oldest first, with whether each has active coverage.", base: base)
        case .activationLock:
            let source = self.source(.activationLock)
            guard case .used(let used) = source else { return nothing(unavailable(.activationLock, source)) }
            var reads: [String: DeviceRead<ActivationLockStatus>] = [:]
            for item in used.items { reads[item.id] = .read(ActivationLockStatus(resource: item)) }
            let list = Self.listRead(used, sweep: .activationLock)
            let built = ActivationLockReport(list.isNotRead ? [] : used.devices.map(OrgDevice.init(resource:)), reads: reads, list: list)
            let rows = key.map { built.rows(group: $0) } ?? built.rows
            let lines = rows.map { row in
                Line(id: row.id, title: row.device.serialNumber,
                     detail: Self.join([Self.text(row.device.attributes["deviceModel"]), "lock: \(row.token == row.group ? row.group : row.group + " (\(row.token))")",
                                        "blocks release: \(row.blocksReleaseWords)", { if case .notRead(let why) = row.kind { return why } else { return "" } }()]),
                     group: row.group)
            }
            let groups = ActivationLockReport.fixedGroups.map { GroupCount(key: $0, count: built.rows(group: $0).count) }
            return finish(report, filters: filters, source: Self.sourceWords(used, sweep: .activationLock, now: when, unattributed: 0, dates: dates), summary: built.words,
                          groups: groups, lines: lines, group: key, built: .activationLock(built),
                          note: "The file holds every device, whatever group is shown, with its lock and whether it blocks release.",
                          base: "activation lock (snapshot \(ChangesModel.stamp(used.takenAt)))")
        case .outOfWarranty:
            let source = self.source(.appleCare)
            guard case .used(let used) = source else { return nothing(unavailable(.appleCare, source)) }
            var reads: [String: DeviceRead<[AppleCareCoverage]>] = [:]
            let (map, unattributed) = Self.coverage(used)
            for (id, read) in map {
                if case .read(let records) = read { reads[id] = .read(records.map(AppleCareCoverage.init(resource:))) }
            }
            let list = Self.listRead(used, sweep: .appleCare)
            let built = WarrantyReport(list.isNotRead ? [] : used.devices.map(OrgDevice.init(resource:)), coverage: reads, now: when, list: list)
            let rows = key.map { built.rows(group: $0) } ?? built.rows
            let lines = rows.map { row in
                Line(id: row.id, title: row.device.serialNumber,
                     detail: Self.join([Self.text(row.device.attributes["deviceModel"]), Self.warrantyState(row), Self.warrantyEstimate(row, dates: dates)]), group: row.group)
            }
            let groups = (WarrantyReport.fixedGroups + [WarrantyReport.estimatedPastToken]).map { GroupCount(key: $0, count: built.rows(group: $0).count) }
            return finish(report, filters: filters, source: Self.sourceWords(used, sweep: .appleCare, now: when, unattributed: unattributed, dates: dates), summary: built.words,
                          groups: groups, lines: lines, group: key, built: .outOfWarranty(built),
                          note: "The file holds every device, whatever group is shown. An estimate from the order date is labelled as one in its own column, with the assumption.",
                          base: "out of warranty (snapshot \(ChangesModel.stamp(used.takenAt)))")
        case .migration:
            let live = liveDevices()
            let built = MigrationReport(live.list.isNotRead ? [] : live.devices, now: when, list: live.list)
            let rows = key.map { built.rows(group: $0) } ?? built.rows
            let lines = rows.map { row in
                Line(id: row.id, title: row.device.serialNumber,
                     detail: Self.join([Self.text(row.device.attributes["deviceModel"]), "status: \(row.status?.rawValue ?? "none sent")",
                                        Self.deadline(row.deadline), "past due: \(row.pastDueWords)"]), group: row.group)
            }
            let groups = (MigrationReport.fixedGroups + [MigrationReport.pastDueToken, MigrationReport.pastDueStatusUnknownToken])
                .map { GroupCount(key: $0, count: built.rows(group: $0).count) }
            return finish(report, filters: filters, source: [live.words(now: when, dates: dates)], summary: built.words, groups: groups, lines: lines, group: key, built: .migration(built),
                          note: "The file holds every device in the list read, whatever group is shown.", base: "mdm migration (\(live.stampWords))")
        case .serviceHealth:
            let days = days ?? Self.defaultQuietDays
            let live = liveServices()
            let built = ServiceHealth(live.list.isNotRead ? [] : live.services, deviceCounts: live.counts, notSent: live.notSent, now: when, days: days, list: live.list)
            let rows = key.map { built.rows(group: $0) } ?? built.rows
            let lines = rows.map { row in
                Line(id: row.id, title: row.service.name,
                     detail: Self.join(["status: \(Self.text(row.service.attributes["status"]).isEmpty ? "not sent" : Self.text(row.service.attributes["status"]))",
                                        "last connected: \(row.lastConnected.words)", "devices: \(Self.count(row.deviceCount))",
                                        { if case .cannotJudge(let why) = row.health { return why } else { return "" } }()]), group: row.group)
            }
            let groups = ServiceHealth.fixedGroups.map { GroupCount(key: $0, count: built.rows(group: $0).count) }
            return finish(report, filters: filters + ["Quiet after \(built.days) days"], source: [live.words(now: when, dates: dates)], summary: built.words, groups: groups, lines: lines,
                          group: key, built: .serviceHealth(built), note: "The file holds every service in the list read, whatever group is shown.",
                          base: "service health, quiet after \(built.days) days (\(live.stampWords))")
        }
    }

    /// The common tail: the filter's rows capped for the screen, with the cap said.
    private func finish(_ report: Report, filters: [String], source: [String], summary: [String], groups: [GroupCount], lines all: [Line], group: String?,
                        built: Built, note: String, base: String) -> Output {
        let shown = Array(all.prefix(displayLimit))
        let cap = all.count > shown.count
            ? "Showing \(shown.count.formatted()) of \(all.count.formatted()): the rest are in the CSV export." + (report == .coverage ? " The file holds the expiring coverages only." : "")
            : nil
        return Output(report: report, title: report.title, filters: filters, source: source, problems: [], judgesNothing: nil, summary: summary, groups: groups,
                      lines: shown, matching: all.count, capNote: cap, estimateNote: report == .outOfWarranty ? WarrantyReport.assumption : nil,
                      exportNote: note, fileBase: base, built: built)
    }

    // MARK: tokens

    /// The tokens as the report takes them, and what's wrong with the rest. The catalog resolves the four it lists; coverage and
    /// fleet age have one number each, held to the report type's bounds. A number out of bounds is a problem, never clamped.
    nonisolated static func resolve(_ report: Report, _ tokens: [String: String]) -> (tokens: [String: String], problems: [String]) {
        if let id = report.catalogID {
            let resolution = ReportCatalog.resolve(id, tokens: tokens)
            var resolved = resolution.tokens, problems = resolution.problems
            if let days = resolved["days"].flatMap(Int.init), !daysRange.contains(days) {
                problems.append("days must be a whole number of days from \(daysRange.lowerBound) to \(daysRange.upperBound)")
                resolved["days"] = nil
            }
            return (resolved, problems)
        }
        let name = report == .coverage ? "days" : "years"
        let range = report == .coverage ? daysRange : yearsRange
        var resolved: [String: String] = [:], problems: [String] = []
        var seen: Set<String> = []
        for (rawName, rawValue) in tokens.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            let key = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == name else {
                problems.append("\(report.title) has no filter named \(rawName)")
                continue
            }
            guard seen.insert(key).inserted else {
                problems.append("\(report.title) filter \(name) is given twice")
                continue
            }
            if let number = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(number) {
                resolved[name] = String(number)
            } else {
                problems.append("\(name) must be a whole number of \(name) from \(range.lowerBound) to \(range.upperBound)")
            }
        }
        return (resolved, problems)
    }

    /// Why a School org can't run a report: a read it needs that Apple School Manager's API doesn't have, in words. Nil when
    /// it can. Nothing is sent. All six reports read the devices and the services, which School has (held to its contract by
    /// `NavigationTests`/`ReportsTests`), so none is refused today; a read added later that School lacks is refused here.
    package nonisolated static func refusal(_ reads: [AppleSection], scope: Scope?) -> String? {
        guard scope == .school, let section = reads.first(where: \.businessOnly) else { return nil }
        return "Apple School Manager's API has no \(section.displayName.lowercased()) to read, so this report can't run for this organization. Nothing was sent."
    }

    // MARK: the sources

    private func source(_ sweep: Sweep) -> SweepSource { sources[sweep] ?? .unavailable(nil) }

    /// Why a sweep's report judges nothing, in words: the history still being read, unreadable, never swept, or the newest attempt
    /// failed with no good copy before it.
    private func unavailable(_ sweep: Sweep, _ source: SweepSource) -> String {
        switch state {
        case .idle, .loading: return "Reading the snapshot history…"
        case .failed(let why): return "The snapshot history couldn't be read: \(why) This report judges nothing."
        case .unusable(let why), .notInScope(let why): return why
        case .forbidden: return "This report judges nothing."
        case .loaded: break
        }
        let name = sweep.title
        let next = "Take one in Activity › Changes › Snapshot now, with \(name) ticked."
        if case .unavailable(let failure?) = source {
            return "\(Self.failureWords(failure, sweep: sweep, dates: dates)). No snapshot has read \(name), so this report judges nothing. Once what that says is dealt with, take one in Activity › Changes › Snapshot now, with \(name) ticked."
        }
        return "No snapshot has read \(name), so this report judges nothing. It isn't zero: nothing was read. \(next)"
    }

    /// "The newest snapshot that read AppleCare coverage (20 Nov 2026) failed with HTTP 500", or "didn't read it (not asked after HTTP 401)",
    /// with the collector's note.
    package nonisolated static func failureWords(_ failure: Failure, sweep: Sweep, dates: DateWords) -> String {
        let how = failure.code.hasPrefix("not asked") || failure.code.hasPrefix("not read") ? "didn't read it (\(failure.code))" : "failed with \(failure.code)"
        return "The newest snapshot that read \(sweep.title) (\(dates.day(takenAt: failure.takenAt))) \(how)" + (failure.note.map { ": \($0)" } ?? "")
    }

    /// "the AppleCare coverage read was cut: HTTP 500 (1 of 6 not read: 1 failed twice (HTTP 500))".
    nonisolated static func cutWords(_ part: SweepPart, sweep: Sweep) -> String {
        "the \(sweep.title) read was cut: \(part.code)" + (part.note.map { " (\($0))" } ?? "")
    }

    /// What a report is given as the list's read: the snapshot's device list and the sweep's own part read, said together, so the
    /// summary line and the CSV's `listRead` column carry both. A device list that wasn't read is that and nothing else.
    nonisolated static func listRead(_ used: Used, sweep: Sweep) -> ListRead {
        var parts: [String] = []
        switch used.deviceList {
        case .notRead: return used.deviceList
        case .partly(let how): parts.append(how)
        case .whole: break
        }
        if let part = used.part {
            parts.append(cutWords(part, sweep: sweep) + (sweep == .appleCare ? "; in a part read a device with no record counts as not read" : ""))
        }
        return parts.isEmpty ? .whole : .partly(parts.joined(separator: "; "))
    }

    /// Where a snapshot's data comes from, in words: the date and the age, a part read, then a newer attempt that read none.
    nonisolated static func sourceWords(_ used: Used, sweep: Sweep, now: Date, unattributed: Int, dates: DateWords) -> [String] {
        var lines = ["From the snapshot of \(dates.day(takenAt: used.takenAt)), \(age(of: used.takenAt, now: now)). Its own device list and its \(sweep.title) read are used together; nothing is read from Apple now."]
        if let part = used.part {
            if used.deviceList.isNotRead {
                lines.append("That snapshot read \(sweep.title) only in part (\(cutWords(part, sweep: sweep))), and its own device list wasn't read, so nothing is judged.")
            } else {
                lines.append("That snapshot read \(sweep.title) only in part: \(cutWords(part, sweep: sweep)). What it read is used; a device it didn't read counts as not read"
                             + (sweep == .appleCare ? ", and so does a device with no record, since a part read can't tell the two apart." : "."))
            }
        }
        if let failure = used.failure {
            let which = used.part == nil ? "this is the last good copy" : "the newest snapshot that read any of it is used, and that read was only in part"
            lines.append("\(failureWords(failure, sweep: sweep, dates: dates)), so \(which), from \(dates.day(takenAt: used.takenAt)).")
        }
        if unattributed > 0 {
            lines.append("\(unattributed) coverage record\(unattributed == 1 ? " has" : "s have") no serial number and can't be matched to a device: counted here and left out of the report.")
        }
        return lines
    }

    private nonisolated static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    package nonisolated static func dayStamp(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "3 days old", "1 day old", "less than a day old"; "of unknown age" for a time that isn't a date.
    nonisolated static func age(of takenAt: String, now: Date) -> String {
        guard let date = ISODate.parse(takenAt)?.date else { return "of unknown age" }
        return age(since: date, now: now)
    }

    nonisolated static func age(since date: Date, now: Date) -> String {
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
        if days < 1 { return "less than a day old" }
        return "\(days.formatted()) day\(days == 1 ? "" : "s") old"
    }

    /// A sweep's items by device id, as the report types take them, and the records with no serial number to attribute them by.
    /// - **A whole copy**: a device of the snapshot's list with no record was read and has none (`.read([])`).
    /// - **A part read** (`used.part`): a device with no record can't be told from one the sweep didn't reach, so it is left out of
    ///   the map, and the reports count it as not read. A later change that has the collector record which devices a sweep didn't read
    ///   can give those devices `.notRead` and the rest `.read([])` here: `notReached` is that seam.
    nonisolated static func coverage(_ used: Used, notReached: Set<String>? = nil) -> (map: [String: DeviceRead<[Resource]>], unattributed: Int) {
        var records: [String: [Resource]] = [:]
        var unattributed = 0
        var order: [String] = []
        for item in used.items {
            guard let serial = item.attributes["serialNumber"]?.string, !serial.isEmpty else {
                unattributed += 1
                continue
            }
            if records[serial] == nil { order.append(serial) }
            records[serial, default: []].append(item)
        }
        var map: [String: DeviceRead<[Resource]>] = [:]
        for device in used.devices {
            if let found = records[device.id] {
                map[device.id] = .read(found)
            } else if let notReached {
                if !notReached.contains(device.id) { map[device.id] = .read([]) }
            } else if used.part == nil {
                map[device.id] = .read([])
            }
        }
        for serial in order where map[serial] == nil { map[serial] = .read(records[serial] ?? []) }
        return (map, unattributed)
    }

    // MARK: the live lists

    /// What a live list says of itself, from the Devices model's own state: when it was read and how old it is; "Not read from Apple yet"
    /// only while nothing was asked or the read is going; a read that stopped says so and why (the list's own words), with the time it
    /// stopped when the model kept it.
    nonisolated static func liveWords(_ what: String, state: LoadState, list: ListRead, readAt: Date?, now: Date, dates: DateWords) -> String {
        switch state {
        case .idle, .loading:
            return "Not read from Apple yet: \(what) is empty or still being read. No snapshot is used."
        case .loaded:
            guard let readAt else { return "Read live from Apple: \(what). No snapshot is used." }
            return "Read live from Apple on \(dates.dayTime(readAt)), \(age(since: readAt, now: now)): \(what). No snapshot is used."
        case .forbidden, .failed, .unusable, .notInScope:
            switch list {
            case .partly(let how):
                let when = readAt.map { " on \(dates.dayTime($0)), \(age(since: $0, now: now))" } ?? ", at a time that isn't kept"
                return "Read live from Apple in part\(when): \(what). The read stopped: \(how). No snapshot is used."
            case .notRead(let why):
                return "Not read from Apple: \(why). No snapshot is used."
            case .whole:
                return "Read live from Apple: \(what). No snapshot is used."
            }
        }
    }

    struct LiveDevices {
        let resources: [Resource]
        let devices: [OrgDevice]
        let list: ListRead
        let state: LoadState
        /// When the list's read finished, or stopped with rows held, from the Devices model; nil otherwise.
        let readAt: Date?
        func words(now: Date, dates: DateWords) -> String {
            ReportsModel.liveWords("the device list the Devices screen holds", state: state, list: list, readAt: readAt, now: now, dates: dates)
        }
        /// The file name's part: the day it was read (UTC), or that it wasn't.
        var stampWords: String { readAt.map { "read live \(ReportsModel.dayStamp($0))" } ?? "not read" }
    }

    /// The device list the Devices model holds, as the reports take it: whole, cut at the page cap or by a failure, or not read.
    func liveDevices() -> LiveDevices {
        let rows = devices.rows.map(\.device)
        let list: ListRead
        switch devices.state {
        case .idle: list = .notRead("the device list hasn't been read yet")
        case .loading: list = .notRead("the device list is still being read")
        case .loaded:
            list = devices.truncated
                ? .partly("showing \(rows.count.formatted()) of \(devices.total.map { $0.formatted() } ?? "more than \(rows.count.formatted())"): the list stopped at the page limit")
                : .whole
        case .forbidden: list = rows.isEmpty ? .notRead("your role can't read devices") : .partly("your role can't read devices; \(rows.count.formatted()) were read before the refusal")
        case .failed(let why): list = rows.isEmpty ? .notRead(why) : .partly("the read failed after \(rows.count.formatted()) devices: \(why)")
        case .unusable(let why), .notInScope(let why): list = .notRead(why)
        }
        var readAt: Date?
        if case .loaded(let date) = devices.state { readAt = date } else if !rows.isEmpty { readAt = devices.devicesStoppedAt }
        return LiveDevices(resources: list.isNotRead ? [] : rows.map(\.resource), devices: rows, list: list, state: devices.state, readAt: readAt)
    }

    struct LiveServices {
        let services: [MDMService]
        let counts: [String: ServiceDeviceCount]
        let notSent: Set<String>
        let list: ListRead
        let state: LoadState
        let readAt: Date?
        func words(now: Date, dates: DateWords) -> String {
            ReportsModel.liveWords("the services list the Services screen holds", state: state, list: list, readAt: readAt, now: now, dates: dates)
        }
        var stampWords: String { readAt.map { "read live \(ReportsModel.dayStamp($0))" } ?? "not read" }
    }

    func liveServices() -> LiveServices {
        let services = devices.services
        let list: ListRead
        switch devices.servicesState {
        case .idle: list = .notRead("the services haven't been read yet")
        case .loading: list = .notRead("the services are still being read")
        case .loaded:
            list = devices.servicesTruncated ? .partly("showing \(services.count.formatted()) services: the list stopped at the page limit") : .whole
        case .forbidden:
            list = services.isEmpty ? .notRead("your role can't read device management services")
                : .partly("your role can't read device management services; \(services.count.formatted()) were read before the refusal")
        case .failed(let why): list = services.isEmpty ? .notRead(why) : .partly("the read failed after \(services.count.formatted()) services: \(why)")
        case .unusable(let why), .notInScope(let why): list = .notRead(why)
        }
        // A count only for a service whose device list was read whole; the rest say "not read" (`ServiceHealth`).
        var counts: [String: ServiceDeviceCount] = [:]
        for (id, count) in devices.deviceCount { counts[id] = .exactly(count) }
        var readAt: Date?
        if case .loaded(let date) = devices.servicesState { readAt = date } else if !services.isEmpty { readAt = devices.servicesStoppedAt }
        return LiveServices(services: services, counts: counts, notSent: devices.servicesAbsent, list: list, state: devices.servicesState, readAt: readAt)
    }

    // MARK: words for rows

    nonisolated static func join(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }

    /// A value as a row shows it: a string as it is, nothing as empty, anything else as JSON text with secrets withheld.
    nonisolated static func text(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "" }
        return SnapshotDiff.shown(value, field: "value")
    }

    nonisolated static func count(_ count: ServiceDeviceCount?) -> String {
        switch count {
        case nil: "not read"
        case .exactly(let n)?: n.formatted()
        case .atLeast(let n)?: "at least \(n.formatted())"
        case .unreadable(let raw)?: "not a whole number (\(raw))"
        }
    }

    nonisolated static func deadline(_ deadline: MigrationReport.Deadline) -> String {
        switch deadline {
        case .none: "no deadline"
        case .unreadable(let raw): "deadline not readable: \(raw)"
        case .left(let days): "\(days) day\(days == 1 ? "" : "s") to the deadline"
        case .overdue(let days): "deadline passed \(days) day\(days == 1 ? "" : "s") ago"
        }
    }

    nonisolated static func warrantyState(_ row: WarrantyReport.Row) -> String {
        switch row.kind {
        case .active(let ends): return "active coverage" + (ends.map { ", ends \($0.isoformat)" } ?? "") + (row.unreadableEnds.isEmpty ? "" : ", an end date not readable: " + row.unreadableEnds.joined(separator: "; "))
        case .noActiveCoverage(let statuses): return "records read, none ACTIVE (\(statuses.joined(separator: ", ")))"
        case .statusUnknown(let statuses): return "a coverage status this version doesn't know (\(statuses.joined(separator: ", "))): not counted as out of warranty"
        case .noRecord: return "no coverage record (may mean no AppleCare, not expired)"
        case .notRead(let why): return "not read: \(why)"
        }
    }

    /// An estimate is always called one.
    nonisolated static func warrantyEstimate(_ row: WarrantyReport.Row, dates: DateWords) -> String {
        switch row.estimate {
        case .notMade: ""
        case .noOrderDate: "estimate not possible: no order date"
        case .unreadableOrderDate(let raw): "estimate not possible: order date not readable (\(raw))"
        case .pastAssumedLimit(let end): "estimate: past the assumed one year (ended \(dates.day(end)))"
        case .withinAssumedLimit(let end): "estimate: within the assumed one year (until \(dates.day(end)))"
        }
    }

    // MARK: the CSV

    /// Why Export is off; nil when there is a report to write. The view builds the report once per redraw and asks these about
    /// that one `Output`: building it again for each would cost a build each.
    public func exportBlocked(for output: Output) -> String? { output.canExport ? nil : output.judgesNothing ?? output.exportNote }

    /// The file's name, naming the client only when the app shows clients (the clients rule).
    public func exportFileName(for output: Output) -> String {
        ScreenWords.filename((output.fileBase ?? output.report.rawValue) + ".csv", client: orgs.exportClient)
    }

    /// What the Save panel says the file holds.
    public func exportWords(for output: Output) -> String {
        let who = orgs.active.map { "\"\($0.name.isEmpty ? $0.id : $0.name)\"" } ?? "this organization"
        let client = orgs.exportClient.map { " It is client \"\($0)\"'s data only." } ?? ""
        let from = output.source.first.map { " \($0)" } ?? ""
        let read = output.summary.first.map { " \($0)" } ?? ""
        return "Saves the \(output.title) report for \(who).\(from)\(read) \(output.exportNote) The first column after the id says how much of the list was read. "
            + "Serial numbers and the attributes each report names are in it. A value under a secret's name is withheld. No key or token is in it." + client
    }

    /// The same for the report on screen (a build each: for tests and callers that have no `Output`).
    public var exportBlocked: String? { exportBlocked(for: current) }
    public var exportFileName: String { exportFileName(for: current) }
    public var exportWords: String { exportWords(for: current) }

    /// The report on screen as CSV, through its own `ExportPolicy` columns; empty text when nothing was judged.
    public func csv() -> String { csv(of: current) }

    public func csv(of output: Output) -> String {
        switch output.built {
        case nil: ""
        case .coverage(let report)?: ExportHistory.coverageExpiring(report)
        case .fleetAge(let report)?: ExportHistory.refreshCandidates(report)
        case .activationLock(let report)?: CSV.text(report.csvItems, columns: ExportPolicy.activationLockReport)
        case .migration(let report)?: CSV.text(report.csvItems, columns: ExportPolicy.migrationReport)
        case .serviceHealth(let report)?: CSV.text(report.csvItems, columns: ExportPolicy.serviceHealth)
        case .outOfWarranty(let report)?: CSV.text(report.csvItems, columns: ExportPolicy.warrantyReport)
        }
    }
}
