import AppleModels
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Vault
import Wire

/// One page of a collection, as it arrives: tables fill progressively. `truncated` is set on the last page
/// when the page cap stopped the walk with more to come, so the UI says "showing N of ≥M" (invariant 8).
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let number: Int
    public let truncated: Bool
    /// Apple's `meta.paging.total`, when it gives one.
    public let total: Int?
}

/// What a read probe found for one section: abapit's `probe_capabilities` rows.
public struct ProbeResult: Sendable, Equatable {
    public let section: AppleSection
    public let status: String

    public static let ok = "ok", forbidden = "forbidden"
}

/// The reads of one Apple Business or Apple School Manager org (plan §8, Phase 1). Reads only: the writes
/// go through ChangeCore in Phase 4.
public actor AppleClient {
    /// Pages walked before a list stops and says so (plan §3.3).
    public static let defaultPageCap = 200

    public let account: TokenBroker.Account
    private let http: HTTPClient
    private let broker: TokenBroker
    private let pageCap: Int

    public init(account: TokenBroker.Account, vault: Vault, transport: any Transport, limiter: RateLimiter,
                pageCap: Int = AppleClient.defaultPageCap, bodyLimit: Int = HTTPClient.bodyLimit, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.account = account
        let http = HTTPClient(transport: transport, limiter: limiter, bodyLimit: bodyLimit, sleep: sleep, clock: now)
        self.http = http
        broker = TokenBroker(account: account, vault: vault, http: http, now: now)
        self.pageCap = pageCap
    }

    var scope: Scope { account.scope }

    /// Tokens minted so far (tests).
    public var mints: Int { get async { await broker.mints } }

    // MARK: devices

    public nonisolated func devices() -> AsyncThrowingStream<Page<OrgDevice>, any Error> {
        pages(AppleRead.devices(account.scope)).map(OrgDevice.init)
    }

    public func device(_ serial: String) async throws -> OrgDevice {
        guard let read = AppleRead.device(scope, serial: serial) else { throw AppleAPIError.notFound }
        return try await OrgDevice(resource: one(read))
    }

    public func appleCare(_ serial: String) async throws -> [AppleCareCoverage] {
        guard let read = AppleRead.appleCare(scope, serial: serial) else { throw AppleAPIError.notFound }
        return try await all(read).map(AppleCareCoverage.init)
    }

    public func activationLock(_ serial: String) async throws -> ActivationLockStatus {
        guard let read = AppleRead.activationLock(scope, serial: serial) else { throw AppleAPIError.notFound }
        return try await ActivationLockStatus(resource: one(read))
    }

    /// The service the device is assigned to; nil when it is unassigned (Apple answers 404).
    public func assignedService(_ serial: String) async throws -> MDMService? {
        guard let read = AppleRead.assignedService(scope, serial: serial) else { throw AppleAPIError.notFound }
        let document: Document
        do {
            document = try await documentOf(read)
        } catch AppleAPIError.notFound {
            return nil
        }
        if case .null? = document.data { return nil }
        guard let resource = document.resource, resource.type == MDMService.resourceType, !resource.id.isEmpty else {
            throw AppleAPIError.malformed("an assigned server")
        }
        return MDMService(resource: resource)
    }

    /// The assigned service's id alone (a linkage); nil when unassigned.
    /// The assigned service's id alone (a linkage); nil when unassigned: a 404, or an explicit `"data": null`.
    /// Anything else that isn't an `mdmServers` linkage throws: the Guard re-validates assignments with this read.
    public func assignedServiceID(_ serial: String) async throws -> String? {
        guard let read = AppleRead.assignedServiceID(scope, serial: serial) else { throw AppleAPIError.notFound }
        let document: Document
        do {
            document = try await documentOf(read)
        } catch AppleAPIError.notFound {
            return nil
        }
        switch document.data {
        case .null?: return nil
        case let value?:
            guard let linkage = Linkage(value), linkage.type == "mdmServers", !linkage.id.isEmpty else {
                throw AppleAPIError.malformed("an assigned-server linkage")
            }
            return linkage.id
        case nil: throw AppleAPIError.malformed("an assigned-server linkage")
        }
    }

    // MARK: device management services

    public nonisolated func services() -> AsyncThrowingStream<Page<MDMService>, any Error> {
        pages(AppleRead.services(account.scope)).map(MDMService.init)
    }

    public func service(_ id: String) async throws -> MDMService {
        guard let read = AppleRead.service(scope, id: id) else { throw AppleAPIError.notFound }
        return try await MDMService(resource: one(read))
    }

    /// The serials assigned to a service.
    public nonisolated func serviceDeviceIDs(_ id: String) -> AsyncThrowingStream<Page<String>, any Error> {
        guard let read = AppleRead.serviceDevices(account.scope, id: id) else {
            return AsyncThrowingStream { $0.finish(throwing: AppleAPIError.notFound) }
        }
        return pages(read).map(\.id)
    }

    // MARK: probes and health

    /// Settings → Test: one cheap read that proves the key, the token and the network.
    public func ping() async throws {
        _ = try await documentOf(AppleRead.probe(scope, section: AppleSectionPath(path: AppleSection.devices.path), now: Date()))
    }

    /// Settings → Permissions, reads half: each section the scope has, `limit=1` (abapit's `READ_PROBES`). A 403
    /// is "forbidden"; anything else that fails is "error <status>". Apple has no permissions endpoint.
    public func probeReads(now: Date = Date()) async -> [ProbeResult] {
        var results: [ProbeResult] = []
        for section in AppleSection.allCases where scope == .business || !section.businessOnly {
            let status: String
            do {
                _ = try await documentOf(AppleRead.probe(scope, section: AppleSectionPath(path: section.path), now: now))
                status = ProbeResult.ok
            } catch AppleAPIError.forbidden {
                status = ProbeResult.forbidden
            } catch let error as AppleAPIError {
                status = Self.probeStatus(error)
            } catch {
                status = "error"
            }
            results.append(ProbeResult(section: section, status: status))
        }
        return results
    }

    static func probeStatus(_ error: AppleAPIError) -> String {
        switch error {
        case .unauthorized: "error 401"
        case .notFound: "error 404"
        case .conflict: "error 409"
        case .unprocessable: "error 422"
        case .badRequest: "error 400"
        case .rateLimited: "error 429"
        case .server(let status), .unexpected(let status): "error \(status)"
        case .malformed: "error malformed"
        default: "error"
        }
    }

    /// The rate the limiter learned, for the org's profile.
    public var learnedReadsPerMinute: Double { get async { await http.learnedReadsPerMinute } }

    // MARK: plumbing

    private func documentOf(_ read: ReadRequest) async throws -> Document {
        try await document(from: http.read(read, authorizer: broker))
    }

    private func document(from response: HTTPResponse) throws -> Document {
        guard response.isSuccess else { throw AppleAPIError(response) }
        do {
            return try Document.parse(response.body)
        } catch Document.Failure.notJSON(let bytes) {
            throw AppleAPIError.notJSON(bytes: bytes)
        }
    }

    /// The single resource a `GET …/{id}` returns. A 2xx without one is malformed, never "not found": only Apple's
    /// 404 says that.
    private func one(_ read: ReadRequest) async throws -> Resource {
        guard let resource = try await documentOf(read).resource, !resource.id.isEmpty else {
            throw AppleAPIError.malformed("a single \(read.template)")
        }
        return resource
    }

    private func all(_ read: ReadRequest) async throws -> [Resource] {
        var found: [Resource] = []
        for try await page in pages(read) { found += page.items }
        return found
    }

    /// Follows `links.next` (or `meta.paging.nextCursor`) up to the page cap, a page at a time.
    nonisolated func pages(_ first: ReadRequest) -> AsyncThrowingStream<Page<Resource>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.walk(first) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func walk(_ first: ReadRequest, _ yield: (Page<Resource>) -> Void) async throws {
        var response = try await http.read(first, authorizer: broker)
        var number = 1
        while true {
            try Task.checkCancellation()
            let document = try document(from: response)
            let more = document.next != nil || document.nextCursor != nil
            let capped = more && number >= pageCap
            yield(Page(items: document.resources, number: number, truncated: capped, total: document.total))
            guard more, !capped else { return }
            number += 1
            if let next = document.next, let url = URL(string: next) {
                response = try await http.read(next: url, on: first.host, template: first.template,
                                               keeping: first.query.first { $0.name == "limit" }?.value, authorizer: broker)
            } else if let cursor = document.nextCursor {
                response = try await http.read(first.setting("cursor", to: cursor), authorizer: broker)
            } else {
                throw AppleAPIError.notJSON(bytes: 0)
            }
        }
    }
}

extension AsyncThrowingStream where Element == Page<Resource>, Failure == any Error {
    /// The same pages, each item turned into `transform`'s view.
    func map<T: Sendable>(_ transform: @escaping @Sendable (Resource) -> T) -> AsyncThrowingStream<Page<T>, any Error> {
        AsyncThrowingStream<Page<T>, any Error> { continuation in
            let task = Task {
                do {
                    for try await page in self {
                        continuation.yield(Page(items: page.items.map(transform), number: page.number, truncated: page.truncated, total: page.total))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
