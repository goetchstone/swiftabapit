import Foundation
import Observation

/// Overview › Dashboard (plan §8 Phase 2; Appendix B): counts by family and status, added per month, per service,
/// unassigned, services not connected in N days, recent audit events. It counts what the Devices screen reads: the
/// device list is read once for both, and its states (`devicesReadWhole`, `unassignedCount`, `quietServices`, the
/// services' panel) are the ones Phase 1's review rounds made honest, so a dash is never a zero here either. It reads
/// only what that screen doesn't (the recent audit events, Business only: a School org's panel says not in scope). A
/// placeholder the dashboard unit fills; until then its load is the Devices read, as Phase 1's Overview was.
@MainActor
@Observable
public final class DashboardModel {
    /// The devices and services the dashboard counts: the Devices screen's own model, not a copy.
    public let devices: DevicesModel
    private let orgs: OrgsModel

    public init(orgs: OrgsModel, devices: DevicesModel) {
        self.orgs = orgs
        self.devices = devices
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R), the devices too.
    public func load(force: Bool = false) {
        devices.load(force: force)
    }
}
