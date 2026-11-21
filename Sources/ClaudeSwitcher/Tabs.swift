import SwiftUI
import SwitcherCore

struct UsageTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.showSetup { SetupCard(model: model) }
            if model.state.profiles.count < 2 && !model.showSetup {
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
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
            Card {
                Text("Appearance").font(.callout.bold())
                Picker("", selection: $model.appearance) {
                    ForEach(AppModel.Appearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Card {
                Text("Usage shows").font(.callout.bold())
                Picker("", selection: $model.menuBarMode) {
                    Text("Remaining").tag(UsageDisplayMode.remaining)
                    Text("Used").tag(UsageDisplayMode.used)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("Applies to the menu bar and the account cards. The menu bar shows the active account's 5-hour session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Toggle("Switch automatically when 5% is left", isOn: $model.autoSwitch)
                Text("When the active account's session or weekly limit drops to 5% left, switch to the account with the most left (at least 20%). Claude Desktop restarts; running `claude` needs a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Button("Show setup guide") {
                    model.setupHidden = false
                    model.showSettings = false
                    model.tab = .usage
                }
                .controlSize(.small)
            }
            Card {
                Text("About").font(.callout.bold())
                Text("Usage is live for the active account, and for other accounts while their saved sign-in is still valid; otherwise the last known numbers are shown.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sessions stay on this Mac. Switching never uploads or deletes them.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Claude Switcher \(model.version)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SetupCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let steps = model.setupSteps
        Card {
            HStack {
                Text("Get set up").font(.callout.bold())
                Text("\(steps.filter(\.done).count) of \(steps.count) done").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Hide") { model.setupHidden = true }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                SetupRow(model: model, step: step)
            }
        }
    }
}

struct SetupRow: View {
    @ObservedObject var model: AppModel
    let step: SetupGuide.Step

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !step.done { action }
            }
            Spacer(minLength: 0)
        }
    }

    private func profile(_ id: String?) -> Profile? { id.flatMap { model.state.profile($0) } }

    private var title: String {
        switch step.kind {
        case .installClaudeCode: "Install Claude Code"
        case .addMain: "Add your main account"
        case .addBackup: "Add your backup account"
        case .desktopSignIn(let id): "Claude Desktop: sign in once as \(profile(id)?.label ?? "each account")"
        case .vsCode: "VS Code: nothing to do"
        }
    }

    private var detail: String {
        switch step.kind {
        case .installClaudeCode:
            return "The switcher uses Claude Code's sign-in. Install it, then reopen this panel."
        case .addMain:
            return "Opens the Claude website. Sign in with the account you use most."
        case .addBackup:
            return "On claude.ai in your browser, switch to the other account first (or use a private window), then add it here."
        case .desktopSignIn(let id):
            guard let p = profile(id) else { return "After adding accounts, Claude Desktop needs one sign-in per account." }
            if step.done { return "Saved — Desktop switches with you." }
            if model.desktopAccountId == nil { return "Open Claude Desktop and sign in as \(p.email)." }
            return p.id == model.state.activeId
                ? "In Claude Desktop, log out and sign in as \(p.email). The switcher remembers it."
                : "Switch to \(p.label), then in Claude Desktop log out and sign in as \(p.email)."
        case .vsCode:
            return "It uses Claude Code's login. After a switch, reload the VS Code window."
        }
    }

    @ViewBuilder private var action: some View {
        switch step.kind {
        case .installClaudeCode:
            Button("How to install") { model.openInstallGuide() }.controlSize(.small)
        case .addMain, .addBackup:
            Button("Add account") { model.addAccount() }.controlSize(.small).disabled(model.isAdding || model.isBusy)
        default:
            EmptyView()
        }
    }
}
