import Foundation
import Testing
import TestSupport
@testable import Planners

/// abapit's `assign.parse_serials`, held to `Tests/Fixtures/parity/serials.json` (invariant 6).
@Suite("Serial parser parity")
struct SerialParserTests {
    struct Golden {
        let whitespace: [UInt32]
        let cases: [(input: String, expected: [String], abapit: [String]?)]
    }

    static func golden() throws -> Golden {
        let root = try #require(try Fixtures.parityGolden("serials") as? [String: Any])
        let whitespace = try #require(root["python_whitespace"] as? [Int]).map(UInt32.init)
        let cases = try #require(root["cases"] as? [[String: Any]]).map { item in
            (input: item["input"] as? String ?? "", expected: item["expected"] as? [String] ?? [],
             abapit: item["abapit"] as? [String])
        }
        return Golden(whitespace: whitespace, cases: cases)
    }

    /// Bytes, not `String ==`: Swift compares strings by canonical equivalence, so "é" would equal
    /// "e" + U+0301 and hide exactly the difference a parity test exists to catch.
    static func bytes(_ tokens: [String]) -> [[UInt8]] { tokens.map { Array($0.utf8) } }

    @Test func everyCaseMatchesTheGolden() throws {
        let golden = try Self.golden()
        #expect(golden.cases.count > 200)
        for item in golden.cases {
            #expect(Self.bytes(SerialParser.parse(item.input)) == Self.bytes(item.expected),
                    "input \(item.input.debugDescription)")
        }
    }

    @Test func theSeparatorsArePythonsWhitespace() throws {
        let golden = try Self.golden()
        #expect(SerialParser.pythonWhitespace == Set(golden.whitespace))
    }

    /// The one deliberate deviation: Swift uppercases ASCII letters only, so each case where abapit
    /// differs holds a non-ASCII letter. The list stays narrow.
    @Test func everyDeviationIsANonASCIILetter() throws {
        let deviations = try Self.golden().cases.filter { $0.abapit != nil }
        #expect(deviations.count < 25)
        for item in deviations {
            #expect(item.input.unicodeScalars.contains { $0.value > 0x7F && $0.properties.isAlphabetic },
                    "deviation without a non-ASCII letter: \(item.input.debugDescription)")
        }
    }

    @Test func tokensAreDedupedByCodePointsNotByCanonicalEquivalence() {
        // "É" both ways: precomposed, and E + COMBINING ACUTE (already uppercase, so the parser keeps both).
        let composed = "\u{C9}", decomposed = "E\u{301}"
        #expect(Self.bytes(SerialParser.parse("\(composed) \(decomposed)")) == Self.bytes([composed, decomposed]))
    }
}
