import AppleBusiness
import AppleModels
import Foundation
import Observation

/// A panel's own result: one panel failing (a role that can't read AppleCare) never blanks the others
/// (SwiftGamGui failure-log 2026-10-13, "load each panel as its own Result").
public enum Panel<Value> {
    case loading
    case loaded(Value)
    case forbidden
    case failed(String)
}

/// The Device inspector's ABM half (plan §4): the device with every attribute, its AppleCare, its
/// Activation Lock and its assigned service, each read on its own. An org switch empties it at once.
@MainActor
@Observable
public final class DeviceDetailModel {
    public private(set) var serial: String?
    public private(set) var device: Panel<OrgDevice> = .loading
    public private(set) var coverage: Panel<[AppleCareCoverage]> = .loading
    public private(set) var lock: Panel<ActivationLockStatus> = .loading
    public private(set) var service: Panel<MDMService?> = .loading

    private let orgs: OrgsModel
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The current request's token: a read for a device shown before, even the same serial, never lands.
    @ObservationIgnored private var token = 0

    public init(orgs: OrgsModel) {
        self.orgs = orgs
        orgs.onSwitch { [weak self] in self?.show(nil) }
    }

    public func show(_ serial: String?) {
        tasks.forEach { $0.cancel() }
        tasks = []
        token += 1
        self.serial = serial
        (device, coverage, lock, service) = (.loading, .loading, .loading, .loading)
        guard let serial else { return }
        guard let client = orgs.appleClient else {
            // Never a spinner that can't end: why, in words (invariant 8).
            let why = "This organization can't be used: \(orgs.unusableReason ?? "there is none.")"
            (device, coverage, lock, service) = (.failed(why), .failed(why), .failed(why), .failed(why))
            return
        }
        let token = token
        func run<T>(_ read: @escaping @Sendable () async throws -> T, _ assign: @escaping (Panel<T>) -> Void) {
            tasks.append(Task { [weak self] in
                let result: Panel<T>
                do {
                    result = .loaded(try await read())
                } catch is CancellationError {
                    return
                } catch AppleAPIError.forbidden {
                    result = .forbidden
                } catch {
                    result = .failed(OrgsModel.message(error))
                }
                guard let self, self.token == token, !Task.isCancelled else { return }
                assign(result)
            })
        }
        run({ try await client.device(serial) }) { [weak self] in self?.device = $0 }
        run({ try await client.appleCare(serial) }) { [weak self] in self?.coverage = $0 }
        run({ try await client.activationLock(serial) }) { [weak self] in self?.lock = $0 }
        run({ try await client.assignedService(serial) }) { [weak self] in self?.service = $0 }
    }
}
