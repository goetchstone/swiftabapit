import Foundation
import Testing
import TestSupport

/// The structural half of invariants 1–4, as source scans (SwiftGamGui's `WriteRouteTests`, adapted). Access
/// levels close most routes at compile time; these close the ones the compiler can't see: another place that
/// opens a connection, builds a request, or touches the Keychain.
@Suite("Routes")
struct RouteTests {
    static let sources = "Packages/AbapitKit/Sources"

    /// Only the transport opens connections (invariant 4: one door, one allowlist).
    @Test func onlyTheTransportNamesURLSession() throws {
        // URLSession as a whole word: constructing the allowed `URLSessionTransport` is not opening a connection.
        let networking = ["NSURLConnection", "CFStream", "nw_connection", "NWConnection", "Network.", "CFSocket", "socket("]
        #expect(try SourceScan.files(in: Self.sources, matching: networking, orWord: "URLSession") == ["\(Self.sources)/HTTPCore/Transport.swift"])
        #expect(try SourceScan.files(in: "App", matching: networking, orWord: "URLSession").isEmpty)
    }

    /// Only the read builders make a read (invariant 2); `Wire` defines it and its `setting` copy.
    @Test func onlyTheReadBuildersMakeAReadRequest() throws {
        // Every spelling of the initializer, `.init(host:` included (Phase 1a's review evaded `ReadRequest(`).
        let makers = try SourceScan.files(in: Self.sources, matching: ["ReadRequest(", "ReadRequest.init", ".init(host:"])
        #expect(makers == ["\(Self.sources)/AppleBusiness/AppleRead.swift", "\(Self.sources)/Mosyle/MosyleRead.swift",
                           "\(Self.sources)/Wire/Requests.swift"], "\(makers)")
        #expect(try SourceScan.files(in: "App", matching: ["ReadRequest(", "AuthRequest("]).isEmpty)
    }

    /// A credential exchange carries a secret: only Apple's token broker and Mosyle's session build one.
    @Test func onlyTheBrokersMakeACredentialExchange() throws {
        let makers = try SourceScan.files(in: Self.sources, matching: ["AuthRequest(", "AuthRequest.init"])
        #expect(makers == ["\(Self.sources)/AppleBusiness/TokenBroker.swift", "\(Self.sources)/Mosyle/MosyleSession.swift"], "\(makers)")
    }

    /// Mosyle's reads are POSTs, so the method can't tell a read from a write (invariant 2): every Mosyle read is on
    /// `MosyleRead.allowed`, and that list holds no operation that changes anything. Phase 7a's review passed
    /// `insert_users`, `variables#save` and an operation-less `/v1/lostmode#`: an operation is now a read verb with no
    /// write word in it, and only the two endpoints that have no operation may go without one. `MosyleReadTests`
    /// holds the list's value, which a computed addition after the literal could change.
    @Test func everyMosyleReadIsOnTheAllowlist() throws {
        let writes = ["update", "assign", "change", "create", "delete", "remove", "wipe", "lock", "restart", "shutdown", "clear",
                      "enable", "disable", "play", "request", "bulk", "set", "add", "insert", "save", "send", "push", "move", "erase",
                      "reset", "revoke", "release", "limbo", "install", "rename", "edit", "modify", "apply", "attach", "detach",
                      "import", "upload", "sync", "activation", "lost", "command", "restore", "enroll", "retire", "write", "post"]
        let file = try #require(SourceScan.swiftFiles(in: "\(Self.sources)/Mosyle").first { $0.path.hasSuffix("MosyleRead.swift") })
        let text = file.lines.joined(separator: "\n")
        let start = try #require(text.range(of: "allowed: Set<String> = ["))
        let end = try #require(text[start.upperBound...].range(of: "]"))
        let entries = text[start.upperBound..<end.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        #expect(entries.count == 8, "\(entries)")
        var allowed: Set<String> = []
        for entry in entries {
            #expect(entry.hasPrefix("\"") && entry.hasSuffix("\"") && entry.filter { $0 == "\"" }.count == 2, "a plain literal: \(entry)")
            let key = String(entry.dropFirst().dropLast())
            allowed.insert(key)
            let parts = key.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
            #expect(parts.count == 2 && parts[0].hasPrefix("/v1/"), "\(entry)")
            let (path, operation) = (parts.first ?? "", (parts.last ?? "").lowercased())
            if operation.isEmpty {
                #expect(["/v1/adminlogs", "/v1/logsstream"].contains(path), "only these two have no operation: \(entry)")
            } else {
                #expect(operation.hasPrefix("list") || operation == "get_info", "a read verb: \(entry)")
                #expect(!writes.contains { operation.contains($0) }, "\(entry)")
            }
        }
        // The only builders in the file go through `read(_:_:_:)` or the Logs Stream's own; both check the list.
        #expect(text.components(separatedBy: "ReadRequest(").count - 1 == 2)
        #expect(text.components(separatedBy: "precondition(allowed.contains").count - 1 == 2)
        // Every `read(path, operation…)` the file makes is on the list, called or not: the trap fires only when called.
        let calls = try Regex(#"read\("(/v1/[A-Za-z_/]+)",\s*(?:"([A-Za-z_]*)"|nil)"#)
        let made = text.matches(of: calls).map { match in
            "\(match.output[1].substring ?? "")#\(match.output[2].substring ?? "")"
        }
        #expect(made.count >= 4 && Set(made).isSubset(of: allowed), "\(made)")
        // The Logs Stream's body is top-level with no `operation`: one there would make it another request.
        let logs = try #require(text.range(of: "func logsStream("))
        let logsEnd = try #require(text[logs.upperBound...].range(of: "\n    }\n"))
        #expect(!text[logs.lowerBound..<logsEnd.lowerBound].contains("operation"))
    }

    /// Nothing outside `Wire` extends `ReadRequest` or names it otherwise: an extension's `Self(host: …)` was a second
    /// Mosyle builder that every scan above passed (Phase 7a review M4).
    @Test func nothingElseExtendsOrRenamesReadRequest() throws {
        let patterns = [try Regex(#"extension\s+(Wire\s*\.\s*)?ReadRequest\b"#),
                        try Regex(#"typealias\s+\w+\s*(<[^>]*>)?\s*=\s*(Wire\s*\.\s*)?ReadRequest\b"#),
                        try Regex(#"\bSelf\s*(\.\s*init\s*)?\(\s*host\s*:"#)]
        var scanned = 0
        for directory in [Self.sources, "App"] {
            for file in try SourceScan.swiftFiles(in: directory) where file.path != "\(Self.sources)/Wire/Requests.swift" {
                scanned += 1
                let code = file.lines.joined(separator: "\n")
                for pattern in patterns { #expect(!code.contains(pattern), "\(file.path)") }
            }
        }
        #expect(scanned > 50)
        let wire = try #require(SourceScan.swiftFiles(in: "\(Self.sources)/Wire").first { $0.path.hasSuffix("Requests.swift") })
        #expect(wire.lines.contains { $0.contains("public struct ReadRequest") })
    }

    /// Only the Vault touches the Keychain (invariant 3); the app's spike uses throwaway items only.
    @Test func onlyTheVaultTouchesTheKeychain() throws {
        let keychain = ["SecItem", "SecKeyCreate", "kSecClass", "SecAccessControl"]
        let found = try SourceScan.files(in: Self.sources, matching: keychain)
        #expect(found == ["\(Self.sources)/Vault/KeychainStore.swift"], "\(found)")
        #expect(try SourceScan.files(in: "App", matching: keychain) == ["App/Debug/Spikes.swift"])
    }

    /// Nothing reads a URL outside the transport: `Data(contentsOf:)` and friends would fetch past the host allowlist
    /// (Phase 1a's review added one to AppleClient and the scans passed). Test fixtures are read in TestSupport only.
    @Test func nothingFetchesOutsideTheTransport() throws {
        let fetches = ["contentsOf:", "NSData(", "dataTask(", "downloadTask(", "uploadTask(", "WKWebView", "CFReadStream"]
        #expect(try SourceScan.files(in: Self.sources, matching: fetches) == ["\(Self.sources)/TestSupport/Fixtures.swift"])
        #expect(try SourceScan.files(in: "App", matching: fetches).isEmpty)
    }

    /// `package` access is the boundary that keeps the app from secrets and the write ticket. A `-package-name`
    /// flag on the app target would open it (Phase 1a's review typechecked `Secret.bytes` from outside that way), so
    /// no committed build setting may carry one; `scripts/check_graph.py` refuses `unsafeFlags` in the manifest.
    @Test func noBuildSettingOpensThePackageBoundary() throws {
        let root = Fixtures.repoRoot
        var settings = [try String(contentsOf: root.appending(path: "SwiftAbapit.xcodeproj/project.pbxproj"), encoding: .utf8)]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Config").path) where name.hasSuffix(".xcconfig") {
            settings.append(try String(contentsOf: root.appending(path: "Config/\(name)"), encoding: .utf8))
        }
        for text in settings {
            #expect(!text.contains("package-name") && !text.contains("PACKAGE_NAME") && !text.contains("-enable-testing"),
                    "a build setting names the package or enables testing")
        }
    }

    /// Reinterpreting memory could forge a value the type system guards.
    @Test func nothingReinterpretsMemory() throws {
        let casts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound", "bindMemory"]
        #expect(try SourceScan.files(in: Self.sources, matching: casts).isEmpty)
        #expect(try SourceScan.files(in: "App", matching: casts).isEmpty)
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesWhatItGuards() throws {
        let transport = try SourceScan.swiftFiles(in: "\(Self.sources)/HTTPCore").first { $0.path.hasSuffix("Transport.swift") }
        #expect(transport?.lines.contains { $0.contains("URLSession(configuration:") } == true)
        let vault = try SourceScan.swiftFiles(in: "\(Self.sources)/Vault").first { $0.path.hasSuffix("KeychainStore.swift") }
        #expect(vault?.lines.contains { $0.contains("SecItemAdd(") } == true)
    }
}
