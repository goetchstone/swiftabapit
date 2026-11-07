import SwiftUI

/// The snapshot harness's row selection (plan §6.5). `ABAPIT_SELECT=first` asks the screen on show to select the first
/// row its table shows, once its list has loaded, so the picture shows that row's inspector (`<name>-detail` and the
/// `narrow-*` runs in `scripts/screenshots.sh`). `ContentView` reads the switch, in debug builds only, and hands it down
/// as `selectsFirstRow`; each screen with an inspector adopts the hook on the view that owns its selection:
///
///     Table(model.shown, selection: $selection) { … }
///         .selectsFirstRow($selection, first: model.shown.first?.id, ready: !model.state.isLoading)
///
/// `first` is the first row as the table shows it (sorted and filtered), `ready` that its read has ended. In Release,
/// and whenever the harness didn't ask, it does nothing: no switch is read here. The harness fails a `first` run whose
/// screen selected nothing (`FirstRowSelected`), since its picture would show no inspector and look like a pass.
extension EnvironmentValues {
    /// Whether the snapshot harness asked for the first row (`ABAPIT_SELECT=first`); always false in Release.
    @Entry var selectsFirstRow = false
}

extension View {
    /// Selects `first`, once, when the harness asked and the screen is `ready` with a first row.
    func selectsFirstRow<ID: Hashable>(_ selection: Binding<ID?>, first: ID?, ready: Bool) -> some View {
        modifier(FirstRowSelection(selection: selection, first: first, ready: ready))
    }
}

private struct FirstRowSelection<ID: Hashable>: ViewModifier {
    @Environment(\.selectsFirstRow) private var asked
    @Binding var selection: ID?
    let first: ID?
    let ready: Bool
    /// Once only: a later reload (an org switch) never moves the operator's selection.
    @State private var done = false

    func body(content: Content) -> some View {
        content.onChange(of: asked && ready && first != nil, initial: true) { _, now in
            guard now, !done, let first else { return }
            done = true
            selection = first
            #if DEBUG
            FirstRowSelected.yet = true
            #endif
        }
    }
}

#if DEBUG
/// Whether a screen's hook has selected its first row: `Snapshots` fails a run that asked (`ABAPIT_SELECT=first`) and got
/// none, a screen that never adopted the hook or never became ready, rather than writing a `-detail` picture without its
/// inspector (the scaffold's open question at the Phase 2b merge).
@MainActor
enum FirstRowSelected {
    static var yet = false
}
#endif
