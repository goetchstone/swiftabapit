import Foundation
import Reports
import TestSupport
@testable import Assist

/// One invented request and what a right answer to it is. `expect` is `choice` (a report, the summary or a rule), `change` (a
/// request to change something: nothing is drafted in this version) or `refuse` (off topic). `choices` lists every accepted
/// `Choices.Choice.id` (a report and a rule can both fit a request); the first is the one `groups` belong to. `groups` lists
/// the accepted group values for that first choice, null standing for "all of them".
struct Sample: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var expect: String
    var choices: [String]
    var groups: [String?]

    var first: String? { choices.first }
}

struct SampleFile: Codable { var about: String; var samples: [Sample] }

/// The two sample files. The dev file is what fixers read and tune against. The held-out file is read by the shape test, and
/// later by one flagged evaluation of the model, and by nothing else: no fast test scores, prints or quotes it, no source file
/// holds one of its sentences, and nobody tunes against it (`SampleFileTests` holds all of that).
enum Samples {
    static var folder: URL { Fixtures.directory.appending(path: "assist") }

    static func load(_ name: String) throws -> [Sample] {
        try JSONDecoder().decode(SampleFile.self, from: Data(contentsOf: folder.appending(path: "\(name).json"))).samples
    }

    static func dev() throws -> [Sample] { try load("dev") }
    static func heldOut() throws -> [Sample] { try load("heldout") }

    /// The list the samples' labels are checked against: the largest one.
    static let choices = Choices.build(scope: .business, hasMosyle: true, thresholds: thresholds)

    static let thresholds = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 14, quietServiceDays: 30)
}
