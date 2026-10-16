import Testing
@testable import History

@Suite("History scaffold")
struct HistorySmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!HistoryModule.purpose.isEmpty)
    }
}
