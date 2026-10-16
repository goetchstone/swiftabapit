import Testing
@testable import Reports

@Suite("Reports scaffold")
struct ReportsSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!ReportsModule.purpose.isEmpty)
    }
}
