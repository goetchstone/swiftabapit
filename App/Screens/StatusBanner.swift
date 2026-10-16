import AppModels
import SwiftUI

/// Where a list's data stands, always in words (invariant 8): loading and how far, loaded and when, cut short
/// by the page cap, forbidden for this role, failed and why (and how many rows were read before it), or unusable
/// and why.
struct StatusBanner: View {
    let state: LoadState
    var shown: Int? = nil
    var truncated = false
    /// Apple's own total, when it gives one.
    var total: Int? = nil
    /// Rows a failed read left on screen: "partial: N rows read before the error".
    var partial: Int? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                EmptyView()
            case .loading(let count):
                ProgressView().controlSize(.small)
                Text(count == 0 ? "Loading…" : "Loading… \(count.formatted()) so far")
            case .loaded(let at):
                if truncated {
                    Label("Showing \((shown ?? 0).formatted()) of \(total.map { $0.formatted() } ?? "more than \((shown ?? 0).formatted())"): the list stopped at the page limit.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text("As of \(at.formatted(.relative(presentation: .named)))")
                    }
                    .foregroundStyle(.secondary)
                }
            case .forbidden:
                Label("Your role can't read this. An administrator can change the API account's role in Apple Business."
                      + (partial.map { " Partial: \($0.formatted()) rows read before the refusal." } ?? ""),
                      systemImage: "lock")
            case .failed(let message):
                Label(message + (partial.map { " Partial: \($0.formatted()) rows read before the error." } ?? ""),
                      systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                if let retry { Button("Try Again", action: retry) }
            case .unusable(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status.banner")
    }
}
