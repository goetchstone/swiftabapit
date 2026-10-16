import Testing
@testable import ChangeCore

@Suite("ChangeCore scaffold")
struct ChangeCoreSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!ChangeCoreModule.purpose.isEmpty)
    }
}
