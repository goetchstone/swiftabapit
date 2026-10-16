import Testing
@testable import Vault

@Suite("Vault scaffold")
struct VaultSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!VaultModule.purpose.isEmpty)
    }
}
