import Testing
@testable import HTTPCore

@Suite("HTTPCore scaffold")
struct HTTPCoreSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!HTTPCoreModule.purpose.isEmpty)
    }
}
