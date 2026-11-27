import AppleModels
import Assist
import Foundation
import JSONAPI
import Reports

/// One function per question an intent or the in-app Ask can put, each returning code's words (plan §5; the operator, 2026-11-24:
/// Q1 "Six reports + more", Q4 "Yes, bounded", Q5 "Counts aloud, 10 rows", Q6 "Active client, named").
///
/// - **The screens' own data, awaited.** A snapshot report awaits the Reports screen's history read; a live one waits, bounded, on
///   the screens' own live read (`LiveWait`); then the report is built by the screen's one function (`ReportsModel.build`). The
///   Needs-attention summary is the screen's evaluation, so findings are recorded exactly as the screen records them: only when
///   a rule was judged over a whole read. A serial is looked up by the Devices screen's Find over the awaited device list.
/// - **`spoken` says counts, never names**: the data's date and age, how much was read, every group's count with values this
///   version doesn't know named (invariant 10), and an estimate called one. Never a serial, a device, service, user or group name.
///   Rows (at most `rowLimit`: serial, model, state) are for the snippet, with the cap said.
/// - **An error is a fixed phrase per kind** (`Phrase`): a model's or `LiveWait`'s reason can quote Apple's `detail` or Mosyle's
///   own text, so it is never spoken; the app's screen shows it.
/// - **Never more than was read** (invariant 8): a list still being read, refused or failed counts nothing; a list that changed
///   after the wait saw it answers nothing; a field the API didn't send is said, never counted as a value.
/// - **The active client only.** With two or more clients its name leads; with one, nothing says "client" (the clients rule).
@MainActor
public final class Answers {
    /// What an answer says and shows.
    public struct Answer: Equatable, Sendable {
        /// One snippet row: never a name.
        public struct Row: Equatable, Sendable {
            public let serial: String
            public let model: String
            public let state: String

            public init(serial: String, model: String, state: String) {
                (self.serial, self.model, self.state) = (serial, model, state)
            }
        }

        /// The rows' column titles, in a row's order.
        public static let columns = ["Serial number", "Model", "State"]

        /// The question answered: the report's or the summary's title, after the client's name when the app shows clients.
        public let lead: String
        /// What is said aloud: counts, the data's age, how much was read.
        public let spoken: String
        /// At most `Answers.rowLimit`.
        public let rows: [Row]
        /// Said when the rows are cut.
        public let capNote: String?
        /// Out of warranty only: the assumption behind every estimate.
        public let estimateNote: String?
        /// Which devices the rows are, when a report with no group asked shows only some of its devices (the locked ones, those
        /// without active coverage, those past the migration deadline); nil when the rows are every device the group holds.
        public var rowsNote: String? = nil
    }

    /// The most rows an answer shows (the operator, 2026-11-24: Q5, "Counts aloud, 10 rows").
    public static let rowLimit = 10

    /// The fixed phrase said for each way a read or a request can end without an answer, so no error's own words are spoken.
    package enum Phrase {
        package static func refused(_ list: String) -> String { "Your role can't read \(list)." }
        package static func failed(_ list: String) -> String { "\(capital(list)) couldn't be read: the read failed, and abapit says why." }
        package static func notInScope(_ list: String) -> String { "\(capital(list)) isn't in this organization's scope." }
        package static func unusable(_ list: String) -> String { "\(capital(list)) can't be read for this organization." }
        package static func notRead(_ list: String) -> String { "\(capital(list)) wasn't read." }
        package static let noMosyleOrg = "No Mosyle Business organization is set up with this one, so Mosyle wasn't read."
        package static func stillReading(_ list: String, after: Duration) -> String {
            "\(capital(list)) was still being read after \(after.components.seconds.formatted()) seconds, so nothing from it is counted. The read goes on in abapit."
        }
        package static func changed(_ list: String) -> String { "\(capital(list)) changed while this was being answered, so nothing is answered. Ask again." }
        package static let switched = "The active organization changed while this was being answered, so nothing is answered."
        package static let cancelled = "Cancelled: nothing is answered."
        package static let historyFailed = "The snapshot history couldn't be read, and abapit says why. This report judges nothing."
        package static func sweepFailed(_ title: String) -> String {
            "The newest snapshot that read \(title) didn't read it, and no earlier one did, so this report judges nothing. Abapit says why."
        }
        /// After the history read's wait: `bound` is `LiveWait.bound`, the one wait every answer has, so the words follow it.
        package static func historyStillReading(after bound: Duration = LiveWait.bound) -> String {
            "The snapshot history was still being read after \(bound.components.seconds.formatted()) seconds, so nothing is answered. Ask again."
        }
        package static let attentionChanged = "What the rules read changed while this was being answered, so nothing is answered. Ask again."
        /// After a list that can't be counted: a report judges nothing; Needs attention skips the rules that read it.
        package static let nothingJudged = "Nothing was judged."
        package static let rulesSkipped = "A rule that reads it is skipped."

        static func capital(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
    }

    /// The lists by name, as spoken.
    package static func name(_ list: LiveWait.List) -> String {
        switch list {
        case .appleDevices: "Apple's device list"
        case .appleServices: "Apple's list of device management services"
        case .mosyleDevices: "Mosyle's device list"
        }
    }

    /// Serial lookup with the Mosyle org active: nothing is read from Mosyle (the executor's words, as the Reports screen's).
    public static let mosyleLookUp = "This is a Mosyle Business organization. Serial lookup reads Apple's device list, and nothing was read from Mosyle."
    /// Needs attention with the Mosyle org active, with one client: the screen's words without "client".
    static let attentionMosyleOne = "This is a Mosyle Business organization. Needs attention runs from the Apple organization: make it active to see what needs attention."

    private let orgs: OrgsModel
    private let devices: DevicesModel
    private let mosyle: MosyleModel
    private let reports: ReportsModel
    private let attentionModel: NeedsAttentionModel
    /// The clock an age is said against, and the bound's sleep: the tests hold both.
    package var now: @MainActor () -> Date = { Date() }
    package var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// `LiveWait`'s hooks for a request: once its reads are started (a test switches the org or cancels there), and once its wait
    /// has ended (a test reads a list again there, to show an answer never counts a list other than the one the wait saw).
    package var afterStart: (@MainActor () async -> Void)?
    package var afterWait: (@MainActor () async -> Void)?

    public init(orgs: OrgsModel, devices: DevicesModel, mosyle: MosyleModel, reports: ReportsModel, attention: NeedsAttentionModel) {
        self.orgs = orgs
        self.devices = devices
        self.mosyle = mosyle
        self.reports = reports
        self.attentionModel = attention
    }

    /// The active client as the Ask's picker needs it (`Assist`'s own scope, whether it has a Mosyle org, the Needs-attention
    /// thresholds): no list data. Nil with no organization open.
    public var assistClient: Picker.Client? {
        guard let active = orgs.active else { return nil }
        let school = active.provider == .known(.apple) && active.scope == .known(.school)
        return Picker.Client(scope: school ? .school : .business, hasMosyle: orgs.mosyleOrg != nil, thresholds: attentionModel.thresholds)
    }

    /// The org generation: a request that awaited something (the Ask's model call) compares it before and after, and a change is
    /// a switch, so nothing picked for one client is answered over another's data.
    var generation: Int { orgs.generation }

    /// Runs `handler` on every org or client switch (the Ask clears its draft).
    func onSwitch(_ handler: @escaping @MainActor () -> Void) { orgs.onSwitch(handler) }

    // MARK: the questions

    /// An intent's group and number as the catalog's tokens: the group under `group`, the number under the report's number filter
    /// (`days` or `years`), or under `number` when the report has none, which the catalog refuses in words. A blank group is none.
    public static func tokens(_ report: ReportsModel.Report, group: String?, number: Int?) -> [String: String] {
        var tokens: [String: String] = [:]
        if let group, group.contains(where: { !$0.isWhitespace }) { tokens["group"] = group }
        if let number {
            let name = ReportCatalog.entry(report.catalogID).filters.first(where: \.isNumber)?.name ?? "number"
            tokens[name] = String(number)
        }
        return tokens
    }

    /// `report` with `tokens` (the catalog's), over the active client's data. A token that doesn't resolve reads nothing.
    public func answer(report: ReportsModel.Report, tokens: [String: String]) async -> Answer {
        await run(report: report, tokens: tokens) { _ in }
    }

    /// A report's CSV as the Reports screen's Export writes it, and the words that say how much was read.
    public struct ReportFile: Equatable, Sendable {
        public let name: String
        public let text: String
    }

    /// What `reportCSV` ends with: the spoken words (counts, the data's age, how much was read, or why nothing was made) and the
    /// file, which is nil whenever the words say nothing was judged, the client changed or the read didn't finish.
    public struct CSVAnswer: Equatable, Sendable {
        public let spoken: String
        public let file: ReportFile?
    }

    /// The report's CSV for the active client: the screen's `csv(of:)` over the same `build`, its allowlisted columns, and its
    /// `exportFileName` (the client's name first only when the app shows clients). It reads as `answer` does and writes nothing; a
    /// read in part or from an old snapshot is said in `spoken`, and the file's own `listRead` column carries it too. The CSV is
    /// made from the same `Output` the answer was, with nothing awaited between, so a switch can't give it another client's rows.
    public func reportCSV(report: ReportsModel.Report, tokens: [String: String]) async -> CSVAnswer {
        var file: ReportFile?
        let answer = await run(report: report, tokens: tokens) { [reports] output in
            guard output.canExport else { return }
            file = ReportFile(name: reports.exportFileName(for: output), text: reports.csv(of: output))
        }
        return CSVAnswer(spoken: answer.spoken, file: file)
    }

    /// `answer`'s body; `took` sees the report's `Output` once it is built over data that was read, in the same turn.
    private func run(report: ReportsModel.Report, tokens: [String: String], took: (ReportsModel.Output) -> Void) async -> Answer {
        let title = report.title
        let resolution = ReportCatalog.resolve(report.catalogID, tokens: tokens)
        guard resolution.problems.isEmpty else { return said(title, reports.build(report, tokens: tokens).judgesNothing ?? "") }
        guard orgs.active != nil else { return said(title, ScreenWords.noOrganization) }
        if reports.isMosyle { return said(title, ReportsModel.mosyleWords) }
        guard !Task.isCancelled else { return said(title, Phrase.cancelled) }
        let generation = orgs.generation
        // Superseded by the screen's own read of the history: that read's result is the one to use, once it has ended.
        if await !reports.loadHistory(), orgs.generation == generation, !Task.isCancelled {
            guard await settle({ [reports] in !reports.state.isLoading }) else {
                return said(title, Task.isCancelled ? Phrase.cancelled : Phrase.historyStillReading())
            }
        }
        if Task.isCancelled { return said(title, Phrase.cancelled) }
        guard orgs.generation == generation else { return said(title, Phrase.switched) }
        let key = resolution.tokens["group"]
        switch basis(report) {
        case .snapshot(let sweep):
            let output = reports.build(report, tokens: tokens)
            if let nothing = output.judgesNothing { return said(title, judgesNothing(nothing, sweep: sweep)) }
            guard case .used(let used)? = reports.sources[sweep] else { return said(title, Phrase.notRead("the snapshot") + " " + Phrase.nothingJudged) }
            took(output)
            return made(output, read: snapshotWords(used, sweep: sweep), group: key, models: Self.models(used.devices))
        case .live(let list):
            let ends: [LiveWait.List: LiveWait.End]
            switch await waitFor([list]) {
            case .answered(let got): ends = got
            case .stopped(let phrase): return said(title, phrase)
            }
            let read = liveWords([list], ends)
            guard read.counts else { return said(title, read.words.joined(separator: " ")) }
            // Built at once after the check: nothing runs between them, so the counts are over the lists as said.
            let output = reports.build(report, tokens: tokens)
            if let nothing = output.judgesNothing { return said(title, nothing) }
            took(output)
            var words = read.words
            if report == .fleetAge { words.append(noCoverage()) }
            return made(output, read: words, group: key, models: Self.models(devices.rows.map(\.device.resource)))
        }
    }

    /// What needs attention: the screen's evaluation over the live lists, read and waited for, and the history. Findings are
    /// recorded as the screen records them, only for a rule judged over a whole read.
    public func attention() async -> Answer {
        let title = "Needs attention"
        guard let active = orgs.active else { return said(title, ScreenWords.noOrganization) }
        guard active.provider == .known(.apple) else {
            return said(title, orgs.showsClients ? NeedsAttentionModel.mosyleWords : Self.attentionMosyleOne)
        }
        // Mosyle's list too with no Mosyle org: the wait asks it nothing, and the answer says Mosyle wasn't read.
        let wanted = LiveWait.List.allCases
        let generation = orgs.generation
        let ends: [LiveWait.List: LiveWait.End]
        switch await waitFor(Set(wanted)) {
        case .answered(let got): ends = got
        case .stopped(let phrase): return said(title, phrase)
        }
        // The history as the screen reads it; superseded by the screen's own read, once that read has ended.
        if await !attentionModel.loadHistory(), orgs.generation == generation, !Task.isCancelled {
            guard await settle({ [attentionModel] in !attentionModel.state.isLoading }) else {
                return said(title, Task.isCancelled ? Phrase.cancelled : Phrase.historyStillReading())
            }
        }
        if Task.isCancelled { return said(title, Phrase.cancelled) }
        guard orgs.generation == generation else { return said(title, Phrase.switched) }
        // The lists must be as the wait saw them before anything is judged or recorded: the evaluation reads them as it starts,
        // with nothing run between this check and that read.
        let read = liveWords(wanted, ends, tail: Phrase.rulesSkipped)
        if read.changed { return said(title, read.words.joined(separator: " ")) }
        // Judged, never recorded (the operator, 2026-11-25, "Don't record (Recommended)": only the screen records). The judgement
        // is over the lists as checked above only if what the rules read is the same once it returns.
        let judged = attentionModel.inputKey
        let judgement = await attentionModel.judge()
        if Task.isCancelled { return said(title, Phrase.cancelled) }
        guard orgs.generation == generation else { return said(title, Phrase.switched) }
        guard let judgement, judgement.key == judged, attentionModel.inputKey == judged else { return said(title, Phrase.attentionChanged) }
        let summary = judgement.summary
        var words = read.words
        words += notSent(wanted, ends)
        words.append("Judged on \(reports.dates.dayTime(judgement.at)); nothing is kept from this answer.")
        // The snapshot rules' data: the oldest snapshot any of them used (invariant 8: its age is said).
        if let oldest = judgement.lines.compactMap(\.takenAt).min() {
            words.append("The oldest snapshot used is from \(reports.dates.day(oldest)), \(ReportsModel.age(since: oldest, now: now())).")
        } else {
            words.append("No snapshot was used.")
        }
        words.append(summary.headline)
        words += summary.rows.map { "\($0.title): \(Self.count($0.open, "open finding"))" + ($0.partial ? ", found over a part read and not kept." : ".") }
        words += summary.words
        return said(title, words.joined(separator: " "))
    }

    /// The devices in Apple's device list whose serial number or other identifier (IMEI, MEID, EID, order number, MAC address)
    /// matches `serial`, exactly or else in part (the Devices screen's Find), and which of the two. The identifier is never said back.
    public func lookUp(serial: String) async -> Answer {
        let title = "Serial lookup"
        guard let active = orgs.active else { return said(title, ScreenWords.noOrganization) }
        guard active.provider == .known(.apple) else { return said(title, Self.mosyleLookUp) }
        guard serial.contains(where: { !$0.isWhitespace }) else { return said(title, "No identifier was given, so nothing was looked up.") }
        let ends: [LiveWait.List: LiveWait.End]
        switch await waitFor([.appleDevices]) {
        case .answered(let got): ends = got
        case .stopped(let phrase): return said(title, phrase)
        }
        let read = liveWords([.appleDevices], ends)
        guard read.counts else { return said(title, read.words.joined(separator: " ")) }
        // Find matches a serial, an IMEI, an MEID, an EID, an order number or a MAC address, exactly, else inside one.
        let (found, exact) = Find.search(serial, in: devices.rows.map(\.device))
        var words = read.words
        let whole = if case .whole? = ends[.appleDevices] { true } else { false }
        switch (found.count, exact) {
        case (0, _):
            words.append("No device matches that identifier among the \(Self.count(devices.rows.count, "device")) read."
                         + (whole ? "" : " The list was read in part, so it may be among the devices not read."))
        case (1, true): words.append("1 device matches that identifier exactly.")
        case (let n, true): words.append("\(n.formatted()) devices match that identifier exactly.")
        case (1, false): words.append("No device matches that identifier exactly; 1 device has it as part of an identifier.")
        case (let n, false): words.append("No device matches that identifier exactly; \(n.formatted()) devices have it as part of an identifier.")
        }
        let rows = found.map { Answer.Row(serial: $0.serialNumber, model: Self.sent($0.deviceModel, "model"), state: Self.sent($0.status?.rawValue, "status")) }
        return said(title, words.joined(separator: " "), rows: rows)
    }

    // MARK: waiting

    private enum Waited {
        case answered([LiveWait.List: LiveWait.End])
        case stopped(String)
    }

    private func waitFor(_ wanted: Set<LiveWait.List>) async -> Waited {
        let wait = LiveWait(orgs: orgs, devices: devices, mosyle: mosyle, now: now, sleep: sleep)
        wait.afterStart = afterStart
        wait.afterWait = afterWait
        switch await wait.lists(wanted) {
        case .cancelled: return .stopped(Phrase.cancelled)
        case .switched: return .stopped(Phrase.switched)
        case .lists(let ends): return .answered(ends)
        }
    }

    /// Each wanted list's end in fixed words, whether every one can be counted, and whether one changed since the wait saw it end.
    private func liveWords(_ wanted: [LiveWait.List], _ ends: [LiveWait.List: LiveWait.End], tail: String = Phrase.nothingJudged) -> (words: [String], counts: Bool, changed: Bool) {
        let check = LiveWait(orgs: orgs, devices: devices, mosyle: mosyle, now: now, sleep: sleep)
        let now = now()
        var words: [String] = [], counts = true
        for list in wanted {
            guard let end = ends[list] else { continue }
            let name = Self.name(list)
            switch end {
            case .stillReading(let after):
                // Still being read now, or it ended since: what is held now isn't what was said, so nothing is answered.
                guard isLoading(list) else { return ([Phrase.changed(name)], false, true) }
                words.append(Phrase.stillReading(name, after: after))
                counts = false
                continue
            case .whole(let at), .partly(_, let at):
                // The same end again means the list is as the wait saw it: a Refresh since would count another read.
                guard check.end(of: list, seen: at) == end else { return ([Phrase.changed(name)], false, true) }
            case .notRead:
                guard check.end(of: list, seen: now) == end else { return ([Phrase.changed(name)], false, true) }
            }
            switch end {
            case .whole(let at):
                words.append("\(Phrase.capital(name)) was read in full on \(reports.dates.dayTime(at)), \(LiveWait.age(since: at, now: now)).")
            case .partly(_, let at):
                words.append("\(Phrase.capital(name)) was read in part on \(reports.dates.dayTime(at)), \(LiveWait.age(since: at, now: now)): \(partWords(list)). The counts cover only what was read.")
            case .notRead:
                words.append(notReadWords(list) + " " + tail)
                counts = false
            case .stillReading: break
            }
        }
        return (words, counts, false)
    }

    /// Whether `list`'s read is under way now.
    private func isLoading(_ list: LiveWait.List) -> Bool {
        switch list {
        case .appleDevices: devices.state.isLoading
        case .appleServices: devices.servicesState.isLoading
        case .mosyleDevices: orgs.mosyleOrg != nil && mosyle.devices.state.isLoading
        }
    }

    /// Waits, up to `LiveWait.bound` on the injected clock, until `done` holds; false when the bound passed or the task was cancelled.
    private func settle(_ done: @escaping @MainActor () -> Bool) async -> Bool {
        if done() { return true }
        let sleep = sleep, seen = Settled()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.watch(done, into: seen) }
            group.addTask { try? await sleep(LiveWait.bound) }
            await group.next()
            group.cancelAll()
        }
        return seen.done && !Task.isCancelled
    }

    @MainActor private final class Settled {
        var done = false
    }

    private static func watch(_ done: @escaping @MainActor () -> Bool, into seen: Settled) async {
        let changes = Observations { done() }
        for await held in changes where held {
            seen.done = true
            return
        }
    }

    /// Why a list was read only in part, from its model's state: numbers and fixed words, never the error's own text.
    private func partWords(_ list: LiveWait.List) -> String {
        switch list {
        case .appleDevices:
            let rows = devices.rows.count
            switch devices.state {
            case .loaded: return "it stopped at the page limit, showing \(rows.formatted()) of \(devices.total.map { $0.formatted() } ?? "more than \(rows.formatted())")"
            case .forbidden: return "your role can't read the rest, and \(Self.count(rows, "device")) were read before the refusal"
            default: return "the read stopped on an error after \(Self.count(rows, "device"))"
            }
        case .appleServices:
            var parts: [String] = []
            let count = devices.services.count
            switch devices.servicesState {
            case .loaded: if devices.servicesTruncated { parts.append("the list stopped at the page limit, showing \(Self.count(count, "service"))") }
            case .forbidden: parts.append("your role can't read the rest, and \(Self.count(count, "service")) were read before the refusal")
            default: parts.append("the read stopped on an error after \(Self.count(count, "service"))")
            }
            if case .loaded = devices.servicesState {
                let lists = devices.serviceDevices.values, short = lists.filter { $0.read != .whole }.count
                if short > 0 { parts.append("the device lists of \(short.formatted()) of \(Self.count(lists.count, "service")) weren't read whole") }
            }
            return parts.joined(separator: "; ")
        case .mosyleDevices:
            let rows = mosyle.devices.rows.count
            if case .loaded = mosyle.devices.state { return "it stopped at the page limit after \(Self.count(rows, "device"))" }
            return "the read stopped on an error after \(Self.count(rows, "device"))"
        }
    }

    /// Why a list wasn't read at all, as a fixed phrase for its kind.
    private func notReadWords(_ list: LiveWait.List) -> String {
        let state = switch list {
        case .appleDevices: devices.state
        case .appleServices: devices.servicesState
        case .mosyleDevices: mosyle.devices.state
        }
        return Self.notRead(list, state: state, mosyleOrg: orgs.mosyleOrg != nil)
    }

    /// The fixed phrase for a list that wasn't read, by its model's state: the state's own text is never used.
    package static func notRead(_ list: LiveWait.List, state: LoadState, mosyleOrg: Bool) -> String {
        let name = name(list)
        if list == .mosyleDevices, !mosyleOrg { return Phrase.noMosyleOrg }
        switch state {
        case .forbidden: return Phrase.refused(name)
        case .failed: return Phrase.failed(name)
        case .notInScope: return Phrase.notInScope(name)
        case .unusable: return Phrase.unusable(name)
        case .idle, .loading, .loaded: return Phrase.notRead(name)
        }
    }

    /// The fields a list's read didn't send, which a rule reads: said, so a rule skipped or partial for one is explained.
    private func notSent(_ wanted: [LiveWait.List], _ ends: [LiveWait.List: LiveWait.End]) -> [String] {
        var words: [String] = []
        func read(_ list: LiveWait.List) -> Bool {
            switch ends[list] {
            case .whole?, .partly?: true
            default: false
            }
        }
        if wanted.contains(.appleServices), read(.appleServices), !devices.servicesAbsent.isEmpty {
            words.append("Apple didn't send \(devices.servicesAbsent.sorted().joined(separator: ", ")) for any service: a rule that needs one doesn't judge it.")
        }
        if wanted.contains(.mosyleDevices), read(.mosyleDevices), let columns = mosyle.columns {
            let missing = Set(columns.refused + columns.untried)
            let fields = [("serial_number", "serial numbers"), ("date_last_beat", "last check-in times")].filter { missing.contains($0.0) }.map(\.1)
            if !fields.isEmpty { words.append("Mosyle didn't send its devices' \(fields.joined(separator: " or ")): a rule that needs them doesn't judge them.") }
        }
        return words
    }

    // MARK: reports

    private enum Basis: Equatable {
        case snapshot(Sweep)
        case live(LiveWait.List)
    }

    /// Where a report's data comes from, as `ReportsModel.build` reads it: Fleet age is a snapshot report when a snapshot read
    /// AppleCare, else a live one.
    private func basis(_ report: ReportsModel.Report) -> Basis {
        switch report {
        case .coverage, .outOfWarranty: .snapshot(.appleCare)
        case .activationLock: .snapshot(.activationLock)
        case .fleetAge: if case .used? = reports.sources[.appleCare] { .snapshot(.appleCare) } else { .live(.appleDevices) }
        case .migration: .live(.appleDevices)
        case .serviceHealth: .live(.appleServices)
        }
    }

    /// A snapshot report that judges nothing: the screen's words, but where they would carry an error's own text, a fixed phrase.
    private func judgesNothing(_ words: String, sweep: Sweep) -> String {
        if case .failed = reports.state { return Phrase.historyFailed }
        if case .unavailable(_?)? = reports.sources[sweep] { return Phrase.sweepFailed(sweep.title) }
        return words
    }

    /// Why Fleet age read the live list with no coverage, in fixed words.
    private func noCoverage() -> String {
        if case .failed = reports.state { return "The snapshot history couldn't be read, so no AppleCare coverage is used." }
        if case .unavailable(_?)? = reports.sources[.appleCare] {
            return "The newest snapshot that read AppleCare coverage didn't read it, and no earlier one did, so no AppleCare coverage is used."
        }
        return "No snapshot has read AppleCare coverage, so none is used."
    }

    /// Where a snapshot report's data comes from: the snapshot's date and age, and how much of it was read, in fixed words.
    private func snapshotWords(_ used: ReportsModel.Used, sweep: Sweep) -> [String] {
        var words = ["From the snapshot of \(reports.dates.day(takenAt: used.takenAt)), \(ReportsModel.age(of: used.takenAt, now: now())); nothing was read from Apple now."]
        switch used.deviceList {
        case .whole: break
        case .partly: words.append("That snapshot's device list was read in part, so the counts cover only what was read.")
        case .notRead: words.append("That snapshot's device list wasn't read, so nothing was judged.")
        }
        if used.part != nil { words.append("That snapshot read \(sweep.title) only in part: a device it didn't read counts as not read.") }
        if used.failure != nil { words.append("A newer snapshot didn't read \(sweep.title), so this is the last good copy.") }
        if used.deviceList == .whole, used.part == nil { words.append("Read in full.") }
        return words
    }

    /// A report that ran: how much was read, then its counts (the report's own lines after its read line, which can carry an error's
    /// text), the values it doesn't know, the group asked for, an estimate called one, and the rows.
    private func made(_ output: ReportsModel.Output, read: [String], group key: String?, models: [String: String]) -> Answer {
        var words = read
        var counts = Array(output.summary.dropFirst())
        var rows: [Answer.Row] = []
        // With no group, the rows are the devices the question is about, never every device the report counts: the counts are
        // spoken whole, and the rows say which they are (the review of PR 52: 10 ACTIVE rows hid the one out of warranty).
        var shown: String?
        func row(_ device: OrgDevice, _ state: String) -> Answer.Row {
            Answer.Row(serial: device.serialNumber, model: Self.sent(device.deviceModel, "model"), state: state)
        }
        switch output.built {
        case .coverage(let report)?:
            rows = report.expiring.map { Answer.Row(serial: $0.device, model: models[$0.device] ?? Self.sent(nil, "model"), state: "\(Self.count($0.daysLeft, "day")) left") }
                + report.unreadableEndDevices.map { Answer.Row(serial: $0, model: models[$0] ?? Self.sent(nil, "model"), state: "end date not readable") }
        case .fleetAge(let report)?:
            rows = report.candidates.map { Answer.Row(serial: $0.serial, model: Self.sent($0.model.string, "model"), state: "\(String(format: "%.1f", $0.ageYears)) years") }
        case .activationLock(let report)?:
            rows = (key.map(report.rows(group:)) ?? report.rows.filter { $0.token.hasPrefix("lock:") }).map { row($0.device, $0.group) }
            if key == nil { shown = Self.shownLocked }
            // A lock type this version doesn't know is counted, never said: Apple's raw value stays on the screen and in the rows.
            let unknown = report.rows.compactMap { row -> String? in
                if case .otherLock(let raw) = row.kind, raw != "NONE", raw != "not sent" { raw } else { nil }
            }
            counts.removeAll { line in Set(unknown).contains { line.hasPrefix("Locked, lock type \($0): ") } }
            if !unknown.isEmpty { counts.append("\(unknown.count.formatted()) locked with a lock type this version doesn't know: can't say whether it blocks release.") }
        case .outOfWarranty(let report)?:
            rows = (key.map(report.rows(group:)) ?? report.rows.filter { Self.withoutActiveCoverage.contains($0.group) })
                .map { row($0.device, $0.group + ($0.estimatedPast ? ", estimated past" : "")) }
            if key == nil { shown = Self.shownWithoutCoverage }
            counts.removeAll { $0.contains(WarrantyReport.assumption) }
            let estimated = report.rows(group: WarrantyReport.estimatedPastToken).count, undated = report.rows.filter(\.lacksReadableOrderDate).count
            counts.append("\(estimated.formatted()) estimated from the order date to be past an assumed one-year warranty: an estimate only. "
                          + "\(undated.formatted()) without active coverage have no readable order date, so no estimate.")
        case .migration(let report)?:
            rows = (key.map(report.rows(group:)) ?? report.rows.filter { $0.pastDue || $0.pastDueStatusUnknown }).map { row($0.device, $0.group) }
            if key == nil { shown = Self.shownPastDue }
            // A status this version doesn't know is counted, never said.
            let unknown = report.rows.compactMap { row -> String? in if case .unknown(let raw)? = row.status { raw } else { nil } }
            counts.removeAll { line in Set(unknown).contains { line.hasPrefix("Status \($0): ") } }
            if !unknown.isEmpty { counts.append("\(unknown.count.formatted()) with a migration status this version doesn't know.") }
        case .serviceHealth(let report)?:
            // Services are known by name: none is shown here, only counted; a status this version doesn't know is counted in the
            // report's own line, never said.
            break
        case nil: break
        }
        // A report's line that is a label and a count ("Status FAILED: 2") ends as a sentence when said.
        words += counts.map { $0.hasSuffix(".") ? $0 : $0 + "." }
        if let key { words.append("The group \(key) holds \(output.matching.formatted()).") }
        var answer = said(output.title, words.joined(separator: " "), rows: rows, estimateNote: output.estimateNote)
        answer.rowsNote = shown
        return answer
    }

    // MARK: words

    /// Out of warranty's groups shown with no group asked: no ACTIVE coverage, with a record or without one.
    static let withoutActiveCoverage: Set = ["no-active-coverage", "no-record"]
    package static let shownWithoutCoverage = "Shown: the devices without active AppleCare coverage. Name a group to see others."
    package static let shownLocked = "Shown: the locked devices. Name a group to see others."
    /// Past due or past due with a status unknown (`past-due`, `past-due-status-unknown`): the rows hold both, so the note names both.
    package static let shownPastDue = "Shown: the devices past the migration deadline without success, and those past it whose status is unknown. Name a group to see others."

    /// The answer, the client's name first when the app shows clients.
    private func said(_ title: String, _ spoken: String, rows all: [Answer.Row] = [], estimateNote: String? = nil) -> Answer {
        let client = orgs.exportClient
        let rows = Array(all.prefix(Self.rowLimit))
        let cap = all.count > rows.count ? "Showing \(rows.count.formatted()) of \(all.count.formatted()): the rest are in abapit." : nil
        return Answer(lead: client.map { "\($0): \(title)" } ?? title, spoken: client.map { "\($0): \(spoken)" } ?? spoken, rows: rows, capNote: cap,
                      estimateNote: estimateNote)
    }

    /// Each device's model by its id, for the rows of a report that carries only the id.
    static func models(_ devices: [Resource]) -> [String: String] {
        var models: [String: String] = [:]
        for device in devices where models[device.id] == nil { models[device.id] = sent(device.attributes["deviceModel"]?.string, "model") }
        return models
    }

    /// A value Apple sent, or that it didn't: never an empty cell that reads as a value.
    static func sent(_ value: String?, _ what: String) -> String {
        guard let value, !value.isEmpty else { return "\(what) not sent" }
        return value
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }
}
