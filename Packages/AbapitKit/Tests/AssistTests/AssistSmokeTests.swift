import Testing
@testable import Assist

@Suite("Assist scaffold")
struct AssistSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!AssistModule.purpose.isEmpty)
    }
}
