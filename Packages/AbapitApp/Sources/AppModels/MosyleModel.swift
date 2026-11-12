import Foundation
import JSONAPI
import Mosyle
import MosyleModels
import Observation
import Reports

/// Mosyle Business (plan Phase 7; Appendix B: Mosyle's devices, people, device groups with members and compliance, the admin
/// log, and abapit's Mosyle reports): the Mosyle org in view (`OrgsModel.mosyleOrg`: the active one, or the one the active
/// Apple org is paired with). Each list has its own state and is read when its tab is first shown; the devices are read
/// first, since the device groups' members, the OS versions, the stale devices, the reconciliation and Device 360 all read
/// them. An Apple org with no Mosyle org paired says Mosyle isn't in scope, in every list, never an empty table. Each read
/// has the model's token, as every screen model's does: an org switch, a new pair or a Refresh drops what the old one read,
/// and a superseded read writes nothing (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Observable
public final class MosyleModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case devices, users, userGroups = "user-groups", deviceGroups = "device-groups", attributes, adminLog = "admin-log"
        case osVersions = "os-versions", stale

        public var id: Self { self }

        public var title: String {
            switch self {
            case .devices: "Devices"
            case .users: "Users"
            case .userGroups: "User groups"
            case .deviceGroups: "Device groups"
            case .attributes: "Custom attributes"
            case .adminLog: "Admin log"
            case .osVersions: "OS versions"
            case .stale: "Not checking in"
            }
        }

        /// The read the tab shows: the two reports are views over the devices.
        public var list: List {
            switch self {
            case .devices, .osVersions, .stale: .devices
            case .users: .users
            case .userGroups: .userGroups
            case .deviceGroups: .deviceGroups
            case .attributes: .attributes
            case .adminLog: .adminLog
            }
        }

        /// abapit's export names where it had one (`mosyle-os-breakdown`, `mosyle-stale`).
        public var filename: String {
            switch self {
            case .osVersions: "mosyle-os-breakdown.csv"
            case .stale: "mosyle-stale.csv"
            default: "mosyle-\(rawValue).csv"
            }
        }

        public var prompt: String {
            switch self {
            case .devices, .stale: "Serial, name, model or user"
            case .users: "Name, email or identifier"
            case .userGroups, .deviceGroups: "Group name"
            case .attributes: "Attribute name or value"
            case .adminLog: "Admin or action"
            case .osVersions: "OS version"
            }
        }

        var noun: String {
            switch self {
            case .devices, .stale: "devices"
            case .users: "users"
            case .userGroups: "user groups"
            case .deviceGroups: "device groups"
            case .attributes: "custom attributes"
            case .adminLog: "admin-log entries"
            case .osVersions: "OS versions"
            }
        }
    }

    /// Mosyle's reads, each with its own state.
    public enum List: Sendable, CaseIterable {
        case devices, users, userGroups, deviceGroups, attributes, adminLog
    }

    /// One read as far as it has gone.
    public struct Listing<Row: Sendable>: Sendable {
        public fileprivate(set) var rows: [Row] = []
        public fileprivate(set) var state: LoadState = .idle
        /// The page cap stopped the list with more to come.
        public fileprivate(set) var truncated = false
        /// Fields Mosyle sent that no column reads (a record no source shows), by name: said, never shown.
        public fileprivate(set) var unread: [String] = []
        /// Mosyle's own count beside the list, when it sent one.
        public fileprivate(set) var total: Int?

        public var partialCount: Int? {
            switch state {
            case .failed, .forbidden: rows.isEmpty ? nil : rows.count
            default: nil
            }
        }

        /// The sentence that takes the table's place when no such list can be read here; nil to show the table.
        public var unavailable: String? {
            switch state {
            case .notInScope(let why), .unusable(let why): why
            default: nil
            }
        }

        /// Whether every row was read: loaded, and not cut.
        public var isWhole: Bool { if case .loaded = state { !truncated } else { false } }
    }

    /// A Mosyle device as the table shows it, its words made once.
    public struct DeviceRow: Identifiable, Sendable {
        public let device: Resource
        public let id: String
        public let serial: String
        public let name: String
        public let model: String
        public let family: String
        public let os: String
        public let user: String
        public let lastCheckIn: Date?
        public let udid: String

        /// Never checked in sorts first, as the stalest.
        public var lastCheckInSort: Date { lastCheckIn ?? .distantPast }

        init(_ device: Resource, index: Int) {
            self.device = device
            let a = device.attributes
            id = device.id.isEmpty ? "row \(index)" : device.id
            serial = MosyleModel.text(a["serialNumber"], or: device.id)
            name = MosyleModel.text(a["deviceName"])
            model = MosyleModel.text(a["deviceModel"])
            family = MosyleModel.text(a["productFamily"])
            os = MosyleModel.text(a["osVersion"])
            user = MosyleModel.text(a["currentUser"], or: MosyleModel.text(a["userEmail"]))
            lastCheckIn = ISODate.parse(a["lastCheckIn"]?.string)?.date
            udid = a["deviceUdid"]?.string ?? ""
        }
    }

    /// A user, or a user or device group: a name, an identifier, and what kind or how many.
    public struct PersonRow: Identifiable, Sendable {
        public let item: Resource
        public let id: String
        public let name: String
        public let detail: String
        public let identifier: String
        public let kind: String

        init(_ item: Resource, index: Int, group: Bool) {
            self.item = item
            let a = item.attributes
            id = item.id.isEmpty ? "row \(index)" : item.id
            name = MosyleModel.text(a["name"])
            identifier = MosyleModel.text(a["identifier"])
            detail = group ? MosyleModel.text(a["memberCount"]) : MosyleModel.text(a["email"])
            kind = group ? MosyleModel.platform(a["os"]) : MosyleModel.text(a["userType"])
        }
    }

    /// A custom device attribute or an admin-log entry: what the guessed fields read, each a dash when absent.
    public struct RecordRow: Identifiable, Sendable {
        public let item: Resource
        public let id: String
        /// The attribute's name, or the entry's action.
        public let title: String
        /// The attribute's value, or the admin who acted.
        public let detail: String
        /// The attribute's platform, or the entry's address.
        public let extra: String
        /// The attribute's source, or the entry's date as Mosyle wrote it.
        public let note: String
        /// The entry's date, read; nil for an attribute.
        public let when: Date?

        public var whenSort: Date { when ?? .distantPast }

        init(attribute item: Resource, index: Int) {
            self.item = item
            let a = item.attributes
            id = item.id.isEmpty ? "row \(index)" : item.id
            title = MosyleModel.text(a["name"])
            detail = MosyleModel.text(a["value"])
            extra = MosyleModel.platform(a["os"])
            note = MosyleModel.text(a["source"])
            when = nil
        }

        init(log item: Resource, index: Int) {
            self.item = item
            let a = item.attributes
            id = "entry \(index)"
            title = MosyleModel.text(a["action"])
            detail = MosyleModel.text(a["admin"])
            extra = MosyleModel.text(a["ip"])
            note = MosyleModel.text(a["when"])
            when = ISODate.parse(a["when"]?.string)?.date
        }
    }

    public var tab: Tab = .devices {
        didSet { if tab != oldValue { show(tab.list) } }
    }
    public var search = ""
    public var deviceOrder = [KeyPathComparator(\DeviceRow.serial)]
    public var personOrder = [KeyPathComparator(\PersonRow.name)]
    public var recordOrder = [KeyPathComparator(\RecordRow.title)]
    /// The stale report's threshold, in days (abapit's default 30, from 1 to 365).
    public var staleDays = 30
    /// How far back the admin log reads, in days (1 to 365); a change reads it again.
    public var adminDays = 30 {
        didSet { if adminDays != oldValue, adminLog.state != .idle { start(.adminLog) } }
    }

    public private(set) var devices = Listing<DeviceRow>()
    public private(set) var users = Listing<PersonRow>()
    public private(set) var userGroups = Listing<PersonRow>()
    public private(set) var deviceGroups = Listing<PersonRow>()
    public private(set) var attributes = Listing<RecordRow>()
    public private(set) var adminLog = Listing<RecordRow>()
    /// Set when Mosyle refused a device column this app asks for, and it asked again without: said beside the devices.
    public private(set) var columnFallback: MosyleColumnFallback?

    public var selectedDevice: String?
    public var selectedGroup: String? {
        didSet { if selectedGroup != oldValue { members.show(selectedGroup, filter: memberFilter) } }
    }
    /// The device group's members, all of them or only the compliant or the non-compliant ones.
    public var memberFilter: MosyleRead.Compliance? {
        didSet { if memberFilter != oldValue { members.show(selectedGroup, filter: memberFilter) } }
    }
    public let members: Members

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [List: Task<Void, Never>] = [:]
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    /// List reads that have returned, superseded ones included: what tests wait on. `package`: the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        members = Members(orgs: orgs)
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    // MARK: loading

    /// Reads the devices and the tab on screen unless this org's are already here; `force` (Refresh, ⌘R) cancels what is
    /// running and reads them again, the selected group's members too.
    public func load(force: Bool = false) {
        guard force || loadedGeneration != orgs.generation || devices.state == .idle else { return }
        reset()
        loadedGeneration = orgs.generation
        show(.devices)
        show(tab.list)
        members.show(selectedGroup, filter: memberFilter)
    }

    /// Reads the devices unless they are read or being read, for the screens that count them (the reconciliation, Device 360).
    public func loadDevices(force: Bool = false) {
        if force || loadedGeneration != orgs.generation {
            load(force: true)
        } else {
            show(.devices)
        }
    }

    /// Reads `list` if nothing has asked for it since the last reset.
    private func show(_ list: List) {
        guard loadedGeneration == orgs.generation, state(of: list) == .idle else { return }
        start(list)
    }

    private func state(of list: List) -> LoadState {
        switch list {
        case .devices: devices.state
        case .users: users.state
        case .userGroups: userGroups.state
        case .deviceGroups: deviceGroups.state
        case .attributes: attributes.state
        case .adminLog: adminLog.state
        }
    }

    /// Reads `list` from the start: what it read before is dropped first, so a read for another range (the admin log's days)
    /// never shows the last range's rows under its banner, nor counts them as its partial read (the review of step 3).
    private func start(_ list: List) {
        tasks[list]?.cancel()
        clear(list)
        let token = token
        guard let client = orgs.mosyleClient else {
            let (why, notInScope) = orgs.mosyleUnavailable ?? ("Mosyle Business can't be read.", false)
            set(list, state: notInScope ? .notInScope(why) : .unusable(why))
            return
        }
        set(list, state: .loading(count: 0))
        let days = adminDays
        tasks[list] = Task { [weak self] in
            defer { self?.readsFinished += 1 }
            do {
                switch list {
                case .devices:
                    for try await page in client.devices() {
                        guard let self, self.current(token) else { return }
                        var listing = self.devices
                        listing.rows += page.items.enumerated().map { DeviceRow($0.element, index: listing.rows.count + $0.offset) }
                        listing.truncated = page.truncated
                        listing.state = .loading(count: listing.rows.count)
                        self.devices = listing
                    }
                    let fallback = await client.columnFallback
                    guard let self, self.current(token) else { return }
                    self.columnFallback = fallback
                    self.devices.state = .loaded(at: Date())
                case .users:
                    let page = try await client.users()
                    self?.finish(\.users, token, page.items.enumerated().map { PersonRow($0.element, index: $0.offset, group: false) }, truncated: page.truncated)
                case .userGroups:
                    let page = try await client.userGroups()
                    self?.finish(\.userGroups, token, page.items.enumerated().map { PersonRow($0.element, index: $0.offset, group: true) }, truncated: page.truncated)
                case .deviceGroups:
                    let page = try await client.deviceGroups()
                    self?.finish(\.deviceGroups, token, page.items.enumerated().map { PersonRow($0.element, index: $0.offset, group: true) }, truncated: page.truncated)
                case .attributes:
                    let records = try await client.customAttributes()
                    self?.finish(\.attributes, token, records.items.enumerated().map { RecordRow(attribute: $0.element, index: $0.offset) },
                                 unread: records.unread)
                case .adminLog:
                    let records = try await client.adminLogs(days: days)
                    self?.finish(\.adminLog, token, records.items.enumerated().map { RecordRow(log: $0.element, index: $0.offset) },
                                 unread: records.unread, total: records.total)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.current(token) else { return }
                self.set(list, state: Self.state(after: error))
            }
        }
    }

    private func finish<Row>(_ list: ReferenceWritableKeyPath<MosyleModel, Listing<Row>>, _ token: Int, _ rows: [Row], truncated: Bool = false,
                             unread: [String] = [], total: Int? = nil) {
        guard current(token) else { return }
        var listing = Listing<Row>()
        (listing.rows, listing.truncated, listing.unread, listing.total, listing.state) = (rows, truncated, unread, total, .loaded(at: Date()))
        self[keyPath: list] = listing
    }

    private func clear(_ list: List) {
        switch list {
        case .devices: devices = Listing()
        case .users: users = Listing()
        case .userGroups: userGroups = Listing()
        case .deviceGroups: deviceGroups = Listing()
        case .attributes: attributes = Listing()
        case .adminLog: adminLog = Listing()
        }
    }

    private func set(_ list: List, state: LoadState) {
        switch list {
        case .devices: devices.state = state
        case .users: users.state = state
        case .userGroups: userGroups.state = state
        case .deviceGroups: deviceGroups.state = state
        case .attributes: attributes.state = state
        case .adminLog: adminLog.state = state
        }
    }

    /// A Mosyle read's error as a list says it: every one in Mosyle's words (a 403 included: Mosyle has no permissions
    /// probe, and its refusal may be the token's IP restriction rather than a role).
    static func state(after error: any Error) -> LoadState { .failed(OrgsModel.message(error)) }

    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func orgChanged() {
        let wasShowing = devices.state != .idle
        reset()
        loadedGeneration = -1
        (selectedDevice, selectedGroup) = (nil, nil)
        if wasShowing { load() }
    }

    private func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        token += 1
        (devices, users, userGroups, deviceGroups) = (Listing(), Listing(), Listing(), Listing())
        (attributes, adminLog) = (Listing(), Listing())
        columnFallback = nil
        members.show(nil, filter: nil)
    }

    // MARK: what the tables show

    public var shownDevices: [DeviceRow] {
        let query = Self.query(search)
        let rows = query.isEmpty ? devices.rows : devices.rows.filter { row in
            [row.serial, row.name, row.model, row.user].contains { $0.localizedStandardContains(query) }
        }
        return rows.sorted(using: deviceOrder)
    }

    public func shown(_ list: Listing<PersonRow>) -> [PersonRow] {
        let query = Self.query(search)
        let rows = query.isEmpty ? list.rows : list.rows.filter { row in
            [row.name, row.detail, row.identifier].contains { $0.localizedStandardContains(query) }
        }
        return rows.sorted(using: personOrder)
    }

    public func shown(_ list: Listing<RecordRow>) -> [RecordRow] {
        let query = Self.query(search)
        let rows = query.isEmpty ? list.rows : list.rows.filter { row in
            [row.title, row.detail].contains { $0.localizedStandardContains(query) }
        }
        return rows.sorted(using: recordOrder)
    }

    /// The devices' OS versions (abapit's `mosyle_os_breakdown`), only over a device list read whole: a count of part of
    /// the fleet would read as the fleet's (invariant 8). Nil until then; `reportNote` says why.
    public var osBreakdown: OSBreakdown? { devices.isWhole ? OSBreakdown(devices.rows.map(\.device)) : nil }

    public var shownVersions: [OSBreakdown.Row] {
        let query = Self.query(search)
        let rows = osBreakdown?.rows ?? []
        return query.isEmpty ? rows : rows.filter { $0.version.localizedStandardContains(query) }
    }

    /// The devices that haven't checked in for `staleDays` days, or never have (abapit's `mosyle_stale_devices`), only over
    /// a device list read whole, as `osBreakdown`.
    public func stale(now: Date = Date()) -> StaleDevices? {
        devices.isWhole ? StaleDevices(devices.rows.map(\.device), days: min(max(staleDays, 1), 365), now: now) : nil
    }

    public func shownStale(now: Date = Date()) -> [StaleDevices.Row] {
        let query = Self.query(search)
        let rows = stale(now: now)?.rows ?? []
        return query.isEmpty ? rows : rows.filter { row in
            [row.serial, Self.text(row.deviceModel), Self.text(row.currentUser)].contains { $0.localizedStandardContains(query) }
        }
    }

    /// Why a report over the devices shows nothing yet, in words; nil when it shows the fleet.
    public var reportNote: String? {
        switch devices.state {
        case .idle, .loading: "Reading Mosyle's devices…"
        case .loaded where devices.truncated:
            "Mosyle's device list stopped at the page limit (\(devices.rows.count.formatted()) devices read), so a report over it would count part of the fleet as the whole."
        case .loaded: nil
        case .failed(let why), .notInScope(let why), .unusable(let why): why
        case .forbidden: "Mosyle refused the device list."
        }
    }

    /// What the tab's list says beside its rows and its banner (which says a cut at the page cap and a partial read): Mosyle's
    /// count above the rows sent, the fields Mosyle sent that nothing shows, the device columns Mosyle refused, why a report
    /// over the devices has nothing yet. Nil when there is nothing to say.
    public func note(_ tab: Tab) -> String? {
        var lines: [String] = []
        func unread(_ names: [String]) {
            if !names.isEmpty {
                lines.append("Mosyle sent fields this version doesn't read, so they aren't shown or exported: \(names.joined(separator: ", ")).")
            }
        }
        switch tab {
        case .devices:
            switch columnFallback {
            case .without(let columns)?: lines.append("Mosyle refused the columns \(columns.joined(separator: ", ")), so they were left out of the request.")
            case .everyColumn?: lines.append("Mosyle refused a requested column, so every column was asked for; only the fields this app keeps are shown.")
            case nil: break
            }
        case .users, .userGroups, .deviceGroups: break
        case .attributes: unread(attributes.unread)
        case .adminLog:
            if let total = adminLog.total, total > adminLog.rows.count {
                lines.append("Mosyle counts \(total.formatted()) entries; it sent \(adminLog.rows.count.formatted()).")
            }
            unread(adminLog.unread)
        case .osVersions, .stale: if let note = reportNote { lines.append(note) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    // MARK: the selection and the inspector

    public var device: DeviceRow? { selectedDevice.flatMap { id in devices.rows.first { $0.id == id } } }
    public var group: PersonRow? { selectedGroup.flatMap { id in deviceGroups.rows.first { $0.id == id } } }

    /// Whether the tab on screen has a selection to inspect: devices and device groups do.
    public var hasSelection: Bool {
        switch tab {
        case .devices: selectedDevice != nil
        case .deviceGroups: selectedGroup != nil
        default: false
        }
    }

    public func clearSelection() {
        switch tab {
        case .devices: selectedDevice = nil
        case .deviceGroups: selectedGroup = nil
        default: break
        }
    }

    /// Why the inspector has nothing to show for the selection; nil when it shows it or nothing is selected.
    public var selectionNote: String? {
        let (selected, found, state, noun): (Bool, Bool, LoadState, String) = switch tab {
        case .deviceGroups: (selectedGroup != nil, group != nil, deviceGroups.state, "device group")
        default: (selectedDevice != nil, device != nil, devices.state, "device")
        }
        guard selected, !found else { return nil }
        switch state {
        case .idle, .loading: return "Reading Mosyle's \(noun)s…"
        case .loaded: return "This \(noun) isn't in the list Mosyle sent."
        default: return "This \(noun) couldn't be read."
        }
    }

    /// A Mosyle device's fields, in the order a person reads them; a dash for what Mosyle didn't send.
    public nonisolated static func fields(of row: DeviceRow) -> [PeopleModel.Field] {
        let a = row.device.attributes
        func field(_ label: String, _ key: String) -> PeopleModel.Field { PeopleModel.Field(label, text(a[key])) }
        return [
            PeopleModel.Field("Serial", row.serial), field("Name", "deviceName"), field("Model", "deviceModel"), field("Family", "productFamily"),
            field("OS version", "osVersion"), PeopleModel.Field("User", row.user), field("Status", "status"),
            PeopleModel.Field("Supervised", flag(a["isSupervised"])), field("Lost mode", "lostModeStatus"),
            field("Enrollment", "enrollmentType"), field("Asset tag", "assetTag"), PeopleModel.Field("Battery", battery(a["batteryLevel"])),
            PeopleModel.Field("Disk, GB", gigabytes(a["totalDiskGB"])), PeopleModel.Field("Free, GB", gigabytes(a["availableDiskGB"])),
            field("IMEI", "imei"),
            field("Wi-Fi MAC", "wifiMacAddress"), field("Bluetooth MAC", "bluetoothMacAddress"), field("UDID", "deviceUdid"),
        ]
    }

    /// The device's Mosyle dates, newest first (abapit's `device_timeline`, Mosyle's half).
    public nonisolated static func timeline(of row: DeviceRow) -> [MergedTimeline.Item] {
        MergedTimeline.items(apple: nil, mosyle: row.device.attributes, audit: nil)
    }

    /// The selected group's members, each the device the device list holds by its UDID, else the UDID itself.
    public var memberRows: [MemberRow] {
        guard case .loaded(let found) = members.panel else { return [] }
        // By bytes, and never by an empty UDID: a device that has none isn't every member that has none (the review of step 3).
        let index = Dictionary(devices.rows.filter { !$0.udid.isEmpty }.map { (Array($0.udid.utf8), $0) }, uniquingKeysWith: { first, _ in first })
        return found.udids.enumerated().map { MemberRow(id: "\($0.offset)", udid: $0.element, device: index[Array($0.element.utf8)]) }
    }

    /// Why some of the group's members show as UDIDs; nil when each is a device read.
    public var memberNote: String? {
        let rows = memberRows, missing = rows.filter { $0.device == nil }.count
        guard missing > 0 else { return nil }
        let which = missing == rows.count && missing > 1 ? "None of them is" : missing == 1 ? "1 member isn't" : "\(missing.formatted()) members aren't"
        switch devices.state {
        case .idle, .loading: return "Reading Mosyle's devices to name the members…"
        case .loaded where devices.truncated: return "\(which) among the devices read before the list stopped at the page limit: shown by UDID."
        case .loaded: return "\(which) in Mosyle's device list: shown by UDID."
        default: return "The device list couldn't be read: members are shown by UDID."
        }
    }

    public struct MemberRow: Identifiable, Sendable {
        public let id: String
        public let udid: String
        public let device: DeviceRow?

        public var name: String { device.map { $0.name == "—" ? $0.serial : $0.name } ?? (udid.isEmpty ? "A member with no UDID" : udid) }
        public var detail: String { device.map { "\($0.serial) · \($0.model)" } ?? "Not among the devices read" }
    }

    /// One device group's members, read when it is chosen (`get_info`), with its own token: a member list for a group no
    /// longer selected never lands.
    @MainActor
    @Observable
    public final class Members {
        public private(set) var panel: Panel<MosyleGroupMembers> = .loading
        public private(set) var group: String?
        private let orgs: OrgsModel
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private var token = 0
        @ObservationIgnored package private(set) var readsFinished = 0

        init(orgs: OrgsModel) { self.orgs = orgs }

        func show(_ group: String?, filter: MosyleRead.Compliance?) {
            task?.cancel()
            token += 1
            self.group = group
            panel = .loading
            guard let group else { return }
            guard let client = orgs.mosyleClient else {
                panel = .failed(orgs.mosyleUnavailable?.why ?? "Mosyle Business can't be read.")
                return
            }
            let token = token
            task = Task { [weak self] in
                defer { self?.readsFinished += 1 }
                let result: Panel<MosyleGroupMembers>
                do {
                    result = .loaded(try await client.deviceGroupMembers(group, compliance: filter))
                } catch is CancellationError {
                    return
                } catch {
                    result = .failed(OrgsModel.message(error))
                }
                guard let self, self.token == token, !Task.isCancelled else { return }
                self.panel = result
            }
        }
    }

    // MARK: export

    public func csv(_ tab: Tab, now: Date = Date()) -> String {
        switch tab {
        case .devices: CSV.text(shownDevices.map { CSV.Item($0.device) }, columns: ExportPolicy.mosyleDevices)
        case .users: CSV.text(shown(users).map { CSV.Item($0.item) }, columns: ExportPolicy.mosyleUsers)
        case .userGroups: CSV.text(shown(userGroups).map { CSV.Item($0.item) }, columns: ExportPolicy.mosyleGroups)
        case .deviceGroups: CSV.text(shown(deviceGroups).map { CSV.Item($0.item) }, columns: ExportPolicy.mosyleGroups)
        case .attributes: CSV.text(shown(attributes).map { CSV.Item($0.item) }, columns: ExportPolicy.mosyleAttributes)
        case .adminLog: CSV.text(shown(adminLog).map { CSV.Item($0.item) }, columns: ExportPolicy.mosyleAdminLogs)
        case .osVersions: OSBreakdown.csv(shownVersions)
        case .stale: StaleDevices.csv(shownStale(now: now))
        }
    }

    /// Why the tab's Export is off; nil when it exports (`ScreenWords.exportBlocked`). A report over a device list that
    /// wasn't read whole has nothing to export.
    public func exportBlocked(_ tab: Tab, now: Date = Date()) -> String? {
        var (state, read, count): (LoadState, Int, Int) = (devices.state, 0, 0)
        switch tab {
        case .devices: (state, read, count) = (devices.state, devices.partialCount ?? 0, shownDevices.count)
        case .users: (state, read, count) = (users.state, users.partialCount ?? 0, shown(users).count)
        case .userGroups: (state, read, count) = (userGroups.state, userGroups.partialCount ?? 0, shown(userGroups).count)
        case .deviceGroups: (state, read, count) = (deviceGroups.state, deviceGroups.partialCount ?? 0, shown(deviceGroups).count)
        case .attributes: (state, read, count) = (attributes.state, attributes.partialCount ?? 0, shown(attributes).count)
        case .adminLog: (state, read, count) = (adminLog.state, adminLog.partialCount ?? 0, shown(adminLog).count)
        case .osVersions, .stale:
            // A report counts devices: a partial read is said of the devices, and a list read but cut says why, not "nothing".
            if !devices.isWhole {
                return ScreenWords.exportBlocked(devices.state, read: devices.partialCount ?? 0, shown: 1, noun: "devices")
                    ?? reportNote ?? ScreenWords.nothingToExport
            }
            (state, read, count) = (devices.state, 0, tab == .osVersions ? shownVersions.count : shownStale(now: now).count)
        }
        return ScreenWords.exportBlocked(state, read: read, shown: count, noun: tab.noun)
    }

    // MARK: words

    /// A value as a cell shows it: a string as sent, a number as its text, a dash for none.
    nonisolated static func text(_ value: JSONValue?, or fallback: String = "—") -> String {
        switch value {
        case .string(let text)? where !text.trimmingCharacters(in: .whitespaces).isEmpty: text
        case .number(let text)?: text
        case .bool(let flag)?: flag ? "Yes" : "No"
        default: fallback
        }
    }

    /// Mosyle's `is_supervised`, sent as `"1"`, `1`, `true` or their opposites (plan §2.3 defect 19).
    nonisolated static func flag(_ value: JSONValue?) -> String {
        switch value {
        case .bool(let flag)?: flag ? "Yes" : "No"
        case .number(let text)?, .string(let text)?:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes": "Yes"
            case "0", "false", "no": "No"
            case "": "—"
            default: text
            }
        default: "—"
        }
    }

    /// Mosyle's numbers come as strings (plan §2.3 defect 19: `"total_disk": "64.0000000000"`, in GB): a number shown as one,
    /// to a tenth; anything else as sent. The CSV keeps Mosyle's text.
    nonisolated static func gigabytes(_ value: JSONValue?) -> String {
        guard let text = value?.string ?? value.flatMap({ if case .number(let n) = $0 { n } else { nil } }),
              let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return text(value) }
        return number.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Mosyle's battery level, a fraction as a string (`"0.81"`): a percentage; anything else as sent.
    nonisolated static func battery(_ value: JSONValue?) -> String {
        guard let text = value?.string ?? value.flatMap({ if case .number(let n) = $0 { n } else { nil } }),
              let number = Double(text.trimmingCharacters(in: .whitespaces)), (0...1).contains(number) else { return text(value) }
        return "\(Int((number * 100).rounded()))%"
    }

    /// Mosyle's platform word in Apple's: `ios` is iOS and iPadOS, `mac` macOS.
    nonisolated static func platform(_ value: JSONValue?) -> String {
        switch value?.string?.lowercased() {
        case "ios": "iOS / iPadOS"
        case "mac", "macos": "macOS"
        case "tvos": "tvOS"
        case "visionos": "visionOS"
        default: text(value)
        }
    }

    nonisolated static func query(_ search: String) -> String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
}
