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
            if model.showSettings {
                Text("Settings").font(.headline)
                SettingsView(model: model)
            } else {
                Picker("", selection: $model.tab) {
                    ForEach(AppModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ScrollView {
                    switch model.tab {
                    case .usage: UsageTab(model: model)
                    case .costs: CostsTab(model: model)
                    case .accounts: AccountsTab(model: model)
                    }
                }
                .frame(height: 560)
            }
            footer
        }
        .padding(14)
        .frame(width: 380)
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
            Button { model.showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
    }
}
