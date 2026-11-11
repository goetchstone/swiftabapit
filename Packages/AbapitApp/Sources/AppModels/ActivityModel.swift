import AppleBusiness
import AppleModels
import Foundation
import Observation
import Reports

/// What the audit read asks Apple for: a range (the last `days` days up to the read, or `start` to `end`) and Apple's
/// own filters. Checked as `AuditQuery` checks it when it is set, so a range or an id Apple would refuse, or that would
/// steer the query, is refused here with the reason, and never sent.
public struct AuditFilter: Equatable, Sendable {
    /// The ranges the screen offers; `AuditQuery.longestSpan` (365 days) is the longest.
    public static let presets = [1, 7, 30, 90, 365]

    /// The last `days` days up to the moment of the read (Refresh moves it on); nil for `start` to `end`.
    public var days: Int? = 7
    public var start: Date
    public var end: Date
    /// `filter[type]`: one of Apple's types, or every type.
    public var type: AuditEventType?
    /// `filter[actorId]` and `filter[subjectId]`, as typed: trimmed when read, and empty for none.
    public var actorID = ""
    public var subjectID = ""

    /// The last seven days, every type (abapit's default); a custom range starts as the same seven days.
    public init(now: Date = Date()) {
        start = now.addingTimeInterval(-7 * 86_400)
        end = now
    }

    /// The query for a read at `now`.
    public func query(now: Date = Date()) throws(AuditQuery.Invalid) -> AuditQuery {
        let actor = Self.id(actorID), subject = Self.id(subjectID)
        if let days {
            return try AuditQuery.last(days: days, now: now, types: type.map { [.known($0)] } ?? [], actorID: actor, subjectID: subject)
        }
        return try AuditQuery(start: start, end: end, types: type.map { [.known($0)] } ?? [], actorID: actor, subjectID: subject)
    }

    /// Why this filter can't be read, in words; nil when it can.
    public func problem(now: Date = Date()) -> String? {
        do {
            _ = try query(now: now)
            return nil
        } catch .notAnID {
            return Self.idProblem(Self.id(actorID), "actor") ?? Self.idProblem(Self.id(subjectID), "subject") ?? Self.words(.notAnID)
        } catch {
            return Self.words(error)
        }
    }

    /// Why `id` can't be sent as one of Apple's filters, each of `AppleRead.isPathSafe`'s rules in its own words (Phase 2b
    /// review L8: a 129-character id, and `.hidden`, whose characters are all allowed, were told to fix their characters);
    /// nil when it can be sent.
    static func idProblem(_ id: String?, _ which: String) -> String? {
        guard let id, !AppleRead.isPathSafe(id) else { return nil }
        // The character rule alone: each scalar after a letter, so neither the length nor the dot rule decides.
        if !id.unicodeScalars.allSatisfy({ AppleRead.isPathSafe("a" + String($0)) }) {
            return "The \(which) ID can hold only letters, digits, -, _ and ., as Apple's IDs do."
        }
        if id.utf8.first == UInt8(ascii: ".") { return "The \(which) ID can't start with a dot, as Apple's IDs don't." }
        return "The \(which) ID is longer than Apple's IDs: at most 128 characters."
    }

    /// A refused range in words.
    static func words(_ invalid: AuditQuery.Invalid) -> String {
        switch invalid {
        case .emptyRange: "The range must start before it ends."
        case .tooLong: "The audit log is read at most \(Int(AuditQuery.longestSpan / 86_400)) days at a time."
        case .outOfRange: "The range must fall between 1970 and 9999."
        case .unknownType(let raw): "\(raw) isn't a type this version knows, so it isn't sent to Apple."
        case .notAnID: "An actor or subject ID is 1 to 128 letters, digits, -, _ and ., not starting with a dot, as Apple's IDs are."
        }
    }

    /// What Apple's filters narrowed the read to, in words; nil when only the range is set. The views over the read
    /// count only what the filters let through, so the screen says so.
    public var summary: String? {
        let parts = [type.map { "type \(ActivityModel.title(of: $0))" }, Self.id(actorID).map { "actor \($0)" },
                     Self.id(subjectID).map { "subject \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : "Apple filtered this read to \(parts.joined(separator: ", ")): the views count only these events."
    }

    /// The range by name.
    public var rangeName: String {
        switch days {
        case nil: "A custom range"
        case 1?: "The last day"
        case let days?: "The last \(days) days"
        }
    }

    /// The same filter with its ids trimmed, as it is sent.
    var trimmed: AuditFilter {
        var filter = self
        filter.actorID = Self.id(actorID) ?? ""
        filter.subjectID = Self.id(subjectID) ?? ""
        return filter
    }

    /// An id as typed, trimmed; nil when nothing is left.
    static func id(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The Activity screen's panes: the whole audit list, Reports' three views over the same read (`AuditView`), and the types
/// no view shows. Every event with a type is in exactly one pane besides Audit; one with none only in Audit.
public enum ActivityPane: String, CaseIterable, Identifiable, Sendable {
    case audit, subscriptions, deviceLifecycle, accessAndSecurity, other

    public var id: Self { self }

    /// The Reports view the pane shows; nil for the whole list and for the other types.
    public var view: AuditView? {
        switch self {
        case .subscriptions: .subscriptions
        case .deviceLifecycle: .deviceLifecycle
        case .accessAndSecurity: .accessAndSecurity
        case .audit, .other: nil
        }
    }

    public var title: String {
        switch self {
        case .audit: "Audit"
        case .subscriptions: "Subscriptions & Purchases"
        case .deviceLifecycle: "Device Lifecycle"
        case .accessAndSecurity: "Access & Security"
        case .other: "Other types"
        }
    }

    /// What the pane is for, in a sentence short enough for the narrowest window (after abapit's blurbs for its two views).
    public var blurb: String {
        switch self {
        case .audit: "Every event Apple logged in the range."
        case .subscriptions: "Apple has no subscription endpoint: these events are where it reports subscriptions and purchases."
        case .deviceLifecycle: "Devices added, removed, assigned, unassigned and erased: Apple's side, not whether the MDM enrolled them."
        case .accessAndSecurity: "Who can get in, and with what: accounts, API keys, roles, domains, identity providers, passwords, terms and webhooks."
        case .other: "Types no view shows (configurations, collections, account pictures) and types this version doesn't know."
        }
    }

    /// The pane an event is in besides Audit, from its type: nil when it has none (missing, or not a string). A type this
    /// version doesn't know (`typed` with no `known`) is in Other types, never dropped.
    static func of(_ known: AuditEventType?, typed: Bool) -> ActivityPane? {
        guard typed else { return nil }
        guard let known else { return .other }
        switch AuditView.allCases.first(where: { $0.eventTypes.contains(known) }) {
        case .subscriptions?: return .subscriptions
        case .deviceLifecycle?: return .deviceLifecycle
        case .accessAndSecurity?: return .accessAndSecurity
        case nil: return .other
        }
    }
}

/// One row of the audit table: the event, with its columns in words, made once per page so sorting and searching don't
/// re-read attributes.
public struct ActivityRow: Identifiable, Sendable {
    /// Its place in the read, from 0: Apple's ids aren't relied on to be unique.
    public let id: Int
    public let event: AuditEvent
    public let time: Date?
    /// A known type by name, an unknown one as Apple sent it (invariant 10), "—" for none.
    public let type: String
    public let category: String
    public let outcome: String
    /// The actor's name, else its id.
    public let actor: String
    /// The subject's name, else its id.
    public let subject: String
    /// The pane that shows it besides Audit; nil for an event with no type, which only Audit lists.
    public let pane: ActivityPane?

    public init(_ event: AuditEvent, id: Int) {
        self.id = id
        self.event = event
        time = event.eventDate?.date
        type = Self.words(event.type?.rawValue, known: event.type?.known != nil)
        category = Self.words(event.category?.rawValue, known: event.category?.known != nil)
        outcome = Self.words(event.outcome?.rawValue, known: event.outcome?.known != nil)
        actor = Self.either(event.actorName, event.actorID)
        subject = Self.either(event.subjectName, event.subjectID)
        pane = ActivityPane.of(event.type?.known, typed: event.type != nil)
    }

    /// Whether Apple says it failed: said in words beside any colour.
    public var failed: Bool { event.outcome?.known == .failure }

    /// Who did it, and whether it failed, for a line under the type (Device 360's timeline).
    public var byline: String { "by \(actor)" + (failed ? ", failed" : "") }

    /// Sorts undated events last when newest is first: a missing date reads oldest.
    public var timeSort: Date { time ?? .distantPast }

    /// An Apple value in words: a known one in sentence case with its acronyms kept ("API account key revoked", "iCloud
    /// storage purchase added": abapit dropped `SUBJECT_HAS_` from its labels too); one this version doesn't know as Apple
    /// sent it (invariant 10); "—" for none.
    public static func words(_ raw: String?, known: Bool) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        guard known else { return raw }
        let parts = (raw.hasPrefix("SUBJECT_HAS_") ? String(raw.dropFirst("SUBJECT_HAS_".count)) : raw).split(separator: "_")
        return parts.enumerated().map { index, part in
            if let kept = acronyms[String(part)] { return kept }
            let word = part.lowercased()
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    static let acronyms = ["API": "API", "IDP": "IdP", "ICLOUD": "iCloud", "APPLECARE": "AppleCare", "MDM": "MDM", "OIDC": "OIDC", "SAML": "SAML"]

    static func either(_ name: String?, _ id: String?) -> String {
        if let name, !name.isEmpty { return name }
        if let id, !id.isEmpty { return id }
        return "—"
    }

    /// Whether the search box's text is in any column, or in the type, actor or subject as Apple sent them.
    func matches(_ text: String) -> Bool {
        [type, category, outcome, actor, subject, event.type?.rawValue, event.actorID, event.subjectID]
            .contains { $0?.localizedStandardContains(text) ?? false }
    }
}

/// What the inspector shows of one event, in words: the common attributes labelled, the payload where Apple put it
/// (`AuditEventPayload`), what was wrong with where it was (`payloadProblems`, never "no payload" with nothing said:
/// Phase 2a review M1), and every other attribute Apple sent. The view shows the values as Apple sent them.
public struct AuditEventDetail: Sendable {
    public struct Field: Sendable, Identifiable, Equatable {
        public let label: String
        public let key: String
        public var id: String { key }
    }

    /// `AuditEvent.fields`, each labelled, in Apple's order.
    public let common: [Field]
    /// The attribute the payload was read under; nil when none was found.
    public let payloadKey: String?
    /// The payload's fields: those Apple documents for the type that came, in its order, then the rest, said to be
    /// undocumented. An unknown type's are all as sent.
    public let payloadFields: [Field]
    /// What reading the payload has to say, in words: each of `payloadProblems`, a type this version doesn't know, a type
    /// Apple documents no fields for, no payload at all.
    public let notes: [String]
    /// Attributes neither common nor the payload's: shown raw (invariant 10).
    public let otherAttributes: [String]
    /// The pane that shows it besides Audit, by title.
    public let pane: String

    static let labels = ["eventDateTime": "When", "type": "Type", "category": "Category", "actorType": "Actor type", "actorId": "Actor ID",
                         "actorName": "Actor", "subjectType": "Subject type", "subjectId": "Subject ID", "subjectName": "Subject",
                         "outcome": "Outcome", "groupId": "Group ID", "eventDataPropertyKey": "Payload key"]

    public init(_ event: AuditEvent) {
        common = AuditEvent.fields.map { Field(label: Self.labels[$0] ?? $0, key: $0) }
        let payload = event.payload
        payloadKey = payload?.key
        var fields: [Field] = []
        if let payload {
            if let documented = payload.fields {
                fields = documented.filter { field in payload.object.keys.contains { $0.utf8.elementsEqual(field.utf8) } }.map { Field(label: $0, key: $0) }
                fields += payload.unreadFields.map { Field(label: "\($0) (not in Apple's docs)", key: $0) }
            } else {
                fields = payload.object.keys.map { Field(label: $0, key: $0) }
            }
        }
        payloadFields = fields
        var notes: [String] = []
        let type = event.type
        if type == nil { notes.append("The event has no type: only Audit lists it, and its payload can't be found by type.") }
        if let type, type.known == nil {
            notes.append("This version doesn't know the type \(type.rawValue): the event and its payload are shown as Apple sent them, under Other types.")
        }
        let problems = event.payloadProblems
        for problem in problems {
            switch problem {
            case .namedKeyAbsent: notes.append("Apple named the payload \(event.eventDataPropertyKey ?? ""), which the event doesn't have.")
            case .namedKeyEmpty: notes.append("Apple named the payload with an empty key.")
            case .namedKeyNotAString: notes.append("Apple named the payload with something that isn't a key.")
            case .notAnObject: notes.append("The payload isn't an object, so its fields can't be read.")
            }
        }
        // The named key missed and the type's own held it: said where the payload came from.
        if let payload, !problems.isEmpty {
            notes[notes.count - 1] += " It was read under the type's own key, \(payload.key)."
        }
        if let known = type?.known, payload != nil, known.payload.fields.isEmpty {
            notes.append("Apple documents no fields for \(ActivityModel.title(of: known)): what came is shown as sent.")
        }
        if payload == nil, problems.isEmpty, type != nil { notes.append("Apple sent no payload.") }
        self.notes = notes
        otherAttributes = event.unreadAttributes
        pane = ActivityPane.of(type?.known, typed: type != nil)?.title ?? "Audit only"
    }
}

/// Activity (Appendix B: "Activity › Audit, Subscriptions, Lifecycle, Access & Security"; plan Phase 2 "Audit"): the audit
/// log over a checked range (`AuditFilter`, `AuditQuery`), Apple's own filters for type, actor and subject, cursor paging
/// as the client gives it, and Reports' `AuditView`s over that one read, each with its counts by type (`AuditDigest`).
///
/// One read, not one per view: every event is in exactly one pane besides Audit, so the panes add up to what was read,
/// and a type Apple adds later is in Other types. A read per view, filtered by Apple to its types, would cost three more
/// walks of the same range against a rate-limited API, and an event of a type none of them names would be read by none:
/// dropped. Business only: a School org's read is not in scope, in words.
///
/// Each load has a token checked after every page, as `DevicesModel`'s: a load that was refreshed, superseded or cancelled
/// writes nothing, and an org switch clears the screen and its filters (an actor's id is one org's) and reads again.
@MainActor
@Observable
public final class ActivityModel {
    public private(set) var rows: [ActivityRow] = []
    public private(set) var state: LoadState = .idle
    /// The page cap stopped the list with more to come: "showing N of ≥M".
    public private(set) var truncated = false
    public private(set) var total: Int?
    /// The query the rows were read with: its range is what the screen says they cover.
    public private(set) var query: AuditQuery?

    /// The range and filters being edited; read when applied.
    public var draft: AuditFilter
    /// The range and filters the rows were read with.
    public private(set) var applied: AuditFilter
    /// Why the last Apply was refused, in words.
    public private(set) var problem: String?

    public var pane = ActivityPane.audit
    public var search = ""
    public var sortOrder = [KeyPathComparator(\ActivityRow.timeSort, order: .reverse)]
    /// The inspected event. Cleared by every read: a row's id is its place in a read, so it would name another event.
    public var selection: ActivityRow.ID?

    /// Each pane's counts by type, once the range was read whole; nil otherwise, so a count over a list cut short or
    /// partial is never shown as one (a dash).
    private var tallies: [ActivityPane: [Tally]]?

    private let orgs: OrgsModel
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The current load's token: every write checks it, so a superseded load never lands.
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var loadedGeneration = -1
    /// Reads that have returned, superseded ones included: what tests wait on instead of the clock. `package`: the app
    /// never sees it.
    @ObservationIgnored package private(set) var readsFinished = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        let filter = AuditFilter()
        draft = filter
        applied = filter
        orgs.onSwitch { [weak self] in self?.orgChanged() }
    }

    /// Every type Apple documents, grouped by the pane that shows it: what the type filter offers.
    public static let typeChoices: [(pane: ActivityPane, types: [AuditEventType])] =
        [(.subscriptions, AuditView.subscriptions.eventTypes), (.deviceLifecycle, AuditView.deviceLifecycle.eventTypes),
         (.accessAndSecurity, AuditView.accessAndSecurity.eventTypes), (.other, AuditView.otherEventTypes)]

    /// A type by name.
    public nonisolated static func title(of type: AuditEventType) -> String { ActivityRow.words(type.rawValue, known: true) }

    /// The rows the table shows: the pane's, searched, then sorted.
    public var shown: [ActivityRow] {
        var result = inPane(pane)
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result = result.filter { $0.matches(text) } }
        return result.sorted(using: sortOrder)
    }

    /// The inspected row.
    public var selected: ActivityRow? { selection.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }

    /// Why the draft can't be read, in words, as it is edited; nil when it can.
    public var draftProblem: String? { draft.problem() }

    /// Reads the draft, unless `AuditFilter.problem` refuses it: then the reason is said, nothing is sent, and the last
    /// read stays.
    @discardableResult
    public func apply(now: Date = Date()) -> Bool {
        if let why = draft.problem(now: now) {
            problem = why
            return false
        }
        problem = nil
        applied = draft.trimmed
        load(force: true)
        return true
    }

    /// The pane's counts by type, most first (`AuditDigest`); nil for Audit, which counts none, and unless the range
    /// was read whole.
    public func counts(_ pane: ActivityPane) -> [Tally]? { pane == .audit ? nil : tallies?[pane] }

    /// The pane's counts in words, most first: "Device assigned to server 2 · Device added to org 1", a type this version
    /// doesn't know as Apple sent it; nil when there are no counts to give (`counts`).
    public func countsText(_ pane: ActivityPane) -> String? {
        guard let counts = counts(pane), !counts.isEmpty else { return nil }
        return counts.map { tally in
            let known = AuditEventType.allCases.contains { $0.rawValue.utf8.elementsEqual(tally.name.utf8) }
            return "\(ActivityRow.words(tally.name, known: known)) \(tally.count.formatted())"
        }.joined(separator: " · ")
    }

    /// How many events the pane holds of those read, in words, and how whole the read is; nil before any arrived.
    public func summary(for pane: ActivityPane) -> String? {
        let all = rows.count, mine = inPane(pane).count
        let events = "event\(all == 1 ? "" : "s")"
        let count = pane == .audit ? "\(all.formatted()) \(events)" : "\(mine.formatted()) of the \(all.formatted()) \(events)"
        switch state {
        case .loading: return all == 0 ? nil : "\(count) read so far."
        case .loaded: return truncated ? "\(count) read: the list stopped at the page limit." : "\(count) in this range."
        case .failed: return all == 0 ? nil : "\(count) read before the error."
        case .forbidden: return all == 0 ? nil : "\(count) read before the refusal."
        case .idle, .unusable, .notInScope: return nil
        }
    }

    /// The events this version can't place in a view, in words: types it doesn't know (in Other types) and events with
    /// no type (in Audit only). Said on every pane, so nothing read is out of sight unsaid.
    public var unplacedNote: String? {
        var unknown: [(type: String, count: Int)] = []
        var untyped = 0
        for row in rows {
            guard let type = row.event.type else {
                untyped += 1
                continue
            }
            guard type.known == nil else { continue }
            if let index = unknown.firstIndex(where: { $0.type.utf8.elementsEqual(type.rawValue.utf8) }) {
                unknown[index].count += 1
            } else {
                unknown.append((type.rawValue, 1))
            }
        }
        var parts: [String] = []
        if !unknown.isEmpty {
            parts.append("Types this version doesn't know, shown raw under Other types: "
                         + unknown.map { "\($0.type) (\($0.count.formatted()))" }.joined(separator: ", ") + ".")
        }
        if untyped > 0 {
            parts.append("\(untyped.formatted()) event\(untyped == 1 ? " has" : "s have") no type: only Audit lists \(untyped == 1 ? "it" : "them").")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Why the table shows no rows, in words; nil when it shows some, or while the first page is still coming.
    public var emptyText: String? {
        switch state {
        case .idle, .loading: return nil
        case .notInScope(let why), .unusable(let why): return why
        case .forbidden: if rows.isEmpty { return "Your role can't read the audit log." }
        case .failed(let why): if rows.isEmpty { return why }
        case .loaded: break
        }
        guard shown.isEmpty else { return nil }
        if rows.isEmpty { return applied.summary == nil ? "No events in this range." : "No events in this range match Apple's filters." }
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inPane(pane).isEmpty, !text.isEmpty { return "No event shown matches \"\(text)\"." }
        return "None of the \(rows.count.formatted()) event\(rows.count == 1 ? "" : "s") read is one of this view's types."
    }

    /// The rows a read left before it failed or was refused: shown, and said to be partial.
    public var partialCount: Int? {
        switch state {
        case .failed, .forbidden: rows.isEmpty ? nil : rows.count
        default: nil
        }
    }

    /// Why Export is off, in words; nil when the rows are a whole read, or one the page cap stopped (which the banner
    /// says): every screen's rule (`ScreenWords.exportBlocked`). A partial list is never exported as if it were whole: the
    /// file couldn't say so.
    public var exportBlocked: String? {
        ScreenWords.exportBlocked(state, read: partialCount ?? 0, shown: shown.count, noun: "events")
    }

    /// The CSV of what the table shows: the common attributes (`ExportPolicy.auditEvents`), no payload (invariant 11).
    public func csv() -> String {
        CSV.text(shown.map { CSV.Item($0.event.resource) }, columns: ExportPolicy.auditEvents)
    }

    public var exportName: String {
        switch pane {
        case .audit: "audit-events.csv"
        case .subscriptions: "audit-subscriptions.csv"
        case .deviceLifecycle: "audit-device-lifecycle.csv"
        case .accessAndSecurity: "audit-access-and-security.csv"
        case .other: "audit-other-types.csv"
        }
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R, Apply) and cancels a load
    /// still running. A "last N days" range moves on to now.
    public func load(force: Bool = false) {
        let generation = orgs.generation
        guard force || loadedGeneration != generation || state == .idle else { return }
        reset()
        loadedGeneration = generation
        guard let client = orgs.appleClient else {
            state = .unusable(ScreenWords.unusable(orgs))
            return
        }
        let query: AuditQuery
        do {
            query = try applied.query()
        } catch {
            state = .failed(AuditFilter.words(error))
            return
        }
        self.query = query
        let token = token
        state = .loading(count: 0)
        task = Task { [weak self] in await self?.read(client, query, token: token) }
    }

    // MARK: loading

    private func inPane(_ pane: ActivityPane) -> [ActivityRow] { pane == .audit ? rows : rows.filter { $0.pane == pane } }

    /// The org changed: nothing of the old one stays on screen or in a CSV, its filters go with it, and if anything was
    /// showing the new org is read at once.
    private func orgChanged() {
        let wasShowing = state != .idle
        reset()
        state = .idle
        loadedGeneration = -1
        applied = AuditFilter()
        draft = applied
        problem = nil
        if wasShowing { load() }
    }

    /// Cancels the running load, retires its token, and drops what it read.
    private func reset() {
        task?.cancel()
        task = nil
        token += 1
        rows = []
        truncated = false
        total = nil
        query = nil
        tallies = nil
        selection = nil
    }

    /// Whether the load holding `token` may still write: checked after every page, because a cancelled
    /// `AsyncThrowingStream` loop ends without throwing (failure-log 2026-10-16, "the screen models had no tests").
    private func current(_ token: Int) -> Bool { token == self.token && !Task.isCancelled }

    private func read(_ client: AppleClient, _ query: AuditQuery, token: Int) async {
        defer { readsFinished += 1 }
        do {
            for try await page in client.auditEvents(query) {
                guard current(token) else { return }
                let first = rows.count
                rows += page.items.enumerated().map { ActivityRow($0.element, id: first + $0.offset) }
                truncated = page.truncated
                total = page.total
                state = .loading(count: rows.count)
            }
            guard current(token) else { return }
            tallies = truncated ? nil : Self.tally(rows)
            state = .loaded(at: Date())
        } catch {
            guard current(token) else { return }
            state = LoadState(after: error)
        }
    }

    /// Each pane's counts by type over a whole read: Reports' digest of its view, and for Other types the digest of the
    /// types no view names, those this version doesn't know included.
    static func tally(_ rows: [ActivityRow]) -> [ActivityPane: [Tally]] {
        let events = rows.map(\.event.resource)
        var result: [ActivityPane: [Tally]] = [:]
        for pane in ActivityPane.allCases {
            if let view = pane.view { result[pane] = AuditDigest(events, view: view).counts }
        }
        var other = AuditView.otherTypes
        for row in rows {
            guard let type = row.event.type, type.known == nil, !other.contains(where: { $0.utf8.elementsEqual(type.rawValue.utf8) }) else { continue }
            other.append(type.rawValue)
        }
        result[.other] = AuditDigest(events, types: other).counts
        return result
    }
}
