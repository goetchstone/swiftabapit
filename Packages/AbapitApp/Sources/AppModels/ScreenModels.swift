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
    /// Mosyle Business: its device read is the reconciliation's and Device 360's too.
    public let mosyle: MosyleModel
    /// Counts `devices` and `mosyle`'s devices.
    public let reconciliation: ReconciliationModel
    /// Takes the active Apple org's snapshots into `orgs.history` (Activity › Changes starts one: "Snapshot now").
    public let snapshots: SnapshotCollector
    /// Activity › Changes: the active org's snapshots, two compared, and "Snapshot now".
    public let changes: ChangesModel
    /// Reports: six reports over the active Apple org, from the latest snapshots' sweeps and the Devices model's lists.
    public let reports: ReportsModel
    /// Imports abapit's history into the snapshot store and exports a copy of it (Settings, "History").
    public let historyTransfer: HistoryTransfer

    public init(orgs: OrgsModel) {
        let devices = DevicesModel(orgs: orgs), people = PeopleModel(orgs: orgs)
        self.devices = devices
        mosyle = MosyleModel(orgs: orgs)
        detail = DeviceDetailModel(orgs: orgs, mosyle: mosyle)
        self.people = people
        // A blueprint's members are named from the lists these two have read, never from a read made for it.
        content = ContentModel(orgs: orgs, otherNames: { MemberNames.sources(devices: devices, people: people) },
                               otherPhases: { MemberNames.phases(devices: devices, people: people) })
        appleMDM = AppleMDMModel(orgs: orgs)
        activity = ActivityModel(orgs: orgs)
        dashboard = DashboardModel(orgs: orgs, devices: devices)
        reconciliation = ReconciliationModel(orgs: orgs, devices: devices, mosyle: mosyle)
        snapshots = SnapshotCollector(orgs: orgs)
        changes = ChangesModel(orgs: orgs, collector: snapshots)
        reports = ReportsModel(orgs: orgs, devices: devices)
        historyTransfer = HistoryTransfer(orgs: orgs)
        let collector = snapshots, importer = historyTransfer
        orgs.historyBusy = { [weak collector, weak importer] in
            if collector?.isRunning == true { return "A snapshot is being taken, and it could write to the history after it was deleted. Wait for it to finish, or remove the organization and keep its history." }
            if importer?.isWorking == true { return "A history import or export is running, and it could write to the history after it was deleted. Wait for it to finish, or remove the organization and keep its history." }
            return nil
        }
    }

    /// Refresh (⌘R, the toolbar) on `section`: that section's model reads again from Apple. The Overview reads its devices
    /// and its audit log; services are part of the Devices read; Settings has no read of its own and refreshes the devices, as
    /// every section did in Phase 1. Reports reads the devices again (its migration and service reports are live) and its
    /// snapshots from the local history, which asks Apple for nothing and never starts a sweep.
    public func refresh(_ section: SidebarItem) {
        switch section {
        case .overview: dashboard.load(force: true)
        case .appleMDM: appleMDM.load(force: true)
        case .people: people.load(force: true)
        case .content: content.load(force: true)
        case .activity:
            activity.load(force: true)
            // Changes is local history: reading it again asks Apple for nothing.
            changes.refresh()
        case .mosyle: mosyle.load(force: true)
        case .reconciliation: reconciliation.load(force: true)
        case .reports:
            devices.load(force: true)
            reports.refresh()
        case .devices, .services, .settings: devices.load(force: true)
        }
    }
}
