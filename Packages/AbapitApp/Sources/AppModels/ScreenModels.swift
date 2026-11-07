import Foundation

/// Every screen model over one `OrgsModel`, made in one order (so their switch handlers run in it too), and what Refresh
/// reads for each sidebar section. The app's `AppServices` and the tests' `World` both build them here, so the routing is
/// held by `swift test`: in the app's `ContentView` it had no test target, and routing People's Refresh to the devices
/// (Phase 2b review L10, mutant X1) left every suite green.
@MainActor
public final class ScreenModels {
    public let devices: DevicesModel
    public let detail: DeviceDetailModel
    public let people: PeopleModel
    public let content: ContentModel
    public let appleMDM: AppleMDMModel
    public let activity: ActivityModel
    /// Counts `devices`: one device read for the Devices screen and the Dashboard.
    public let dashboard: DashboardModel

    public init(orgs: OrgsModel) {
        devices = DevicesModel(orgs: orgs)
        detail = DeviceDetailModel(orgs: orgs)
        people = PeopleModel(orgs: orgs)
        content = ContentModel(orgs: orgs)
        appleMDM = AppleMDMModel(orgs: orgs)
        activity = ActivityModel(orgs: orgs)
        dashboard = DashboardModel(orgs: orgs, devices: devices)
    }

    /// Refresh (⌘R, the toolbar) on `section`: that section's model reads again from Apple. The Overview reads its devices
    /// and its audit log; services are part of the Devices read; Reports and Settings have no read of their own yet and
    /// refresh the devices, as every section did in Phase 1.
    public func refresh(_ section: SidebarItem) {
        switch section {
        case .overview: dashboard.load(force: true)
        case .appleMDM: appleMDM.load(force: true)
        case .people: people.load(force: true)
        case .content: content.load(force: true)
        case .activity: activity.load(force: true)
        case .devices, .services, .reports, .settings: devices.load(force: true)
        }
    }
}
