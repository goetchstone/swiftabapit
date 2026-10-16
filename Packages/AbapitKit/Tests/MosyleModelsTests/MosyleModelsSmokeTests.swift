import Testing
@testable import MosyleModels

@Suite("MosyleModels scaffold")
struct MosyleModelsSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!MosyleModelsModule.purpose.isEmpty)
    }
}
