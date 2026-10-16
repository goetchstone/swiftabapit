import Foundation
import HTTPCore
import JSONAPI
import MosyleModels
import Vault
import Wire

/// A page of Mosyle items as they arrive, with the cap noted (invariant 8).
public struct MosylePage: Sendable {
    public let items: [Resource]
    public let truncated: Bool
}

/// One Mosyle Business org's reads (plan §8, Phase 7). Paging continues until a page comes back empty or
/// `DEVICES_NOTFOUND`, or adds nothing new, or hits the cap: whether `rows` is the overall total or the page's
/// count is still unconfirmed, and abapit's stop-on-a-short-page lost every row past 50 (defect 2).
public actor MosyleClient {
    public static let defaultPageCap = 200

    public let org: String
    private let http: HTTPClient
    private let session: MosyleSession
    private let pageCap: Int

    public init(org: String, vault: Vault, transport: any Transport, limiter: RateLimiter = RateLimiter(), pageCap: Int = MosyleClient.defaultPageCap,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.org = org
        let http = HTTPClient(transport: transport, limiter: limiter, sleep: sleep)
        self.http = http
        session = MosyleSession(org: org, service: .business, vault: vault, http: http)
        self.pageCap = pageCap
    }

    public var logins: Int { get async { await session.logins } }

    /// Every device on every platform, adapted through the allowlist, deduplicated by serial (else UDID).
    public nonisolated func devices() -> AsyncThrowingStream<MosylePage, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var seen: Set<String> = []
                    for os in MosyleRead.platforms {
                        try await self.walk({ MosyleRead.devices(os: os, page: $0, columns: MosyleAdapter.deviceColumns) }, keys: ["devices"]) { raw, truncated in
                            let fresh = raw.filter { device in
                                let key = [device["serial_number"], device["deviceudid"]].compactMap { $0?.string }.first { !$0.isEmpty }
                                return key.map { seen.insert($0).inserted } ?? true
                            }
                            continuation.yield(MosylePage(items: fresh.map(MosyleAdapter.device), truncated: truncated))
                            return !fresh.isEmpty
                        }
                    }
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
        let (rows, truncated) = try await all({ MosyleRead.users(page: $0) }, keys: ["users"])
        return MosylePage(items: rows.map(MosyleAdapter.user), truncated: truncated)
    }

    public func userGroups() async throws -> MosylePage {
        let (rows, truncated) = try await all({ MosyleRead.userGroups(page: $0) }, keys: ["usergroups", "groups"])
        return MosylePage(items: rows.map { MosyleAdapter.group($0, kind: "userGroups") }, truncated: truncated)
    }

    /// Device groups are per platform (`os` is required), as abapit read them: iOS, macOS, tvOS.
    public func deviceGroups() async throws -> MosylePage {
        var groups: [Resource] = [], truncated = false
        for os in ["ios", "mac", "tvos"] {
            let (rows, cut) = try await all({ MosyleRead.deviceGroups(os: os, page: $0) }, keys: ["devicegroups", "groups", "device_groups"])
            groups += rows.map { MosyleAdapter.group($0, kind: "deviceGroups") }
            truncated = truncated || cut
        }
        return MosylePage(items: groups, truncated: truncated)
    }

    /// Settings → Test: a login and the smallest list.
    public func ping() async throws {
        _ = try await envelope(MosyleRead.devices(os: "mac", page: 1, columns: ["serial_number"]))
    }

    // MARK: plumbing

    /// Every row of a list, and whether the walk stopped at the cap.
    private func all(_ request: @escaping (Int) -> ReadRequest, keys: [String]) async throws -> ([JSONObject], Bool) {
        var found: [JSONObject] = [], truncated = false
        try await walk(request, keys: keys) { rows, last in
            found += rows
            truncated = last
            return true
        }
        return (found, truncated)
    }

    /// Pages from 1 until an empty page, `DEVICES_NOTFOUND`, a page the same as the one before (a tenant that ignores
    /// `page`), a page `take` says added nothing new, or the cap.
    private func walk(_ request: (Int) -> ReadRequest, keys: [String], _ take: ([JSONObject], Bool) -> Bool) async throws {
        var page = 1, previous: [JSONObject] = []
        while page <= pageCap {
            try Task.checkCancellation()
            let envelope = try await envelope(request(page))
            if envelope.status?.known?.isEndOfList == true { return }
            let rows = keys.lazy.map { envelope.list($0) }.first { !$0.isEmpty } ?? []
            if rows.isEmpty || rows == previous { return }
            guard take(rows, page == pageCap) else { return }
            previous = rows
            page += 1
        }
    }

    private func envelope(_ read: ReadRequest) async throws -> MosyleEnvelope {
        let response: HTTPResponse
        do {
            response = try await http.read(read, authorizer: session)
        } catch let failure as HTTPFailure {
            throw MosyleAPIError.http(failure)
        }
        switch response.status {
        case 200..<300: break
        case 401, 403: throw MosyleAPIError.unauthorized
        case 405: throw MosyleAPIError.invalidMethod
        case 429: throw MosyleAPIError.rateLimited
        case 500...599: throw MosyleAPIError.server(status: response.status)
        default: throw MosyleAPIError.unexpected(status: response.status)
        }
        guard let envelope = MosyleEnvelope(response.body) else { throw MosyleAPIError.notJSON(bytes: response.body.count) }
        if let failure = envelope.failure { throw MosyleAPIError.status(failure, info: envelope.info) }
        return envelope
    }
}
