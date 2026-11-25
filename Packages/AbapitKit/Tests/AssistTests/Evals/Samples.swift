import Foundation
import Reports
import TestSupport
@testable import Assist

/// One invented request and what a right answer to it is. `expect` is `choice` (a report, the summary or a rule: `choice` is
/// its `Choices.Choice.id`), `change` (a request to change something: nothing is drafted in this version) or `refuse`
/// (off topic). `group` is the group value a report's pick takes, nil for "all".
struct Sample: Codable, Sendable, Equatable {
    var id: String
    var text: String
    var expect: String
    var choice: String?
    var group: String?
}

struct SampleFile: Codable { var about: String; var samples: [Sample] }

/// The two files. `dev.json` is what fixers read and tune against. `heldout.json` is read by one flagged evaluation (S9.8's
/// run), by the shape test and by nothing else: no fast test prints, scores or quotes it, and nobody tunes against it.
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
