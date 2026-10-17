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
    /// Every column but the ones Mosyle named.
    case without([String])
    /// No `specific_columns`: Mosyle named none this app asked for, or refused again. The adapter's allowlist is then
    /// all that keeps the Activation Lock bypass codes out (invariant 11), as it was for abapit, which never sent one.
    case everyColumn
}

/// One Mosyle Business org's reads (plan §8, Phase 7). Paging continues until the list's own end-of-list status, an
/// empty page, a page that adds nothing new, or the cap: whether `rows` is the overall total or the page's count is
/// still unconfirmed, and abapit's stop-on-a-short-page lost every row past 50 (defect 2).
public actor MosyleClient {
    public static let defaultPageCap = 200
    private static let log = Logger(subsystem: "io.github.goetchstone.swiftabapit", category: "mosyle")

    public let org: String
    private let session: MosyleSession
    private let pageCap: Int
    /// The device columns asked for: the adapter's, until Mosyle refuses one; nil once every column is asked for.
    private var deviceColumns: [String]? = MosyleAdapter.deviceColumns
    /// Set once Mosyle refused a requested device column, so a screen can say so; nil while every one is accepted.
    public private(set) var columnFallback: MosyleColumnFallback?

    public init(org: String, vault: Vault, transport: any Transport, limiter: RateLimiter = RateLimiter(), pageCap: Int = MosyleClient.defaultPageCap,
                bodyLimit: Int = HTTPClient.bodyLimit, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.org = org
        session = MosyleSession(org: org, service: .business, vault: vault,
                                http: HTTPClient(transport: transport, limiter: limiter, bodyLimit: bodyLimit, sleep: sleep))
        self.pageCap = pageCap
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

    /// Settings → Test: a login and the first page of Macs, asked as the device list asks them (its columns, and their
    /// fallback: a ping of `serial_number` alone failed on a refused column where the list degraded and read). "ok"
    /// only for an answer Mosyle sends, a `devices` list or `DEVICES_NOTFOUND` (Phase 7a review H2).
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

    /// One page of a platform's devices. On `UNKNOWN_COLUMNS` it is asked again: without the columns Mosyle named,
    /// the first time, else without `specific_columns`; a third refusal is the error. No source confirms any of the
    /// names as a `specific_columns` name (abapit sent only `os` and `page`), and one wrong name would fail every
    /// device list on the live tenant (Phase 7a review H3). Failing closed would lose the list, where the adapter's
    /// allowlist still drops what wasn't asked for; so it degrades, and says so in the log and `columnFallback`. An
    /// empty `specific_columns` is never sent (what Mosyle makes of one is unknown): with nothing left, every column.
    private func devicesPage(os: String, page: Int) async throws -> MosyleEnvelope {
        while true {
            let asked = deviceColumns
            let envelope = try await envelope(MosyleRead.devices(os: os, page: page, columns: asked))
            guard envelope.status == .known(.unknownColumns), let asked else { return envelope }
            // Another walk degraded the columns while this page was out: ask again with what it settled on.
            if asked != deviceColumns { continue }
            let named = Set(envelope.info?.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init) ?? [])
            let refused = asked.filter(named.contains), rest = asked.filter { !named.contains($0) }
            if columnFallback == nil, !refused.isEmpty, !rest.isEmpty {
                deviceColumns = rest
                columnFallback = .without(refused)
                Self.log.error("Mosyle refused the device columns \(refused.joined(separator: ", "), privacy: .public) (UNKNOWN_COLUMNS): asking without them")
            } else {
                // The columns refused, when Mosyle named any it was asked for: the live check reads which, and a test
                // tells its own line from the lines of the tests running beside it.
                let what = refused.isEmpty ? "a device column (UNKNOWN_COLUMNS) without naming one this app asked for"
                    : "the device columns \(refused.joined(separator: ", ")) (UNKNOWN_COLUMNS)" + (columnFallback == nil ? ", every one asked for" : " after an earlier fallback")
                deviceColumns = nil
                columnFallback = .everyColumn
                Self.log.error("Mosyle refused \(what, privacy: .public): asking for every column; only the adapter's allowlist now keeps the Activation Lock bypass codes out")
            }
        }
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
    func envelope(_ read: ReadRequest) async throws -> MosyleEnvelope {
        let response: HTTPResponse
        do {
            response = try await session.read(read)
        } catch let failure as HTTPFailure {
            throw MosyleAPIError.http(failure)
        }
        switch response.status {
        case 200..<300: break
        case 401: throw MosyleAPIError.unauthorized
        case 403: throw MosyleAPIError.forbidden
        case 405: throw MosyleAPIError.invalidMethod
        case 429: throw MosyleAPIError.rateLimited
        case 500...599: throw MosyleAPIError.server(status: response.status)
        default: throw MosyleAPIError.unexpected(status: response.status)
        }
        guard let envelope = MosyleEnvelope(response.body) else { throw MosyleAPIError.notJSON(bytes: response.body.count) }
        return envelope
    }
}
