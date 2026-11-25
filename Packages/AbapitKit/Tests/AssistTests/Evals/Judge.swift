import Foundation
@testable import Assist

/// The code evaluators (shared lessons: code first): each judges one thing about an answer and returns nil when the sample
/// doesn't ask about it, so a score counts only the samples it applies to. Written once, so the model's run, when there is one, is judged
/// by the same code as `WordRule`.
enum Judge {
    /// The report (or summary, or rule) is an accepted one. Applies to samples that expect a choice.
    static func report(_ sample: Sample, _ answer: WordRule.Answer) -> Bool? {
        guard sample.expect == "choice" else { return nil }
        if case .choice(let id, _) = answer { return sample.choices.contains(id) }
        return false
    }

    /// The group each rule's findings are, in the report that holds them: a rule answered where a report fits too is credited a
    /// group only when its own is accepted (the rule *is* that group's rows, over its fixed window). A rule with no entry here
    /// has no group, so an answer with it is wrong for the group.
    static let ruleGroup: [String: String] = [
        "rule:activation_lock_user": "lock:USER", "rule:quiet_service": "quiet", "rule:migration_deadline": "past-due",
    ]

    /// The right group, nil standing for "all". Applies to samples whose first accepted choice has groups. Another accepted
    /// choice (a rule) is right only when the group the rule stands for is accepted (`ruleGroup`).
    static func group(_ sample: Sample, _ answer: WordRule.Answer, choices: [Choices.Choice]) -> Bool? {
        guard sample.expect == "choice", let first = sample.first, let want = choices.first(where: { $0.id == first }),
              !want.groups.isEmpty else { return nil }
        guard case .choice(let id, let group) = answer, sample.choices.contains(id) else { return false }
        if id != first { return ruleGroup[id].map { stands in sample.groups.contains { $0 == stands } } ?? false }
        return sample.groups.contains { $0 == group }
    }

    /// A request to change something is told so, and an off-topic one is refused: never a report. Applies to those samples.
    static func refusal(_ sample: Sample, _ answer: WordRule.Answer) -> Bool? {
        switch sample.expect {
        case "change": answer == .changeRequest
        case "refuse": answer == .refuse
        default: nil
        }
    }

    struct Score: Equatable {
        var report = 0, reports = 0, group = 0, groups = 0, refusal = 0, refusals = 0
        var summary: String { "report \(report)/\(reports), group \(group)/\(groups), refusal \(refusal)/\(refusals)" }
    }

    static func score(_ samples: [Sample], choices: [Choices.Choice], _ answer: (String) -> WordRule.Answer) -> Score {
        var score = Score()
        for sample in samples {
            let answered = answer(sample.text)
            if let ok = report(sample, answered) { score.reports += 1; score.report += ok ? 1 : 0 }
            if let ok = group(sample, answered, choices: choices) { score.groups += 1; score.group += ok ? 1 : 0 }
            if let ok = refusal(sample, answered) { score.refusals += 1; score.refusal += ok ? 1 : 0 }
        }
        return score
    }
}
