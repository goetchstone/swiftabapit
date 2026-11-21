import AppleModels
import Foundation
import JSONAPI
import MosyleModels

/// "Needs attention" (plan §8.0): work that should have been done and hasn't, found by deterministic rules over what was
/// read. **A model never decides what's overdue**: it can be unavailable, and a wrong "nothing's overdue" fails silently
/// (invariant 8). So a rule is **judged**, and recorded, only over a complete read. Over an input read in part (cut at a page
/// limit, some devices not read) it is **partial** (the operator, 2026-11-20: "Show what it found, marked partial"): what it
/// found in what was read is shown, how much wasn't read is said, and nothing is recorded. A comparison is partial only when
/// the list it searches for an absence was read whole: an absence from a list read in part can't be judged. A rule whose
/// input wasn't read at all, or belongs to an org this client doesn't have, is **skipped, in words**. None of the three ever
/// reads as "nothing's overdue" when it isn't known.
///
/// Each rule reuses the report that already answers it, so one rule shows the same on two screens: the reconciliation's
/// buckets (`Reconciliation`), the coverage window (`CoverageReport`), stale check-ins (`StaleDevices`), the Activation Lock
/// groups (`ActivationLockReport`), the quiet services (`ServiceHealth`, which is `QuietServices`) and the migration days
/// (`MigrationReport`). Each rule's edge is its report's: a check-in `checkInDays` whole days old is stale, a service exactly
/// `quietServiceDays` silent isn't quiet, AppleCare ending exactly `appleCareExpiringDays` from now is expiring, and a
/// migration whose report reads `migrationDeadlineDays` days left is near.
///
/// Pure: no store, no UI, no read of its own. The caller hands every list with how much of it was read, and records a rule's
/// findings in `SnapshotStore.seen` only when `RuleResult.subjectsToRecord` isn't nil (the store's caller contract). A
/// finding's subject is a serial number or an id, never a name; what it says is computed here every time and never stored.
/// No abapit counterpart, so no golden: `NeedsAttentionTests` holds it.
public struct NeedsAttention: Sendable {
    /// Each rule's id is what the attention store keeps (`rule`): an identifier, at most `ruleLimit` characters. A rule judged
    /// from two providers is two rules (`missingFromAppleMDM`, `missingFromMosyle`), so a half that is skipped never ages the
    /// findings of the half that was judged.
    public enum Rule: String, Sendable, CaseIterable {
        /// Assigned in Apple to an `APPLE_MDM` service, and not in Apple MDM's device list.
        case missingFromAppleMDM = "missing_from_apple_mdm"
        /// Assigned in Apple to the service set as the client's Mosyle org, and not in Mosyle's device list.
        case missingFromMosyle = "missing_from_mosyle"
        /// In Apple MDM's device list, and not in Apple's device list.
        case appleMDMNotInApple = "apple_mdm_not_in_apple"
        /// In Mosyle's device list, and not in Apple's device list: the reconciliation's Mosyle-only bucket.
        case mosyleNotInApple = "mosyle_not_in_apple"
        /// ACTIVE AppleCare coverage ending within the threshold: `CoverageReport.expiring`.
        case appleCareExpiring = "applecare_expiring"
        /// No check-in to Mosyle for the threshold or more: `StaleDevices`.
        case mosyleCheckIn = "mosyle_check_in"
        /// No check-in to Apple MDM for the threshold or more, from each device's details: `StaleDevices`' rule.
        case appleMDMCheckIn = "apple_mdm_check_in"
        /// A Mac in Apple MDM whose details say FileVault is off.
        case fileVaultOff = "filevault_off"
        /// A Mac in Apple MDM whose details say the firewall is off.
        case firewallOff = "firewall_off"
        /// Activation Lock held by a person's Apple Account: `ActivationLockReport`'s `blocksRelease`.
        case activationLock = "activation_lock_user"
        /// A service in `ServiceHealth`'s `quiet` group, which is `QuietServices`.
        case quietService = "quiet_service"
        /// A migration not done (a known status other than SUCCESS) whose deadline is within the threshold or past.
        case migrationDeadline = "migration_deadline"

        /// The rules that read Mosyle: skipped, and said, for a client with no Mosyle org.
        public var needsMosyle: Bool { [.missingFromMosyle, .mosyleNotInApple, .mosyleCheckIn].contains(self) }

        public func title(_ thresholds: Thresholds) -> String {
            switch self {
            case .missingFromAppleMDM: "Assigned in Apple to Apple MDM, but not enrolled in Apple MDM"
            case .missingFromMosyle: "Assigned in Apple to your Mosyle org's service, but not in Mosyle"
            case .appleMDMNotInApple: "Enrolled in Apple MDM, but not in Apple's device list"
            case .mosyleNotInApple: "In Mosyle, but not in Apple's device list"
            case .appleCareExpiring:
                "AppleCare coverage ending within \(Self.days(min(thresholds.appleCareExpiringDays, CoverageReport.maximumDays)))"
            case .mosyleCheckIn: "No check-in to Mosyle for \(Self.days(thresholds.checkInDays)) or more"
            case .appleMDMCheckIn: "No check-in to Apple MDM for \(Self.days(thresholds.checkInDays)) or more"
            case .fileVaultOff: "FileVault off (Macs in Apple MDM)"
            case .firewallOff: "Firewall off (Macs in Apple MDM)"
            case .activationLock: "Activation Lock held by a person's Apple Account: blocks redeploy and release"
            case .quietService: "Device management service silent for more than \(Self.days(thresholds.quietServiceDays))"
            case .migrationDeadline: "MDM migration not done, its deadline within \(Self.days(thresholds.migrationDeadlineDays)) or past"
            }
        }

        static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
    }

    /// When a rule raises a finding, in days. Fed from the local settings (`LocalSettings.Thresholds`, whose defaults, 30, 90,
    /// 14 and 30, the operator kept on 2026-11-20: "Keep these defaults (Recommended)"); Reports doesn't import Orgs, so the
    /// defaults live there alone and every value is passed.
    public struct Thresholds: Sendable, Equatable {
        /// A device whose last check-in is this many whole days old or more (`StaleDevices`).
        public let checkInDays: Int
        /// ACTIVE AppleCare coverage ending between now and this many days ahead, both ends included (`CoverageReport`,
        /// which holds it to `CoverageReport.maximumDays`).
        public let appleCareExpiringDays: Int
        /// A migration whose days left, as the migration report counts them, are at most this, or that is past its deadline.
        public let migrationDeadlineDays: Int
        /// A service silent for more than this (`QuietServices`).
        public let quietServiceDays: Int

        public init(checkInDays: Int, appleCareExpiringDays: Int, migrationDeadlineDays: Int, quietServiceDays: Int) {
            self.checkInDays = checkInDays
            self.appleCareExpiringDays = appleCareExpiringDays
            self.migrationDeadlineDays = migrationDeadlineDays
            self.quietServiceDays = quietServiceDays
        }
    }

    /// One list as the rules get it: its items, how much of it was read, the attributes its source sent for no item (a
    /// services read with default fields, a Mosyle column refused), and when the snapshot it came from was taken.
    public struct Listed<Element: Sendable>: Sendable {
        public var items: [Element]
        public var read: ListRead
        /// Attribute names the source sent for no item: a rule that needs one can't judge, and says so.
        public var notSent: Set<String>
        /// When the snapshot these items come from was taken; nil when they were read live.
        public var takenAt: Date?

        public init(_ items: [Element], read: ListRead, notSent: Set<String> = [], takenAt: Date? = nil) {
            self.items = items
            self.read = read
            self.notSent = notSent
            self.takenAt = takenAt
        }

        public static func notRead(_ why: String) -> Listed { Listed([], read: .notRead(why)) }
    }

    /// One read per device (a sweep: AppleCare, Activation Lock, Apple MDM details), keyed by the id the list gives the
    /// device. A device with no entry wasn't reached, which is not read.
    public struct Swept<Value: Sendable>: Sendable {
        public var reads: [String: DeviceRead<Value>]
        /// When the snapshot the sweep comes from was taken; nil when it was read live.
        public var takenAt: Date?

        public init(_ reads: [String: DeviceRead<Value>] = [:], takenAt: Date? = nil) {
            self.reads = reads
            self.takenAt = takenAt
        }
    }

    /// The client's Mosyle Business org, if it has one.
    public enum MosyleInput: Sendable {
        /// The client has no Mosyle org: every rule that reads Mosyle is skipped and says so.
        case noMosyleOrg
        /// The Mosyle org's device list (the adapter's resources: `lastCheckIn` is `date_last_beat`).
        case devices(Listed<Resource>)
    }

    /// Everything the rules read, for one client. `init()` is "nothing read": every rule is skipped and says why, so a list
    /// the caller forgets is said, never judged as empty.
    public struct Input: Sendable {
        /// Apple's device list (`orgDevices`).
        public var devices: Listed<OrgDevice>
        /// The device management services (`mdmServers`), with the attributes Apple sent for none (`Page.absent`).
        public var services: Listed<MDMService>
        /// Each service's device ids (`mdmServers/{id}/relationships/devices`, the device ids Apple sets to serials), by
        /// service id. A service with no entry wasn't read.
        public var serviceDevices: [String: Listed<String>]
        /// Apple MDM's devices (`mdmDevices`; Apple Business only: a School org passes `.notRead` with its reason).
        public var appleMDM: Listed<MDMDevice>
        /// Each Apple MDM device's details by its `mdmDevices` id: `.read(nil)` is Apple's answer that it has none (a 404).
        public var appleMDMDetails: Swept<MDMDeviceDetail?>
        /// Each device's AppleCare coverage, by device id.
        public var coverage: Swept<[AppleCareCoverage]>
        /// Each device's Activation Lock status, by device id.
        public var activationLock: Swept<ActivationLockStatus>
        public var mosyle: MosyleInput
        /// Which Apple service is the client's Mosyle org: a per-client setting (**a proposal, for the operator to confirm**).
        /// Nil, the default, skips `missingFromMosyle` and says the setting isn't set.
        public var mosyleServiceID: String?

        public init() {
            let why = "not read yet"
            devices = .notRead(why)
            services = .notRead(why)
            serviceDevices = [:]
            appleMDM = .notRead(why)
            appleMDMDetails = Swept()
            coverage = Swept()
            activationLock = Swept()
            mosyle = .devices(.notRead(why))
            mosyleServiceID = nil
        }
    }

    /// Whether the rule was judged over a complete read, over part of one, or not at all.
    public enum Verdict: Sendable, Equatable {
        /// Over a complete read: the findings are every one there is, and the store is told.
        case judged
        /// Over what was read, which wasn't all of it (the operator, 2026-11-20: "Show what it found, marked partial"): the
        /// findings are real, the text says how much wasn't read, and nothing is recorded, so dismissals and "first seen" stay
        /// accurate. Only a per-device rule, or a comparison whose searched side was read whole, is ever partial.
        case partial(String)
        /// Nothing could be judged: the text says why.
        case skipped(String)
    }

    public struct Finding: Sendable, Equatable {
        public let rule: Rule
        /// A serial number or an id, never a name: what the attention store keeps.
        public let subject: String
        /// What the rule found, in a short line of words.
        public let reason: String
        /// When the oldest snapshot among the rule's inputs was taken; nil when every input was read live.
        public let takenAt: Date?
        /// Found over a partial read: shown, never recorded.
        public let isPartial: Bool

        /// Whether the attention store can keep it (`isIdentifier`). One it can't is still shown, and said.
        public var isTrackable: Bool { NeedsAttention.isIdentifier(subject, limit: NeedsAttention.subjectLimit) }
    }

    public struct RuleResult: Sendable {
        public let rule: Rule
        public let title: String
        public let verdict: Verdict
        /// Empty when skipped: a skipped rule found nothing because it judged nothing. Over a partial read, what that part held.
        public let findings: [Finding]
        /// What the rule read whole but couldn't judge for some items (a Mac that sent no FileVault value), in words.
        public let notes: [String]
        /// When the oldest snapshot among the rule's inputs was taken; nil when every input was read live, or when skipped.
        public let takenAt: Date?

        /// The subjects to hand `SnapshotStore.seen`: every trackable finding's, possibly none, when the rule was judged over a
        /// complete read; nil when it was partial or skipped, so the store isn't told anything (not even `[]`, which would age
        /// every finding of the rule, nor a partial run's findings, which would make "first seen" and dismissals wrong).
        public var subjectsToRecord: [String]? {
            guard verdict == .judged else { return nil }
            return findings.filter(\.isTrackable).map(\.subject)
        }

        /// Judged over a complete read (not partial, not skipped).
        public var isJudged: Bool { verdict == .judged }

        /// The rule's line, then what it couldn't judge. A skipped rule says only why: never a count. A partial one says it was
        /// read in part, how much wasn't, and that what it found isn't kept.
        public var words: [String] {
            switch verdict {
            case .skipped(let why): return ["\(title): skipped. \(why)."]
            case .partial(let why):
                let found = findings.isEmpty ? "none found in what was read." : "\(findings.count) found in what was read."
                return ["\(title): read in part, \(found)", "\(why).",
                        "What was read in part isn't kept for later (dismiss, snooze, first seen) until a complete read."] + notes
            case .judged:
                var lines = ["\(title): " + (findings.isEmpty ? "none found." : "\(findings.count) found.")]
                lines += notes
                let untracked = findings.filter { !$0.isTrackable }.count
                if untracked > 0 {
                    lines.append("\(untracked) found can't be kept for later (dismiss, snooze, first seen): the serial or id isn't one this app can store.")
                }
                return lines
            }
        }

        static func skipped(_ rule: Rule, _ thresholds: Thresholds, _ why: String) -> RuleResult {
            RuleResult(rule: rule, title: rule.title(thresholds), verdict: .skipped(why), findings: [], notes: [], takenAt: nil)
        }
    }

    public let thresholds: Thresholds
    /// One per rule, in `Rule.allCases` order.
    public let results: [RuleResult]

    public init(_ input: Input, thresholds: Thresholds, now: Date) {
        self.thresholds = thresholds
        results = Rule.allCases.map { rule in
            // Each rule that reads Mosyle unwraps it first, and a client with no Mosyle org skips it there, said.
            let judge = Judge(input: input, thresholds: thresholds, now: now, rule: rule)
            return switch rule {
            case .missingFromAppleMDM: judge.missingFromAppleMDM()
            case .missingFromMosyle: judge.missingFromMosyle()
            case .appleMDMNotInApple: judge.appleMDMNotInApple()
            case .mosyleNotInApple: judge.mosyleNotInApple()
            case .appleCareExpiring: judge.appleCareExpiring()
            case .mosyleCheckIn: judge.mosyleCheckIn()
            case .appleMDMCheckIn: judge.appleMDMCheckIn()
            case .fileVaultOff: judge.securitySetting("isFileVaultEnabled", "FileVault", off: "FileVault is off.")
            case .firewallOff: judge.securitySetting("isFirewallEnabled", "firewall", off: "The firewall is off.")
            case .activationLock: judge.activationLock()
            case .quietService: judge.quietService()
            case .migrationDeadline: judge.migrationDeadline()
            }
        }
    }

    public func result(_ rule: Rule) -> RuleResult { results.first { $0.rule == rule }! }

    /// Every rule's findings, in rule order.
    public var findings: [Finding] { results.flatMap(\.findings) }

    public var words: [String] { results.flatMap(\.words) }

    // MARK: identifiers

    /// The longest rule id and subject the attention store keeps.
    public static let ruleLimit = 64
    public static let subjectLimit = 128

    /// Whether `text` can be a rule or a subject in the attention store: 1 to `limit` characters and at most four bytes a
    /// character in all (`limit * 4` UTF-8 bytes, so one character carrying thousands of combining marks can't pass as one),
    /// none whitespace, a control, a format character (a direction override, a joiner, a zero-width space), a default-ignorable
    /// code point (a grapheme joiner, a Hangul filler, a variation selector: each shows as nothing), a noncharacter (U+FFFF), a
    /// quote, a slash or a backslash. A serial number, a UUID or a numeric id passes; a name with a space ("Jane Example's MacBook Pro")
    /// doesn't. A one-word name would pass: callers pass identifiers, and this is the backstop. One rule for the store
    /// (`SnapshotStore.seen` refuses what fails it) and for the findings it is given. Compared by bytes elsewhere:
    /// precomposed and decomposed "e with acute" both pass, and are two subjects.
    public static func isIdentifier(_ text: String, limit: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= limit * 4, text.count <= limit else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !(scalar.properties.isWhitespace || scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
              || scalar.properties.isDefaultIgnorableCodePoint || scalar.properties.isNoncharacterCodePoint
              || "\"'`/\\".unicodeScalars.contains(scalar))
        }
    }
}

// MARK: the rules

/// One rule's judgment over one input. An input that wasn't read at all skips the rule. An input read in part makes a
/// per-device rule partial (its findings are real, never recorded); a comparison is partial only when the side it searches
/// for an absence was read whole, because an absence from a list read in part can't be judged, so it skips then, and says
/// which list. A rule that could judge **no item** because every item it read was unknown (no value, no family this version
/// knows, no serial, Apple's "no details") is skipped too, never "none found": a zero judged over nothing isn't a zero.
private struct Judge {
    let input: NeedsAttention.Input
    let thresholds: NeedsAttention.Thresholds
    let now: Date
    let rule: NeedsAttention.Rule

    typealias Result = NeedsAttention.RuleResult

    func skipped(_ why: String) -> Result { .skipped(rule, thresholds, why) }

    /// Judged: `found` as (subject, reason) in the report's order, the first of a subject kept (the store keys by subject).
    /// `partial` holds, in words, every part of the input that wasn't read: any makes the verdict partial.
    func judged(_ found: [(subject: String, reason: String)], notes: [String] = [], takenAt: [Date?], partial: [String] = []) -> Result {
        let age = takenAt.compactMap { $0 }.min()
        var seen: Set<[UInt8]> = []
        let findings = found.filter { seen.insert(Array($0.subject.utf8)).inserted }
            .map { NeedsAttention.Finding(rule: rule, subject: $0.subject, reason: $0.reason, takenAt: age, isPartial: !partial.isEmpty) }
        let verdict: NeedsAttention.Verdict = partial.isEmpty ? .judged : .partial(partial.joined(separator: "; "))
        return Result(rule: rule, title: rule.title(thresholds), verdict: verdict, findings: findings, notes: notes, takenAt: age)
    }

    /// Why nothing can be judged from a list, in words: nil unless it wasn't read at all.
    func unread<E>(_ name: String, _ listed: NeedsAttention.Listed<E>) -> String? {
        if case .notRead(let why) = listed.read { return "\(name) wasn't read (\(why))" }
        return nil
    }

    /// How much of a list wasn't read, in words: nil unless it was read in part.
    func part<E>(_ name: String, _ listed: NeedsAttention.Listed<E>) -> String? {
        if case .partly(let how) = listed.read { return "\(name) was read in part (\(how))" }
        return nil
    }

    /// Why an absence from a list can't be judged: it wasn't read, or was read in part. Nil when it was read whole.
    func searched<E>(_ name: String, _ listed: NeedsAttention.Listed<E>) -> String? {
        unread(name, listed) ?? part(name, listed).map { "\($0), so a device can't be called absent from it" }
    }

    /// How much of a sweep wasn't read: `whys` holds one reason per item it didn't read. Nil when it read every item.
    func sweepGap(_ name: String, whys: [String], of total: Int, _ one: String, _ many: String) -> String? {
        guard !whys.isEmpty else { return nil }
        var reasons: [String] = []
        for why in whys where !reasons.contains(where: { $0.utf8.elementsEqual(why.utf8) }) { reasons.append(why) }
        let shown = reasons.prefix(3).joined(separator: "; ") + (reasons.count > 3 ? "; and more" : "")
        return "\(name) wasn't read for \(whys.count) of \(Self.count(total, one, many)) (\(shown))"
    }

    /// "1 device", "3 devices".
    static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    /// "1 device has", "3 devices have": `count` with its verb.
    static func count(_ n: Int, _ one: String, _ many: String, _ verbOne: String, _ verbMany: String) -> String {
        "\(count(n, one, many)) \(n == 1 ? verbOne : verbMany)"
    }

    /// Each device's read by id, by bytes (`CoverageReport` reads its map the same way): the first of two equivalent keys.
    static func byBytes<V>(_ reads: [String: DeviceRead<V>]) -> [[UInt8]: DeviceRead<V>] {
        Dictionary(reads.map { (Array($0.key.utf8), $0.value) }) { first, _ in first }
    }

    static let unreached = "the sweep didn't reach it"

    static func days(_ count: Int) -> String { NeedsAttention.Rule.days(count) }

    /// The device's serial, as Apple MDM lists it; its `mdmDevices` id when it has none.
    static func serial(_ device: MDMDevice) -> String { hasSerial(device) ? device.serialNumber! : device.id }

    /// Whether Apple MDM listed the device with a serial number the reconciliation can join on.
    static func hasSerial(_ device: MDMDevice) -> Bool { device.serialNumber.map { !Reconciliation.key($0).isEmpty } ?? false }

    /// Whether Mosyle listed the device by its serial number. The adapter's id falls back to the UDID, then to nothing
    /// (`MosyleAdapter.device`), and the reconciliation joins on that id: a device listed by UDID, or with no id, can't be
    /// matched with Apple's serials.
    static func hasSerial(mosyle device: Resource) -> Bool {
        Python.truthy(device.attributes["serialNumber"]) && !Reconciliation.key(device.id).isEmpty
    }

    /// Why a comparison can't be made with Mosyle's devices, in words: Mosyle sent no serial numbers.
    static func mosyleSerials(_ mosyle: NeedsAttention.Listed<Resource>) -> String? {
        mosyle.notSent.contains("serialNumber")
            ? "Mosyle didn't send its devices' serial numbers (the column wasn't read), so they can't be matched with Apple's" : nil
    }

    /// Why a comparison can't be made with Apple MDM's devices, in words: Apple sent no serial numbers.
    static func appleMDMSerials(_ mdm: NeedsAttention.Listed<MDMDevice>) -> String? {
        mdm.notSent.contains("serialNumber")
            ? "Apple didn't send Apple MDM's devices' serial numbers, so they can't be matched with Apple's device list" : nil
    }

    // 1. Assigned in Apple to an MDM service, and missing from that MDM. The MDM's list is the one searched.

    func missingFromAppleMDM() -> Result {
        let services = input.services
        if let why = unread("The device management services list", services) { return skipped(why) }
        if services.notSent.contains("serverType") {
            return skipped("Apple didn't send the services' type (read with default fields), so Apple MDM's service can't be told apart")
        }
        var partial = [part("The device management services list", services)].compactMap { $0 }
        let untyped = services.items.filter { $0.type == nil }
        if !untyped.isEmpty, untyped.count == services.items.count {
            return skipped("No service came with a type Apple sent as text (\(Self.count(services.items.count, "service", "services"))), so Apple MDM's service can't be told apart")
        }
        if !untyped.isEmpty {
            partial.append("\(untyped.count) of \(Self.count(services.items.count, "service", "services")) came with no type Apple sent as text, so their devices weren't looked for")
        }
        let apple = services.items.filter { $0.type == .known(.appleMDM) }
        // No Apple MDM service among those read: nothing read can be assigned to it.
        guard !apple.isEmpty else { return judged([], takenAt: [services.takenAt], partial: partial) }
        var assigned: [Resource] = [], serviceOf: [[UInt8]: String] = [:], ages = [services.takenAt], lists = 0
        for service in apple {
            guard let listed = input.serviceDevices[service.id] else { partial.append("The device list of \(service.name) wasn't read"); continue }
            if let why = unread("The device list of \(service.name)", listed) { partial.append(why); continue }
            if let why = part("The device list of \(service.name)", listed) { partial.append(why) }
            lists += 1
            ages.append(listed.takenAt)
            for id in listed.items {
                assigned.append(Resource(type: OrgDevice.resourceType, id: id))
                serviceOf[Reconciliation.key(id)] = serviceOf[Reconciliation.key(id)] ?? service.name
            }
        }
        // No Apple MDM service's devices read: nothing to look for.
        guard lists > 0 else { return skipped(partial.joined(separator: "; ")) }
        let mdm = input.appleMDM
        if let why = searched("Apple MDM's device list", mdm) { return skipped(why) }
        if let why = Self.appleMDMSerials(mdm) { return skipped(why) }
        let unnamed = mdm.items.filter { !Self.hasSerial($0) }
        if !unnamed.isEmpty {
            return skipped("\(unnamed.count) of Apple MDM's devices came with no serial number, so a device assigned to Apple MDM can't be called missing from it: it could be one of them")
        }
        ages.append(mdm.takenAt)
        let report = Reconciliation(apple: assigned, mosyle: mdm.items.map { Resource(type: MDMDevice.resourceType, id: Self.serial($0)) })
        return judged(report.appleOnly.map { row in
            (row.serial, "Assigned in Apple to \(serviceOf[Reconciliation.key(row.serial)] ?? "Apple MDM"); Apple MDM doesn't list it.")
        }, takenAt: ages, partial: partial)
    }

    func missingFromMosyle() -> Result {
        guard case .devices(let mosyle) = input.mosyle else { return skipped("This client has no Mosyle Business org") }
        guard let serviceID = input.mosyleServiceID else {
            return skipped("Which Apple service is your Mosyle org isn't set, so a device assigned to it can't be looked for in Mosyle")
        }
        if case .whole = input.services.read, !input.services.items.contains(where: { $0.id.utf8.elementsEqual(serviceID.utf8) }) {
            return skipped("The service set as your Mosyle org isn't among the services Apple listed")
        }
        let name = input.services.items.first { $0.id.utf8.elementsEqual(serviceID.utf8) }?.name ?? "the service set as your Mosyle org"
        guard let listed = input.serviceDevices[serviceID] else { return skipped("The device list of \(name) wasn't read") }
        if let why = unread("The device list of \(name)", listed) { return skipped(why) }
        if let why = searched("Mosyle's device list", mosyle) { return skipped(why) }
        if let why = Self.mosyleSerials(mosyle) { return skipped(why) }
        // As the Apple MDM half: a Mosyle device listed by its UDID, or by nothing, could be the assigned one.
        let unnamed = mosyle.items.filter { !Self.hasSerial(mosyle: $0) }
        if !unnamed.isEmpty {
            return skipped("\(unnamed.count) of Mosyle's devices came with no serial number (listed by UDID or by nothing), so a device assigned to \(name) can't be called missing from Mosyle: it could be one of them")
        }
        let report = Reconciliation(apple: listed.items.map { Resource(type: OrgDevice.resourceType, id: $0) }, mosyle: mosyle.items)
        return judged(report.appleOnly.map { ($0.serial, "Assigned in Apple to \(name), your Mosyle org's service; Mosyle doesn't list it.") },
                      takenAt: [listed.takenAt, mosyle.takenAt], partial: [part("The device list of \(name)", listed)].compactMap { $0 })
    }

    // 2. In the MDM, and not in Apple. Apple's device list is the one searched.

    func appleMDMNotInApple() -> Result {
        let mdm = input.appleMDM
        if let why = unread("Apple MDM's device list", mdm) { return skipped(why) }
        if let why = searched("Apple's device list", input.devices) { return skipped(why) }
        if let why = Self.appleMDMSerials(mdm) { return skipped(why) }
        let named = mdm.items.filter(Self.hasSerial)
        if named.isEmpty, !mdm.items.isEmpty {
            return skipped("None of Apple MDM's \(Self.count(mdm.items.count, "device", "devices")) came with a serial number, so none could be compared with Apple's device list")
        }
        let notes = named.count == mdm.items.count ? []
            : ["\(mdm.items.count - named.count) of Apple MDM's devices came with no serial number: not compared with Apple's device list."]
        let report = Reconciliation(apple: input.devices.items.map(\.resource),
                                    mosyle: named.map { Resource(type: MDMDevice.resourceType, id: Self.serial($0)) })
        return judged(report.mosyleOnly.map { ($0.serial, "Enrolled in Apple MDM; Apple's device list doesn't have it.") }, notes: notes,
                      takenAt: [input.devices.takenAt, mdm.takenAt], partial: [part("Apple MDM's device list", mdm)].compactMap { $0 })
    }

    func mosyleNotInApple() -> Result {
        guard case .devices(let mosyle) = input.mosyle else { return skipped("This client has no Mosyle Business org") }
        if let why = unread("Mosyle's device list", mosyle) { return skipped(why) }
        if let why = searched("Apple's device list", input.devices) { return skipped(why) }
        if let why = Self.mosyleSerials(mosyle) { return skipped(why) }
        // A device Mosyle lists by its UDID, or by nothing, can't be matched with Apple's serials: noted, not compared, as
        // Apple MDM's devices with no serial are.
        let named = mosyle.items.filter { Self.hasSerial(mosyle: $0) }
        if named.isEmpty, !mosyle.items.isEmpty {
            return skipped("None of Mosyle's \(Self.count(mosyle.items.count, "device", "devices")) came with a serial number, so none could be compared with Apple's device list")
        }
        let notes = named.count == mosyle.items.count ? []
            : ["\(mosyle.items.count - named.count) of Mosyle's devices came with no serial number (listed by UDID or by nothing): not compared with Apple's device list."]
        let report = Reconciliation(apple: input.devices.items.map(\.resource), mosyle: named)
        return judged(report.mosyleOnly.map { ($0.serial, "In Mosyle; Apple's device list doesn't have it.") }, notes: notes,
                      takenAt: [input.devices.takenAt, mosyle.takenAt], partial: [part("Mosyle's device list", mosyle)].compactMap { $0 })
    }

    // 3. AppleCare expiring.

    func appleCareExpiring() -> Result {
        let devices = input.devices
        if let why = unread("Apple's device list", devices) { return skipped(why) }
        let coverage = input.coverage.reads.mapValues { read -> DeviceRead<[Resource]> in
            switch read {
            case .read(let records): .read(records.map(\.resource))
            case .notRead(let why): .notRead(why)
            }
        }
        let report = CoverageReport(devices: devices.items.map(\.resource), coverage: coverage, days: thresholds.appleCareExpiringDays,
                                    now: now, list: devices.read)
        let reads = Self.byBytes(input.coverage.reads)
        let whys = report.notRead.map { device -> String in
            if case .notRead(let why)? = reads[Array(device.id.utf8)] { return why }
            return Self.unreached
        }
        let sweep = sweepGap("AppleCare coverage", whys: whys, of: devices.items.count, "device", "devices")
        if let sweep, whys.count == devices.items.count { return skipped(sweep) }
        // A device read whose ACTIVE coverage ends on a date this app can't read, and that has nothing expiring, is unknown.
        let expiring = Set(report.expiring.map { Array($0.device.utf8) })
        let unknown = Set(report.unreadableEndDevices.map { Array($0.utf8) }).subtracting(expiring)
        let readDevices = Set(devices.items.map { Array($0.id.utf8) }).subtracting(report.notRead.map { Array($0.id.utf8) })
        if !unknown.isEmpty, readDevices.subtracting(unknown).isEmpty {
            return skipped("Every device's ACTIVE coverage read ends on a date this app can't read (\(Self.count(unknown.count, "device", "devices"))), so none could be judged")
        }
        var notes: [String] = []
        if !report.unreadableEnd.isEmpty {
            notes.append("\(Self.count(report.unreadableEnd.count, "ACTIVE coverage", "ACTIVE coverages", "has", "have")) an end date this app can't read: covered, but not judged.")
        }
        if thresholds.appleCareExpiringDays > CoverageReport.maximumDays {
            notes.append("The threshold, \(Self.days(thresholds.appleCareExpiringDays)), is past the most the coverage report looks ahead: \(Self.days(CoverageReport.maximumDays)) were used.")
        }
        return judged(report.expiring.map { ($0.device, $0.daysLeft == 0 ? "AppleCare coverage ends in less than a day." : "AppleCare coverage ends in \(Self.days($0.daysLeft)).") },
                      notes: notes, takenAt: [devices.takenAt, input.coverage.takenAt],
                      partial: [part("Apple's device list", devices), sweep].compactMap { $0 })
    }

    // 4. No check-in for N days.

    func mosyleCheckIn() -> Result {
        guard case .devices(let mosyle) = input.mosyle else { return skipped("This client has no Mosyle Business org") }
        if let why = unread("Mosyle's device list", mosyle) { return skipped(why) }
        if mosyle.notSent.contains("lastCheckIn") {
            return skipped("Mosyle didn't send when its devices last checked in (the column wasn't read)")
        }
        let report = StaleDevices(mosyle.items, days: thresholds.checkInDays, now: now)
        return judged(report.rows.map { row in
            if let days = row.daysStale { return (row.serial, "Last checked in to Mosyle \(Self.days(days)) ago.") }
            switch row.lastCheckIn {
            case .null, .string(""): return (row.serial, "Never checked in to Mosyle.")
            case let value: return (row.serial, "Mosyle's last check-in isn't a date this app reads: \(shownJSON(value)).")
            }
        }, takenAt: [mosyle.takenAt], partial: [part("Mosyle's device list", mosyle)].compactMap { $0 })
    }

    func appleMDMCheckIn() -> Result {
        let mdm = input.appleMDM
        if let why = unread("Apple MDM's device list", mdm) { return skipped(why) }
        let reads = Self.byBytes(input.appleMDMDetails.reads)
        var stamped: [Resource] = [], none = 0, whys: [String] = []
        for device in mdm.items {
            switch reads[Array(device.id.utf8)] {
            case nil: whys.append(Self.unreached)
            case .notRead(let why)?: whys.append(why)
            case .read(nil)?: none += 1
            case .read(let detail?)?:
                switch detail.attributes["lastCheckInDateTime"] {
                case nil, .null?: none += 1
                // `StaleDevices` reads `lastCheckIn`: the rule is the Mosyle one, over Apple's stamp.
                case let value?: stamped.append(Resource(type: MDMDeviceDetail.resourceType, id: Self.serial(device), attributes: ["lastCheckIn": value]))
                }
            }
        }
        let sweep = sweepGap("Apple MDM's device detail", whys: whys, of: mdm.items.count, "device", "devices")
        if let sweep, whys.count == mdm.items.count { return skipped(sweep) }
        if stamped.isEmpty, none > 0 {
            return skipped("None of the \(Self.count(none, "Apple MDM device", "Apple MDM devices")) read has a last check-in in its details (Apple sent none, or no details), so none could be judged")
        }
        let report = StaleDevices(stamped, days: thresholds.checkInDays, now: now)
        let notes = none == 0 ? [] : ["\(none) of Apple MDM's devices \(none == 1 ? "has" : "have") no last check-in in \(none == 1 ? "its" : "their") details: unknown, not judged."]
        return judged(report.rows.map { row in
            row.daysStale.map { (row.serial, "Last checked in to Apple MDM \(Self.days($0)) ago.") }
                ?? (row.serial, "Apple MDM's last check-in isn't a date this app reads: \(shownJSON(row.lastCheckIn)).")
        }, notes: notes, takenAt: [mdm.takenAt, input.appleMDMDetails.takenAt],
           partial: [part("Apple MDM's device list", mdm), sweep].compactMap { $0 })
    }

    // 5. FileVault or the firewall off: Macs only, from Apple MDM's details. A value that wasn't sent is unknown, never off.

    /// `key` is the details' attribute, `name` the setting as a noun ("FileVault", "firewall"), `off` the finding's words.
    func securitySetting(_ key: String, _ name: String, off sentence: String) -> Result {
        let mdm = input.appleMDM
        if let why = unread("Apple MDM's device list", mdm) { return skipped(why) }
        if mdm.notSent.contains("productFamily") {
            return skipped("Apple didn't send Apple MDM's devices' product family, so a Mac can't be told apart")
        }
        let macs = mdm.items.filter { $0.productFamily == .known(.mac) }
        let unplaced = mdm.items.filter { $0.productFamily?.known == nil }.count
        let reads = Self.byBytes(input.appleMDMDetails.reads)
        var off: [(String, String)] = [], judgedMacs = 0, unknown = 0, whys: [String] = []
        for mac in macs {
            switch reads[Array(mac.id.utf8)] {
            case nil: whys.append(Self.unreached)
            case .notRead(let why)?: whys.append(why)
            case .read(nil)?: unknown += 1
            case .read(let detail?)?:
                switch detail.attributes.bool(key) {
                case false?: judgedMacs += 1; off.append((Self.serial(mac), sentence))
                case true?: judgedMacs += 1
                case nil: unknown += 1
                }
            }
        }
        let sweep = sweepGap("Apple MDM's device detail", whys: whys, of: macs.count, "Mac", "Macs")
        if let sweep, whys.count == macs.count { return skipped(sweep) }
        if judgedMacs == 0, unknown + unplaced > 0 {
            var why: [String] = []
            if unknown > 0 { why.append("\(Self.count(unknown, "Mac has", "Macs have")) no \(name) value in the details read") }
            if unplaced > 0 { why.append("\(unplaced) of Apple MDM's devices came with no product family this version knows, so a Mac can't be told apart") }
            return skipped("No Mac could be judged: " + why.joined(separator: "; "))
        }
        var notes: [String] = []
        if unknown > 0 {
            notes.append("\(Self.count(unknown, "Mac has", "Macs have")) no \(name) value in Apple MDM's details (none sent, or not a yes or no): unknown, not counted as off.")
        }
        if unplaced > 0 { notes.append("\(unplaced) of Apple MDM's devices came with no product family this version knows: not judged (only Macs are).") }
        if case .devices = input.mosyle { notes.append("Mosyle's devices aren't judged: this app reads no \(name) value from Mosyle.") }
        return judged(off, notes: notes, takenAt: [mdm.takenAt, input.appleMDMDetails.takenAt],
                      partial: [part("Apple MDM's device list", mdm), sweep].compactMap { $0 })
    }

    // 6. Activation Lock blocking a redeploy.

    func activationLock() -> Result {
        let devices = input.devices
        if let why = unread("Apple's device list", devices) { return skipped(why) }
        let report = ActivationLockReport(devices.items, reads: input.activationLock.reads, list: devices.read)
        let whys = report.rows.compactMap { row -> String? in if case .notRead(let why) = row.kind { why } else { nil } }
        let sweep = sweepGap("Activation Lock status", whys: whys, of: devices.items.count, "device", "devices")
        if let sweep, whys.count == devices.items.count { return skipped(sweep) }
        var unplaced = 0, placed = 0
        for row in report.rows {
            switch row.kind {
            case .otherLock, .unclear: unplaced += 1
            case .userLock, .mdmLock, .unlocked: placed += 1
            case .notRead: break
            }
        }
        if placed == 0, unplaced > 0 {
            return skipped("Every Activation Lock status read is unclear or a lock type this version can't place (\(Self.count(unplaced, "device", "devices"))), so none could be judged")
        }
        let notes = unplaced == 0 ? []
            : ["\(Self.count(unplaced, "device is", "devices are")) locked by a type this version can't place, or sent no readable isLocked: can't say whether \(unplaced == 1 ? "it blocks" : "they block") release."]
        return judged(report.rows.filter(\.blocksRelease).map { ($0.device.id, ActivationLockReport.title("lock:USER") + ".") },
                      notes: notes, takenAt: [devices.takenAt, input.activationLock.takenAt],
                      partial: [part("Apple's device list", devices), sweep].compactMap { $0 })
    }

    // 7. A quiet service.

    func quietService() -> Result {
        let services = input.services
        if let why = unread("The device management services list", services) { return skipped(why) }
        if services.notSent.contains("lastConnectedDateTime") {
            return skipped("Apple didn't send when the services last connected (read with default fields), so a quiet service can't be judged")
        }
        let report = ServiceHealth(services.items, notSent: services.notSent, now: now, days: thresholds.quietServiceDays, list: services.read)
        let notes = services.notSent.contains("status")
            ? ["Apple didn't send the services' status, so a deleted service can't be told apart and may be listed."] : []
        return judged(report.rows(group: "quiet").map { row in
            let when = switch row.lastConnected {
            case .at(_, let days): "last connected \(Self.days(days)) ago"
            case .never: "never connected"
            case .unreadable(let raw): "last connected at a date this app can't read: \(raw)"
            case .notSent, .inFuture: row.lastConnected.words
            }
            return (row.service.id, "\(row.service.name): \(when).")
        }, notes: notes, takenAt: [services.takenAt], partial: [part("The device management services list", services)].compactMap { $0 })
    }

    // 8. A migration deadline near.

    func migrationDeadline() -> Result {
        let devices = input.devices
        if let why = unread("Apple's device list", devices) { return skipped(why) }
        let report = MigrationReport(devices.items, now: now, list: devices.read)
        let limit = thresholds.migrationDeadlineDays
        var found: [(String, String)] = [], unknownStatus = 0, unreadable = 0
        for row in report.rows {
            let near: Bool
            switch row.deadline {
            case .left(let days): near = days <= limit
            case .overdue: near = true
            case .none: near = false
            case .unreadable:
                if row.status != .known(.success) { unreadable += 1 }
                continue
            }
            guard near else { continue }
            guard case .known(let status)? = row.status else { unknownStatus += 1; continue }
            guard status != .success else { continue }
            let when = switch row.deadline {
            case .overdue(let days): "\(Self.days(days)) past its deadline"
            case .left(0): "its deadline in less than a day"
            case .left(let days): "its deadline in \(Self.days(days))"
            case .none, .unreadable: ""
            }
            found.append((row.device.id, "Migration \(status.rawValue), \(when)."))
        }
        if report.rows.count == unknownStatus + unreadable, unknownStatus + unreadable > 0 {
            return skipped("Every device's migration has a status this version doesn't know near or past its deadline, or a deadline this app can't read (\(Self.count(unknownStatus + unreadable, "device", "devices"))), so none could be judged")
        }
        var notes: [String] = []
        if unknownStatus > 0 {
            notes.append("\(Self.count(unknownStatus, "device", "devices")) with a deadline within \(Self.days(limit)) or past \(unknownStatus == 1 ? "has" : "have") no migration status this version knows: not judged.")
        }
        if unreadable > 0 { notes.append("\(Self.count(unreadable, "device has", "devices have")) a migration deadline this app can't read: not judged.") }
        return judged(found, notes: notes, takenAt: [devices.takenAt], partial: [part("Apple's device list", devices)].compactMap { $0 })
    }
}
