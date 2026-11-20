import SwiftUI
import SwitcherCore

struct MenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let active = model.active {
            Text("● \(active.label)  (\(active.email))")
        } else {
            Text("No account saved yet")
        }
        ForEach(Array(model.others.enumerated()), id: \.element.id) { index, profile in
            let button = Button("Switch to \(profile.label)") { Task { await model.switchTo(profile) } }
                .disabled(model.isBusy)
            if index == 0 { button.keyboardShortcut("b", modifiers: [.command, .shift]) } else { button }
        }
        Divider()
        if let active = model.active {
            Text("Sessions on \(active.label)  (★ = shared)")
            if model.sessions.isEmpty { Text("No Desktop Code sessions") }
            ForEach(model.sessions) { session in
                Button("\(model.isShared(session.id) ? "★" : "☆") \(session.title) — \(folderName(session.cwd)) · \(session.lastActivityAt.formatted(.relative(presentation: .named)))") {
                    model.toggleShared(session.id)
                }
                .disabled(model.state.shareAll)
            }
            Divider()
        }
        Button("Accounts…") { open() }
        Button("Refresh") { model.reload() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func folderName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }

    private func open() {
        openWindow(id: "accounts")
        NSApp.activate(ignoringOtherApps: true)
    }
}
