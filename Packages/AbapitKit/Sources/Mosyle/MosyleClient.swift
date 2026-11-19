import Foundation
import HTTPCore
import JSONAPI
import MosyleModels
import os
import Vault
import Wire

/// A page of Mosyle items as they arrive, with the cap noted (invariant 8). In the device stream `truncated` stays
/// set on every page after a platform was cut, so the last page says so (Phase 7a review L3), and no page is empty.
public struct MosylePage: Sendable {
    public let items: [Resource]
    public let truncated: Bool
}

/// What the device list asks for after Mosyle refused a requested column (`UNKNOWN_COLUMNS`; Phase 7a review H3).
public enum MosyleColumnFallback: Sendable, Equatable {
    /// Every column but these: the ones Mosyle refused, by name or when tried alone, and any left out untried.
    case without([String])
    /// No `specific_columns`: Mosyle refused the columns its doc lists without naming one, or named every column asked
    /// for. The adapter's allowlist is then all that keeps the Activation Lock bypass codes out (invariant 11), as it was
    /// for abapit, which never sent one.
    case everyColumn
}

/// Where the device columns stand once Mosyle refused one, as Settings' Test, the devices' note and a failed read say it:
/// the columns Mosyle refused (named in its answer, or refused when tried alone beside the ones it took), the ones it took,
/// and any left out untried. Names only, each one this app asked for: nothing else from Mosyle's answer.
public struct MosyleColumns: Sendable, Equatable {
    /// In the adapter's order.
    public let refused: [String]
    /// The columns asked for now (never one Mosyle refused, or one still to try); nil once every column is asked for.
    /// Mosyle took them when `answered`.
    public let taken: [String]?
    /// Left out without a verdict, in the adapter's order: this session's tries were spent (`MosyleClient.columnTries`),
    /// Mosyle's answer to a try couldn't be read as the page, or a try failed (the next read tries it again).
    public let untried: [String]
    /// Past this session's tries, Mosyle refused every column asked for by name: a later read asks for the same ones, as
    /// there is nothing smaller to send.
    public let everyAskedRefused: Bool
    /// Mosyle answered a page asked with `taken`: until it does (a refusal moved the columns, or a status answered them),
    /// the words say what the next read asks for, never that Mosyle took it.
    public let answered: Bool

    public init(refused: [String], taken: [String]?, untried: [String], everyAskedRefused: Bool = false, answered: Bool = true) {
        (self.refused, self.taken, self.untried, self.everyAskedRefused, self.answered) = (refused, taken, untried, everyAskedRefused, answered)
    }

    /// What Settings' Test says when Mosyle took every column asked for.
    public static let allTaken = "Mosyle took all \(MosyleAdapter.deviceColumns.count) device columns asked for."

    public var fallback: MosyleColumnFallback {
        taken.map { taken in .without(MosyleAdapter.deviceColumns.filter { !taken.contains($0) }) } ?? .everyColumn
    }

    public var words: String {
        func list(_ names: [String]) -> String {
            names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        var sentences: [String] = []
        if let taken, everyAskedRefused {
            if !refused.isEmpty {
                sentences.append("Mosyle refused the device column\(refused.count == 1 ? " \(list(refused)), so it was" : "s \(list(refused)), so they were") left out of the request.")
            }
            sentences.append((refused.isEmpty ? "Mosyle refused" : "Then it refused") + " all \(taken.count) device columns asked for, by name, once "
                             + "this session's tries were spent; the next read asks for the same \(taken.count), as there is nothing smaller to send.")
        } else if let taken {
            sentences.append(refused.isEmpty ? "Mosyle refused a device column without naming it."
                             : "Mosyle refused the device column\(refused.count == 1 ? " \(list(refused)), so it was" : "s \(list(refused)), so they were") left out of the request.")
            // The columns Mosyle's doc doesn't list are the ones in doubt: which of them Mosyle took is what the live check reads.
            let doubtful = taken.filter(MosyleClient.undocumentedColumns.contains)
            let lead = answered ? "It took " : "The next read asks for "
            sentences.append(taken.isEmpty ? "It took none." : lead + (untried.isEmpty ? "the other \(taken.count)" : "\(taken.count)")
                             + (doubtful.isEmpty ? "." : ", among them \(list(doubtful)), which Mosyle's doc doesn't list."))
        } else {
            sentences.append("Mosyle refused the requested device columns" + (refused.isEmpty ? "" : " (by name: \(list(refused)))")
                             + ", so every column was asked for; only the fields this app keeps are shown.")
        }
        if !untried.isEmpty { sentences.append("Left out untried: \(list(untried)).") }
        return sentences.joined(separator: " ")
    }
}

/// Records read in a shape no source shows (custom device attributes, admin-log entries), cut to the fields this app
/// guesses at, and the names of the fields it didn't read (sorted, unique): a screen says them, so a wrong guess is seen on
/// the first live read, never silent (invariant 8). Only names, never values (invariant 11).
public struct MosyleRecords: Sendable {
    public let items: [Resource]
    public let unread: [String]
    /// Mosyle's own `rows` beside the list, when it sent one: more than `items` holds means the list was cut.
    public let total: Int?
}

/// A device group's members (`get_info`): their UDIDs, as Mosyle lists them, and the group's name.
public struct MosyleGroupMembers: Sendable, Equatable {
    public let name: String?
    public let udids: [String]
}

/// One Mosyle Business org's reads (plan §8, Phase 7). Paging continues until the list's own end-of-list status, an
/// empty page, a page that adds nothing new, or the cap: whether `rows` is the overall total or the page's count is
/// still unconfirmed, and abapit's stop-on-a-short-page lost every row past 50 (defect 2).
public actor MosyleClient {
    public static let defaultPageCap = 200
    private static let log = Logger(subsystem: "io.github.goetchstone.swiftabapit", category: "mosyle")

    /// The adapter's device columns that Mosyle's in-console doc doesn't list as `specific_columns` names (they came from
    /// third-party research), in the adapter's order. Asked for like the others; when Mosyle refuses
    /// a list without naming a column, each is tried alone.
    static let undocumentedColumns = ["enrollment_type", "currentconsolemanageduser", "imei", "meid", "date_enroll", "date_checkin"]
    /// The requests one client may send because Mosyle refused device columns: one to ask again (without the named ones,
    /// for the documented ones, or for every column), and one per undocumented column tried alone. A proposal made with the
    /// fix of 2026-11-19, for the operator to confirm; the operator decided only to try the columns.
    static let columnTries = 1 + undocumentedColumns.count

    public let org: String
    private let session: MosyleSession
    private let pageCap: Int
    /// The device columns asked for: the adapter's, until Mosyle refuses one; nil once every column is asked for. Kept in
    /// memory for the client's life (an org's session), never stored.
    private var deviceColumns: [String]? = MosyleAdapter.deviceColumns
    /// What Mosyle refused, by name or when tried alone, and what was left out untried.
    private var refusedColumns: [String] = [], untriedColumns: [String] = []
    /// Columns Mosyle refused without naming one, still to be tried alone beside the columns it took.
    private var trying: [String] = []
    /// Column lists Mosyle refused: never sent again.
    private var refusedAsks: Set<[String]> = []
    /// Past the tries, Mosyle named every column asked for: a later read asks for the same ones, as nothing smaller can be
    /// sent; cleared by the next answer it takes.
    private var everyAskedRefused = false
    /// Mosyle answered a page asked with `deviceColumns`: false from a refusal until the next page.
    private var columnsAnswered = false
    /// Requests left to send because Mosyle refused columns (`columnTries`).
    private var triesLeft = MosyleClient.columnTries
    /// The tries in flight: every other walk waits for them, so every page carries the columns settled on.
    private var learning: Task<MosyleEnvelope, any Error>?
    /// Set once Mosyle refused a requested device column, so a screen can say which it refused and which it took; nil while
    /// it takes every one.
    public private(set) var columns: MosyleColumns?
    public var columnFallback: MosyleColumnFallback? { columns?.fallback }

    public init(org: String, vault: Vault, transport: any Transport, limiter: RateLimiter = RateLimiter(), pageCap: Int = MosyleClient.defaultPageCap,
                bodyLimit: Int = HTTPClient.bodyLimit, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.org = org
        session = MosyleSession(org: org, service: .business, vault: vault,
                                http: HTTPClient(transport: transport, limiter: limiter, bodyLimit: bodyLimit, sleep: sleep))
        self.pageCap = pageCap
    }

    /// The app's client: Mosyle over `URLSession`.
    public init(org: String, vault: Vault) {
        self.init(org: org, vault: vault, transport: URLSessionTransport())
    }

    public var logins: Int { get async { await session.logins } }

    /// Every device on every platform, adapted through the allowlist, deduplicated by serial (else UDID).
    public nonisolated func devices() -> AsyncThrowingStream<MosylePage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.allDevices { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Every user; `truncated` when the walk stopped at the cap (invariant 8: a cut-off list says so).
    public func users() async throws -> MosylePage {
        try await list({ MosyleRead.users(page: $0) }, keys: ["users"], adapt: MosyleAdapter.user)
    }

    public func userGroups() async throws -> MosylePage {
        try await list({ MosyleRead.userGroups(page: $0) }, keys: ["usergroups", "groups"]) { MosyleAdapter.group($0, kind: "userGroups") }
    }

    /// Device groups are per platform (`os` is required), as abapit read them: iOS, macOS, tvOS.
    public func deviceGroups() async throws -> MosylePage {
        var groups: [Resource] = [], truncated = false
        for os in ["ios", "mac", "tvos"] {
            let page = try await list({ MosyleRead.deviceGroups(os: os, page: $0) }, keys: ["devicegroups", "groups", "device_groups"]) {
                MosyleAdapter.group($0, kind: "deviceGroups")
            }
            groups += page.items
            truncated = truncated || page.truncated
        }
        return MosylePage(items: groups, truncated: truncated)
    }

    /// Every platform's custom device attributes, one read each (not paged). The list may come under any of three names
    /// (a guess each, `Assumed, check live`); anything else, an end status included, is an error, never an empty list.
    public func customAttributes() async throws -> MosyleRecords {
        var items: [Resource] = [], unread: [String] = []
        for os in MosyleRead.platforms {
            let page = try Self.page(try await envelope(MosyleRead.customAttributes(os: os)), ["custom_device_attributes", "attributes", "info"], [])
            guard case .rows(let rows) = page else { continue }
            for row in rows {
                let (item, names) = MosyleAdapter.customAttribute(row, os: os)
                items.append(item)
                unread += names
            }
        }
        return MosyleRecords(items: items, unread: Self.unique(unread), total: nil)
    }

    /// A device group's members, only the compliant or the non-compliant ones when `compliance` says. The answer is an
    /// object (`response.devicegroup`, its `udids` a list of strings: Mosyle's Postman collection); any other shape is
    /// `.malformed`, and a status of its own (a group Mosyle doesn't have) is `.status`.
    public func deviceGroupMembers(_ id: String, compliance: MosyleRead.Compliance? = nil) async throws -> MosyleGroupMembers {
        let envelope = try await envelope(MosyleRead.deviceGroupInfo(id: id, compliance: compliance))
        if let malformed = envelope.malformed { throw MosyleAPIError.malformed(malformed) }
        if let status = envelope.status, status != .known(.ok) { throw MosyleAPIError.status(status, info: envelope.info) }
        guard case .object(let group)? = envelope.entry["devicegroup"] else { throw MosyleAPIError.malformed("it has no devicegroup object") }
        guard case .array(let listed)? = group["udids"] else { throw MosyleAPIError.malformed("its devicegroup has no udids list") }
        let udids = listed.compactMap(\.string)
        guard udids.count == listed.count else { throw MosyleAPIError.malformed("a udid in its devicegroup isn't a string") }
        return MosyleGroupMembers(name: group["name"]?.string, udids: udids)
    }

    /// The admin audit log for the last `days` days (1 to 365), today included, as UTC days: one read, not paged (no
    /// source shows a page). Mosyle's `rows`, when sent, is kept beside the entries, so a cut list can be said.
    public func adminLogs(days: Int, now: Date = Date()) async throws -> MosyleRecords {
        let days = min(max(days, 1), 365)
        let request = MosyleRead.adminLogs(start: Self.day(now.addingTimeInterval(-Double(days - 1) * 86_400)), end: Self.day(now))
        let envelope = try await envelope(request)
        guard case .rows(let rows) = try Self.page(envelope, ["logs", "adminlogs", "admin_logs"], []) else {
            return MosyleRecords(items: [], unread: [], total: envelope.total)
        }
        var items: [Resource] = [], unread: [String] = []
        for row in rows {
            let (item, names) = MosyleAdapter.adminLog(row)
            items.append(item)
            unread += names
        }
        return MosyleRecords(items: items, unread: Self.unique(unread), total: envelope.total)
    }

    /// `YYYY-MM-DD` of `date` in UTC.
    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    static func unique(_ names: [String]) -> [String] {
        var seen: Set<[UInt8]> = []
        return names.filter { seen.insert(Array($0.utf8)).inserted }.sorted(by: Python.precedes)
    }

    /// Settings → Test: a login and the first page of Macs, asked as the device list asks them (its columns, and their
    /// fallback: a ping of `serial_number` alone failed on a refused column where the list degraded and read), so a Test
    /// learns which columns Mosyle takes (`columns`). "ok" only for an answer Mosyle sends, a `devices` list or
    /// `DEVICES_NOTFOUND` (Phase 7a review H2).
    public func ping() async throws {
        _ = try Self.page(try await devicesPage(os: "mac", page: 1), ["devices"], MosyleRead.ends(MosyleRead.devices(os: "mac", page: 1)))
    }

    // MARK: plumbing

    /// abapit's dedupe key, `raw.get("serial_number") or raw.get("deviceudid")`: the first truthy one, so an empty
    /// serial or a zero is no key, and a number is a key as well as a string (Python's `12345` and `"12345"` stay
    /// two). Numbers are keyed as Python's set compares them: `12345`, `12345.0` and `1.2345e4` are one key, and
    /// `true` is `1` (Phase 7a's verification). One deviation, recorded: past `Int`'s range an integer and an equal
    /// float stay two keys, where Python makes them one.
    static func deviceKey(_ raw: JSONObject) -> String? {
        for field in ["serial_number", "deviceudid"] {
            switch raw[field] {
            case .string(let text)? where !text.isEmpty: return "s" + text
            case .number(let text)?: if let key = number(text) { return "n" + key }
            case .bool(true)?: return "n1"
            default: continue
            }
        }
        return nil
    }

    /// A JSON number's value as Python compares it, or nil for a zero (falsy). An integer is exact; a float that is a
    /// whole number in `Int`'s range is that integer; any other float is its shortest spelling, one per `Double`.
    static func number(_ text: String) -> String? {
        if let int = Int(text) { return int == 0 ? nil : String(int) }
        if text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) { return text }
        guard let value = Double(text) else { return text }
        if value == 0 { return nil }
        if value.isFinite, value == value.rounded(), let int = Int(exactly: value) { return String(int) }
        return "\(value)"
    }

    private func allDevices(_ yield: (MosylePage) -> Void) async throws {
        var seen: Set<String> = [], cut = false
        for os in MosyleRead.platforms {
            let ends = MosyleRead.ends(MosyleRead.devices(os: os, page: 1))
            try await walk({ try await self.devicesPage(os: os, page: $0) }, keys: ["devices"], endOfList: ends) { raw, capped in
                let fresh = raw.filter { device in Self.deviceKey(device).map { seen.insert($0).inserted } ?? true }
                guard !fresh.isEmpty else { return false }
                // Once any platform was cut, every later page says so: the screen reads the last one (review L3).
                cut = cut || capped
                yield(MosylePage(items: fresh.map(MosyleAdapter.device), truncated: cut))
                return true
            }
        }
    }

    /// One page of a platform's devices, asking for the adapter's 33 columns until Mosyle refuses one (Phase 7a review H3;
    /// asking for the documented columns, then trying the others, on a refusal that names none is the operator's decision of
    /// 2026-11-19; the rest is proposed, docs/domains/mosyle.md). A refusal is `UNKNOWN_COLUMNS`, inside a 2xx or with HTTP 400 (seen live: a 400 for the
    /// list asking 33 columns, its body unseen), and its names are the strings under `unknown_columns` (its doc's answer)
    /// together with the words of `info`, as one set:
    /// - naming columns asked for, it is asked again without exactly those;
    /// - naming none, it is asked for the columns Mosyle's doc lists (`undocumentedColumns` out); once Mosyle takes those,
    ///   each undocumented one is tried alone beside them (`tryEach`), and the ones it takes are kept for the session;
    /// - naming none when only documented columns were asked, or naming every one, it is asked for every column, as the
    ///   adapter's allowlist still drops what wasn't asked for (failing closed would lose the list).
    /// Each request a refusal brings costs one of `columnTries`; with none left a refusal is the error, naming what Mosyle
    /// named (kept as refused, so a later read asks without it). Every step is an
    /// error-level log line naming the columns (only names this app asked for), and `columns` says it for a screen. An
    /// empty `specific_columns` is never sent (what Mosyle makes of one is unknown).
    private func devicesPage(os: String, page: Int) async throws -> MosyleEnvelope {
        while true {
            // Another walk is trying columns: wait, so this page carries the columns it settles on.
            if let learning { _ = try? await learning.value }
            let asked = deviceColumns
            let envelope = try await envelope(MosyleRead.devices(os: os, page: page, columns: asked))
            // The columns moved while this page was out (another walk's refusal or tries): ask again with them. Every column
            // (nil) is where they end, so a refusal of every column is the read's error.
            if asked != deviceColumns || learning != nil { continue }
            if envelope.status == .known(.unknownColumns), let asked {
                try refuse(asked, envelope)
                continue
            }
            // Only an answer that reads as a page is Mosyle taking the columns asked: a status (SERVICE_BUSY) isn't.
            let read = Self.devicePage(envelope, os: os)
            if read != nil, !columnsAnswered || everyAskedRefused {
                (columnsAnswered, everyAskedRefused) = (true, false)
                // Nothing to say until Mosyle refused a column.
                if columns != nil { note() }
            }
            // Tries start only from a page that reads as one (rows, or the end): a status there is the read's error.
            guard !trying.isEmpty, read != nil else { return envelope }
            let tries = Task { try await self.tryEach(os: os, page: page, envelope) }
            learning = tries
            // The walk that started the tries stops them when it is cancelled; a walk waiting on them then tries the rest.
            return try await withTaskCancellationHandler { try await tries.value } onCancel: { tries.cancel() }
        }
    }

    /// Mosyle refused `asked` (`devicesPage` says what follows each kind of refusal).
    private func refuse(_ asked: [String], _ envelope: MosyleEnvelope) throws {
        refusedAsks.insert(asked)
        columnsAnswered = false
        let named = Self.named(envelope)
        let refused = asked.filter(named.contains), rest = asked.filter { !named.contains($0) }
        defer { note() }
        let earlier = MosyleAdapter.deviceColumns.filter(refusedColumns.contains)
        let before = earlier.isEmpty ? "" : ", after refusing \(earlier.joined(separator: ", "))"
        guard triesLeft > 0 else {
            // No request more. What was still to try is left out. What Mosyle named is kept as refused and a later read asks
            // without it; when it named every column asked for there is nothing smaller to send, so a later read asks for the
            // same ones, and the words and the error say so.
            (untriedColumns, trying) = (untriedColumns + trying, [])
            let spent = "with this session's \(Self.columnTries) tries spent: the read fails"
            if refused.isEmpty {
                Self.log.error("Mosyle refused the \(asked.count) device columns asked for (UNKNOWN_COLUMNS) without naming one this app asked for\(before, privacy: .public), \(spent, privacy: .public)")
                throw MosyleAPIError.columnsRefused([], info: envelope.info)
            }
            if rest.isEmpty {
                everyAskedRefused = true
                Self.log.error("Mosyle refused every one of the \(asked.count) device columns asked for by name (UNKNOWN_COLUMNS)\(before, privacy: .public), \(spent, privacy: .public); the next read asks for the same columns")
                throw MosyleAPIError.everyAskedColumnRefused(count: asked.count, info: envelope.info)
            }
            (refusedColumns, deviceColumns, everyAskedRefused) = (refusedColumns + refused, rest, false)
            Self.log.error("Mosyle refused the device columns \(refused.joined(separator: ", "), privacy: .public) (UNKNOWN_COLUMNS) \(spent, privacy: .public); the next read asks without them")
            throw MosyleAPIError.columnsRefused(refused, info: envelope.info)
        }
        triesLeft -= 1
        let undocumented = asked.filter(Self.undocumentedColumns.contains), documented = asked.filter { !Self.undocumentedColumns.contains($0) }
        if !refused.isEmpty, !rest.isEmpty {
            refusedColumns += refused
            deviceColumns = rest
            Self.log.error("Mosyle refused the device columns \(refused.joined(separator: ", "), privacy: .public) (UNKNOWN_COLUMNS): asking without them")
        } else if refused.isEmpty, !undocumented.isEmpty, !documented.isEmpty {
            // The request adding these together is the one just refused, so each is tried alone once Mosyle takes the rest.
            deviceColumns = documented
            trying = MosyleAdapter.deviceColumns.filter { undocumented.contains($0) || trying.contains($0) }
            Self.log.error("Mosyle refused a device column (UNKNOWN_COLUMNS) without naming one this app asked for: asking for the ones its doc lists, then trying \(undocumented.joined(separator: ", "), privacy: .public) one at a time")
        } else {
            // The columns refused, when Mosyle named any it was asked for: the live check reads which, and a test tells its
            // own line from the lines of the tests running beside it.
            refusedColumns += refused
            let what = refused.isEmpty ? "the \(asked.count) device columns asked for (UNKNOWN_COLUMNS) without naming one\(before)"
                : "the device columns \(refused.joined(separator: ", ")) (UNKNOWN_COLUMNS), every one asked for\(before)"
            deviceColumns = nil
            (trying, untriedColumns) = ([], [])
            Self.log.error("Mosyle refused \(what, privacy: .public): asking for every column; only the adapter's allowlist now keeps the Activation Lock bypass codes out")
        }
    }

    /// Tries each column in `trying` alone beside the columns Mosyle took, on the page just read (which reads as a page),
    /// while tries are left. A column is kept only when Mosyle's answer reads as rows, as many as the page had, or as the
    /// end where the page was the end; a refusal refuses it, and any other answer (another status, fewer or more rows, no
    /// rows where there were rows) leaves it out untried, the page as it was read. A list Mosyle already refused isn't sent again; the one column it would add is the one refused.
    /// Returns the last answer Mosyle took, which asked for every column kept. A cancelled walk stops between tries, and a
    /// request that fails leaves the rest to try on the next read (`columns` says them untried meanwhile).
    private func tryEach(os: String, page: Int, _ answer: MosyleEnvelope) async throws -> MosyleEnvelope {
        var answer = answer, took: [String] = [], refused: [String] = []
        let baseRead = Self.devicePage(answer, os: os)
        defer {
            learning = nil
            note()
            let untried = MosyleAdapter.deviceColumns.filter { self.untriedColumns.contains($0) || self.trying.contains($0) }
            Self.log.error("Mosyle's device columns tried alone: took \(took.isEmpty ? "none" : took.joined(separator: ", "), privacy: .public); refused \(refused.isEmpty ? "none" : refused.joined(separator: ", "), privacy: .public); left untried \(untried.isEmpty ? "none" : untried.joined(separator: ", "), privacy: .public)")
        }
        while let column = trying.first, let base = deviceColumns {
            try Task.checkCancellation()
            let asked = MosyleAdapter.deviceColumns.filter { base.contains($0) || $0 == column }
            if refusedAsks.contains(asked) {
                trying.removeFirst()
                (refusedColumns, refused) = (refusedColumns + [column], refused + [column])
                continue
            }
            guard triesLeft > 0 else {
                untriedColumns += trying
                trying = []
                break
            }
            triesLeft -= 1
            let tried = try await envelope(MosyleRead.devices(os: os, page: page, columns: asked))
            trying.removeFirst()
            if tried.status == .known(.unknownColumns) {
                refusedAsks.insert(asked)
                (refusedColumns, refused) = (refusedColumns + [column], refused + [column])
            } else if Self.samePage(Self.devicePage(tried, os: os), baseRead) {
                (deviceColumns, answer) = (asked, tried)
                took.append(column)
            } else {
                untriedColumns.append(column)
            }
        }
        return answer
    }

    /// The columns as a screen says them: never one Mosyle refused, or one still to try, among those it took.
    private func note() {
        let refused = MosyleAdapter.deviceColumns.filter(refusedColumns.contains)
        columns = MosyleColumns(refused: refused, taken: deviceColumns?.filter { !refused.contains($0) },
                                untried: MosyleAdapter.deviceColumns.filter { untriedColumns.contains($0) || trying.contains($0) },
                                everyAskedRefused: everyAskedRefused, answered: columnsAnswered)
    }

    /// A device list's answer read as a page of `os`'s list (rows, or its end); nil for anything else.
    static func devicePage(_ envelope: MosyleEnvelope, os: String) -> MosyleEnvelope.Page? {
        try? page(envelope, ["devices"], MosyleRead.ends(MosyleRead.devices(os: os, page: 1)))
    }

    /// Whether a try's page is the page read without it: as many rows, or the end where that was the end.
    static func samePage(_ tried: MosyleEnvelope.Page?, _ base: MosyleEnvelope.Page?) -> Bool {
        switch (tried, base) {
        case (.rows(let rows)?, .rows(let had)?): rows.count == had.count
        case (.end?, .end?): true
        default: false
        }
    }

    /// The columns a refusal names: the strings under `unknown_columns` (Mosyle's doc shows the answer so) and the words
    /// of `info` (no source shows a name there), as one set.
    static func named(_ envelope: MosyleEnvelope) -> Set<String> {
        var named = Set(envelope.info?.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init) ?? [])
        if case .array(let listed)? = envelope.entry["unknown_columns"] { named.formUnion(listed.compactMap(\.string)) }
        return named
    }

    /// Every row of a list, adapted and deduplicated by id (by the whole row when it has none): a tenant that wraps
    /// past its end served 60 users as 6000 (Phase 7a review L2), and the page that adds nothing new ends the walk.
    private func list(_ request: (Int) -> ReadRequest, keys: [String], adapt: (JSONObject) -> Resource) async throws -> MosylePage {
        var found: [Resource] = [], seen: Set<String> = [], truncated = false
        try await walk({ try await self.envelope(request($0)) }, keys: keys, endOfList: MosyleRead.ends(request(1))) { rows, capped in
            let fresh = rows.compactMap { row -> Resource? in
                let item = adapt(row)
                return seen.insert(item.id.isEmpty ? "row " + JSONValue.dumps(.object(row)) : "id " + item.id).inserted ? item : nil
            }
            found += fresh
            truncated = capped && !fresh.isEmpty
            return !fresh.isEmpty
        }
        return MosylePage(items: found, truncated: truncated)
    }

    /// Pages from 1 until the list's own end-of-list status, an empty page, a page `take` says added nothing new (a
    /// tenant that ignores `page` or wraps past its end), or the cap; `take` hears whether its page was the cap's.
    private func walk(_ fetch: (Int) async throws -> MosyleEnvelope, keys: [String], endOfList: Set<String>,
                      _ take: ([JSONObject], Bool) -> Bool) async throws {
        var page = 1
        while page <= pageCap {
            try Task.checkCancellation()
            let envelope = try await fetch(page)
            guard case .rows(let rows) = try Self.page(envelope, keys, endOfList) else { return }
            // Mosyle's `rows` beside the page's count: what the Phase 7 live check reads to settle what `rows` means.
            Self.log.info("Mosyle \(keys[0], privacy: .public) page \(page): \(rows.count) rows; its rows field says \(envelope.total ?? -1)")
            guard take(rows, page == pageCap) else { return }
            page += 1
        }
    }

    static func page(_ envelope: MosyleEnvelope, _ keys: [String], _ endOfList: Set<String>) throws -> MosyleEnvelope.Page {
        do {
            return try envelope.read(keys, endOfList: endOfList)
        } catch {
            switch error {
            case .malformed(let reason): throw MosyleAPIError.malformed(reason)
            case .status(let status, let info): throw MosyleAPIError.status(status, info: info)
            }
        }
    }

    /// One request's answer, its HTTP status classified. Internal, not private, so a test can hand it a forged read:
    /// the session checks it as it will be sent and logs in again once for a 401 or a 403 (`MosyleSession.read`).
    /// A refusal of columns (`UNKNOWN_COLUMNS`) is an answer at HTTP 400 as inside a 2xx: a 400 was seen live for the
    /// device list asking 33 columns (2026-11-19, its body unseen), and Mosyle's doc gives a refusal no HTTP code. Any
    /// other 4xx or 5xx is an error carrying Mosyle's own `status` and `info` when its body has them
    /// (`MosyleAPIError.said`); a redirect is not Mosyle's answer, and nothing is read from one.
    func envelope(_ read: ReadRequest) async throws -> MosyleEnvelope {
        let response: HTTPResponse
        do {
            response = try await session.read(read)
        } catch let failure as HTTPFailure {
            throw MosyleAPIError.http(failure)
        }
        if (200..<300).contains(response.status) {
            guard let envelope = Self.answer(response.body) else { throw MosyleAPIError.notJSON(bytes: response.body.count) }
            return envelope
        }
        let error: MosyleAPIError = switch response.status {
        case 401: .unauthorized
        case 403: .forbidden
        case 405: .invalidMethod
        case 429: .rateLimited
        case 500...599: .server(status: response.status)
        default: .unexpected(status: response.status)
        }
        guard (400...599).contains(response.status) else { throw error }
        // Only Mosyle's status code is public, and only when it is shaped as one; its `info` is its own text.
        Self.log.error("Mosyle answered HTTP \(response.status) to \(read.template, privacy: .public), its status \(MosyleAPIError.code(response.body) ?? "none", privacy: .public)")
        if response.status == 400, let refusal = Self.answer(response.body), refusal.status == .known(.unknownColumns) { return refusal }
        throw MosyleAPIError.said(response.body).map { MosyleAPIError.answered(error, said: $0) } ?? error
    }

    /// A body read as Mosyle's envelope. A refusal of columns with no `response` around it (`{"unknown_columns": [...],
    /// "status": "UNKNOWN_COLUMNS", "info": …}`, the three keys of the example in Mosyle's doc) is read as that refusal:
    /// whether Mosyle sends one bare or inside `response` is unseen. Anything else reads as `MosyleEnvelope` reads it.
    static func answer(_ body: Data) -> MosyleEnvelope? {
        guard let envelope = MosyleEnvelope(body) else { return nil }
        guard envelope.entry.isEmpty, let root = JSONValue.parse(String(decoding: body, as: UTF8.self))?.object, root["response"] == nil,
              root["status"]?.string?.utf8.elementsEqual(MosyleStatus.unknownColumns.rawValue.utf8) == true else { return envelope }
        return MosyleEnvelope(Data(JSONValue.dumps(.object(["response": .array([.object(root)])])).utf8))
    }
}
