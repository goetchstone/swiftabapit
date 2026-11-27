import AppModels
import Reports
import SwiftUI
import UniformTypeIdentifiers

/// Needs attention (plan §8.0; the operator's Q6: its own section): what each rule found for the active client, grouped by rule with
/// its counts; why a rule was skipped or judged only in part; Dismiss and Snooze, which write to the local history only; and the CSV.
/// Everything it says comes from `NeedsAttentionModel`. It evaluates again whenever a list it reads changes (`inputKey`).
struct NeedsAttentionView: View {
    @Bindable var model: NeedsAttentionModel
    @State private var exporting = false

    var body: some View {
        let lines = model.lines
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(lines)
                ForEach(lines) { line in rule(line) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked != nil)
                    .help(model.exportBlocked ?? "Saves every finding, and each rule that found none or wasn't judged")
                    .accessibilityIdentifier("attention.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv()) : nil, contentType: .commaSeparatedText,
                      defaultFilename: model.exportFileName) { _ in }
        .fileDialogMessage(model.exportWords)
        .task { await model.load() }
        .task(id: model.inputKey) { await model.evaluate() }
        // Each rule with findings explained by the on-device model, again only when its facts change (S9.12). Only this screen asks:
        // the Overview's card and the intents never do.
        .task(id: model.explainKey) { await model.explain() }
    }

    @ViewBuilder private func header(_ lines: [NeedsAttentionModel.Line]) -> some View {
        if let waiting = model.waiting ?? model.updating {
            Label(waiting, systemImage: "hourglass").accessibilityIdentifier("attention.waiting")
        }
        if let summary = model.summary {
            Text(summary.headline).font(.headline).accessibilityIdentifier("attention.summary")
            ForEach(summary.screenWords, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
        }
        if let note = model.settingsNote {
            Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("attention.settingsnote")
        }
        if let note = model.recordNote {
            Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("attention.recordnote")
        }
        if let note = model.actionNote {
            Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("attention.actionnote")
        }
        if let off = model.explanationsOff {
            Label(off, systemImage: "text.bubble").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("attention.explainoff")
        }
        let hidden = lines.reduce(0) { $0 + $1.hidden }
        if hidden > 0 || model.showsHidden {
            Toggle("Show dismissed and snoozed (\(hidden.formatted()))", isOn: $model.showsHidden)
                .accessibilityIdentifier("attention.showhidden")
        }
    }

    private func rule(_ line: NeedsAttentionModel.Line) -> some View {
        let (findings, cap) = model.shown(line)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // The rule's own words: why it was skipped, what a partial run left out, what it couldn't judge.
                ForEach(Array(line.words.dropFirst().enumerated()), id: \.offset) { _, words in
                    Text(words).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if case .skipped(let why) = line.verdict {
                    Label(why, systemImage: "eye.slash").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let explanation = model.explanation(line) { explained(explanation, rule: line.rule) }
                ForEach(line.source, id: \.self) {
                    Label($0, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { finding in row(finding) }
                }
                if let cap { Text(cap).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(line.title).font(.headline)
                Spacer(minLength: 8)
                Text(count(line)).font(.callout).foregroundStyle(line.open.isEmpty ? Color.secondary : Color.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.rule.\(line.rule.rawValue)")
    }

    /// The on-device model's explanation of a rule's findings, labelled as the model's, with what the checks left out. Shown only.
    @ViewBuilder private func explained(_ explanation: NeedsAttentionModel.Explanation, rule: NeedsAttentionModel.Rule) -> some View {
        Group {
            switch explanation {
            case .writing:
                Label("Explaining with the on-device model…", systemImage: "ellipsis.bubble").font(.callout).foregroundStyle(.secondary)
            case .shown(let sentences, let dropped):
                VStack(alignment: .leading, spacing: 4) {
                    Text(sentences.joined(separator: " ")).fixedSize(horizontal: false, vertical: true)
                    Label([NeedsAttentionModel.explanationLabel, NeedsAttentionModel.droppedWords(dropped)].compactMap { $0 }.joined(separator: " "),
                          systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            case .none(let why):
                Label(why, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attention.explain.\(rule.rawValue)")
    }

    private func count(_ line: NeedsAttentionModel.Line) -> String {
        switch line.verdict {
        case .skipped: return "Skipped"
        case .judged, .partial:
            let open = line.open.isEmpty ? "None open" : "\(line.open.count.formatted()) open"
            return open + (line.hidden > 0 ? ", \(line.hidden.formatted()) hidden" : "") + (line.isPartial ? " · partial, not kept" : "")
        }
    }

    private func row(_ finding: NeedsAttentionModel.Finding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.subject).monospaced().textSelection(.enabled)
                Text(finding.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(state(finding)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Dismiss") { Task { await model.dismiss(finding) } }
                .disabled(finding.actionsBlocked != nil || finding.dismissedAt != nil)
                .help(finding.actionsBlocked ?? "Hides it until it clears: kept in this Mac's history only")
                .accessibilityLabel("Dismiss \(finding.subject)")
                .accessibilityIdentifier("attention.dismiss.\(finding.id)")
            Menu("Snooze") {
                ForEach(NeedsAttentionModel.snoozeDays, id: \.self) { days in
                    Button("For \(days == 7 ? "a week" : "\(days) days")") { Task { await model.snooze(finding, days: days) } }
                }
            }
            .fixedSize()
            .disabled(finding.actionsBlocked != nil)
            .help(finding.actionsBlocked ?? "Hides it until a date: kept in this Mac's history only")
            .accessibilityLabel("Snooze \(finding.subject)")
            .accessibilityIdentifier("attention.snooze.\(finding.id)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attention.finding.\(finding.id)")
    }

    /// First seen, partial, dismissed or snoozed, in words.
    private func state(_ finding: NeedsAttentionModel.Finding) -> String {
        var parts: [String] = []
        if let first = finding.firstSeen { parts.append("First seen \(first.formatted(date: .abbreviated, time: .omitted))") }
        if finding.isPartial { parts.append("Found over a part read: not kept") } else if finding.firstSeen == nil { parts.append("Not kept") }
        if let dismissed = finding.dismissedAt { parts.append("Dismissed \(dismissed.formatted(date: .abbreviated, time: .omitted))") }
        if let until = finding.snoozedUntil, finding.isHidden { parts.append("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }
}

/// The Overview's Needs-attention card: counts only, the open findings per rule and a line for the rules skipped, and the way to
/// the screen (the operator's Q6). No serial number or name is on it.
struct NeedsAttentionCard: View {
    let model: NeedsAttentionModel
    let open: () -> Void

    var body: some View {
        DashboardCard("Needs attention", id: "attention", words: words) {
            if let summary = model.summary {
                if !summary.rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.rows) { row in
                            HStack {
                                Text(row.title).lineLimit(2)
                                Spacer(minLength: 8)
                                Text(row.open.formatted() + (row.partial ? " (partial)" : "")).monospacedDigit().foregroundStyle(.orange)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .accessibilityIdentifier("overview.attention.rows")
                }
                ForEach(summary.words, id: \.self) {
                    Text($0).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("overview.attention.words")
            }
            Button("Open Needs Attention", action: open).accessibilityIdentifier("overview.attention.open")
        }
        .task { await model.load() }
        .task(id: model.inputKey) { await model.evaluate() }
    }

    /// The card's first line: still judging, judging again, or why nothing is kept; the counts' own words come from the model's summary.
    private var words: String? { model.waiting ?? model.updating ?? model.recordNote }
}
