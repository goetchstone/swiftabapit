import Foundation
import Testing
import TestSupport

/// The screen models moved into the package to be testable (Phase 1b review M6), and the compiler now lets them
/// see `package` declarations the app can't: a secret's bytes, the Vault's reads and signatures, the read and
/// credential builders, the HTTP client. They stay on the app's side of that line (invariants 1–3): this scan holds
/// them to the routes the app itself may use, and a screen model that needs more is a design change, reviewed.
@Suite("Screen-model boundary")
struct BoundaryTests {
    static let directory = "Packages/AbapitKit/Sources/AppModels"

    /// The package-only routes, by the names a use would spell: `Secret.bytes`, `Vault.secret`/`optionalSecret`/
    /// `sign`/`refresh` and its `secretStore:` init, the `SecretStore` protocol, `ImportedKey.key`, the request and
    /// credential builders, the HTTP client, the assertion signer, the write ticket, `JSONValue.dumps`.
    static let routes = ["bytes", "secret", "optionalSecret", "sign", "refresh", "secretStore", "SecretStore", "ReadRequest", "AuthRequest",
                         "AppleRead", "HTTPClient", "ClientAssertion", "WriteTicket", "dumps", "KeychainStore", "MemoryStore", "Transport"]

    /// A line's identifiers, outside string literals and trailing comments, with `.key` kept apart (`ImportedKey.key`
    /// is the private key itself).
    static func words(_ line: String) -> (words: Set<String>, readsKey: Bool) {
        let code = line.replacing(#/"(?:[^"\\]|\\.)*"/#, with: "\"\"").replacing(#/\/\/.*$/#, with: "")
        let words = Set(code.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init))
        return (words, code.contains(#/\.key\b/#))
    }

    @Test func theScreenModelsTakeNoPackageOnlyRoute() throws {
        let files = try SourceScan.swiftFiles(in: Self.directory)
        // The scan must see what it guards.
        #expect(Set(files.map(\.path)).isSuperset(of: ["OrgsModel.swift", "DevicesModel.swift", "DeviceDetailModel.swift"].map { "\(Self.directory)/\($0)" }))
        for file in files {
            for (index, line) in file.lines.enumerated() {
                let (words, readsKey) = Self.words(line)
                let used = words.intersection(Self.routes)
                #expect(used.isEmpty && !readsKey, "\(file.path), code line \(index + 1): \(used.sorted()) \(readsKey ? ".key" : "")")
            }
        }
    }

    /// The scan sees a use however it is spaced, and ignores one in a string or a comment.
    @Test func theScanSeesAUseAndOnlyAUse() {
        #expect(Self.words("        let value = try await orgs.vault.secret(item)").words.contains("secret"))
        #expect(Self.words("let raw = key.key").readsKey)
        #expect(Self.words("_ = imported .key").readsKey)
        #expect(Self.words("let note = \"a secret's bytes\" // sign here").words.isDisjoint(with: Self.routes))
        #expect(!Self.words("try await vault.storeKey(key, as: item)").readsKey)
    }
}
