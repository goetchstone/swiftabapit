import Testing
@testable import AppleBusiness

@Suite("AppleBusiness scaffold")
struct AppleBusinessSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!AppleBusinessModule.purpose.isEmpty)
    }
}
