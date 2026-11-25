import Foundation
import Reports

/// The run-time list a person's sentence is mapped onto (plan §5; the operator's answers of 2026-11-24, Q1 "Six reports +
/// more" and Q3 "Picks + explanations"): the six reports, the Needs-attention summary and the Needs-attention rules this
/// client can answer. The model only picks from this list and code checks every pick; the model gets no tools.
///
/// **Built from code's words alone.** A report's label and holds line come from `ReportCatalog`, a rule's label from
/// `NeedsAttention.Rule.title`; the only words of its own are the summary's label. The inputs are the client's kind, whether it
/// has a Mosyle org and the thresholds: no list data (no `Resource`, `OrgDevice`, name or id) can reach a label, and a scan test
/// holds that. The list is bounded (`limit`); the largest it gets today is `largest`.
public enum Choices {
    /// Apple Business or Apple School Manager. `Assist` may not import `Orgs`, so the caller maps its own `Scope` onto this.
    public enum Scope: Sendable, Equatable { case business, school }

    public struct Choice: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case report(ReportCatalog.ID)
            /// All the rules this client can answer, as the Needs attention screen shows them.
            case attentionSummary
            case rule(NeedsAttention.Rule)
        }

        public let kind: Kind
        /// What a pick list shows, and nothing else.
        public let label: String
        /// What the choice holds, in code's words, for a line after the list; nil for a rule, whose label says it.
        public let holds: String?
        /// The values a second pick may take (a report's `group` values); empty when the choice has none. A number filter
        /// (`days`, `years`) is never here: code parses numbers from the sentence.
        public let groups: [String]

        public var id: String {
            switch kind {
            case .report(let id): "report:\(id.rawValue)"
            case .attentionSummary: "attention"
            case .rule(let rule): "rule:\(rule.rawValue)"
            }
        }
    }

    /// Past about this many, narrow in steps (the shared lessons); `build` never returns more.
    public static let limit = 40
    /// The list's largest size today: six reports, the summary and the twelve rules, for an Apple Business client with Mosyle.
    public static let largest = 19

    /// The summary's label: the one string here that isn't from the catalog or a rule's title.
    public static let summaryLabel = "Needs attention"

    /// The rules that read Apple MDM's device list, which Apple School Manager has no such list for (its contract has no `mdmDevices`).
    static let appleMDMRules: Set<NeedsAttention.Rule> = [.missingFromAppleMDM, .appleMDMNotInApple, .appleMDMCheckIn, .fileVaultOff, .firewallOff]

    public static func rules(scope: Scope, hasMosyle: Bool) -> [NeedsAttention.Rule] {
        NeedsAttention.Rule.allCases.filter { rule in
            if rule.needsMosyle && !hasMosyle { return false }
            if scope == .school && appleMDMRules.contains(rule) { return false }
            return true
        }
    }

    public static func build(scope: Scope, hasMosyle: Bool, thresholds: NeedsAttention.Thresholds) -> [Choice] {
        var choices = ReportCatalog.entries.map { entry in
            Choice(kind: .report(entry.id), label: entry.title, holds: entry.holds,
                   groups: entry.filters.first { $0.name == "group" }?.values ?? [])
        }
        let rules = rules(scope: scope, hasMosyle: hasMosyle)
        let titles = rules.map { $0.title(thresholds) }
        choices.append(Choice(kind: .attentionSummary, label: summaryLabel,
                              holds: "\(summaryLabel): " + titles.joined(separator: "; ") + ".", groups: []))
        for (rule, title) in zip(rules, titles) { choices.append(Choice(kind: .rule(rule), label: title, holds: nil, groups: [])) }
        precondition(choices.count <= limit, "the choice list outgrew its bound")
        return choices
    }
}
