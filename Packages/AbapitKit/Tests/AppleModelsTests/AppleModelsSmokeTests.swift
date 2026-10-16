import Testing
@testable import AppleModels

@Suite("AppleModels scaffold")
struct AppleModelsSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!AppleModelsModule.purpose.isEmpty)
    }
}
