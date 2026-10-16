import Testing
@testable import JSONAPI

@Suite("JSONAPI scaffold")
struct JSONAPISmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!JSONAPIModule.purpose.isEmpty)
    }
}
