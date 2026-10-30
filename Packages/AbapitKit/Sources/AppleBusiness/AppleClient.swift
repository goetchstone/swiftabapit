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

    public init(section: AppleSection, status: String) {
        self.section = section
        self.status = status
    }

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

    /// The app's client: Apple over `URLSession`, at the rate this org learned before (`OrgProfile`).
    public init(account: TokenBroker.Account, vault: Vault, readsPerMinute: Double? = nil) {
        self.init(account: account, vault: vault, transport: URLSessionTransport(), limiter: RateLimiter(readsPerMinute: readsPerMinute))
    }

    /// A client over another transport: the demo org's `AppleStub`.
    public init(account: TokenBroker.Account, vault: Vault, transport: any Transport) {
        self.init(account: account, vault: vault, transport: transport, limiter: RateLimiter())
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

    /// The serials assigned to a service: `orgDevices` linkages, each checked.
    public nonisolated func serviceDeviceIDs(_ id: String) -> AsyncThrowingStream<Page<String>, any Error> {
        guard let read = AppleRead.serviceDevices(account.scope, id: id) else { return Self.failed(AppleAPIError.notFound) }
        return pages(read, linkagesOf: OrgDevice.resourceType).map(\.id)
    }

    // MARK: people (Business only)

    public nonisolated func users() -> AsyncThrowingStream<Page<User>, any Error> {
        isBusiness ? pages(AppleRead.users()).map(User.init) : Self.failed(.notInScope(.users))
    }

    public func user(_ id: String) async throws -> User {
        try businessOnly(.users)
        guard let read = AppleRead.user(id: id) else { throw AppleAPIError.notFound }
        return try await User(resource: one(read))
    }

    public nonisolated func userGroups() -> AsyncThrowingStream<Page<UserGroup>, any Error> {
        isBusiness ? pages(AppleRead.userGroups()).map(UserGroup.init) : Self.failed(.notInScope(.userGroups))
    }

    public func userGroup(_ id: String) async throws -> UserGroup {
        try businessOnly(.userGroups)
        guard let read = AppleRead.userGroup(id: id) else { throw AppleAPIError.notFound }
        return try await UserGroup(resource: one(read))
    }

    /// A group's members' ids: `users` linkages, each checked.
    public nonisolated func userGroupMemberIDs(_ id: String) -> AsyncThrowingStream<Page<String>, any Error> {
        guard isBusiness else { return Self.failed(.notInScope(.userGroups)) }
        guard let read = AppleRead.userGroupMembers(id: id) else { return Self.failed(.notFound) }
        return pages(read, linkagesOf: User.resourceType).map(\.id)
    }

    public nonisolated func organizationalUnits() -> AsyncThrowingStream<Page<OrganizationalUnit>, any Error> {
        isBusiness ? pages(AppleRead.organizationalUnits()).map(OrganizationalUnit.init) : Self.failed(.notInScope(.orgUnits))
    }

    public func organizationalUnit(_ id: String) async throws -> OrganizationalUnit {
        try businessOnly(.orgUnits)
        guard let read = AppleRead.organizationalUnit(id: id) else { throw AppleAPIError.notFound }
        return try await OrganizationalUnit(resource: one(read))
    }

    /// An org unit's members' ids: `users` linkages, each checked.
    public nonisolated func organizationalUnitMemberIDs(_ id: String) -> AsyncThrowingStream<Page<String>, any Error> {
        guard isBusiness else { return Self.failed(.notInScope(.orgUnits)) }
        guard let read = AppleRead.organizationalUnitMembers(id: id) else { return Self.failed(.notFound) }
        return pages(read, linkagesOf: User.resourceType).map(\.id)
    }

    // MARK: content (Business only)

    public nonisolated func apps() -> AsyncThrowingStream<Page<ContentApp>, any Error> {
        isBusiness ? pages(AppleRead.apps()).map(ContentApp.init) : Self.failed(.notInScope(.apps))
    }

    public func app(_ id: String) async throws -> ContentApp {
        try businessOnly(.apps)
        guard let read = AppleRead.app(id: id) else { throw AppleAPIError.notFound }
        return try await ContentApp(resource: one(read))
    }

    public nonisolated func packages() -> AsyncThrowingStream<Page<ContentPackage>, any Error> {
        isBusiness ? pages(AppleRead.packages()).map(ContentPackage.init) : Self.failed(.notInScope(.packages))
    }

    public func package(_ id: String) async throws -> ContentPackage {
        try businessOnly(.packages)
        guard let read = AppleRead.package(id: id) else { throw AppleAPIError.notFound }
        return try await ContentPackage(resource: one(read))
    }

    public nonisolated func blueprints() -> AsyncThrowingStream<Page<Blueprint>, any Error> {
        isBusiness ? pages(AppleRead.blueprints()).map(Blueprint.init) : Self.failed(.notInScope(.blueprints))
    }

    /// One blueprint, with the members of `include` (abapit's `blueprint`). Apple refuses the whole read when the role
    /// can't read one of the included relationships (abapit saw a 403 on users and user groups turn into a 400): on a
    /// 400 or a 403, and only when something was included, it is read once more without the include, and the answer
    /// says so (`includeRefused`, invariant 8), never as if the blueprint had no members. Any other failure is thrown,
    /// and so is a failure of the second read.
    public func blueprint(_ id: String, include: Set<Blueprint.Relationship> = []) async throws -> BlueprintRead {
        try businessOnly(.blueprints)
        guard let read = AppleRead.blueprint(id: id, include: include) else { throw AppleAPIError.notFound }
        var document: Document
        var refused: AppleAPIError?
        do {
            document = try await documentOf(read)
        } catch let error as AppleAPIError where !include.isEmpty && Self.refusesInclude(error) {
            guard let bare = AppleRead.blueprint(id: id) else { throw AppleAPIError.notFound }
            document = try await documentOf(bare)
            refused = error
        }
        let blueprint = try Blueprint(resource: Self.resource(of: document, read.template))
        var related: [Blueprint.Relationship: Blueprint.Related] = [:]
        if refused == nil {
            for relationship in include {
                do {
                    related[relationship] = try blueprint.related(relationship)
                } catch {
                    throw AppleAPIError.malformed("the blueprint's \(relationship.rawValue)")
                }
            }
        }
        return BlueprintRead(blueprint: blueprint, related: related, included: refused == nil ? document.included : [], includeRefused: refused)
    }

    /// Apple's answer to an include it won't serve: a 400 (what abapit saw) or a 403. Nothing else is retried.
    static func refusesInclude(_ error: AppleAPIError) -> Bool {
        switch error {
        case .badRequest, .forbidden: true
        default: false
        }
    }

    /// A blueprint's members of one relationship: linkages of its type, each checked.
    public nonisolated func blueprintMemberIDs(_ id: String, _ relationship: Blueprint.Relationship) -> AsyncThrowingStream<Page<String>, any Error> {
        guard isBusiness else { return Self.failed(.notInScope(.blueprints)) }
        guard let read = AppleRead.blueprintMembers(id: id, relationship) else { return Self.failed(.notFound) }
        return pages(read, linkagesOf: relationship.resourceType).map(\.id)
    }

    /// The configurations; a custom setting's profile is null here (`configuration(_:)` reads it).
    public nonisolated func configurations() -> AsyncThrowingStream<Page<Configuration>, any Error> {
        isBusiness ? pages(AppleRead.configurations()).map(Configuration.init) : Self.failed(.notInScope(.configurations))
    }

    /// One configuration: the only read that carries a custom setting's `customSettingsValues`.
    public func configuration(_ id: String) async throws -> Configuration {
        try businessOnly(.configurations)
        guard let read = AppleRead.configuration(id: id) else { throw AppleAPIError.notFound }
        return try await Configuration(resource: one(read))
    }

    // MARK: Apple MDM (Business only)

    public nonisolated func mdmDevices() -> AsyncThrowingStream<Page<MDMDevice>, any Error> {
        isBusiness ? pages(AppleRead.mdmDevices()).map(MDMDevice.init) : Self.failed(.notInScope(.mdmEnrolled))
    }

    /// An Apple-managed device's posture, from the documented `mdmDevices/{id}/details`.
    public func mdmDeviceDetails(_ id: String) async throws -> MDMDeviceDetail {
        try businessOnly(.mdmEnrolled)
        guard let read = AppleRead.mdmDeviceDetails(id: id) else { throw AppleAPIError.notFound }
        return try await MDMDeviceDetail(resource: one(read))
    }

    // MARK: audit (Business only)

    /// The audit log over `query`, as Apple filtered it, a cursor at a time: each next page is this read again with
    /// Apple's `meta.paging.nextCursor`, so the range and the filters go with every page. A cursor Apple gives twice is
    /// malformed, not a loop to the page cap.
    public nonisolated func auditEvents(_ query: AuditQuery) -> AsyncThrowingStream<Page<AuditEvent>, any Error> {
        isBusiness ? pages(AppleRead.auditEvents(query), cursorPaging: true).map(AuditEvent.init) : Self.failed(.notInScope(.auditEvents))
    }

    // MARK: Business only

    /// School has no people, content, Apple MDM or audit endpoints (plan §2.4): asked of a School org, those reads throw
    /// `.notInScope` before anything is built, so nothing is sent.
    nonisolated var isBusiness: Bool { account.scope == .business }

    private func businessOnly(_ section: AppleSection) throws {
        guard isBusiness else { throw AppleAPIError.notInScope(section) }
    }

    private nonisolated static func failed<Item>(_ error: AppleAPIError) -> AsyncThrowingStream<Page<Item>, any Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
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
        for section in probedSections {
            let status: String
            do {
                try await probe(section, now: now)
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

    /// The sections a read probe covers: School has no people, content or audit endpoints.
    nonisolated var probedSections: [AppleSection] { AppleSection.allCases.filter { account.scope == .business || !$0.businessOnly } }

    /// One read probe, `limit=1`. A 2xx that isn't a list is malformed, never "ok" (Phase 1b verifier round 1: a 200
    /// `{}` probe read "ok").
    func probe(_ section: AppleSection, now: Date) async throws {
        let read = AppleRead.probe(scope, section: AppleSectionPath(path: section.path), now: now)
        _ = try await Self.list(documentOf(read), read.template)
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
        try await Self.resource(of: documentOf(read), read.template)
    }

    private static func resource(of document: Document, _ template: String) throws -> Resource {
        guard let resource = document.resource, !resource.id.isEmpty else { throw AppleAPIError.malformed("a single \(template)") }
        return resource
    }

    private func all(_ read: ReadRequest) async throws -> [Resource] {
        var found: [Resource] = []
        for try await page in pages(read) { found += page.items }
        return found
    }

    /// A list page's resources. A 2xx whose `data` isn't an array of resources (`{}`, `null`, one object, an item with no
    /// `type` or `id`, an `errors` body sent with 200) is malformed: read as an empty page it said "none", and the
    /// acceptance pass printed `ok, 0 items` and skipped every per-device read (Phase 1b verifier round 1).
    private static func list(_ document: Document, _ template: String) throws -> [Resource] {
        guard case .array(let items)? = document.data else { throw AppleAPIError.malformed("a page of \(template)") }
        let resources = items.compactMap(Resource.init)
        guard resources.count == items.count else { throw AppleAPIError.malformed("a page of \(template)") }
        return resources
    }

    /// Follows `links.next` (or `meta.paging.nextCursor`) up to the page cap, a page at a time. `cursorPaging` (the audit
    /// log) asks each next page as the first was, with Apple's cursor set, so its required range and filters go with
    /// every page. `linkagesOf` checks every item is a linkage of that type: a member list of another type is malformed,
    /// as an assigned server that isn't one is.
    nonisolated func pages(_ first: ReadRequest, cursorPaging: Bool = false, linkagesOf type: String? = nil)
        -> AsyncThrowingStream<Page<Resource>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.walk(first, cursorPaging: cursorPaging, linkagesOf: type) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func walk(_ first: ReadRequest, cursorPaging: Bool, linkagesOf type: String?, _ yield: (Page<Resource>) -> Void) async throws {
        var response = try await http.read(first, authorizer: broker)
        var number = 1
        // Every next page asked so far: one Apple gives again would walk the same pages to the cap.
        var asked: Set<String> = []
        while true {
            try Task.checkCancellation()
            let document = try document(from: response)
            let items = try Self.list(document, first.template)
            if let type, !items.allSatisfy({ $0.type.utf8.elementsEqual(type.utf8) && !$0.id.isEmpty }) {
                throw AppleAPIError.malformed("linkages of type \(type)")
            }
            let more = document.next != nil || document.nextCursor != nil
            let capped = more && number >= pageCap
            yield(Page(items: items, number: number, truncated: capped, total: document.total))
            guard more, !capped else { return }
            number += 1
            let repeated = AppleAPIError.malformed("a repeated cursor on \(first.template)")
            if cursorPaging {
                // Apple's cursor, or the one its next link carries: never a next link followed, which may drop the filters.
                guard let cursor = document.nextCursor ?? document.next.flatMap(Self.cursor(in:)) else {
                    throw AppleAPIError.malformed("a next page of \(first.template) without a cursor")
                }
                guard asked.insert(cursor).inserted else { throw repeated }
                response = try await http.read(first.setting("cursor", to: cursor), authorizer: broker)
            } else if let next = document.next, let url = URL(string: next) {
                guard asked.insert(next).inserted else { throw repeated }
                response = try await http.read(next: url, on: first.host, template: first.template,
                                               keeping: first.query.first { $0.name == "limit" }?.value, authorizer: broker)
            } else if let cursor = document.nextCursor {
                guard asked.insert(cursor).inserted else { throw repeated }
                response = try await http.read(first.setting("cursor", to: cursor), authorizer: broker)
            } else {
                throw AppleAPIError.notJSON(bytes: 0)
            }
        }
    }

    /// The `cursor` a next link carries.
    private static func cursor(in next: String) -> String? {
        URLComponents(string: next)?.queryItems?.first { $0.name == "cursor" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One blueprint as `AppleClient.blueprint(_:include:)` read it.
public struct BlueprintRead: Sendable {
    public let blueprint: Blueprint
    /// Each included relationship Apple listed, with its linkages and whether the include's limit cut it; one Apple sent
    /// links for only is absent. Empty when the include was refused.
    public let related: [Blueprint.Relationship: Blueprint.Related]
    /// The resources Apple included, in its order.
    public let included: [Resource]
    /// Apple refused the include (a 400 or a 403) and the blueprint was read again without it: its members weren't read,
    /// and the screen says so (invariant 8), with "your role can't read this" for a 403.
    public let includeRefused: AppleAPIError?
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
