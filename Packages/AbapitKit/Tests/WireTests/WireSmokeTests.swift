import Testing
@testable import Wire

@Suite("Wire scaffold")
struct WireSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!WireModule.purpose.isEmpty)
    }
}
