import AppKit
import SwiftUI
import SwitcherCore

/// `ClaudeSwitcher --screenshots <dir>` renders the panel with fake accounts into PNGs for the docs.
@MainActor
enum Screenshots {
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func shot(_ name: String, _ scheme: ColorScheme, setup: Bool = false, configure: (AppModel) -> Void) {
            let model = setup ? freshModel() : demoModel()
            configure(model)
            let view = PanelView(model: model)
                .environment(\.colorScheme, scheme)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)))
                .padding(24)
                .background(LinearGradient(colors: scheme == .dark
                    ? [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.24, green: 0.16, blue: 0.30)]
                    : [Color(red: 0.62, green: 0.78, blue: 0.95), Color(red: 0.93, green: 0.80, blue: 0.86)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            // Render through a real (off-screen) window so native controls draw like they do on screen.
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = host.appearance
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("failed: \(name)"); return }
            host.cacheDisplay(in: host.bounds, to: rep)
            window.orderOut(nil)
            guard let png = rep.representation(using: .png, properties: [:]) else { print("failed: \(name)"); return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }

        shot("usage-dark", .dark) { $0.tab = .usage }
        shot("usage-light", .light) { $0.tab = .usage }
        shot("costs", .dark) { $0.tab = .costs }
        shot("accounts", .dark) { $0.tab = .accounts }
        shot("settings", .dark) { $0.showSettings = true }
        shot("setup", .light, setup: true) { $0.tab = .usage }
        exit(0)
    }

    static func profile(_ id: String, _ label: String, _ role: ProfileRole, _ email: String, _ plan: String,
                        desktop: Bool) -> Profile {
        Profile(id: id, label: label, role: role, orgUuid: "org-\(id)", email: email,
                oauthAccount: ["organizationType": .string(plan)], hasDesktopSnapshot: desktop)
    }

    static func demoModel() -> AppModel {
        let now = Date()
        let main = profile("a", "main", .main, "main@example.com", "claude_max", desktop: true)
        let backup = profile("b", "backup", .backup, "backup@example.com", "claude_team", desktop: true)
        let state = SwitcherState(profiles: [main, backup], activeId: "a")
        let week = now.addingTimeInterval(2 * 86400), week2 = now.addingTimeInterval(4 * 86400)
        let usage: [String: AccountUsage] = [
            // Max: no 5-hour session limit; weekly limit plus a per-model weekly limit.
            "a": AccountUsage(session: nil, weekly: UsageWindow(utilization: 48, resetsAt: week),
                              extra: ExtraUsage(isEnabled: true, monthlyLimit: 5000, usedCredits: 1240, utilization: 24.8,
                                                currency: "USD", decimalPlaces: 2, spendLimitReached: false),
                              fetchedAt: now, isLive: true,
                              limits: [UsageLimit(kind: "weekly_all", group: "weekly", percent: 48, resetsAt: week, scope: nil, isActive: false),
                                       UsageLimit(kind: "weekly_scoped", group: "weekly", percent: 86, resetsAt: week, scope: "Opus", isActive: true)]),
            // Team/Pro: 5-hour session plus weekly.
            "b": AccountUsage(session: UsageWindow(utilization: 6, resetsAt: now.addingTimeInterval(4 * 3600 + 9 * 60)),
                              weekly: UsageWindow(utilization: 27, resetsAt: week2),
                              extra: ExtraUsage(isEnabled: false, monthlyLimit: nil, usedCredits: nil, utilization: nil,
                                                currency: "USD", decimalPlaces: 2, spendLimitReached: false),
                              fetchedAt: now.addingTimeInterval(-2 * 3600), isLive: false),
        ]
        return AppModel(demo: state, usage: usage)
    }

    static func freshModel() -> AppModel {
        let main = profile("a", "main", .main, "main@example.com", "claude_max", desktop: false)
        let model = AppModel(demo: SwitcherState(profiles: [main], activeId: "a"), usage: [:])
        model.desktopAccountId = nil
        return model
    }
}
