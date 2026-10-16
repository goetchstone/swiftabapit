import AppleBusiness
import AppModels
import Foundation
import Orgs
import Vault
#if DEBUG
import TestSupport
#endif

/// The app's long-lived services, built once at launch (adapted from SwiftGamGui App/AppServices.swift
/// @ bfdb494): the Keychain and `orgs.json` for real use; memory and the strict stub for the demo.
final class AppServices {
    let orgs: OrgsModel
    let devices: DevicesModel
    let detail: DeviceDetailModel
    let isDemo: Bool

    private init(orgs: OrgsModel, isDemo: Bool) {
        self.orgs = orgs
        devices = DevicesModel(orgs: orgs)
        detail = DeviceDetailModel(orgs: orgs)
        self.isDemo = isDemo
    }

    /// The folder the app keeps its files in: inside the sandbox container. Injected everywhere, never read
    /// from a global by the package (SwiftGamGui failure-log 2026-09-25).
    static var storageRoot: URL { URL.applicationSupportDirectory.appending(path: "abapit") }

    static func make() -> AppServices {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ABAPIT_DEMO"] == "1" { return demo() }
        #endif
        let vault = Vault(store: KeychainStore())
        let orgs = OrgsModel(storage: .folder(storageRoot), vault: vault) { account, rate in
            AppleClient(account: account, vault: vault, readsPerMinute: rate)
        }
        return AppServices(orgs: orgs, isDemo: false)
    }

    #if DEBUG
    /// Debug builds only: one Apple Business org whose key lives in memory and whose "Apple" is the strict
    /// `AppleStub` serving the seeded demo fleet. Nothing is read from or written to the Keychain, `orgs.json`
    /// or the network.
    static func demo() -> AppServices {
        let (store, stub) = DemoOrg.make()
        let vault = Vault(store: store)
        var profile = OrgProfile(id: DemoOrg.orgID, name: DemoOrg.name, provider: .apple)
        profile.scope = .known(.business)
        profile.clientID = DemoOrg.clientID
        profile.keyID = DemoOrg.keyID
        profile.role = "Administrator"
        var orgs = OrgStore()
        try? orgs.add(profile)
        let model = OrgsModel(storage: .memory, vault: vault, store: orgs) { account, _ in
            AppleClient(account: account, vault: vault, transport: stub)
        }
        return AppServices(orgs: model, isDemo: true)
    }
    #endif
}
