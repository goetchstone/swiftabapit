import Foundation
import JSONAPI
@testable import MosyleModels
import Testing
import TestSupport

/// `Python.upper`, `Python.title` and `Python.isWhitespace` against CPython itself, for every code point: the
/// `unicode_case` golden holds each one's `upper()`, `title()` alone and after a cased character, whether it is cased and
/// `isspace()`, as abapit's Python (Unicode 15) reads them. Swift's tables are newer, and four letters with a capital since
/// Unicode 16 joined serials abapit keeps apart (the review of step 3), so no character is left to a list of cases.
@Suite("Python's case rules")
struct UnicodeCaseTests {
    @Test func everyCodePointCasesAsPythonDoes() throws {
        let golden = try Fixtures.parityValue("unicode_case")
        #expect(golden["unicode"]?.string == "\(Python.unicodeVersion.major).\(Python.unicodeVersion.minor).0")
        let cases = try #require(golden["cases"]?.object)
        #expect(cases.count > 4_000)
        var wrong: [String] = []
        for value in UInt32(0)..<0x110000 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let entry = cases[String(value)]?.object ?? [:]
            let alone = String(scalar)
            func check(_ what: String, _ got: String, _ key: String) {
                let expected = entry[key]?.string ?? alone
                if Array(got.utf8) != Array(expected.utf8) { wrong.append("\(what) U+\(String(value, radix: 16))") }
            }
            check("upper", Python.upper(alone), "upper")
            check("title", Python.title(alone), "title")
            check("after a cased one", String(String.UnicodeScalarView(Python.title("A" + alone).unicodeScalars.dropFirst())), "after_cased")
            if (Python.title(alone + "A").unicodeScalars.last == "a") != (entry["cased"] == .bool(true)) { wrong.append("cased U+\(String(value, radix: 16))") }
            if Python.isWhitespace(scalar) != (entry["space"] == .bool(true)) { wrong.append("space U+\(String(value, radix: 16))") }
        }
        #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(20))")
    }

    /// The final sigma in words, past case-ignorable characters, as CPython's `handle_capital_sigma` reads it.
    @Test func aCapitalSigmaEndingAWordIsFinal() {
        #expect(Array(Python.title("\u{39F}\u{394}\u{39F}\u{3A3}").unicodeScalars) == Array("\u{39F}\u{3B4}\u{3BF}\u{3C2}".unicodeScalars))
        #expect(Array(Python.title("\u{39F}\u{394}\u{39F}\u{3A3} \u{39F}\u{394}\u{39F}\u{3A3}").unicodeScalars) == Array("\u{39F}\u{3B4}\u{3BF}\u{3C2} \u{39F}\u{3B4}\u{3BF}\u{3C2}".unicodeScalars))
        #expect(Array(Python.title("\u{39F}\u{394}\u{39F}\u{3A3}'").unicodeScalars) == Array("\u{39F}\u{3B4}\u{3BF}\u{3C2}'".unicodeScalars))
        #expect(Array(Python.title("\u{3A3}\u{391}").unicodeScalars) == Array("\u{3A3}\u{3B1}".unicodeScalars))
        #expect(Array(Python.title("\u{391}\u{3A3}\u{391}").unicodeScalars) == Array("\u{391}\u{3C3}\u{3B1}".unicodeScalars))
    }
}
