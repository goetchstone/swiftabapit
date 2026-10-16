import Testing
@testable import Mosyle

@Suite("Mosyle scaffold")
struct MosyleSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!MosyleModule.purpose.isEmpty)
    }
}
