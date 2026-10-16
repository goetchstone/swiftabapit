import Foundation
import Testing
@testable import Wire

@Suite("Requests")
struct RequestTests {
    @Test func queryNamesAreEncodedAsAbapitSentThem() {
        let url = URL.make(host: .appleBusiness, path: "/v1/auditEvents",
                           query: [QueryItem("filter[startTimestamp]", "2026-10-01T00:00:00Z"), QueryItem("fields[orgDevices]", "a,b")])
        #expect(url?.absoluteString == "https://api-business.apple.com/v1/auditEvents?filter%5BstartTimestamp%5D=2026-10-01T00%3A00%3A00Z&fields%5BorgDevices%5D=a%2Cb")
    }

    @Test func onlyTheAllowlistedHostsOverHTTPSAreHosts() {
        #expect(APIHost(of: URL(string: "https://api-business.apple.com/v1/x")!) == .appleBusiness)
        #expect(APIHost(of: URL(string: "https://businessapilogs.mosyle.com/v1/x")!) == .mosyleLogs)
        #expect(APIHost(of: URL(string: "http://api-business.apple.com/v1/x")!) == nil)
        #expect(APIHost(of: URL(string: "https://api-business.apple.com.evil.example/v1/x")!) == nil)
        #expect(APIHost(of: URL(string: "https://x@api-business.apple.com/v1/x")!) == nil)
        #expect(APIHost(of: URL(string: "https://api-business.apple.com:444/v1/x")!) == nil)
        #expect(APIHost.allCases.count == 5)
    }
}
