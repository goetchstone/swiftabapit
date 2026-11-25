import Testing
@testable import Assist

@Suite("Evaluators")
struct JudgeTests {
    let choices = Samples.choices
    func sample(_ expect: String, _ accepted: [String] = [], _ groups: [String?] = []) -> Sample {
        Sample(id: "x", text: "t", expect: expect, choices: accepted, groups: groups)
    }

    @Test func reportAcceptsAnyListedAnswerAndJudgesOnlyChoiceSamples() {
        let s = sample("choice", ["report:coverage", "rule:applecare_expiring"])
        #expect(Judge.report(s, .choice("report:coverage", group: nil)) == true)
        #expect(Judge.report(s, .choice("rule:applecare_expiring", group: nil)) == true)
        #expect(Judge.report(s, .choice("report:coverage", group: "x")) == true, "the report evaluator ignores the group")
        #expect(Judge.report(s, .choice("report:fleet-age", group: nil)) == false)
        #expect(Judge.report(s, .refuse) == false)
        #expect(Judge.report(s, .changeRequest) == false)
        #expect(Judge.report(sample("refuse"), .refuse) == nil)
        #expect(Judge.report(sample("change"), .changeRequest) == nil)
    }

    @Test func groupNeedsAnAcceptedChoiceAndAnAcceptedGroup() {
        let s = sample("choice", ["report:activation-lock"], ["lock:USER"])
        #expect(Judge.group(s, .choice("report:activation-lock", group: "lock:USER"), choices: choices) == true)
        #expect(Judge.group(s, .choice("report:activation-lock", group: "lock:MDM"), choices: choices) == false)
        #expect(Judge.group(s, .choice("report:activation-lock", group: nil), choices: choices) == false)
        #expect(Judge.group(s, .choice("report:migration", group: "lock:USER"), choices: choices) == false)
        #expect(Judge.group(s, .refuse, choices: choices) == false)
        // "all" is an answer: nil expected, nil given.
        let all = sample("choice", ["report:activation-lock"], [nil])
        #expect(Judge.group(all, .choice("report:activation-lock", group: nil), choices: choices) == true)
        #expect(Judge.group(all, .choice("report:activation-lock", group: "unlocked"), choices: choices) == false)
        // Either of two groups is accepted when both are listed.
        let either = sample("choice", ["report:migration"], ["status:SUCCESS", nil])
        #expect(Judge.group(either, .choice("report:migration", group: nil), choices: choices) == true)
        #expect(Judge.group(either, .choice("report:migration", group: "status:SUCCESS"), choices: choices) == true)
        #expect(Judge.group(either, .choice("report:migration", group: "status:FAILED"), choices: choices) == false)
        // A rule answered where a report fits too has no group to judge.
        let both = sample("choice", ["report:activation-lock", "rule:activation_lock_user"], ["lock:USER"])
        #expect(Judge.group(both, .choice("rule:activation_lock_user", group: nil), choices: choices) == true)
        #expect(Judge.group(both, .choice("report:activation-lock", group: nil), choices: choices) == false)
        // A first choice with no groups, and the samples that aren't choices, aren't asked.
        #expect(Judge.group(sample("choice", ["report:coverage"], [nil]), .refuse, choices: choices) == nil)
        #expect(Judge.group(sample("choice", ["attention"], [nil]), .refuse, choices: choices) == nil)
        #expect(Judge.group(sample("choice", ["rule:firewall_off", "report:coverage"]), .refuse, choices: choices) == nil)
        #expect(Judge.group(sample("refuse"), .refuse, choices: choices) == nil)
    }

    @Test func refusalIsTheRightKindOfRefusal() {
        #expect(Judge.refusal(sample("change"), .changeRequest) == true)
        #expect(Judge.refusal(sample("change"), .refuse) == false)
        #expect(Judge.refusal(sample("change"), .choice("report:coverage", group: nil)) == false)
        #expect(Judge.refusal(sample("refuse"), .refuse) == true)
        #expect(Judge.refusal(sample("refuse"), .changeRequest) == false)
        #expect(Judge.refusal(sample("refuse"), .choice("attention", group: nil)) == false)
        #expect(Judge.refusal(sample("choice", ["attention"]), .refuse) == nil)
    }

    @Test func aScoreCountsOnlyTheSamplesAMetricAppliesTo() {
        let samples = [sample("choice", ["report:activation-lock"], ["lock:USER"]), sample("choice", ["report:coverage"], [nil]),
                       sample("change"), sample("refuse")]
        let score = Judge.score(samples, choices: choices) { _ in .choice("report:activation-lock", group: "lock:USER") }
        #expect(score == Judge.Score(report: 1, reports: 2, group: 1, groups: 1, refusal: 0, refusals: 2))
        #expect(score.summary == "report 1/2, group 1/1, refusal 0/2")
    }
}
