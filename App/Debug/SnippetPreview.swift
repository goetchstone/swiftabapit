#if DEBUG
import AppModels
import SwiftUI

/// Debug builds only: `ABAPIT_SNIPPET=<a report's id>` puts in the window what an intent says and shows for that report over the
/// demo org (the dialog's words above the snippet, as Siri shows them), so CI's screenshots draw the snippet
/// (`scripts/screenshots.sh`). It is the snippet's own view; Siri's frame around it isn't drawn.
struct SnippetPreview: View {
    let screens: ScreenModels
    let report: ReportsModel.Report
    @State private var answer: Answers.Answer?

    static var requested: ReportsModel.Report? {
        ProcessInfo.processInfo.environment["ABAPIT_SNIPPET"].flatMap(ReportsModel.Report.init(rawValue:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let answer {
                Text(answer.spoken)
                    .fixedSize(horizontal: false, vertical: true)
                AnswerSnippet(answer: answer)
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
            } else {
                ProgressView()
            }
        }
        .padding()
        .frame(width: 560, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { answer = await screens.answers.answer(report: report, tokens: [:]) }
    }
}
#endif
