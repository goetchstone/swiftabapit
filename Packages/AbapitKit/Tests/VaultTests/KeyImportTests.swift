import CryptoKit
import Darwin
import Foundation
import Testing
import TestSupport
@testable import Vault

/// abapit's `config.normalize_private_key`, P-256 only, held to `Tests/Fixtures/parity/private_keys.json`,
/// and the read-by-descriptor rules for the picked file (plan §3.4.1).
@Suite("Key import")
struct KeyImportTests {
    struct Golden: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable { let accepted: Bool; let scalar: String? }
            let name: String
            let input: String
            let expected: Expected
            let abapit: [String: Bool]?
        }
        let cases: [Case]
    }

    static func cases() throws -> [Golden.Case] {
        try JSONDecoder().decode(Golden.self, from: Fixtures.parity("private_keys")).cases
    }

    @Test func everyCaseMatchesTheGolden() throws {
        let cases = try Self.cases()
        #expect(cases.count > 40)
        for item in cases {
            let parsed = try? KeyImport.parse(Secret(item.input))
            #expect((parsed != nil) == item.expected.accepted, "\(item.name)")
            if let parsed, let scalar = item.expected.scalar {
                #expect(parsed.key.rawRepresentation.map { String(format: "%02x", $0) }.joined() == scalar, "\(item.name)")
            }
        }
    }

    /// The listed deviation: abapit accepts a P-384 key, which would import and then fail to sign.
    @Test func theOnlyDeviationsAreKeysThatArentP256() throws {
        let deviating = try Self.cases().filter { $0.abapit != nil }.map(\.name)
        #expect(Set(deviating) == ["p384", "p384-sec1"])
    }

    @Test func anImportedKeyNeverPrintsItself() throws {
        let key = KeyImport.parseForTests(P256.Signing.PrivateKey())
        #expect(!String(describing: key).contains("PRIVATE"))
        #expect(String(describing: key).hasPrefix("<P-256 key "))
        #expect(Mirror(reflecting: key).children.isEmpty)
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains(key.key.rawRepresentation.base64EncodedString()))
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftabapit-keyimport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aRegularFileIsReadOnce() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let file = dir.appending(path: "key.txt")
        try Data(pem.utf8).write(to: file)
        let read = try KeyImport.read(file)
        #expect(read.bytes == Data(pem.utf8))
        #expect(try KeyImport.parse(read).key.rawRepresentation.count == 32)
    }

    @Test func aLinkAFolderAndAFIFOAreRefusedWithoutHanging() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "real.txt")
        try Data("x".utf8).write(to: target)
        let link = dir.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: KeyImport.Failure.unreadable(errno: ELOOP)) { try KeyImport.read(link) }
        #expect(throws: KeyImport.Failure.notARegularFile) { try KeyImport.read(dir) }
        let fifo = dir.appending(path: "fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: KeyImport.Failure.notARegularFile) { try KeyImport.read(fifo) }
    }

    @Test func aLargeFileIsRefused() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "big.txt")
        try Data(repeating: 0x41, count: KeyImport.maximumBytes + 1).write(to: file)
        #expect(throws: KeyImport.Failure.tooLarge) { try KeyImport.read(file) }
    }

    @Test func base64URLHasNoPaddingAndRoundTrips() {
        for count in 0..<40 {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 251) })
            let text = Base64URL.encode(data)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(Base64URL.decode(text) == data)
        }
        #expect(Base64URL.decode("a b") == nil)
    }
}

extension KeyImport {
    static func parseForTests(_ key: P256.Signing.PrivateKey) -> ImportedKey { ImportedKey(key: key) }
}
