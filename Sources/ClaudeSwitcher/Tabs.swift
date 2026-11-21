import SwiftUI
import SwitcherCore

struct UsageTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.state.profiles.count < 2 {
                Card {
                    Text(model.state.profiles.isEmpty ? "Add your Claude accounts" : "Add your other account")
                        .font(.callout.bold())
                    Text("Sign in on the Claude website and it's saved automatically. You can also run `claude auth login` yourself — I'll pick it up.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Add account") { model.addAccount() }.disabled(model.isAdding || model.isBusy)
                    Text("Tip: sign in to that account on claude.ai in your browser first — the sign-in uses whoever is logged in there.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(model.orderedProfiles) { AccountCard(model: model, profile: $0) }
        }
    }
}

struct CostsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.state.profiles.isEmpty {
                Text("No accounts yet").foregroundStyle(.secondary)
            }
            ForEach(model.orderedProfiles) { profile in
                Card {
                    HStack {
                        Text(profile.email).font(.callout.bold()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        PlanBadge(plan: profile.plan)
                    }
                    extraUsage(model.usage[profile.id]?.extra)
                    AsOfLine(usage: model.usage[profile.id])
                }
            }
            Text("Extra usage is spending beyond your plan, billed monthly.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func extraUsage(_ extra: ExtraUsage?) -> some View {
        if let extra {
            if !extra.isEnabled {
                HStack { Text("Extra usage"); Spacer(); Text("Off").foregroundStyle(.secondary) }.font(.callout)
            } else {
                let used = extra.usedCredits ?? 0
                HStack {
                    Text("This month").font(.callout)
                    Spacer()
                    if let limit = extra.monthlyLimit {
                        Text("\(extra.formatted(used)) of \(extra.formatted(limit))").font(.callout.monospacedDigit())
                    } else {
                        Text(extra.formatted(used)).font(.callout.monospacedDigit())
                    }
                }
                if let limit = extra.monthlyLimit, limit > 0 { UsageBar(fraction: used / limit) }
                if extra.spendLimitReached {
                    Label("Monthly limit reached", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        } else {
            Text("No data yet").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AccountsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.orderedProfiles) { profile in
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            if model.renamingId == profile.id {
                                TextField("Name", text: $model.renameText, onCommit: { model.commitRename() })
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                HStack(spacing: 6) {
                                    Text(profile.label).font(.callout.bold())
                                    if profile.id == model.state.activeId { StatusBadge(text: "Active") }
                                    Text(profile.role == .main ? "Main" : "Backup").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(profile.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        PlanBadge(plan: profile.plan)
                    }
                    HStack {
                        if profile.id != model.state.activeId {
                            Button("Switch") { Task { await model.switchTo(profile) } }
                        }
                        if model.renamingId == profile.id {
                            Button("Done") { model.commitRename() }
                        } else {
                            Button("Rename") { model.startRename(profile) }
                        }
                        if profile.role != .main { Button("Make Main") { model.makeMain(profile) } }
                        Spacer()
                        Button("Remove", role: .destructive) { model.remove(profile) }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy || model.isAdding)
                }
            }
            if model.isAdding {
                Card {
                    if model.signInStalled {
                        Text("The browser sign-in didn't finish. Try again in Terminal, or cancel.").font(.callout)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to sign in in the browser…").font(.callout)
                        }
                        Text("The browser signs in whoever is logged in to claude.ai there. To add a different account, switch accounts on claude.ai (or use a private window) before approving.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Use Terminal instead") { model.signInInTerminal() }
                        Spacer()
                        Button("Cancel") { model.cancelAdd() }
                    }
                    .controlSize(.small)
                }
            } else {
                Button { model.addAccount() } label: { Label("Add account", systemImage: "plus") }
                    .disabled(model.isBusy)
                Text("Tip: sign in to the account you want to add on claude.ai in your browser first.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            Text("Usage comes from Claude's usage service (live for the active account, and for other accounts while their saved sign-in is still valid), otherwise the last known numbers.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sessions stay on this Mac. Switching never uploads or deletes them.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Done") { model.showSettings = false }
        }
    }
}
