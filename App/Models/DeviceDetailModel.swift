import AppleBusiness
import AppleModels
import Foundation
import Observation

/// A panel's own result: one panel failing (a role that can't read AppleCare) never blanks the others
/// (SwiftGamGui failure-log 2026-10-13, "load each panel as its own Result").
enum Panel<Value> {
    case loading
    case loaded(Value)
    case forbidden
    case failed(String)
}

/// The Device inspector's ABM half (plan §4): the device with every attribute, its AppleCare, its
/// Activation Lock and its assigned service, each read on its own.
@Observable
final class DeviceDetailModel {
    private(set) var serial: String?
    private(set) var device: Panel<OrgDevice> = .loading
    private(set) var coverage: Panel<[AppleCareCoverage]> = .loading
    private(set) var lock: Panel<ActivationLockStatus> = .loading
    private(set) var service: Panel<MDMService?> = .loading

    private let orgs: OrgsModel
    private var tasks: [Task<Void, Never>] = []

    init(orgs: OrgsModel) { self.orgs = orgs }

    func show(_ serial: String?) {
        tasks.forEach { $0.cancel() }
        tasks = []
        self.serial = serial
        (device, coverage, lock, service) = (.loading, .loading, .loading, .loading)
        guard let serial, let client = orgs.appleClient else { return }
        let generation = orgs.generation
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
                    result = .failed(DevicesModel.message(error))
                }
                guard let self, self.serial == serial, self.orgs.generation == generation else { return }
                assign(result)
            })
        }
        run({ try await client.device(serial) }) { [weak self] in self?.device = $0 }
        run({ try await client.appleCare(serial) }) { [weak self] in self?.coverage = $0 }
        run({ try await client.activationLock(serial) }) { [weak self] in self?.lock = $0 }
        run({ try await client.assignedService(serial) }) { [weak self] in self?.service = $0 }
    }
}
