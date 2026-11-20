import AppKit
import SwitcherCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var state = SwitcherState()
    @Published var sessions: [DesktopSession] = []
    @Published var isBusy = false

    let env = SwitcherEnvironment.live(desktop: LiveDesktopApp())
    private var switcher: Switcher { Switcher(env: env) }

    init() { reload() }

    var active: Profile? { state.activeId.flatMap { state.profile($0) } }
    var others: [Profile] { state.profiles.filter { $0.id != state.activeId } }

    func reload() {
        state = (try? env.store.load()) ?? SwitcherState()
        if let p = active {
            sessions = Array(((try? env.sessions.list(account: p.id, org: p.orgUuid)) ?? []).prefix(10))
        } else {
            sessions = []
        }
    }

    func isShared(_ id: String) -> Bool { state.shareAll || state.sharedSessionIds.contains(id) }

    func toggleShared(_ id: String) {
        if state.sharedSessionIds.contains(id) { state.sharedSessionIds.remove(id) } else { state.sharedSessionIds.insert(id) }
        persist()
    }

    func setShareAll(_ on: Bool) {
        state.shareAll = on
        persist()
    }

    func switchTo(_ profile: Profile) async {
        let running = (try? RunningClaude().cliProcessCount()) ?? 0
        if running > 0 || env.desktop.isRunning {
            let alert = NSAlert()
            alert.messageText = "Switch to \(profile.label)?"
            alert.informativeText = "Claude is running. Running CLI sessions keep the old account until restarted. Desktop will be quit and relaunched."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        isBusy = true
        defer { isBusy = false; reload() }
        do {
            let result = try await switcher.switchTo(profile.id)
            var body = "Restart running `claude` and reload VS Code's Claude panel; use `claude --resume` to continue."
            if !result.sharedSessionIds.isEmpty { body += " Shared \(result.sharedSessionIds.count) session(s)." }
            body += result.warnings.map { " " + $0 }.joined()
            notify(title: "Now on \(profile.label)", body: body)
        } catch {
            showError(error)
        }
    }

    func captureCurrent(label: String, role: ProfileRole, includeDesktop: Bool) async {
        isBusy = true
        defer { isBusy = false; reload() }
        do {
            let p = try await switcher.captureCurrent(label: label, role: role, includeDesktop: includeDesktop)
            notify(title: "Saved \(p.label)", body: p.email)
        } catch {
            showError(error)
        }
    }

    func remove(_ profile: Profile) {
        try? env.secrets.delete(service: ServiceNames.vault(profile.id))
        try? FileManager.default.removeItem(at: SwitcherEnvironment.switcherRoot.appendingPathComponent("vault/\(profile.id)"))
        state.profiles.removeAll { $0.id == profile.id }
        if state.activeId == profile.id { state.activeId = nil }
        persist()
    }

    private func persist() {
        do { try env.store.save(state) } catch { showError(error) }
        reload()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        switch error {
        case SwitchError.stepFailed(let step, let underlying):
            alert.messageText = "Switch failed at: \(step)"
            alert.informativeText = "Nothing was changed.\n\n\(underlying)"
        case SwitchError.noLiveLogin:
            alert.messageText = "No Claude Code login found"
            alert.informativeText = "Sign in with `claude` then `/login` first."
        case SwitchError.missingSecret(let label):
            alert.messageText = "Saved login for \(label) is missing"
            alert.informativeText = "Sign in to that account again and use Save current login."
        case SwitchError.alreadyActive:
            alert.messageText = "That account is already active"
        default:
            alert.messageText = "Something went wrong"
            alert.informativeText = String(describing: error)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter needs a real app bundle; under `swift run` fall back to nothing.
        guard Bundle.main.bundleIdentifier != nil else { print("\(title): \(body)"); return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
