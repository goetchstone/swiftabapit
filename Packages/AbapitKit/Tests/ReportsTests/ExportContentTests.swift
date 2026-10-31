import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// The Content screen's exports (invariant 11: an allowlist). Each list's columns are its documented attributes, the
/// table's first, and two are never among them: a package's `url` (it can carry credentials, which a column list can't
/// mask) and a configuration's `customSettingsValues` (a custom setting's profile, Wi-Fi password and all).
@Suite("Content exports")
struct ExportContentTests {
    static func header(_ text: String) -> String { String(text.prefix { $0 != "\r\n" }) }

    /// Each list, exactly: a dropped, added or reordered column fails, as the Devices export's test holds its own.
    @Test func eachListExportsItsDocumentedAttributesAndNothingElse() {
        #expect(ExportPolicy.apps.names == ["name", "bundleId", "version", "supportedOS", "isCustomApp", "appStoreUrl", "websiteUrl"])
        #expect(ExportPolicy.packages.names == ["name", "version", "bundleIds", "hash", "description", "createdDateTime", "updatedDateTime"])
        #expect(ExportPolicy.blueprints.names == ["name", "status", "appLicenseDeficient", "description", "createdDateTime", "updatedDateTime"])
        #expect(ExportPolicy.configurations.names == ["name", "type", "configuredForPlatforms", "createdDateTime", "updatedDateTime"])
        // Every documented attribute but the two held back, each once, and none the denylist would drop unsaid.
        for (columns, fields, held) in [(ExportPolicy.apps, ContentApp.fields, [String]()), (ExportPolicy.packages, ContentPackage.fields, ["url"]),
                                        (ExportPolicy.blueprints, Blueprint.fields, []),
                                        (ExportPolicy.configurations, Configuration.fields, ["customSettingsValues"])] {
            #expect(Set(columns.names) == Set(fields).subtracting(held), "\(columns.names)")
            #expect(Set(columns.names).count == columns.names.count)
            for column in columns.names {
                #expect(!ExportPolicy.isSensitive(column) && !ExportPolicy.isNotByDefault(column), "\(column)")
            }
        }
    }

    /// A custom setting's profile never reaches the configurations CSV, even from a caller that hands the CSV the raw
    /// attributes rather than the view's withheld resource: the column isn't listed.
    @Test func theConfigurationsExportHoldsNoProfile() {
        let canary = "canary-export-wifi-password"
        let raw: JSONObject = [
            "type": .string("CUSTOM_SETTING"), "name": .string("Office Wi-Fi"), "configuredForPlatforms": .array([.string("PLATFORM_MACOS")]),
            "customSettingsValues": .object(["configurationProfile": .string("<plist version=\"1.0\"><dict><key>Password</key><string>\(canary)</string></dict></plist>"),
                                             "filename": .string("Office.mobileconfig")]),
        ]
        let configuration = Configuration(resource: Resource(type: "configurations", id: "C1", attributes: raw))
        for item in [CSV.Item(configuration.resource), CSV.Item(id: "C1", attributes: raw)] {
            let text = CSV.text([item], columns: ExportPolicy.configurations)
            #expect(!text.contains(canary) && !text.contains("customSettingsValues") && !text.contains("Office.mobileconfig"), "\(text)")
            #expect(text == "id,name,type,configuredForPlatforms,createdDateTime,updatedDateTime\r\nC1,Office Wi-Fi,CUSTOM_SETTING,PLATFORM_MACOS,,\r\n")
        }
    }

    /// A package's location never leaves in a CSV, whatever it carries; an attribute Apple adds later isn't exported
    /// until it is listed.
    @Test func thePackagesExportHoldsNoLocation() {
        let url = "https://deploy:canary-password@packages.example.com/agent.pkg?sig=canary-signature"
        let item = CSV.Item(id: "P1", attributes: ["name": .string("Agent"), "url": .string(url), "version": .string("2.1"),
                                                   "someFutureAttribute": .string("not yet")])
        let text = CSV.text([item], columns: ExportPolicy.packages)
        #expect(Self.header(text) == "id,name,version,bundleIds,hash,description,createdDateTime,updatedDateTime")
        #expect(!text.contains("canary") && !text.contains("packages.example.com") && !text.contains("not yet"), "\(text)")
    }
}
