import AppleBusiness
import AppModels
import Foundation
import Mosyle
import Orgs
import Vault
#if DEBUG
import TestSupport
#endif

/// The app's long-lived services, built once at launch (adapted from SwiftGamGui App/AppServices.swift
/// @ bfdb494): the Keychain and `orgs.json` for real use; memory and the strict stub for the demo.
final class AppServices {
    let orgs: OrgsModel
    /// Every screen model over the one `orgs`, so an org switch reaches each (`OrgsModel.onSwitch`), and each section's
    /// Refresh (`ScreenModels.refresh`). The tests' `World` builds the same `ScreenModels`.
    let screens: ScreenModels
    let isDemo: Bool

    var devices: DevicesModel { screens.devices }
    var detail: DeviceDetailModel { screens.detail }
    var people: PeopleModel { screens.people }
    var content: ContentModel { screens.content }
    var appleMDM: AppleMDMModel { screens.appleMDM }
    var activity: ActivityModel { screens.activity }
    /// Counts `devices`: one device read for the Devices screen and the Dashboard.
    var dashboard: DashboardModel { screens.dashboard }

    private init(orgs: OrgsModel, isDemo: Bool) {
        self.orgs = orgs
        screens = ScreenModels(orgs: orgs)
        self.isDemo = isDemo
    }

    /// The folder the app keeps its files in: inside the sandbox container. Injected everywhere, never read
    /// from a global by the package (SwiftGamGui failure-log 2026-09-25).
    static var storageRoot: URL { URL.applicationSupportDirectory.appending(path: "abapit") }

    static func make() -> AppServices {
        #if DEBUG
        // `1`: the demo, one client; `clients`: the same with a second client, for the snapshots of the client switcher.
        switch ProcessInfo.processInfo.environment["ABAPIT_DEMO"] {
        case "1": return demo()
        case "clients": return demo(clients: true)
        default: break
        }
        #endif
        let vault = Vault(store: KeychainStore())
        let orgs = OrgsModel(storage: .folder(storageRoot), vault: vault) { account, rate in
            AppleClient(account: account, vault: vault, readsPerMinute: rate)
        } makeMosyleClient: { org in
            MosyleClient(org: org, vault: vault)
        }
        return AppServices(orgs: orgs, isDemo: false)
    }

    #if DEBUG
    /// Debug builds only: one Apple Business org whose key lives in memory and whose "Apple" is the strict
    /// `AppleStub` serving the demo org's data (`DemoOrg`), paired with a Mosyle Business org whose "Mosyle" is the strict
    /// `MosyleStub` serving its devices (`DemoMosyle`). Nothing is read from or written to the Keychain, `orgs.json` or the
    /// network.
    static func demo(clients: Bool = false) -> AppServices {
        let (store, stub) = DemoOrg.make()
        DemoMosyle.storeSecrets(in: store)
        if clients { DemoMosyle.storeSecrets(in: store, org: DemoMosyle.secondOrgID) }
        let mosyleStub = DemoMosyle.make()
        let vault = Vault(store: store)
        var profile = OrgProfile(id: DemoOrg.orgID, name: DemoOrg.name, provider: .apple)
        profile.scope = .known(.business)
        profile.clientID = DemoOrg.clientID
        profile.keyID = DemoOrg.keyID
        profile.role = "Administrator"
        var orgs = OrgStore()
        try? orgs.add(profile)
        // Moved into the Apple org's client: one client, so nothing on screen says "client".
        try? orgs.add(OrgProfile(id: DemoMosyle.orgID, name: DemoMosyle.name, provider: .mosyle))
        if let client = orgs.client(of: DemoOrg.orgID) { try? orgs.move(DemoMosyle.orgID, to: client.id) }
        // A second client: a Mosyle org with no Apple org (the active client has one), read from the same stub.
        if clients { try? orgs.add(OrgProfile(id: DemoMosyle.secondOrgID, name: DemoMosyle.secondName, provider: .mosyle)) }
        orgs.activeID = DemoOrg.orgID
        let model = OrgsModel(storage: .memory, vault: vault, store: orgs) { account, _ in
            AppleClient(account: account, vault: vault, transport: stub)
        } makeMosyleClient: { org in
            MosyleClient(org: org, vault: vault, transport: mosyleStub)
        }
        return AppServices(orgs: model, isDemo: true)
    }
    #endif
}
