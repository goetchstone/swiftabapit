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
///   shared with the screens; a 429 halves its rate and holds it for Apple's `Retry-After`), then one pass, a read at a time,
///   over the devices whose read failed: a device is asked at most twice. A 403 stops the sweep (the role can't read it, so
///   every other device would be refused too), a failure of the key, the token or the account stops the run, and a switch or
///   a cancel stops it at once: no read starts after it, and the reads in flight are cancelled.
/// - **Never silent** (invariant 8): a device not read (its read failed twice, its id can't be sent, the sweep stopped, the
///   device list was cut) makes the sweep a part read, its items with an error, so `latest` never takes it for a whole one;
///   the note counts the devices not read and why. In a whole sweep, a device with no item was read and had nothing on
///   record (no AppleCare record; Apple's 404 for an Apple-managed device's details, "no details").
public enum Sweep: String, CaseIterable, Sendable {
    /// `orgDevices/{serial}/appleCareCoverage`: each record, with the serial it was read for.
    case appleCare
    /// `orgDevices/{serial}/activationLockStatus`: one item per device, keyed by serial.
    case activationLock
    /// `mdmDevices/{id}/details` for each Apple-managed device (Business only), keyed by the `mdmDevices` id.
    case mdmDetails

    /// Reads at once, at most. The org's rate limiter sets the pace; this bounds what a slow answer can pile up.
    public static let inFlight = 4

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
        public let readsPerMinute: Double

        public init(reads: Int, readsPerMinute: Double) {
            self.reads = reads
            self.readsPerMinute = readsPerMinute
        }

        /// At the rate (the limiter never goes below 2 a minute; one a minute stands in for a rate that isn't one).
        public var seconds: Double {
            let rate = readsPerMinute.isFinite && readsPerMinute >= 1 ? readsPerMinute : 1
            return Double(reads) * 60 / rate
        }

        public var words: String {
            guard reads > 0 else { return "Nothing to read." }
            let minutes = Int((seconds / 60).rounded(.up))
            let time = minutes <= 1 ? "About a minute" : minutes < 120 ? "About \(minutes) minutes" : "About \(Int((Double(minutes) / 60).rounded())) hours"
            let rate = readsPerMinute.isFinite ? Int(readsPerMinute.rounded()) : 0
            return "\(time): \(reads) read\(reads == 1 ? "" : "s") at about \(rate) a minute, this organization's rate now. An estimate: "
                + "Apple may slow the reads, and a device whose read fails is asked once more."
        }
    }

    static func devices(_ count: Int) -> String { count == 1 ? "1 device" : "\(count) devices" }

    // MARK: one device's read

    /// Apple's details named another serial than the device asked for: never kept as this device's (the Apple MDM screen's
    /// rule).
    struct AnotherSerial: Error {}

    /// A failure as the sweep records it: the snapshot's code, or the sweep's own word.
    static func code(_ error: any Error) -> String { error is AnotherSerial ? "another serial" : SnapshotPolicy.code(error) }

    /// One device's read, as the items a snapshot keeps before the policy's allowlist: what the client returns, under the
    /// store's name, keyed as abapit keyed it. `serials` are the Apple-managed devices' serials by id, for the details' check.
    func reader(_ client: AppleClient, serials: [String: String] = [:]) -> @Sendable (String) async throws -> [Resource] {
        let name = rule.name
        switch self {
        case .appleCare:
            // abapit's `fetch_applecare_bulk`: every record, the serial added, its id Apple's or `serial:description`.
            return { serial in
                try await client.appleCare(serial).map { coverage in
                    var attributes = coverage.resource.attributes
                    attributes["serialNumber"] = .string(serial)
                    let id = coverage.resource.id.isEmpty ? "\(serial):\(coverage.summary ?? "")" : coverage.resource.id
                    return Resource(type: name, id: id, attributes: attributes)
                }
            }
        case .activationLock:
            // A 404 is a failure, never "unlocked": Apple documents a status for every device (docs/domains/history.md).
            return { serial in [Resource(type: name, id: serial, attributes: try await client.activationLock(serial).resource.attributes)] }
        case .mdmDetails:
            return { id in
                let detail: MDMDeviceDetail
                do {
                    detail = try await client.mdmDeviceDetails(id)
                } catch AppleAPIError.notFound {
                    // Apple's "no details on record" (the Apple MDM screen's "No details"): read, nothing kept.
                    return []
                }
                if let theirs = detail.serialNumber, let ours = serials[id], !theirs.utf8.elementsEqual(ours.utf8) { throw AnotherSerial() }
                return [Resource(type: name, id: id, attributes: detail.resource.attributes)]
            }
        }
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
        /// The failure that stopped the sweep: a 403 (this sweep), or a failure of the key, the token or the account (the run).
        var stop: (any Error)?
    }

    /// Reads each of `ids` (the order kept, a repeated id asked once) through `read`, at most `limit` at once, then once
    /// more, a read at a time, those that failed. An id that can't go in a path is never sent. A 403 or a failure of the key,
    /// the token or the account stops the asking. `going()` is asked after every answer: once it is false no read starts,
    /// the reads in flight are cancelled, and what they bring isn't taken. `answered(done, total)` is called before the first
    /// read and after each device is settled (read, failed twice, or never sendable).
    @MainActor
    static func run(_ ids: [String], limit: Int = inFlight, read: @escaping @Sendable (String) async throws -> [Resource],
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

        /// Takes one answer; false when it stops the asking.
        func take(_ index: Int, _ result: Result<[Resource], any Error>, last: Bool) -> Bool {
            switch result {
            case .success(let items):
                states[index] = .read(items)
                done += 1
                answered(done, unique.count)
            case .failure(let error):
                if SnapshotPolicy.stopsTheRun(error) || Self.refused(error) {
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
        await withTaskGroup(of: (Int, Result<[Resource], any Error>).self) { group in
            var next = 0
            func add(_ group: inout TaskGroup<(Int, Result<[Resource], any Error>)>) {
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
            case .read(let items):
                swept.items += items
                swept.read += 1
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
        case read([Resource])
        case failed(String)
    }

    /// One read, unless the sweep was cancelled before it started.
    private static func attempt(_ id: String, _ read: @Sendable (String) async throws -> [Resource]) async -> Result<[Resource], any Error> {
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
