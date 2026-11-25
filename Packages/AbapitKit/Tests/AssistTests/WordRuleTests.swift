import Foundation
import Testing
@testable import Assist

@Suite("WordRule")
struct WordRuleTests {
    let choices = Samples.choices
    func answer(_ text: String) -> WordRule.Answer { WordRule.answer(text, choices: choices) }

    @Test func wholeWordsOnly() {
        #expect(WordRule.words("Which iPads' AppleCare, ends?") == ["ipad", "applecare", "end"])
        // "lock" is not a word of "blocked" or "unlocked": no substring match.
        #expect(answer("blocked") == .refuse)
        #expect(answer("clocks") == .refuse)
    }

    @Test func picksTheChoiceSharingTheMostWords() {
        #expect(answer("how old is the fleet") == .choice("report:fleet-age", group: nil))
        #expect(answer("Which services are quiet?") == .choice("report:service-health", group: "quiet"))
        #expect(answer("what is the state of the Activation Lock") == .choice("report:activation-lock", group: nil))
        #expect(answer("any firewall problems") == .choice("rule:firewall_off", group: nil))
    }

    @Test func theGroupIsTheValueWhoseWordsTheSentenceShares() {
        #expect(answer("activation lock lock:USER") == .choice("report:activation-lock", group: "lock:USER"))
        #expect(answer("activation lock that is unlocked") == .choice("report:activation-lock", group: "unlocked"))
        #expect(answer("MDM migration status failed") == .choice("report:migration", group: "status:FAILED"))
    }

    @Test func aTieKeepsTheEarlierChoice() {
        // "fleet" and "age" each appear in exactly one label; one word apiece ties nothing: the list's order decides ties.
        let two = [Choices.Choice(kind: .attentionSummary, label: "alpha beta", holds: nil, groups: []),
                   Choices.Choice(kind: .attentionSummary, label: "alpha gamma", holds: nil, groups: [])]
        #expect(WordRule.answer("alpha", choices: two) == .choice("attention", group: nil))
        #expect(WordRule.answer("alpha gamma", choices: two) == .choice("attention", group: nil))
        #expect(WordRule.answer("alpha gamma", choices: [two[1], two[0]]) == .choice("attention", group: nil))
        let ordered = [Choices.Choice(kind: .rule(.firewallOff), label: "one two", holds: nil, groups: []),
                       Choices.Choice(kind: .rule(.fileVaultOff), label: "one three", holds: nil, groups: [])]
        #expect(WordRule.answer("one", choices: ordered) == .choice("rule:firewall_off", group: nil))
        #expect(WordRule.answer("one", choices: ordered.reversed()) == .choice("rule:filevault_off", group: nil))
    }

    @Test func aChangeWordIsAChangeRequestAndNothingElseIsRefused() {
        #expect(answer("Assign these Macs to the Sales service") == .changeRequest)
        #expect(answer("wipe every device with an expired lock") == .changeRequest)
        #expect(answer("write me a poem about autumn") == .refuse)
        #expect(answer("") == .refuse)
    }

    @Test func aOneLetterWordIsNotAWord() {
        #expect(WordRule.words("org's what's x y") == ["org"])
        // The s of "what's" used to match the s of "org's" in a rule's title.
        #expect(answer("What's the weather like tomorrow?") == .refuse)
        #expect(answer("what's pending for me") == .refuse)
    }

    @Test func theChangeWordsAreTheDevVerbsOnly() throws {
        let dev = try Samples.dev().filter { $0.expect == "change" }.map(\.text)
        let verbs = Set(dev.flatMap { WordRule.words($0) })
        #expect(WordRule.changeWords.isSubset(of: verbs), "every change word is in a dev change sample")
    }

    @Test func theStopWordsDoNotCarryAPick() {
        // Only ignored words in common with every label: no pick.
        #expect(answer("the of and to in") == .refuse)
        #expect(answer("which of the") == .refuse)
    }

    @Test func printedAnswersRoundTrip() {
        for answer: WordRule.Answer in [.changeRequest, .refuse, .choice("a", group: nil), .choice("a", group: "g:x")] {
            #expect(WordRule.Answer(printed: answer.printed) == answer)
        }
    }
}
