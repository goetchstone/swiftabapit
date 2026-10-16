#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import CryptoKit
import Foundation
import Vault

/// The demo org (plan §4): a fresh key in a memory store, and the strict stub trusting it and serving the
/// demo fleet. Debug builds of the app and the screenshots use it; nothing touches the Keychain, `orgs.json`
/// or the network.
public enum DemoOrg {
    public static let orgID = "demo-business"
    public static let name = "Example Business (demo)"
    public static let clientID = "BUSINESSAPI.00000000-0000-4000-8000-00000000d3e0"
    public static let keyID = "00000000-0000-4000-8000-00000000d3e1"

    public static func make() -> (store: MemoryStore, stub: AppleStub) {
        let key = P256.Signing.PrivateKey()
        let store = MemoryStore()
        if let item = VaultItem(org: orgID, kind: .appleKey) { try? store.storeKey(key, as: item) }
        let stub = AppleStub()
        stub.register(AppleStub.Account(clientID: clientID, keyID: keyID, publicKey: key.publicKey))
        stub.load(DemoFleet.make())
        return (store, stub)
    }
}
#endif
