import SwiftUI
import SwitcherCore

struct PlanBadge: View {
    let plan: String?
    var body: some View {
        if let plan {
            Text(plan).font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange))
        }
    }
}

struct StatusBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.green))
    }
}

struct UsageBar: View {
    let fraction: Double
    /// % used, which decides the colour (defaults to the fraction shown).
    var usedPercent: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(UsageBar.color(usedPercent ?? fraction * 100))
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }

    static func color(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 75 ? .orange : .green
    }
}

struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    var mode: UsageDisplayMode = .used

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(resetText).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                // Numbers from before a reset no longer mean anything.
                let resetPassed = window?.resetsAt.map { $0 <= Date() } ?? false
                let used = resetPassed ? 0 : (window?.utilization ?? 0)
                UsageBar(fraction: mode == .remaining ? max(0, 100 - used) / 100 : used / 100, usedPercent: used)
                Text(resetPassed ? "–" : window.map { mode == .remaining ? "\(Int(max(0, 100 - $0.utilization).rounded()))% left" : "\(Int($0.utilization.rounded()))%" } ?? "–")
                    .font(.callout.monospacedDigit().bold())
                    .foregroundStyle(window.map { UsageBar.color($0.utilization) } ?? .secondary)
                    .frame(width: 76, alignment: .trailing)
            }
        }
    }

    private var resetText: String {
        guard let window else { return "" }
        guard let date = window.resetsAt else { return window.utilization == 0 ? "Not started" : "" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "Reset since last check" }
        if seconds < 24 * 3600 {
            let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
            return h > 0 ? "Resets in \(h) hr \(m) min" : "Resets in \(m) min"
        }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard())
    }
}

/// Liquid Glass on macOS 26 and later; a soft material card before that.
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Glass only behind the content, so badges and bars keep their colours.
            content.background {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

struct AsOfLine: View {
    let usage: AccountUsage?
    var body: some View {
        if let usage, !usage.isLive {
            Text("as of " + usage.fetchedAt.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct AccountCard: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    private var isActive: Bool { profile.id == model.state.activeId }
    private var usage: AccountUsage? { model.usage[profile.id] }

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.orange)
                Text(profile.email).font(.callout.bold()).lineLimit(1).truncationMode(.middle)
                if isActive { StatusBadge(text: "Active") }
                Spacer()
                PlanBadge(plan: profile.plan)
            }
            if usage == nil {
                Text("No usage data yet").font(.caption).foregroundStyle(.secondary)
            } else {
                // No session window while other numbers are known: the 5-hour session hasn't started (0%).
                UsageRow(title: "Session", window: usage?.session ?? UsageWindow(utilization: 0, resetsAt: nil),
                         mode: model.menuBarMode)
                UsageRow(title: "Weekly", window: usage?.weekly, mode: model.menuBarMode)
                HStack {
                    Image(systemName: "bolt.slash").font(.caption).foregroundStyle(.secondary)
                    Text("Extra usage").font(.callout)
                    Spacer()
                    Text(usage?.extra.map { $0.isEnabled ? "On" : "Off" } ?? "–").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !profile.hasDesktopSnapshot {
                Text("Claude Desktop: sign in once as this account to have it switch too.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                AsOfLine(usage: usage)
                Spacer()
                if !isActive {
                    Button("Switch") { Task { await model.switchTo(profile) } }
                        .disabled(model.isBusy || model.isAdding)
                }
            }
        }
    }
}
