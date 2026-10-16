import Foundation
import Testing
import TestSupport
import JSONAPI

/// abapit's `reports.parse_iso`, held to the `parse_iso` cases in `Tests/Fixtures/parity/reports.json`.
@Suite("ISO dates parity")
struct ISODateTests {
    struct Golden: Decodable {
        struct Case: Decodable {
            struct Value: Decodable { let value: String? }
            struct Ok: Decodable { let ok: String? }
            let function: String
            let input: Value?
            let expected: Ok?
            let abapit: Ok?

            enum CodingKeys: String, CodingKey { case function, input, expected, abapit }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                function = try container.decode(String.self, forKey: .function)
                // Only parse_iso's cases have this shape; the rest of reports.json is skipped.
                input = function == "parse_iso" ? try container.decode(Value.self, forKey: .input) : nil
                expected = function == "parse_iso" ? try container.decode(Ok.self, forKey: .expected) : nil
                abapit = function == "parse_iso" ? try container.decodeIfPresent(Ok.self, forKey: .abapit) : nil
            }
        }
        let cases: [Case]
    }

    static func cases() throws -> [(input: String?, expected: String?, deviates: Bool)] {
        try JSONDecoder().decode(Golden.self, from: Fixtures.parity("reports")).cases.filter { $0.function == "parse_iso" }
            .map { (input: $0.input?.value, expected: $0.expected?.ok, deviates: $0.abapit != nil) }
    }

    @Test func everyCaseMatchesTheGolden() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 30)
        for item in cases {
            #expect(ISODate.parse(item.input)?.isoformat == item.expected, "\(item.input.debugDescription)")
        }
    }

    /// The deviations are the two the parser documents: ISO week dates and a space before the offset.
    @Test func theDeviationsAreTheListedOnes() throws {
        let deviations = try Self.cases().filter(\.deviates).compactMap(\.input)
        #expect(Set(deviations) == ["2024-W09", "2024-03-01T10:00:00 +00:00"])
    }

    @Test func anOffsetKeepsItsCalendarFields() throws {
        let parsed = try #require(ISODate.parse("2024-03-31T23:30:00-02:00"))
        #expect(parsed.localComponents.month == 3)
        #expect(parsed.date == ISODate.parse("2024-04-01T01:30:00Z")?.date)
    }
}
