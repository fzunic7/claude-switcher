import SwiftUI
import SwitcherCore

struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = model.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            // One fixed-height area for tabs and settings, so the panel never changes size.
            VStack(spacing: 12) {
                if model.showSettings {
                    ScrollView { SettingsView(model: model).padding(.horizontal, 2) }
                } else {
                    Picker("", selection: $model.tab) {
                        ForEach(AppModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ScrollView {
                        Group {
                            switch model.tab {
                            case .usage: UsageTab(model: model)
                            case .costs: CostsTab(model: model)
                            case .accounts: AccountsTab(model: model)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .frame(height: 600, alignment: .top)
            footer
        }
        .padding(14)
        .frame(width: 380)
        .preferredColorScheme(model.appearance.colorScheme)
        .onAppear { model.panelOpened() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.active?.label ?? "No account").font(.title3.bold())
                    PlanBadge(plan: model.active?.plan)
                }
                Text(model.active?.email ?? "Add an account to get started").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            Button { Task { await model.refreshUsage(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh usage")
            .disabled(model.isRefreshing)
            Button { model.showSettings.toggle() } label: {
                Image(systemName: model.showSettings ? "gearshape.fill" : "gearshape")
            }
                .help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
    }
}
