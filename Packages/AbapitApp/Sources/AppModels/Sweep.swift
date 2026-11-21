import AppleBusiness
import AppleModels
import Foundation
import JSONAPI

/// A per-device sweep a snapshot can run (plan §3.6; docs/domains/history.md, "The sweeps"): one read per device, AppleCare
/// coverage and Activation Lock status for each device in Apple's device list, the details of each Apple-managed device.
///
/// - **Opt-in per run** (`SnapshotCollector.run(sweeps:)`): a snapshot without a sweep has it in neither `counts` nor
///   `errors`, so `SnapshotStore.latest` passes over that snapshot for it.
/// - **Bounded** (invariant 7): at most `inFlight` reads at once, each waiting on the org's rate limiter (the client's,
///   shared with the screens; one throttle event halves its rate and holds it for the server's `Retry-After`), then one pass,
///   a read at a time, over the devices whose read failed: a device is asked at most twice. A 403 stops the sweep (the role
///   can't read it, so every other device would be refused too), `transportBreaker` transport failures in a row stop it
///   (the network is down, not a device), a failure of the key, the token or the account stops the run, and a switch or a
///   cancel stops it at once: no read starts after it, and the reads in flight are cancelled.
/// - **Never silent** (invariant 8): a device not read (its read failed twice, its id can't be sent, the sweep stopped, the
///   device list was cut, its own coverage list was cut) makes the sweep a part read, its items with an error, so `latest`
///   never takes it for a whole one; the note counts the devices not read and why. In a whole sweep, a device with no item
///   was read and had nothing on record (no AppleCare record; Apple's 404 for an Apple-managed device's details, read as
///   "no details" and counted in the note while Apple's meaning is unconfirmed).
public enum Sweep: String, CaseIterable, Sendable {
    /// `orgDevices/{serial}/appleCareCoverage`: each record, with the serial it was read for.
    case appleCare
    /// `orgDevices/{serial}/activationLockStatus`: one item per device, keyed by serial.
    case activationLock
    /// `mdmDevices/{id}/details` for each Apple-managed device (Business only), keyed by the `mdmDevices` id.
    case mdmDetails

    /// Reads at once, at most, per sweep (the sweeps run one after another). The org's rate limiter, which every send waits
    /// on, sets the pace; this bounds what a slow answer can pile up.
    public static let inFlight = 4

    /// Transport failures in a row (no answer: offline, DNS, TLS, a timeout) after which a sweep stops. The client has
    /// already sent each of those reads five times with backoff (`HTTPClient.attempts`), so five in a row is 25 sends
    /// unanswered: the network is down, not a device, and asking every other device would only fail the same way. Recorded as
    /// `transport`; the reads in flight when it trips (three at most) are cancelled.
    public static let transportBreaker = 5

    /// What a snapshot keeps of it.
    public var rule: SnapshotPolicy.Rule {
        switch self {
        case .appleCare: SnapshotPolicy.appleCare
        case .activationLock: SnapshotPolicy.activationLock
        case .mdmDetails: SnapshotPolicy.mdmDetails
        }
    }

    public var title: String {
        switch self {
        case .appleCare: "AppleCare coverage"
        case .activationLock: "Activation Lock"
        case .mdmDetails: "Apple MDM details"
        }
    }

    // MARK: progress and the estimate

    /// How far the sweep running has come: devices answered (read, failed twice, or never sendable) of the devices it covers.
    public struct Progress: Equatable, Sendable {
        public let sweep: Sweep
        public let done: Int
        public let total: Int

        public init(sweep: Sweep, done: Int, total: Int) {
            self.sweep = sweep
            self.done = done
            self.total = total
        }

        public var words: String { "\(sweep.title): \(done) of \(Sweep.devices(total))" }
    }

    /// How long reads take at a rate: an estimate, said as one. The rate is the org's limiter's now (what it learned from
    /// Apple's answers, else its default); the time leaves out Apple's latency, a 429's wait and the second asking of a
    /// device whose read failed.
    public struct Estimate: Equatable, Sendable {
        public let reads: Int
        /// The rate the time is reckoned at, and the one the words say: the one given, held to 1...600 a minute (the
        /// limiter's ceiling; a rate below one a minute, or not a number, reads as one).
        public let readsPerMinute: Double

        public init(reads: Int, readsPerMinute: Double) {
            self.reads = max(0, reads)
            self.readsPerMinute = readsPerMinute.isNaN ? 1 : min(max(readsPerMinute, 1), 600)
        }

        public var seconds: Double { Double(reads) * 60 / readsPerMinute }

        public var words: String {
            guard reads > 0 else { return "Nothing to read." }
            let seconds = seconds, minutes = (seconds / 60).rounded(.up)
            let time = seconds < 60 ? "Under a minute"
                : minutes < 2 ? "About a minute"
                : minutes < 120 ? "About \(Int(minutes)) minutes"
                : "About \(Int(min((minutes / 60).rounded(), 1_000_000))) hours"
            return "\(time): \(reads) read\(reads == 1 ? "" : "s") at about \(Int(readsPerMinute.rounded())) a minute, this organization's rate "
                + "now. An estimate: Apple may slow the reads, and a device whose read fails is asked once more."
        }
    }

    static func devices(_ count: Int) -> String { count == 1 ? "1 device" : "\(count) devices" }

    // MARK: one device's read

    /// Apple answered for another device than the one asked for (details naming another serial, an Activation Lock status
    /// under another id): never kept as this device's (the Apple MDM screen's rule).
    struct AnotherSerial: Error {}

    /// A failure as the sweep records it: the snapshot's code, or the sweep's own word.
    static func code(_ error: any Error) -> String { error is AnotherSerial ? "another serial" : SnapshotPolicy.code(error) }

    /// One device's answer: the items a snapshot keeps of it, before the policy's allowlist.
    struct DeviceRead: Sendable {
        var items: [Resource]
        /// The page cap cut the device's own list (its AppleCare records): what came is kept, and the sweep is a part read.
        var cut = false
        /// Apple answered 404, read as "nothing on record" (the details): counted, so the note says how many.
        var notFound = false
    }

    /// One device's read: what the client returns, under the store's name, keyed as abapit keyed it. `serials` are the
    /// Apple-managed devices' serials by id, for the details' check.
    func reader(_ client: AppleClient, serials: [String: String] = [:]) -> @Sendable (String) async throws -> DeviceRead {
        let name = rule.name
        switch self {
        case .appleCare:
            // A page at a time, so a list the page cap cut is said (`appleCare(_:)` would hand over the part as whole).
            return { serial in
                var records: [AppleCareCoverage] = [], cut = false
                for try await page in client.appleCarePages(serial) {
                    records += page.items
                    cut = cut || page.truncated
                }
                // A list read whose task is cancelled ends without throwing: never "no records".
                try Task.checkCancellation()
                return DeviceRead(items: records.map { Self.coverage($0, serial: serial, as: name) }, cut: cut)
            }
        case .activationLock:
            // A 404 is a failure, never "unlocked": Apple documents a status for every device (docs/domains/history.md).
            return { serial in
                let status = try await client.activationLock(serial)
                // Apple's example keys the status by the device's serial: one under another id is never kept as this device's.
                if !status.resource.id.isEmpty, !status.resource.id.utf8.elementsEqual(serial.utf8) { throw AnotherSerial() }
                return DeviceRead(items: [Resource(type: name, id: serial, attributes: status.resource.attributes)])
            }
        case .mdmDetails:
            return { id in
                let detail: MDMDeviceDetail
                do {
                    detail = try await client.mdmDeviceDetails(id)
                } catch AppleAPIError.notFound {
                    // Read as Apple's "no details on record" (the Apple MDM screen's "No details", the Needs-attention rules'
                    // `.read(nil)`): nothing kept, and counted for the note, since Apple's meaning is unconfirmed.
                    return DeviceRead(items: [], notFound: true)
                }
                if let theirs = detail.serialNumber, let ours = serials[id], !theirs.utf8.elementsEqual(ours.utf8) { throw AnotherSerial() }
                return DeviceRead(items: [Resource(type: name, id: id, attributes: detail.resource.attributes)])
            }
        }
    }

    /// abapit's `fetch_applecare_bulk`: the record with the serial it was read for, under Apple's id, or, when Apple's is
    /// empty, `serial:description` as Python's f-string writes it, for continuity with an imported abapit history: a null
    /// description is `None`, a missing one empty (Apple types it a string; another shape reads as empty here).
    static func coverage(_ coverage: AppleCareCoverage, serial: String, as name: String) -> Resource {
        var attributes = coverage.resource.attributes
        attributes["serialNumber"] = .string(serial)
        guard coverage.resource.id.isEmpty else { return Resource(type: name, id: coverage.resource.id, attributes: attributes) }
        let description: String
        switch attributes["description"] {
        case .null?: description = "None"
        case .string(let text)?: description = text
        default: description = ""
        }
        return Resource(type: name, id: "\(serial):\(description)", attributes: attributes)
    }

    /// AppleCare records whose id more than one device's list carries (Apple's example keys AppleCare+ by its agreement
    /// number, which may cover several devices): each kept as `serial:id`, so no device's record replaces another's in the
    /// store, and nothing is lost. An id one device alone carries keeps Apple's, as abapit kept it, so an id changes only
    /// when its sharing does. The coordinating session's decision (2026-11-21), for the operator to overrule, pending the
    /// live check of whether coverage ids repeat across devices. Returns the items, in order, and how many were rekeyed.
    static func keyedBySerialWhereShared(_ items: [Resource]) -> (items: [Resource], rekeyed: Int) {
        func serial(_ item: Resource) -> String { item.attributes["serialNumber"]?.string ?? "" }
        var serials: [[UInt8]: Set<[UInt8]>] = [:]
        for item in items { serials[Array(item.id.utf8), default: []].insert(Array(serial(item).utf8)) }
        var rekeyed = 0
        let kept = items.map { item -> Resource in
            guard (serials[Array(item.id.utf8)]?.count ?? 0) > 1 else { return item }
            rekeyed += 1
            return Resource(type: item.type, id: "\(serial(item)):\(item.id)", attributes: item.attributes)
        }
        return (kept, rekeyed)
    }

    // MARK: the sweep

    /// What a sweep came to.
    struct Swept {
        /// The items read, device by device in the order asked.
        var items: [Resource] = []
        /// Devices read (with or without items).
        var read = 0
        /// The code of each device whose read failed twice, in the order asked.
        var failed: [String] = []
        /// Devices whose id can't go in a path: never sent.
        var unsendable = 0
        /// Devices not asked, or whose answer wasn't taken, because the sweep stopped.
        var notAsked = 0
        /// Devices read whose own list the page cap cut.
        var cut = 0
        /// Devices read whose answer was a 404 read as "nothing on record" (the details).
        var notFound = 0
        /// The failure that stopped the sweep: a 403 or the transport breaker (this sweep), or a failure of the key, the token
        /// or the account (the run).
        var stop: (any Error)?
    }

    /// Reads each of `ids` (the order kept, a repeated id asked once) through `read`, at most `limit` at once, then once
    /// more, a read at a time, those that failed. An id that can't go in a path is never sent. A 403, `transportBreaker`
    /// transport failures in a row, or a failure of the key, the token or the account stops the asking. `going()` is asked
    /// after every answer: once it is false no read starts, the reads in flight are cancelled, and what they bring isn't
    /// taken. That last part matters: a list read whose task is cancelled ends without throwing (AppleCare's coverage is one),
    /// so a cancelled read could come back as "no records". `answered(done, total)` is called before the first read and
    /// after each device is settled (read, failed twice, or never sendable), so `done` never passes `total`.
    @MainActor
    static func run(_ ids: [String], limit: Int = inFlight, read: @escaping @Sendable (String) async throws -> DeviceRead,
                    going: () -> Bool, answered: (_ done: Int, _ total: Int) -> Void) async -> Swept {
        var seen: Set<[UInt8]> = []
        let unique = ids.filter { seen.insert(Array($0.utf8)).inserted }
        // An id that can't go in a path is never sent: the client would call a device Apple has just listed "no such item".
        let sendable = unique.filter(AppleRead.isPathSafe)
        var swept = Swept(unsendable: unique.count - sendable.count)
        var done = swept.unsendable
        answered(done, unique.count)
        var states: [Device] = Array(repeating: .notAsked, count: sendable.count)
        var retry: [Int] = []
        var unanswered = 0

        /// Takes one answer; false when it stops the asking.
        func take(_ index: Int, _ result: Result<DeviceRead, any Error>, last: Bool) -> Bool {
            switch result {
            case .success(let answer):
                unanswered = 0
                states[index] = .read(answer)
                done += 1
                answered(done, unique.count)
            case .failure(let error):
                unanswered = AppleAPIError.of(error)?.isTransport == true ? unanswered + 1 : 0
                if SnapshotPolicy.stopsTheRun(error) || Self.refused(error) || unanswered >= transportBreaker {
                    swept.stop = error
                    return false
                }
                if last {
                    states[index] = .failed(code(error))
                    done += 1
                    answered(done, unique.count)
                } else {
                    retry.append(index)
                }
            }
            return true
        }

        // The first pass: at most `limit` in flight.
        await withTaskGroup(of: (Int, Result<DeviceRead, any Error>).self) { group in
            var next = 0
            func add(_ group: inout TaskGroup<(Int, Result<DeviceRead, any Error>)>) {
                let index = next, id = sendable[index]
                next += 1
                group.addTask { (index, await Self.attempt(id, read)) }
            }
            while next < min(limit, sendable.count) { add(&group) }
            while let (index, result) = await group.next() {
                guard going(), take(index, result, last: false) else {
                    group.cancelAll()
                    return
                }
                if next < sendable.count { add(&group) }
            }
        }
        // The retry pass: a read at a time, in the list's order, at the limiter's pace (abapit's "gentle, sequential second
        // chance").
        if going(), swept.stop == nil {
            for index in retry.sorted() {
                let result = await attempt(sendable[index], read)
                guard going(), take(index, result, last: true) else { break }
            }
        }
        for state in states {
            switch state {
            case .read(let answer):
                swept.items += answer.items
                swept.read += 1
                if answer.cut { swept.cut += 1 }
                if answer.notFound { swept.notFound += 1 }
            case .failed(let code): swept.failed.append(code)
            case .notAsked: swept.notAsked += 1
            }
        }
        return swept
    }

    /// Where one device stands: read, failed twice, or not (yet) asked to the end. A device whose first read failed and
    /// whose second the sweep never made (it stopped first) is not asked: it was never given its second chance.
    private enum Device {
        case notAsked
        case read(DeviceRead)
        case failed(String)
    }

    /// One read, unless the sweep was cancelled before it started.
    private static func attempt(_ id: String, _ read: @Sendable (String) async throws -> DeviceRead) async -> Result<DeviceRead, any Error> {
        do {
            try Task.checkCancellation()
            return .success(try await read(id))
        } catch {
            return .failure(error)
        }
    }

    /// A 403: the role can't read this for any device.
    static func refused(_ error: any Error) -> Bool {
        if case .forbidden? = error as? AppleAPIError { return true }
        return false
    }
}
