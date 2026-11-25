import Foundation

/// The plain alternative the model must beat (shared lessons, "Testing": measure it in the same run): the choice whose label
/// and group words share the most whole words with the sentence. No model, no list data, no learning. A word rule fits the
/// words it was written for, so it is scored on the dev samples in the fast run and on the held-out ones beside the model.
///
/// It also keeps a short list of change words, so a request to change something is a "change request" and not a report: the
/// same split the model's first pick makes, so the two are scored alike.
public enum WordRule {
    public enum Answer: Sendable, Equatable {
        /// A choice's `id`, and the group whose words the sentence shares most; nil when it names none (all of them).
        case choice(String, group: String?)
        /// A request to change something: nothing is drafted in this version.
        case changeRequest
        /// Nothing in the sentence is a word any choice holds.
        case refuse
    }

    /// Words that carry no choice: dropped from both sides.
    static let ignored: Set<String> = [
        "a", "an", "the", "of", "in", "on", "to", "is", "are", "was", "were", "be", "do", "does", "did", "i", "me", "my", "we", "our",
        "you", "your", "it", "its", "this", "that", "these", "those", "and", "or", "for", "with", "by", "at", "as", "from", "all",
        "any", "show", "list", "give", "get", "tell", "what", "which", "who", "how", "many", "much", "can", "could", "would", "please",
        "have", "has", "had", "there", "them", "than", "more", "not", "but", "out", "up", "no", "by", "if", "so",
    ]

    /// A sentence that starts or contains one of these asks for a change, not a read.
    static let changeWords: Set<String> = [
        "assign", "unassign", "reassign", "move", "release", "delete", "remove", "wipe", "erase", "enroll", "unenroll", "rename",
        "change", "disable", "enable", "install", "reset", "restart", "create",
    ]

    /// Lowercased whole words, split on anything that isn't a letter or digit, a plural's trailing s dropped, the ignored dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map { word -> String in
            let word = String(word)
            return word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        }.filter { !ignored.contains($0) }
    }

    public static func answer(_ sentence: String, choices: [Choices.Choice]) -> Answer {
        let said = Set(words(sentence))
        if !said.isDisjoint(with: changeWords) { return .changeRequest }
        var best: (choice: Choices.Choice, score: Int)?
        for choice in choices {
            let score = said.intersection(Set(words(choice.label))).count
            // Strictly greater: a tie keeps the earlier choice, the list's order being code's (reports first).
            if score > 0, score > (best?.score ?? 0) { best = (choice, score) }
        }
        guard let best else { return .refuse }
        // A group's words count when the choice's own label doesn't already have them: "lock" names the report, not "lock:USER".
        let named = Set(words(best.choice.label))
        var group: (value: String, score: Int)?
        for value in best.choice.groups {
            let score = said.intersection(Set(words(value)).subtracting(named)).count
            if score > 0, score > (group?.score ?? 0) { group = (value, score) }
        }
        return .choice(best.choice.id, group: group?.value)
    }
}
