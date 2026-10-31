import Foundation
import Observation

/// Apple MDM (Appendix B: "Devices › Apple MDM", abapit's `/mdm-enrolled`): the devices Apple's own MDM enrolls,
/// with each one's posture from the documented `mdmDevices/{id}/details` (plan §2.3, defect 11). Business only. A
/// placeholder the Apple MDM unit fills.
@MainActor
@Observable
public final class AppleMDMModel {
    private let orgs: OrgsModel

    public init(orgs: OrgsModel) {
        self.orgs = orgs
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R).
    public func load(force: Bool = false) {}
}
