import AppIntents
import AppModels
import SwiftUI

/// What an intent says and shows, all of it `Answers`' words: the spoken answer as the dialog and as the value Shortcuts passes on,
/// and a snippet of the rows (serial, model, state; at most 10), with the cap and any estimate said beneath (the operator, 2026-11-24:
/// Q5 "Counts aloud, 10 rows"). No intent words an answer itself.
struct AnswerSnippet: View {
    let answer: Answers.Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answer.lead)
                .font(.headline)
            if !answer.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(Answers.Answer.columns, id: \.self) { Text($0).font(.caption.bold()) }
                    }
                    ForEach(Array(answer.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.serial).monospaced()
                            Text(row.model)
                            Text(row.state)
                        }
                        .font(.callout)
                    }
                }
            }
            if let cap = answer.capNote {
                Text(cap).font(.caption).foregroundStyle(.secondary)
            }
            if let estimate = answer.estimateNote {
                Text(estimate).font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The intent's result: the spoken words as dialog and value, the rows as the snippet.
    @MainActor
    static func result(_ answer: Answers.Answer) -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        .result(value: answer.spoken, dialog: IntentDialog("\(answer.spoken)"), view: AnswerSnippet(answer: answer))
    }
}
