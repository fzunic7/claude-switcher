import AppKit
import SwiftUI
import ServiceManagement
import SwitcherCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
        var nsAppearance: NSAppearance? {
            self == .light ? NSAppearance(named: .aqua) : self == .dark ? NSAppearance(named: .darkAqua) : nil
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case usage = "Usage", costs = "Costs", accounts = "Accounts"
        var id: String { rawValue }
    }

    @Published var state = SwitcherState()
    @Published var usage: [String: AccountUsage] = [:]
    @Published var tab: Tab = .usage
    @Published var showSettings = false
    @Published var isBusy = false
    @Published var isAdding = false
    @Published var isRefreshing = false
    @Published var renamingId: String?
    @Published var renameText = ""
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var appearance: Appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApp.appearance = appearance.nsAppearance
        }
    }
    @Published var menuBarMode: UsageDisplayMode = UsageDisplayMode(rawValue: UserDefaults.standard.string(forKey: "menuBarMode") ?? "") ?? .remaining {
        didSet { UserDefaults.standard.set(menuBarMode.rawValue, forKey: "menuBarMode") }
    }
    @Published var setupHidden = UserDefaults.standard.bool(forKey: "setupHidden") {
        didSet { UserDefaults.standard.set(setupHidden, forKey: "setupHidden") }
    }
    @Published var lowUsageAlerts = UserDefaults.standard.object(forKey: "lowUsageAlerts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lowUsageAlerts, forKey: "lowUsageAlerts") }
    }
    /// Limit windows already announced (see `LowUsageAlert.Alert.key`).
    private var announcedKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: "announcedLowUsage") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(50)), forKey: "announcedLowUsage") }
    }
    private let notifications = NotificationHandler()
    @Published var autoSwitch = UserDefaults.standard.bool(forKey: "autoSwitch") {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch") }
    }
    private var lastAutoSwitch: Date? {
        get { UserDefaults.standard.object(forKey: "lastAutoSwitch") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastAutoSwitch") }
    }
    @Published var claudeInstalled = true
    @Published var desktopAccountId: String?
    let isDemo: Bool
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Problems found by background checks; shown in the panel instead of interrupting with alerts.
    @Published var statusMessage: String?
    /// The background sign-in ended without adding an account.
    @Published var signInStalled = false

    let env = SwitcherEnvironment.live(desktop: LiveDesktopApp())
    private lazy var watcher = AccountWatcher(env: env)
    private lazy var usageService = UsageService(secrets: env.secrets, claudeJSON: env.claudeJSON, store: env.store)
    private var switcher: Switcher { Switcher(env: env) }

    private var timer: Timer?
    private var lastAccountCheck = Date.distantPast
    private var lastUsageRefresh = Date.distantPast
    private var loginProcess: Process?
    private var addStartedAt: Date?
    private var checkInFlight = false

    /// Fake accounts for documentation screenshots; nothing is read from or written to this Mac.
    init(demo: SwitcherState, usage: [String: AccountUsage]) {
        isDemo = true
        state = demo
        self.usage = usage
        desktopAccountId = demo.activeId
    }

    var setupSteps: [SetupGuide.Step] {
        SetupGuide.steps(state: state, claudeInstalled: claudeInstalled, desktopAccountId: desktopAccountId)
    }

    var showSetup: Bool { !setupHidden && !SetupGuide.isComplete(setupSteps) }

    private func refreshSetupFacts() {
        let env = self.env
        Task {
            let facts = await Task.detached { (LoginLauncher.claudePath() != nil, env.desktopAccount.signedInAccount()?.id) }.value
            claudeInstalled = facts.0
            desktopAccountId = facts.1
        }
    }

    func openInstallGuide() {
        NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
    }

    init() {
        isDemo = false
        installNotifications()
        reload()
        refreshSetupFacts()
        notifications.model = self
        DispatchQueue.main.async { [appearance] in NSApp.appearance = appearance.nsAppearance }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await checkAccounts(); await refreshUsage(force: true) }
    }

    // MARK: Derived

    var active: Profile? { state.activeId.flatMap { state.profile($0) } }

    /// Active first, then main, then the rest by label.
    var orderedProfiles: [Profile] {
        state.profiles.sorted { a, b in
            if (a.id == state.activeId) != (b.id == state.activeId) { return a.id == state.activeId }
            if a.role != b.role { return a.role == .main }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    var menuBarTitle: String {
        guard let active else { return "Claude" }
        return UsageDisplay.menuBarTitle(label: active.label, usage: usage[active.id], mode: menuBarMode)
    }

    // MARK: Timers

    private func tick() async {
        if let started = addStartedAt, Date().timeIntervalSince(started) > 300 { cancelAdd() }
        var loginJustEnded = false
        if isAdding, let p = loginProcess, !p.isRunning {
            loginProcess = nil
            watcher.signInInProgress = false
            loginJustEnded = true
            if p.terminationStatus != 0 { signInStalled = true }
        }
        if isAdding || Date().timeIntervalSince(lastAccountCheck) >= 30 { await checkAccounts() }
        // A finished sign-in that added nothing (e.g. the same account again) ends the wait.
        if loginJustEnded, isAdding, !signInStalled { cancelAdd() }
        if Date().timeIntervalSince(lastUsageRefresh) >= 300 { await refreshUsage(force: true) }
    }

    func panelOpened() {
        guard !isDemo else { return }
        refreshSetupFacts()
        Task { await checkAccounts(); await refreshUsage(force: false) }
    }

    func reload() {
        guard !isDemo else { return }
        state = (try? env.store.load()) ?? SwitcherState()
    }

    // MARK: Accounts

    func checkAccounts() async {
        lastAccountCheck = Date()
        guard !isBusy, !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        do {
            let event = try await watcher.check()
            switch event {
            case .none: break
            case .activeChanged: break
            case .added(let p):
                notify(title: "Added \(p.email)", body: "Saved as \(p.role == .main ? "Main" : "Backup").")
            case .addedAndRestored(let p, let restored):
                let back = state.profile(restored)?.label ?? "your previous account"
                notify(title: "Added \(p.email)", body: "You're still on \(back).")
            }
            if event != .none { reload(); await refreshUsage(force: true) }
            statusMessage = nil
        } catch {
            statusMessage = "Couldn't check accounts: \(describe(error))"
        }
        if isAdding && !watcher.isAdding { finishAdd() }
    }

    func addAccount() {
        guard !isAdding, !isBusy else { return }
        isAdding = true
        signInStalled = false
        tab = .accounts
        let watcher = self.watcher
        Task {
            do {
                // Saving the current login and finding `claude` run subprocesses: keep them off the main thread.
                let process: Process? = try await Task.detached {
                    try watcher.beginAdd()
                    if let p = try? LoginLauncher.startLogin() { return p }
                    try LoginLauncher.openInTerminal()
                    return nil
                }.value
                loginProcess = process
                watcher.signInInProgress = process != nil
                addStartedAt = Date()
            } catch {
                watcher.cancelAdd()
                isAdding = false
                showError(error)
            }
        }
    }

    func signInInTerminal() {
        if let p = loginProcess, p.isRunning { p.terminate() }
        loginProcess = nil
        watcher.signInInProgress = false
        signInStalled = false
        addStartedAt = Date()
        do { try LoginLauncher.openInTerminal() } catch { showError(error) }
    }

    /// Stops waiting; if the sign-in removed or replaced your login, the previous account is put back.
    func cancelAdd() {
        if let p = loginProcess, p.isRunning { p.terminate() }
        watcher.signInInProgress = false
        do { try watcher.abandonAdd() } catch { showError(error) }
        finishAdd()
        reload()
    }

    private func finishAdd() {
        loginProcess = nil
        addStartedAt = nil
        isAdding = false
        signInStalled = false
    }

    func startRename(_ profile: Profile) {
        renamingId = profile.id
        renameText = profile.label
    }

    func commitRename() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        if let id = renamingId, !text.isEmpty, let i = state.profiles.firstIndex(where: { $0.id == id }) {
            state.profiles[i].label = text
            persist()
        }
        renamingId = nil
    }

    func makeMain(_ profile: Profile) {
        for i in state.profiles.indices { state.profiles[i].role = state.profiles[i].id == profile.id ? .main : .backup }
        persist()
    }

    func remove(_ profile: Profile) {
        guard !isBusy else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.email)?"
        alert.informativeText = "This deletes its saved login. Your sessions are not affected. Add it again any time by signing in."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        let switcher = self.switcher
        Task {
            do { try await Task.detached { try switcher.removeProfile(profile.id) }.value } catch { showError(error) }
            usage[profile.id] = nil
            isBusy = false
            reload()
        }
    }

    private func persist() {
        // Merge onto the latest file so a concurrent switch/watch isn't overwritten.
        guard var latest = try? env.store.load() else { return }
        for edited in state.profiles {
            guard let i = latest.profiles.firstIndex(where: { $0.id == edited.id }) else { continue }
            latest.profiles[i].label = edited.label
            latest.profiles[i].role = edited.role
        }
        do { try env.store.save(latest) } catch { showError(error) }
        reload()
    }

    // MARK: Switching

    func switchTo(_ profile: Profile, automatic: Bool = false) async {
        guard !isBusy, !isAdding else { return }
        isBusy = true          // also pauses background account checks while the confirmation is up
        defer { isBusy = false; reload() }
        let running = (try? RunningClaude().cliProcessCount()) ?? 0
        if !automatic && (running > 0 || env.desktop.isRunning) {
            let alert = NSAlert()
            alert.messageText = "Switch to \(profile.label)?"
            alert.informativeText = running > 0
                ? "\(running) claude process(es) are running. Quit them first (Desktop's Code tab counts too, and is closed by the switch): a running claude can write its old account's login back over the new one."
                : "Claude Desktop will be quit and reopened."
            alert.addButton(withTitle: running > 0 ? "Switch Anyway" : "Switch")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let result = try await switcher.switchTo(profile.id)
            var body = automatic
                ? "Your previous account was nearly out. Restart running `claude` and reload VS Code's window."
                : "Restart running `claude` and reload VS Code's Claude panel; `claude --resume` shows all your sessions."
            body += result.warnings.map { " " + $0 }.joined()
            notify(title: automatic ? "Switched to \(profile.label) automatically" : "Now on \(profile.label)", body: body)
            reload()
            await refreshUsage(force: true)
        } catch {
            if automatic { statusMessage = "Automatic switch to \(profile.label) failed: \(describe(error))" }
            else { showError(error) }
        }
    }

    // MARK: Usage

    func refreshUsage(force: Bool) async {
        guard force || Date().timeIntervalSince(lastUsageRefresh) >= 60, !isRefreshing else { return }
        isRefreshing = true
        lastUsageRefresh = Date()
        usage = await usageService.refresh()
        isRefreshing = false
        reload()
        alertIfLow()
        await autoSwitchIfNeeded()
    }

    private func installNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        notifications.install()
    }

    private func alertIfLow() {
        guard lowUsageAlerts, !isDemo, let active,
              let alert = LowUsageAlert.check(accountId: active.id, usage: usage[active.id], now: Date()),
              !announcedKeys.contains(alert.key) else { return }
        announcedKeys.append(alert.key)
        let what = alert.window == .session ? "5-hour session" : "weekly limit"
        var body = "\(Int(alert.left.rounded()))% of the \(what) left."
        var userInfo: [String: String] = [:]
        if let targetId = AutoSwitch.bestTarget(activeId: active.id, candidates: state.profiles, usage: usage, now: Date()),
           let target = state.profile(targetId) {
            let targetLeft = Int(AutoSwitch.left(usage[targetId]?.session, Date()).rounded())
            body += " \(target.label) has \(targetLeft)% left — click Switch to move to it."
            userInfo["targetId"] = targetId
        }
        notify(title: "\(active.label) is running low", body: body,
               category: userInfo.isEmpty ? nil : NotificationHandler.lowUsageCategory, userInfo: userInfo)
    }

    /// Entry point for the notification's Switch button.
    func switchTo(accountId: String) async {
        guard let profile = state.profile(accountId) else { return }
        await switchTo(profile)
    }

    private func autoSwitchIfNeeded() async {
        guard autoSwitch, !isDemo, !isBusy, !isAdding, let active else { return }
        guard let targetId = AutoSwitch.target(activeId: active.id, candidates: state.profiles, usage: usage,
                                               lastAutoSwitch: lastAutoSwitch, now: Date()),
              let target = state.profile(targetId) else { return }
        lastAutoSwitch = Date()
        await switchTo(target, automatic: true)
    }

    // MARK: Settings

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showError(error)
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Feedback

    private func describe(_ error: Error) -> String {
        switch error {
        case SwitchError.stepFailed(let step, let underlying): "\(step): \(underlying)"
        case SwitchError.missingSecret(let label): "saved login for \(label) is missing"
        default: String(describing: error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        switch error {
        case SwitchError.stepFailed(let step, let underlying):
            alert.messageText = "Failed at: \(step)"
            alert.informativeText = "You are still on your previous account; its login was put back.\n\n\(underlying)"
        case SwitchError.rollbackIncomplete(let step, let failures):
            alert.messageText = "Switch failed at: \(step), and some things could not be put back"
            alert.informativeText = "Check these before using Claude:\n• " + failures.joined(separator: "\n• ")
        case SwitchError.loginMismatch(let active, let owner):
            alert.messageText = "Login mismatch — switch stopped"
            alert.informativeText = "~/.claude.json says \(active), but the Claude Code login in the Keychain is \(owner)'s. A running claude probably wrote it back. Quit all claude processes, run `claude auth login` as \(active), then try again. Nothing was changed."
        case SwitchError.unsavedLiveLogin(let email):
            alert.messageText = "Claude Code is signed in to \(email), which isn't saved yet"
            alert.informativeText = "Give it a few seconds to be added automatically, then try again. Nothing was changed."
        case SwitchError.noLiveLogin:
            alert.messageText = "No Claude Code login found"
            alert.informativeText = "Use Add account to sign in."
        case SwitchError.missingSecret(let label):
            alert.messageText = "Saved login for \(label) is missing"
            alert.informativeText = "Remove it and add it again by signing in."
        case SwitchError.alreadyActive:
            alert.messageText = "That account is already active"
        default:
            alert.messageText = "Something went wrong"
            alert.informativeText = String(describing: error)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func notify(title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) {
        guard Bundle.main.bundleIdentifier != nil else { print("\(title): \(body)"); return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
