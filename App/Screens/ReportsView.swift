import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// Reports (plan Phase 3): the six reports in a list, the chosen one's result beside it. Everything it says comes from
/// `ReportsModel`; the view lays it out. It reads the local history and the Devices model's lists, and never starts a
/// sweep or a snapshot.
struct ReportsView: View {
    @Bindable var model: ReportsModel
    @State private var exporting = false

    var body: some View {
        let output = model.current
        HStack(spacing: 0) {
            List(ReportsModel.Report.allCases, selection: Binding(get: { Optional(model.report) }, set: { if let pick = $0 { model.select(pick) } })) { report in
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title).fontWeight(.medium)
                    Text(report.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .tag(report)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reports.item.\(report.rawValue)")
            }
            .frame(width: 270)
            .accessibilityIdentifier("reports.list")
            Divider()
            detail(output)
        }
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked(for: output) != nil)
                    .help(model.exportBlocked(for: output) ?? "Saves the report shown")
                    .accessibilityIdentifier("reports.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv(of: output)) : nil, contentType: .commaSeparatedText,
                      defaultFilename: model.exportFileName(for: output)) { _ in }
        .fileDialogMessage(model.exportWords(for: output))
        .task { await model.load() }
    }

    private func detail(_ output: ReportsModel.Output) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(output.title).font(.title2).fontWeight(.semibold).accessibilityIdentifier("reports.title")
                // A history that couldn't be read is said once, by the report that needs it (its "judges nothing" or its source line).
                if case .loading = model.state {
                    Label("Reading the snapshot history…", systemImage: "hourglass")
                }
                filters(output)
                ForEach(output.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                ForEach(output.source, id: \.self) { Label($0, systemImage: "clock.arrow.circlepath").accessibilityIdentifier("reports.source") }
                if let nothing = output.judgesNothing {
                    Label(nothing, systemImage: "eye.slash").accessibilityIdentifier("reports.judgesnothing")
                } else {
                    GroupBox("Summary") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(output.summary, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        .accessibilityIdentifier("reports.summary")
                    }
                    if let estimate = output.estimateNote { Label(estimate, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("reports.estimate") }
                    rows(output)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("reports.detail")
    }

    @ViewBuilder private func filters(_ output: ReportsModel.Output) -> some View {
        HStack(spacing: 16) {
            switch model.report {
            case .coverage:
                Stepper("Ending within \(model.coverageDays) days", value: $model.coverageDays, in: ReportsModel.daysRange, step: 30)
                    .accessibilityIdentifier("reports.days")
            case .fleetAge:
                Stepper("\(model.fleetYears) or more years old", value: $model.fleetYears, in: ReportsModel.yearsRange)
                    .accessibilityIdentifier("reports.years")
            case .serviceHealth:
                Stepper("Quiet after \(model.quietDays) days", value: $model.quietDays, in: ReportsModel.quietDaysRange, step: 10)
                    .accessibilityIdentifier("reports.quietdays")
            default: EmptyView()
            }
            if !output.groups.isEmpty {
                Picker("Group", selection: Binding(get: { model.group ?? "" }, set: { model.setGroup($0.isEmpty ? nil : $0) })) {
                    Text("All groups").tag("")
                    ForEach(output.groups) { Text("\($0.key) (\($0.count.formatted()))").tag($0.key) }
                }
                .frame(maxWidth: 320)
                .accessibilityIdentifier("reports.group")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func rows(_ output: ReportsModel.Output) -> some View {
        if output.lines.isEmpty {
            Label("No rows to list for these filters.", systemImage: "tray").foregroundStyle(.secondary).accessibilityIdentifier("reports.norows")
        } else {
            Text("\(output.matching.formatted()) row\(output.matching == 1 ? "" : "s")").font(.headline)
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(output.lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title).fontWeight(.medium)
                        Text(line.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("reports.rows")
            if let cap = output.capNote { Text(cap).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("reports.cap") }
        }
        Text(output.exportNote).font(.callout).foregroundStyle(.secondary)
    }
}
