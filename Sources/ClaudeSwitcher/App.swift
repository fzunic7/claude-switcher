import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Label(model.active.map { $0.role == .main ? "M" : "B" } ?? "?", systemImage: "person.2.circle")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.menu)

        Window("Claude Accounts", id: "accounts") {
            AccountsWindow(model: model)
        }
        .windowResizability(.contentSize)
    }
}
