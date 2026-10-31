import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// One row of the Apple MDM table: an Apple-managed device and what was read of its details, each posture column in
/// words, made when the row is so sorting doesn't re-read attributes.
public struct AppleMDMRow: Identifiable, Sendable {
    /// What was read of the device's `mdmDevices/{id}/details`. Every case but `read` is said in each posture column, so a
    /// device whose details weren't read never shows a blank or an "Off" (invariant 8).
    public enum Details: Sendable {
        /// To be read in its turn, or being read.
        case reading
        case read(MDMDeviceDetail)
        /// Apple answered 404: no details on record (the stub's assumption; check live).
        case none
        /// 403: this role can't read device details.
        case forbidden
        case failed(String)
        /// Not asked: past the first `AppleMDMModel.detailLimit`, the list didn't finish, or the reads stopped at a refusal.
        /// Selecting the row asks.
        case notRead

        /// In each posture cell of a row whose details weren't read, and the CSV's `detailsStatus` (with `status`).
        public var word: String {
            switch self {
            case .reading: "Reading…"
            case .read: "Read"
            case .none: "No details"
            case .forbidden: "Role can't read"
            case .failed: "Failed"
            case .notRead: "Not read"
            }
        }

        /// The CSV's `detailsStatus`: the word, and for a failure why.
        public var status: String { if case .failed(let why) = self { "Failed: \(why)" } else { word } }

        public var detail: MDMDeviceDetail? { if case .read(let detail) = self { detail } else { nil } }
    }

    public let device: MDMDevice
    public let details: Details
    /// The list's serial, else the id (abapit: `attributes.get('serialNumber', d.id)`).
    public let serial: String
    public let name: String
    public let family: String
    public let user: String
    public let os: String
    public let checkIn: String
    /// A device that never checked in, and a row whose details weren't read, sort first.
    public let checkInSort: Date
    public let fileVault: String
    public let firewall: String
    public let lock: String
    public let erase: String
    public let lostMode: String
    public let storage: String
    /// Free bytes; -1 sorts a row with none below every row with some.
    public let storageSort: Int

    public var id: String { device.id }

    public init(_ device: MDMDevice, details: Details) {
        self.device = device
        self.details = details
        serial = device.serialNumber ?? device.id
        name = device.deviceName ?? ""
        family = device.productFamily?.rawValue ?? ""
        user = device.enrolledUserID ?? ""
        guard case .read(let detail) = details else {
            let word = details.word
            (os, checkIn, fileVault, firewall, lock, erase, lostMode, storage) = (word, word, word, word, word, word, word, word)
            (checkInSort, storageSort) = (.distantPast, -1)
            return
        }
        os = Self.words(detail, "osVersion", detail.osVersion, absent: "—") { $0 }
        // As the quiet services read a service's last connection: absent and null read as never (Reports; check live).
        checkIn = Self.words(detail, "lastCheckInDateTime", detail.lastCheckIn, absent: "Never") { $0.date.formatted(date: .abbreviated, time: .shortened) }
        checkInSort = detail.lastCheckIn?.date ?? .distantPast
        fileVault = Self.words(detail, "isFileVaultEnabled", detail.isFileVaultEnabled) { $0 ? "On" : "Off" }
        firewall = Self.words(detail, "isFirewallEnabled", detail.isFirewallEnabled) { $0 ? "On" : "Off" }
        lock = Self.words(detail, "deviceLockStatus", detail.lockStatus) {
            switch $0 {
            case .known(.locked): "Locked"
            case .known(.unlocked): "Unlocked"
            case .unknown(let raw): raw
            }
        }
        erase = Self.words(detail, "deviceEraseStatus", detail.eraseStatus) {
            switch $0 {
            case .known(.erased): "Erased"
            case .known(.notErased): "Not erased"
            case .unknown(let raw): raw
            }
        }
        lostMode = Self.words(detail, "lostModeStatus", detail.lostModeStatus) {
            switch $0 {
            case .known(.enabled): "On"
            case .known(.disabled): "Off"
            case .unknown(let raw): raw
            }
        }
        let free = Self.words(detail, "storageFreeCapacity", detail.storageFree, Self.bytes)
        let total = Self.words(detail, "storageTotalCapacity", detail.storageTotal, Self.bytes)
        storage = free == "Unknown" && total == "Unknown" ? "Unknown" : "\(free) free of \(total)"
        storageSort = detail.storageFree ?? -1
    }

    /// What Apple sent under `key`, in words: `typed` (its typed read) through `say`; `absent` when Apple sent nothing or
    /// null; and anything that didn't read, as Apple sent it (invariant 10: a value this version doesn't know shows raw,
    /// never as a blank or a guess).
    static func words<Value>(_ detail: MDMDeviceDetail, _ key: String, _ typed: Value?, absent: String = "Unknown",
                             _ say: (Value) -> String) -> String {
        guard let value = detail.attributes[key], value != .null else { return absent }
        return typed.map(say) ?? value.jsonText
    }

    /// Storage in the operator's units. Apple documents integers; read as bytes (assumed; check live).
    static func bytes(_ count: Int) -> String { Int64(count).formatted(.byteCount(style: .file)) }

    /// Whether a person's search finds the row: its serial, name, family or enrolled user, ignoring case and accents. A
    /// filter on screen only, never an identity (Find's exact rules are for identifiers).
    func matches(_ query: String) -> Bool {
        [serial, name, family, user].contains { $0.localizedStandardContains(query) }
    }
}

/// Apple MDM (Appendix B: "Devices › Apple MDM", abapit's `/mdm-enrolled`): the devices Apple's own MDM enrolls, then each
/// one's posture from the documented `mdmDevices/{id}/details` (plan §2.3, defect 11), read one device at a time after
/// the list, up to `detailLimit`. Business only: a School org's read says so (`LoadState.notInScope`).
///
/// Each load has a token checked after every await and every page, as `DevicesModel`'s: a load or a detail read that
/// was refreshed, superseded or cancelled writes nothing, and an org switch clears the screen and reads the new org
/// (failure-log 2026-10-16, "the screen models had no tests"). The selection lives here, so the switch clears it too.
@MainActor
@Observable
public final class AppleMDMModel {
    /// The details a load reads after the list, at most, in the list's order. One read each, at the client's pace: Apple's
    /// reported 20 reads a minute after a burst of 10 (`RateLimiter`), which every screen of the org shares, so 50 take
    /// about two minutes on a new account. Past it a row says "Not read" and selecting it reads its own: a sweep of the
    /// whole fleet isn't a page load's (plan §3.6).
    public static let detailLimit = 50

    public private(set) var devices: [MDMDevice] = []
    public private(set) var state: LoadState = .idle
    /// The page cap stopped the list with more to come: "showing N of ≥M".
    public private(set) var truncated = false
    public private(set) var total: Int?

    public var search = ""
    /// Serials sort as text, character by character, as the Devices table's do.
    public var sortOrder: [KeyPathComparator<AppleMDMRow>] = [KeyPathComparator(\AppleMDMRow.serial, comparator: String.StandardComparator.lexical)]
    /// The device the inspector shows. Selecting one whose details weren't read, or failed, reads them.
    public var selection: String? {
        didSet { if selection != oldValue { readSelected() } }
    }

    /// What was read of each device's details, by id. A device with no entry is `reading` within the limit and `notRead`
    /// past it (`details(at:)`).
    private var details: [String: AppleMDMRow.Details] = [:]
    /// The reads stopped at a 403: the role can't read details, so no more were asked.
    private var refused = false

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current load's token: every write checks it, so a superseded load never lands.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    /// Reads that have returned, superseded ones included: each load (its list and its details) and each selection's own
    /// read. What tests wait on instead of the clock. `package`: the app never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    /// Every device with what was read of its details, in the list's order.
    public var rows: [AppleMDMRow] {
        devices.indices.map { AppleMDMRow(devices[$0], details: details(at: $0)) }
    }

    /// The rows the table shows: searched, then sorted.
    public var shown: [AppleMDMRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return (query.isEmpty ? rows : rows.filter { $0.matches(query) }).sorted(using: sortOrder)
    }

    /// The selected device's row, for the inspector.
    public var selected: AppleMDMRow? {
        guard let selection, let index = devices.firstIndex(where: { $0.id == selection }) else { return nil }
        return AppleMDMRow(devices[index], details: details(at: index))
    }

    /// The rows a list read before it failed: shown, and said to be partial.
    public var partialCount: Int? {
        switch state {
        case .failed, .forbidden: devices.isEmpty ? nil : devices.count
        default: nil
        }
    }

    /// What stands in place of the table when it has no rows and the read has ended; the banner above says why in full.
    /// Never an empty table (invariant 8): a School org, a refusal and a failure each have their own words.
    public var emptyTitle: String? {
        guard devices.isEmpty else { return nil }
        switch state {
        case .idle, .loading: return nil
        case .loaded: return "No devices are enrolled in Apple's device management"
        case .forbidden: return "Your role can't read Apple MDM"
        case .failed: return "Apple MDM couldn't be read"
        case .unusable: return "Nothing to read"
        case .notInScope: return "Not in Apple School Manager"
        }
    }

    /// Where the details stand, in words, once the list is read; nil when every device's details were read.
    public var detailsNote: String? {
        guard !devices.isEmpty else { return nil }
        switch state {
        case .loaded: break
        case .failed, .forbidden: return "Details aren't read for a list that didn't finish: select a device to read its own."
        default: return nil
        }
        let all = rows.map(\.details), asked = min(devices.count, Self.detailLimit)
        func count(_ details: some Sequence<AppleMDMRow.Details>, _ test: (AppleMDMRow.Details) -> Bool) -> Int { details.filter(test).count }
        let reading = count(all.prefix(asked)) { if case .reading = $0 { true } else { false } }
        let failed = count(all) { if case .failed = $0 { true } else { false } }
        let none = count(all) { if case .none = $0 { true } else { false } }
        let notRead = count(all) { if case .notRead = $0 { true } else { false } }
        var parts: [String] = []
        if reading > 0 { parts.append("Reading each device's details: \(asked - reading) of \(asked) so far.") }
        if refused {
            parts.append("Your role can't read Apple MDM device details: the first read was refused, so no more were asked.")
        } else if notRead > 0 {
            parts.append("Details are read for the first \(Self.detailLimit) devices only: "
                         + (notRead == 1 ? "1 more says \"Not read\" until it is selected." : "\(notRead) more say \"Not read\" until one is selected."))
        }
        if failed > 0 { parts.append("Details couldn't be read for \(Self.devices(failed)): select \(failed == 1 ? "it" : "one") to try again.") }
        if none > 0 { parts.append("Apple has no details on record for \(Self.devices(none)).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Why Export is off, in words; nil when the rows can be exported. A partial list is never exported as if whole, nor
    /// a list whose details are still being read; a row whose details weren't read says so in its `detailsStatus`.
    public var exportBlocked: String? {
        switch state {
        case .loading: return "The list is still loading."
        case .failed, .forbidden:
            return devices.isEmpty ? nil : "The list is partial: \(devices.count.formatted()) devices were read before the error. Refresh, then export."
        case .loaded:
            return rows.contains { if case .reading = $0.details { true } else { false } } ? "The devices' details are still being read." : nil
        default: return nil
        }
    }

    /// The CSV of what the table shows: the Apple MDM columns (`ExportPolicy.appleMDM`), never an attribute off that list
    /// (invariant 11), and each row's `detailsStatus`.
    public func csv() -> String {
        CSV.text(shown.map { CSV.Item($0.device, details: $0.details.detail, detailsStatus: $0.details.status) }, columns: ExportPolicy.appleMDM)
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R) and cancels a load still
    /// running, its detail reads included.
    public func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || state == .idle else { return }
        reset()
        loadedGeneration = generation
        guard orgs.active != nil else {
            state = .unusable("No organization yet: add an Apple Business API account in Settings.")
            return
        }
        guard let client = orgs.appleClient else {
            state = .unusable("This organization can't be used: \(orgs.unusableReason ?? "it has no Apple API account.")")
            return
        }
        let token = token
        state = .loading(count: 0)
        tasks = [Task { [weak self] in await self?.read(client, token: token) }]
    }

    // MARK: loading

    /// The org changed: nothing of the old one stays on screen, selected or in a CSV, and if anything was showing, the
    /// new org is read at once.
    private func orgChanged() {
        let wasShowing = state != .idle
        reset()
        selection = nil
        state = .idle
        loadedGeneration = -1
        if wasShowing { load() }
    }

    /// Cancels the running load and every detail read, retires its token, and drops what it read.
    private func reset() {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        devices = []
        details = [:]
        truncated = false
        total = nil
        refused = false
    }

    /// Whether the load holding `token` may still write: not superseded, not cancelled. Checked after every await and
    /// every page, because a cancelled `AsyncThrowingStream` loop ends without throwing (Phase 1b review H2).
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    /// The device at `index`'s details: what was read, else `reading` within the limit (its turn will come) and `notRead`
    /// past it.
    private func details(at index: Int) -> AppleMDMRow.Details {
        details[devices[index].id] ?? (index < Self.detailLimit ? .reading : .notRead)
    }

    /// The list, then the first `detailLimit` devices' details, one at a time.
    private func read(_ client: AppleClient, token: Int) async {
        defer { readsFinished += 1 }
        do {
            for try await page in client.mdmDevices() {
                guard current(token) else { return }
                devices += page.items
                truncated = page.truncated
                total = page.total
                state = .loading(count: devices.count)
            }
            guard current(token) else { return }
        } catch {
            guard current(token) else { return }
            state = Self.state(after: error)
            // A list that didn't finish reads no details: its rows say so rather than "Reading…" for ever.
            for device in devices.prefix(Self.detailLimit) { details[device.id] = .notRead }
            return
        }
        state = .loaded(at: Date())
        // A Refresh keeps the selection: if it is past the limit, it reads its own again.
        readSelected()
        let asked = Array(devices.prefix(Self.detailLimit))
        for device in asked where details[device.id] == nil {
            let result = await Self.details(of: device, from: client)
            guard current(token) else { return }
            details[device.id] = result
            if case .forbidden = result {
                // A role that can't read one device's details can't read any: asking the rest would only be refused.
                refused = true
                for rest in asked where details[rest.id] == nil { details[rest.id] = .notRead }
                return
            }
        }
    }

    /// Selecting a device whose details weren't read, or failed, reads them for the inspector, under the load's token.
    private func readSelected() {
        guard let selection, let index = devices.firstIndex(where: { $0.id == selection }), let client = orgs.appleClient else { return }
        switch details(at: index) {
        case .notRead, .failed: break
        default: return
        }
        let device = devices[index], token = token
        details[device.id] = .reading
        tasks.append(Task { [weak self] in
            let result = await Self.details(of: device, from: client)
            guard let self else { return }
            defer { readsFinished += 1 }
            guard current(token) else { return }
            details[device.id] = result
        })
    }

    /// One device's details, or why not, in words. An id that can't go in a path is never sent (the client would call it
    /// "no such item", which isn't so), and details naming another serial aren't shown as this device's (Phase 1b verifier
    /// round 2: a read is checked to be the one asked for).
    private static func details(of device: MDMDevice, from client: AppleClient) async -> AppleMDMRow.Details {
        guard AppleRead.isPathSafe(device.id) else { return .failed("This device's id can't be sent to Apple, so its details weren't asked for.") }
        do {
            let detail = try await client.mdmDeviceDetails(device.id)
            if let theirs = detail.serialNumber, let ours = device.serialNumber, !theirs.utf8.elementsEqual(ours.utf8) {
                return .failed("Apple's details were for another serial number (\(theirs)).")
            }
            return .read(detail)
        } catch AppleAPIError.forbidden {
            return .forbidden
        } catch AppleAPIError.notFound {
            return .none
        } catch {
            return .failed(OrgsModel.message(error))
        }
    }

    /// A read's error as the list's state: `LoadState(after:)`, with this section's own words for a School org (the shared
    /// words name the section by its probe: "no apple mdm enrolled to read").
    private static func state(after error: any Error) -> LoadState {
        let state = LoadState(after: error)
        if case .notInScope = state { return .notInScope("Apple School Manager's API has no Apple MDM devices to read.") }
        return state
    }

    private static func devices(_ count: Int) -> String { count == 1 ? "1 device" : "\(count) devices" }
}
