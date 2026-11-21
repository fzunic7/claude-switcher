import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @StateObject private var model = AppModel()

    init() {
        Screenshots.renderIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(model.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
