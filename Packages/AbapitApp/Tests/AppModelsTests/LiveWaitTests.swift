import AppleBusiness
import AppModels
import Foundation
import JSONAPI
import Mosyle
import Orgs
import Synchronization
import Testing
import TestSupport

/// Waiting for a live read (the operator, 2026-11-24: an intent may start the screen's own live read, never a sweep, and wait up to a
/// time limit; a read under 15 minutes old is reused, and its age is said). Over the strict stubs, the bound on a manual timer: each
/// list ends whole, in part (the page cap, a failure after rows), not read (403, a dropped connection, a revoked account, no Mosyle
/// org) or still being read (a hold or a `Retry-After` past the bound); a switch answers nothing; a cancel or a timeout stops the wait,
/// never the read; two requests share one read; a fresh held read is reused with its age and a stale one read again once; and no
/// per-device path is ever asked.
@MainActor
@Suite("Live wait", .serialized, .timeLimit(.minutes(1)))
struct LiveWaitTests {
    /// Org `a` with two services, ADEV0000000 on S1 and ADEV0000001 on S2; Mosyle org `m` (when `mosyle`) with two Macs.
    static func world(devices: Int = 3, pageCap: Int = AppleClient.defaultPageCap, mosyle: Bool = true, mosylePageCap: Int = MosyleClient.defaultPageCap,
                      appleSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) async throws -> World {
        let world = try await World.make(devices: ["a": devices, "b": 2], pageCap: pageCap, mosyle: mosyle, mosylePageCap: mosylePageCap,
                                         appleSleep: appleSleep)
        let stub = world.stubs["a"]!
        stub.add(services: [World.service("S1", name: "One"), World.service("S2", name: "Two")])
        stub.assign("ADEV0000000", to: "S1")
        stub.assign("ADEV0000001", to: "S2")
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000"), MosyleScreenTests.device("MAC1")], os: "mac")
        return world
    }

    static func waiter(_ world: World, _ timer: ManualTimer, now: @escaping @MainActor () -> Date = { Date() }) -> LiveWait {
        LiveWait(orgs: world.orgs, devices: world.devices, mosyle: world.mosyle, now: now, sleep: { try await timer.sleep($0) })
    }

    static let all = Set(LiveWait.List.allCases)

    static func ends(_ outcome: LiveWait.Outcome) -> [LiveWait.List: LiveWait.End] {
        if case .lists(let ends) = outcome { return ends }
        Issue.record("not answered: \(outcome)")
        return [:]
    }

    static func loadedAt(_ state: LoadState) -> Date? { if case .loaded(let at) = state { at } else { nil } }

    /// A request's outcome; when the test is cancelled (its time limit), the request is too, so a wait that never ends fails the test
    /// instead of hanging the run.
    static func outcome(_ request: Task<LiveWait.Outcome, Never>) async -> LiveWait.Outcome {
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    /// Requests to `path` exactly (any query), as the Apple stub saw them.
    static func count(_ stub: AppleStub, _ path: String) -> Int { stub.requests.filter { Self.path(of: $0) == path }.count }

    static func path(of request: String) -> String {
        let target = request.split(separator: " ")[1]
        return String(target.drop { $0 != "/" }.prefix { $0 != "?" })
    }

    /// How many times Mosyle's device list was walked: each walk starts at iOS's first page.
    static func mosyleWalks(_ world: World) -> Int {
        world.mosyleStub.bodies.filter { $0["operation"]?.string == "list" && $0["options"]?["os"]?.string == "ios" && $0["options"]?["page"]?.int == 1 }.count
    }

    /// Nothing but the lists' own reads: Apple's token, devices, services and each service's device list; Mosyle's login and device
    /// list. Never a device's own path (a sweep's AppleCare, Activation Lock or assigned server), never any other list.
    static func expectOnlyListReads(_ world: World, sourceLocation: SourceLocation = #_sourceLocation) {
        for (org, stub) in world.stubs {
            for request in stub.requests {
                let method = request.split(separator: " ")[0], path = Self.path(of: request)
                let segments = path.split(separator: "/")
                let listed = method == "POST" ? path == "/auth/oauth2/token"
                    : method == "GET" && (path == "/v1/orgDevices" || path == "/v1/mdmServers"
                        || (segments.count == 5 && segments[1] == "mdmServers" && segments[3] == "relationships" && segments[4] == "devices"))
                #expect(listed, "org \(org) was asked \(request)", sourceLocation: sourceLocation)
            }
        }
        for request in world.mosyleStub.requests {
            let parts = request.split(separator: " ")
            let listed = parts.count >= 2 && parts[0] == "POST"
                && (Self.path(of: request) == "/v1/login" || (Self.path(of: request) == "/v1/devices" && parts.count == 3 && parts[2] == "list"))
            #expect(listed, "Mosyle was asked \(request)", sourceLocation: sourceLocation)
        }
    }

    // MARK: whole, in part, not read

    /// Nothing read yet: each list is read with its screen's own read, and the wait ends when they end, long before the bound.
    @Test func everyListIsReadAndEndsWhole() async throws {
        let world = try await Self.world()
        let timer = ManualTimer()
        let ends = Self.ends(await Self.waiter(world, timer).lists(Self.all))
        let apple = try #require(Self.loadedAt(world.devices.state)), services = try #require(Self.loadedAt(world.devices.servicesState))
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        #expect(ends == [.appleDevices: .whole(at: apple), .appleServices: .whole(at: services), .mosyleDevices: .whole(at: mosyle)])
        #expect(world.devices.rows.count == 3 && world.mosyle.devices.rows.count == 2)
        let stub = world.stubs["a"]!
        #expect(Self.count(stub, "/v1/orgDevices") == 1 && Self.count(stub, "/v1/mdmServers") == 1 && Self.mosyleWalks(world) == 1)
        // The bound's sleep ended with the wait.
        #expect(timer.sleeping == 0)
        Self.expectOnlyListReads(world)
    }

    /// The page cap: in part, said as the screens say it ("showing N of ≥M"), at the time the read ended. A service whose device list
    /// was cut makes the services in part too.
    @Test func aListCutAtThePageCapIsInPartAndSaysSo() async throws {
        let world = try await Self.world(devices: 1002, pageCap: 1, mosylePageCap: 1)
        let stub = world.stubs["a"]!
        stub.reportTotals()
        // S1 holds 1,001 devices: a second page, which the cap stops.
        for index in 2..<1002 { stub.assign(String(format: "ADEV%07d", index), to: "S1") }
        world.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists(Self.all))
        let apple = try #require(Self.loadedAt(world.devices.state)), services = try #require(Self.loadedAt(world.devices.servicesState))
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        #expect(ends[.appleDevices] == .partly("showing 1,000 of 1,002: the list stopped at the page limit", at: apple))
        #expect(ends[.appleServices] == .partly("the device list of 1 of 2 services wasn't read whole", at: services))
        #expect(ends[.mosyleDevices] == .partly("showing 50 devices: the list stopped at the page limit", at: mosyle))
        Self.expectOnlyListReads(world)
    }

    /// A 403: "your role can't read …", for the devices and the services alike.
    @Test func a403SaysTheRoleCantRead() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/orgDevices")
        world.stubs["a"]!.forbid("/v1/mdmServers")
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists([.appleDevices, .appleServices]))
        #expect(ends == [.appleDevices: .notRead("your role can't read devices"),
                         .appleServices: .notRead("your role can't read device management services")])
        // A refusal held is a read that stopped: the next request asks again, once.
        #expect(Self.ends(await Self.waiter(world, ManualTimer()).lists([.appleDevices])) == [.appleDevices: .notRead("your role can't read devices")])
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 2)
        Self.expectOnlyListReads(world)
    }

    /// A dropped connection, every try: not read, in the screen's words.
    @Test func aDroppedConnectionIsNotReadAndSaysWhy() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.failTransport(100)
        world.mosyleStub.failTransport(100)
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists(Self.all))
        guard case .failed(let apple) = world.devices.state, case .failed(let services) = world.devices.servicesState,
              case .failed(let mosyle) = world.mosyle.devices.state else {
            Issue.record("\(world.devices.state) \(world.devices.servicesState) \(world.mosyle.devices.state)")
            return
        }
        #expect(!apple.isEmpty && !mosyle.isEmpty)
        #expect(ends == [.appleDevices: .notRead(apple), .appleServices: .notRead(services), .mosyleDevices: .notRead(mosyle)])
        Self.expectOnlyListReads(world)
    }

    /// A revoked account (every request 401, a fresh token or login doesn't help): not read, and why.
    @Test func aRevokedAccountIsNotReadAndSaysWhy() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.revokeAccount()
        world.mosyleStub.revoke()
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists([.appleDevices, .mosyleDevices]))
        guard case .failed(let apple) = world.devices.state, case .failed(let mosyle) = world.mosyle.devices.state else {
            Issue.record("\(world.devices.state) \(world.mosyle.devices.state)")
            return
        }
        #expect(ends == [.appleDevices: .notRead(apple), .mosyleDevices: .notRead(mosyle)])
        Self.expectOnlyListReads(world)
    }

    /// A read that fails after rows: in part, with the rows read and why, at the time it stopped.
    @Test func aFailureAfterRowsIsInPartAtTheTimeItStopped() async throws {
        let world = try await Self.world(devices: 1001)
        world.stubs["a"]!.queue(500, for: "/v1/orgDevices?limit=1000&cursor=")
        world.mosyleStub.add(devices: (0..<60).map { MosyleScreenTests.device(String(format: "MAC%03d", $0)) }, os: "mac")
        world.mosyleStub.queue(500, for: "/v1/devices", page: 2)
        // The model's own clock is far from the devices' stop times: a part read's time is the model's, never the wait's.
        let ends = Self.ends(await Self.waiter(world, ManualTimer(), now: { Date(timeIntervalSince1970: 0) }).lists([.appleDevices, .mosyleDevices]))
        guard case .failed(let apple) = world.devices.state, case .failed(let mosyle) = world.mosyle.devices.state else {
            Issue.record("\(world.devices.state) \(world.mosyle.devices.state)")
            return
        }
        let appleAt = try #require(world.devices.devicesStoppedAt), mosyleAt = try #require(world.mosyle.devicesStoppedAt)
        #expect(ends == [.appleDevices: .partly("the read failed after 1,000 devices: \(apple)", at: appleAt),
                         .mosyleDevices: .partly("the read failed after 50 devices: \(mosyle)", at: mosyleAt)])
        Self.expectOnlyListReads(world)
    }

    /// No Mosyle org: not read, in the Mosyle screen's words, and Mosyle is asked nothing.
    @Test func noMosyleOrgIsNotReadAndMosyleIsAskedNothing() async throws {
        let world = try await Self.world(mosyle: false)
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists([.mosyleDevices]))
        #expect(ends == [.mosyleDevices: .notRead(MosyleScreenTests.notPaired)])
        #expect(world.mosyleStub.requests.isEmpty && world.mosyle.devices.state == .idle)
    }

    /// The Mosyle org active: Apple's lists can't be read here, said as the Devices screen says it, and Apple is asked nothing.
    @Test func appleListsOfAMosyleOrgAreNotRead() async throws {
        let world = try await Self.world()
        world.orgs.select("m")
        let ends = Self.ends(await Self.waiter(world, ManualTimer()).lists(Self.all))
        guard case .unusable(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        #expect(ends == [.appleDevices: .notRead(why), .appleServices: .notRead(why), .mosyleDevices: .whole(at: mosyle)])
        #expect(world.stubs.values.allSatisfy { $0.requests.isEmpty })
        Self.expectOnlyListReads(world)
    }

    // MARK: the bound

    /// A 429 whose `Retry-After` (60 s) outlasts the bound (25 s): still being read at the bound, and the read goes on to its end.
    @Test func aRetryAfterPastTheBoundIsStillReadingAndTheReadGoesOn() async throws {
        let timer = ManualTimer()
        let world = try await Self.world(appleSleep: { try await timer.sleep($0) })
        world.stubs["a"]!.queue(429, for: "/v1/orgDevices", headers: ["Retry-After": "60"])
        let wait = Self.waiter(world, timer)
        let request = Task { await wait.lists([.appleDevices]) }
        // The bound's sleep and the client's wait for Apple's minute.
        await eventually("both sleeps") { timer.sleeping == 2 }
        timer.advance(.seconds(25))
        #expect(await Self.outcome(request) == .lists([.appleDevices: .stillReading(after: .seconds(25))]))
        #expect(world.devices.state.isLoading)
        timer.advance(.seconds(35))
        await eventually("the read's end") { Self.loadedAt(world.devices.state) != nil }
        #expect(world.devices.rows.count == 3 && Self.count(world.stubs["a"]!, "/v1/orgDevices") == 2)
        Self.expectOnlyListReads(world)
    }

    /// A page held past the bound: that list is still being read, the others have ended; the read is never stopped, and lands.
    @Test func aPageHeldPastTheBoundIsStillReadingAndTheReadLands() async throws {
        let world = try await Self.world()
        let timer = ManualTimer()
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.mosyleStub.holdRequests(to: "/v1/devices", fromPage: 1)
        let wait = Self.waiter(world, timer)
        let request = Task { await wait.lists(Self.all) }
        await eventually("held, the services read, the bound's sleep") {
            world.gates["a"]!.held == 1 && Self.loadedAt(world.devices.servicesState) != nil && timer.sleeping == 1
                && world.mosyleStub.requests.contains { $0.hasSuffix("/v1/devices list") }
        }
        timer.advance(.seconds(24))
        #expect(timer.sleeping == 1)
        timer.advance(.seconds(1))
        let services = try #require(Self.loadedAt(world.devices.servicesState))
        #expect(await Self.outcome(request) == .lists([.appleDevices: .stillReading(after: .seconds(25)), .appleServices: .whole(at: services),
                                               .mosyleDevices: .stillReading(after: .seconds(25))]))
        world.gates["a"]!.release("devices")
        world.mosyleStub.release()
        await eventually("the reads' end") { Self.loadedAt(world.devices.state) != nil && Self.loadedAt(world.mosyle.devices.state) != nil }
        #expect(world.devices.rows.count == 3 && world.mosyle.devices.rows.count == 2)
        // The held page was answered, never asked again.
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 1 && Self.mosyleWalks(world) == 1)
        Self.expectOnlyListReads(world)
    }

    /// The bound is the caller's: a shorter one ends the wait sooner.
    @Test func theBoundIsTheCallers() async throws {
        let world = try await Self.world()
        let timer = ManualTimer()
        world.gates["a"]!.hold("devices", Gate.devicePages)
        let wait = Self.waiter(world, timer)
        let request = Task { await wait.lists([.appleDevices], bound: .seconds(3)) }
        await eventually("held") { world.gates["a"]!.held == 1 && timer.sleeping == 1 }
        timer.advance(.seconds(3))
        #expect(await Self.outcome(request) == .lists([.appleDevices: .stillReading(after: .seconds(3))]))
        world.gates["a"]!.release("devices")
    }

    // MARK: a switch, a cancel

    /// A switch of org while the wait is under way: nothing of either org is answered, at once (b's read is held too, and the bound's
    /// clock never moves), and the new org's read is the screen's.
    @Test func aSwitchMidWaitAnswersNothing() async throws {
        let world = try await Self.world()
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.gates["b"]!.hold("devices", Gate.devicePages)
        let wait = Self.waiter(world, ManualTimer())
        let request = Task { await wait.lists(Self.all) }
        await eventually("held") { world.gates["a"]!.held == 1 }
        world.orgs.select("b")
        #expect(await Self.outcome(request) == .switched)
        world.gates["a"]!.release("devices")
        world.gates["b"]!.release("devices")
        await eventually("b's devices") { Self.loadedAt(world.devices.state) != nil }
        #expect(world.devices.rows.allSatisfy { $0.serial.hasPrefix("BDEV") })
        Self.expectOnlyListReads(world)
    }

    /// The same at the moment the reads are started (a hook, as the other models' `afterRead`).
    @Test func aSwitchAsTheReadsStartAnswersNothing() async throws {
        let world = try await Self.world()
        let wait = Self.waiter(world, ManualTimer())
        wait.afterStart = { world.orgs.select("b") }
        #expect(await wait.lists(Self.all) == .switched)
        Self.expectOnlyListReads(world)
    }

    /// A cancel while the wait is under way: the wait ends, the bound's sleep with it, and the read goes on and lands.
    @Test func aCancelMidWaitStopsTheWaitNotTheRead() async throws {
        let world = try await Self.world()
        let timer = ManualTimer()
        world.gates["a"]!.hold("devices", Gate.devicePages)
        let wait = Self.waiter(world, timer)
        let request = Task { await wait.lists([.appleDevices]) }
        await eventually("held") { world.gates["a"]!.held == 1 && timer.sleeping == 1 }
        request.cancel()
        #expect(await Self.outcome(request) == .cancelled)
        #expect(timer.sleeping == 0 && world.devices.state.isLoading)
        world.gates["a"]!.release("devices")
        await eventually("the read's end") { Self.loadedAt(world.devices.state) != nil }
        #expect(world.devices.rows.count == 3 && Self.count(world.stubs["a"]!, "/v1/orgDevices") == 1)
        Self.expectOnlyListReads(world)
    }

    /// The same at the moment the reads are started: the read it started lands.
    @Test func aCancelAsTheReadsStartStopsTheWaitNotTheRead() async throws {
        let world = try await Self.world()
        let wait = Self.waiter(world, ManualTimer())
        wait.afterStart = { withUnsafeCurrentTask { $0?.cancel() } }
        let request = Task { await wait.lists([.appleDevices, .mosyleDevices]) }
        #expect(await Self.outcome(request) == .cancelled)
        await eventually("the reads' end") { Self.loadedAt(world.devices.state) != nil && Self.loadedAt(world.mosyle.devices.state) != nil }
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 1 && Self.mosyleWalks(world) == 1)
    }

    /// A request cancelled before it starts reads nothing.
    @Test func aCancelledRequestReadsNothing() async throws {
        let world = try await Self.world()
        let wait = Self.waiter(world, ManualTimer())
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await wait.lists(Self.all)
        }
        #expect(await Self.outcome(request) == .cancelled)
        #expect(world.devices.state == .idle && world.mosyle.devices.state == .idle && world.stubs["a"]!.requests.isEmpty)
    }

    // MARK: sharing a read

    /// Two requests at once share one read: the second finds it under way and waits on it.
    @Test func twoWaitersShareOneRead() async throws {
        let world = try await Self.world()
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.mosyleStub.holdRequests(to: "/v1/devices", fromPage: 1)
        let first = Self.waiter(world, ManualTimer()), second = Self.waiter(world, ManualTimer())
        let one = Task { await first.lists(Self.all) }
        await eventually("held") { world.gates["a"]!.held == 1 && world.mosyleStub.requests.contains { $0.hasSuffix("/v1/devices list") } }
        let two = Task { await second.lists(Self.all) }
        world.gates["a"]!.release("devices")
        world.mosyleStub.release()
        let (a, b) = (await Self.outcome(one), await Self.outcome(two))
        let apple = try #require(Self.loadedAt(world.devices.state)), services = try #require(Self.loadedAt(world.devices.servicesState))
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        let whole = LiveWait.Outcome.lists([.appleDevices: .whole(at: apple), .appleServices: .whole(at: services), .mosyleDevices: .whole(at: mosyle)])
        #expect(a == whole && b == whole)
        let stub = world.stubs["a"]!
        #expect(Self.count(stub, "/v1/orgDevices") == 1 && Self.count(stub, "/v1/mdmServers") == 1 && Self.mosyleWalks(world) == 1)
        Self.expectOnlyListReads(world)
    }

    /// A read under way is never restarted, even when a list it already ended (the services, refused) would be read again on its own:
    /// the request waits on that read.
    @Test func aReadUnderWayIsSharedNeverRestarted() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/mdmServers")
        world.gates["a"]!.hold("devices", Gate.devicePages)
        world.devices.load()
        await eventually("services refused, devices held") { world.devices.servicesState == .forbidden && world.gates["a"]!.held == 1 }
        let wait = Self.waiter(world, ManualTimer())
        let request = Task { await wait.lists([.appleDevices, .appleServices]) }
        await eventually("waiting") { world.gates["a"]!.held == 1 }
        world.gates["a"]!.release("devices")
        let apple = Self.ends(await Self.outcome(request))
        let at = try #require(Self.loadedAt(world.devices.state))
        #expect(apple == [.appleDevices: .whole(at: at), .appleServices: .notRead("your role can't read device management services")])
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 1 && Self.count(world.stubs["a"]!, "/v1/mdmServers") == 1)
    }

    // MARK: fresh and stale

    /// A held read under `fresh` old is answered as it is, with its time and its age, and nothing is read again.
    @Test func aFreshHeldReadIsReusedWithItsAge() async throws {
        let world = try await Self.world()
        world.devices.load()
        world.mosyle.loadDevices()
        await eventually("the screens' reads") {
            Self.loadedAt(world.devices.servicesState) != nil && Self.loadedAt(world.devices.state) != nil && Self.loadedAt(world.mosyle.devices.state) != nil
        }
        let apple = try #require(Self.loadedAt(world.devices.state)), services = try #require(Self.loadedAt(world.devices.servicesState))
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        let requests = (world.stubs["a"]!.requests.count, world.mosyleStub.requests.count)
        for minutes in [5.0, 14.9] {
            let now = max(apple, services, mosyle).addingTimeInterval(minutes * 60)
            let ends = Self.ends(await Self.waiter(world, ManualTimer(), now: { now }).lists(Self.all))
            #expect(ends == [.appleDevices: .whole(at: apple), .appleServices: .whole(at: services), .mosyleDevices: .whole(at: mosyle)])
            #expect(ends[.appleDevices]?.words(now: apple.addingTimeInterval(5 * 60)) == "read in full 5 minutes ago")
        }
        #expect((world.stubs["a"]!.requests.count, world.mosyleStub.requests.count) == requests)
    }

    /// A held read older than `fresh` is read again, once, with the screen's own read; `fresh` is the caller's.
    @Test func aStaleHeldReadIsReadAgainOnce() async throws {
        let world = try await Self.world()
        world.devices.load()
        world.mosyle.loadDevices()
        await eventually("the screens' reads") {
            Self.loadedAt(world.devices.servicesState) != nil && Self.loadedAt(world.devices.state) != nil && Self.loadedAt(world.mosyle.devices.state) != nil
        }
        let held = try #require(Self.loadedAt(world.devices.state))
        // Fifteen minutes and a little: stale. Under a shorter `fresh`, a minute is stale too.
        let ends = Self.ends(await Self.waiter(world, ManualTimer(), now: { held.addingTimeInterval(15 * 60 + 1) }).lists(Self.all))
        let apple = try #require(Self.loadedAt(world.devices.state)), mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        #expect(apple > held && ends[.appleDevices] == .whole(at: apple) && ends[.mosyleDevices] == .whole(at: mosyle))
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 2 && Self.count(world.stubs["a"]!, "/v1/mdmServers") == 2 && Self.mosyleWalks(world) == 2)
        let again = try #require(Self.loadedAt(world.devices.state))
        _ = await Self.waiter(world, ManualTimer(), now: { again.addingTimeInterval(61) }).lists([.appleDevices], fresh: .seconds(60))
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 3 && Self.mosyleWalks(world) == 2)
        Self.expectOnlyListReads(world)
    }

    /// A held read that stopped on an error is read again once; a read that fails then is said, not tried again in that request.
    @Test func aStoppedReadIsReadAgainOnceAndNeverRetried() async throws {
        let world = try await Self.world()
        let stub = world.stubs["a"]!
        stub.queue(500, for: "/v1/orgDevices")
        stub.queue(500, for: "/v1/orgDevices")
        world.devices.load()
        // The screen's whole read ended: the devices failed, the services were read (a read still under way is shared, not restarted).
        await eventually("the screen's read failed") {
            if case .failed = world.devices.state { Self.loadedAt(world.devices.servicesState) != nil } else { false }
        }
        let failed = Self.ends(await Self.waiter(world, ManualTimer()).lists([.appleDevices]))
        guard case .failed(let why) = world.devices.state else {
            Issue.record("\(world.devices.state)")
            return
        }
        #expect(failed == [.appleDevices: .notRead(why)] && Self.count(stub, "/v1/orgDevices") == 2)
        // A later request reads the devices again, once that read's services have ended.
        await eventually("the services read again") { Self.count(stub, "/v1/mdmServers") == 2 && Self.loadedAt(world.devices.servicesState) != nil }
        // The services are fresh, the devices failed: one of them is enough to read again.
        let read = Self.ends(await Self.waiter(world, ManualTimer()).lists([.appleDevices, .appleServices]))
        let apple = try #require(Self.loadedAt(world.devices.state)), services = try #require(Self.loadedAt(world.devices.servicesState))
        #expect(read == [.appleDevices: .whole(at: apple), .appleServices: .whole(at: services)] && Self.count(stub, "/v1/orgDevices") == 3)
        Self.expectOnlyListReads(world)
    }

    /// Each end is the one seen when its list ended: a screen's Refresh right after the wait (here a read started again and held) never
    /// turns a fast 403 into "still being read".
    @Test func anEndIsTheOneSeenWhenItsListEnded() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/orgDevices")
        let wait = Self.waiter(world, ManualTimer())
        wait.afterWait = {
            world.gates["a"]!.hold("devices", Gate.devicePages)
            world.devices.load(force: true)
        }
        let request = Task { await wait.lists([.appleDevices]) }
        #expect(await Self.outcome(request) == .lists([.appleDevices: .notRead("your role can't read devices")]))
        #expect(world.devices.state.isLoading)
        world.gates["a"]!.release("devices")
    }

    /// Mosyle's device list is read again alone: the tab on screen (users), the selected group and its members stay as the screen has
    /// them, and nothing but the device list is asked.
    @Test func aMosyleReadAgainReadsTheDeviceListAlone() async throws {
        let world = try await Self.world()
        world.mosyleStub.add(deviceGroups: [["iddevicegroup": .string("G1"), "name": .string("Group")]], os: "mac")
        world.mosyle.tab = .users
        world.mosyle.load()
        world.mosyle.selectedGroup = "G1"
        await eventually("the Mosyle screen's reads") {
            Self.loadedAt(world.mosyle.devices.state) != nil && Self.loadedAt(world.mosyle.users.state) != nil && world.mosyle.members.readsFinished >= 1
        }
        let held = try #require(Self.loadedAt(world.mosyle.devices.state)), users = world.mosyle.users.state
        let (before, members) = (world.mosyleStub.requests.count, world.mosyle.members.readsFinished)
        let ends = Self.ends(await Self.waiter(world, ManualTimer(), now: { held.addingTimeInterval(16 * 60) }).lists([.mosyleDevices]))
        let mosyle = try #require(Self.loadedAt(world.mosyle.devices.state))
        #expect(mosyle > held && ends == [.mosyleDevices: .whole(at: mosyle)])
        #expect(world.mosyle.users.state == users && world.mosyle.selectedGroup == "G1" && world.mosyle.members.readsFinished == members)
        let asked = world.mosyleStub.requests.dropFirst(before)
        #expect(!asked.isEmpty && asked.allSatisfy { $0.hasSuffix("/v1/devices list") }, "\(Array(asked))")
        #expect(world.stubs["a"]!.requests.isEmpty)
    }

    /// A read stamped after now (the clock was set back) is read again, never reused as "less than a minute ago".
    @Test func aReadFromAfterNowIsReadAgain() async throws {
        let world = try await Self.world()
        world.devices.load()
        world.mosyle.loadDevices()
        await eventually("the screens' reads") {
            Self.loadedAt(world.devices.servicesState) != nil && Self.loadedAt(world.devices.state) != nil && Self.loadedAt(world.mosyle.devices.state) != nil
        }
        let held = try #require(Self.loadedAt(world.devices.state))
        let ends = Self.ends(await Self.waiter(world, ManualTimer(), now: { held.addingTimeInterval(-60) }).lists(Self.all))
        let apple = try #require(Self.loadedAt(world.devices.state))
        #expect(apple > held && ends[.appleDevices] == .whole(at: apple))
        #expect(Self.count(world.stubs["a"]!, "/v1/orgDevices") == 2 && Self.mosyleWalks(world) == 2)
        Self.expectOnlyListReads(world)
    }

    // MARK: words

    @Test func eachEndSaysItselfWithItsAge() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(59)) == "read in full less than a minute ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(60)) == "read in full 1 minute ago")
        #expect(LiveWait.End.partly("showing 1,000 of 1,001: the list stopped at the page limit", at: at).words(now: at.addingTimeInterval(14 * 60))
            == "read in part 14 minutes ago: showing 1,000 of 1,001: the list stopped at the page limit")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(59 * 60 + 59)) == "read in full 59 minutes ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(60 * 60)) == "read in full 1 hour ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(119 * 60)) == "read in full 1 hour ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(47 * 3600)) == "read in full 47 hours ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(48 * 3600)) == "read in full 2 days ago")
        #expect(LiveWait.End.whole(at: at).words(now: at.addingTimeInterval(-3600)) == "read in full less than a minute ago")
        #expect(LiveWait.End.notRead("your role can't read devices").words(now: at) == "not read: your role can't read devices")
        #expect(LiveWait.End.stillReading(after: .seconds(25)).words(now: at) == "still being read after 25 seconds")
        #expect(LiveWait.bound == .seconds(25) && LiveWait.fresh == .seconds(900))
    }
}

/// The bound's clock in these tests (as `ManualClock` moves only the limiter's): a sleep returns once the test moves the timer past
/// its end, and throws when its task is cancelled.
final class ManualTimer: Sendable {
    private struct Sleeper {
        let end: Duration
        let wake: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Duration.zero
        var sleepers: [Int: Sleeper] = [:]
        var cancelled: Set<Int> = []
        var next = 0
    }

    private let state = Mutex(State())

    /// Sleeps not yet ended.
    var sleeping: Int { state.withLock { $0.sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state in
            defer { state.next += 1 }
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (wake: CheckedContinuation<Void, any Error>) in
                let now: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.contains(id) { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    state.sleepers[id] = Sleeper(end: state.now + duration, wake: wake)
                    return nil
                }
                if let now { wake.resume(with: now) }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                state.cancelled.insert(id)
                return state.sleepers.removeValue(forKey: id)
            }
            sleeper?.wake.resume(throwing: CancellationError())
        }
    }

    func advance(_ by: Duration) {
        let due = state.withLock { state in
            state.now += by
            let due = state.sleepers.filter { $0.value.end <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.wake)
        }
        for wake in due { wake.resume() }
    }
}
