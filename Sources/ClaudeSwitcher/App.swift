import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    var body: some Scene {
        MenuBarExtra("Claude Switcher", systemImage: "person.2.circle") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
