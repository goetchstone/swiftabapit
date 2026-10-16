import Testing
@testable import ProfileSchema

@Suite("ProfileSchema scaffold")
struct ProfileSchemaSmokeTests {
    @Test func theModuleBuildsAndSaysWhatItIsFor() {
        #expect(!ProfileSchemaModule.purpose.isEmpty)
    }
}
