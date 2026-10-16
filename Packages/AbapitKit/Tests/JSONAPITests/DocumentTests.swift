import Foundation
import Testing
import TestSupport
import JSONAPI

@Suite("JSON:API documents")
struct DocumentTests {
    static func example(_ name: String) throws -> Data {
        try Data(contentsOf: Fixtures.docc.appending(path: "business/\(name).response.json"))
    }

    @Test func aListKeepsAttributesInApplesOrderAndItsNextLink() throws {
        let document = try Document.parse(Self.example("get-org-devices"))
        let first = try #require(document.resources.first)
        #expect(first.type == "orgDevices")
        #expect(first.attributes.keys.first == "serialNumber")
        #expect(document.next?.hasPrefix("https://api-business.apple.com/v1/orgDevices") == true)
    }

    @Test func aSingleResourceAndARelationshipLinkage() throws {
        let full = try Document.parse(Self.example("get-the-assigned-server-information-for-an-orgdevice"))
        #expect(full.resource?.type == "mdmServers")
        #expect(full.resource?.attributes["serverName"] != nil)
        let linkage = try Document.parse(Self.example("get-the-assigned-server-id-for-an-orgdevice"))
        #expect(linkage.data.flatMap(Linkage.init) == Linkage(type: "mdmServers", id: "1F97349736CF4614A94F624E705841AD"))
    }

    @Test func notJSONSaysOnlyTheByteCount() {
        #expect(throws: Document.Failure.notJSON(bytes: 5)) { try Document.parse(Data("hello".utf8)) }
        #expect(throws: Document.Failure.notJSON(bytes: 2)) { try Document.parse(Data("[]".utf8)) }
    }

    @Test func objectKeysAreExactTextNotCanonicalEquivalents() throws {
        let value = try #require(JSONValue.parse(#"{"é": 1, "é": 2}"#))
        #expect(value.object?.count == 2)
    }

    @Test func numbersKeepTheirText() throws {
        let value = try #require(JSONValue.parse(#"{"a": 1.0, "b": 10000000000000000000001}"#))
        #expect(value["a"] == .number("1.0"))
        #expect(value["b"] == .number("10000000000000000000001"))
    }

    @Test func nestingPastTheLimitIsRefused() {
        #expect(JSONValue.parse(String(repeating: "[", count: 200) + String(repeating: "]", count: 200)) == nil)
    }

    @Test func applesErrorBodyIsReadByCodeAndSummarized() throws {
        let body = Data(#"{"errors":[{"id":"x","status":"403","code":"FORBIDDEN.NOT_PERMITTED","title":"Forbidden","detail":"Not allowed.","source":{"parameter":"include"}}]}"#.utf8)
        let error = try #require(ErrorBody(body))
        #expect(error.errors.first?.code == "FORBIDDEN.NOT_PERMITTED")
        #expect(error.errors.first?.parameter == "include")
        #expect(error.summary == "Forbidden: Not allowed.")
    }

    enum Color: String, KnownValues { case red = "RED", blue = "BLUE" }

    @Test func anUnknownEnumValueSurvivesRaw() {
        #expect(OpenEnum<Color>("RED") == .known(.red))
        #expect(OpenEnum<Color>("GREEN") == .unknown("GREEN"))
        #expect(OpenEnum<Color>("GREEN").rawValue == "GREEN")
    }
}
