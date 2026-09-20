import SwiftUI

/// ⛔ BUILD 105 — THE DOOR THAT MUST ALWAYS BE THERE.
///
/// **Why this exists, 2026-09-20.** Michael cancelled a running bar and got a grey sheet with
/// no content and no buttons: *"why does this ghost sheet come up? it causes me to have to
/// force quit commander."* Two separate routes produce that, and this closes the second one.
///
/// Four sheets were written as `.sheet(isPresented: $flag) { if let x = optional { … } }`.
/// If the flag is ever true while the optional is nil, SwiftUI presents the sheet and renders
/// **nothing** — and because every Close button lived *inside* the `if let`, the way out
/// disappeared along with the content. A modal with no door leaves Force Quit as the only
/// exit, which on this app means killing a file operation mid-flight.
///
/// ⚠️ The fix is deliberately NOT "work out how the flag and the optional got out of step."
/// That is worth knowing and it is still worth fixing at the source, but it is a *diagnosis*,
/// and a diagnosis cannot be relied on to be complete. **A sheet that cannot be dismissed is
/// a trap whatever the cause**, so the guarantee is structural: there is always something to
/// press. → fail-safe: when state is unexpected, preserve and surface, never strand.
struct SheetRecovery: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("There is nothing to show here.", systemImage: "questionmark.square.dashed")
                .font(.title3)
            Text("This window opened without anything to put in it. Nothing has been changed, and closing it is safe.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
