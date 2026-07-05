import SwiftUI
import CCUsageCore

/// The expanded popover shown when the menu bar item is clicked.
struct UsagePanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var openRouter: OpenRouterService
    @ObservedObject var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings

    @State private var installError: String?
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4).padding(.vertical, 10)

            if let snapshot = store.snapshot {
                LimitRowView(
                    title: "5-hour window",
                    tag: "PRIMARY",
                    limit: snapshot.fiveHour,
                    health: UsageHealth(percentage: snapshot.fiveHour.usedPercentage.map { $0/100 },
                                        warnAt: settings.warnThreshold, dangerAt: settings.dangerThreshold),
                    dimmed: store.isStale,
                    shortFormat: true
                )
                .padding(.bottom, 14)

                Divider().opacity(0.4).padding(.bottom, 14)

                LimitRowView(
                    title: "Weekly limit",
                    tag: "7 DAYS",
                    limit: snapshot.sevenDay,
                    health: UsageHealth(percentage: snapshot.sevenDay.usedPercentage.map { $0/100 },
                                        warnAt: settings.warnThreshold, dangerAt: settings.dangerThreshold),
                    dimmed: store.isStale,
                    shortFormat: false
                )
                .padding(.bottom, 14)

                Divider().opacity(0.4).padding(.bottom, 14)

                if store.isStale {
                    staleBanner
                        .padding(.bottom, 14)
                }
            } else if store.bridgeInstalled, !store.bridgeActivated {
                bridgeBypassed
            } else if store.isReactivating {
                reactivatingBridge
            } else if store.bridgeInstalled {
                waitingForSession
            } else {
                installPrompt
            }

            openRouterCard
                .padding(.top, store.snapshot == nil ? 0 : 0)

            Divider().opacity(0.4).padding(.top, 12).padding(.bottom, 8)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial)
        .task {
            store.refresh()
            if openRouter.hasApiKey { await openRouter.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code")
                        .font(.system(size: 13, weight: .semibold))
                    Text(updatedText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.77, green: 0.35, blue: 0.23)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 22, height: 22)
            .overlay(
                Text("C")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var updatedText: String {
        guard let scanned = store.snapshot?.updatedAt else { return "no data yet" }
        let ago = Int(-scanned.timeIntervalSinceNow.rounded())
        if ago < 60 { return "updated \(ago)s ago" }
        if ago < 3600 { return "updated \(ago / 60)m ago" }
        return "updated \(ago / 3600)h ago"
    }

    // MARK: - States

    private var staleBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 10))
            Text("Last updated \(staleText) ago · open Claude Code to refresh")
                .font(.system(size: 10))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var staleText: String {
        guard let updated = store.snapshot?.updatedAt else { return "—" }
        let ago = Int(-updated.timeIntervalSinceNow.rounded())
        if ago < 3600 { return "\(ago / 60)m" }
        return "\(ago / 3600)h"
    }

    private var bridgeBypassed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Bridge bypassed")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Status line isn't routing through the collector. Check Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var reactivatingBridge: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Re-activating bridge…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("Nudging Claude Code to pick up the bridge for a running session.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }

    private var waitingForSession: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Bridge installed · waiting for a Claude Code session…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("The menu bar will populate on your next Claude Code message.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }

    private var installPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Statusline bridge not installed")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Install the bridge to receive live usage data from Claude Code. It chains to your existing statusline, so nothing else changes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let err = installError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "ff453a"))
            }

            Button {
                installBridge()
            } label: {
                HStack {
                    if installing { ProgressView().controlSize(.small) }
                    Text(installing ? "Installing…" : "Install bridge")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(installing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func installBridge() {
        installing = true
        installError = nil
        Task {
            do {
                try BridgeInstaller.shared.install()
                store.refresh()
            } catch {
                installError = error.localizedDescription
            }
            installing = false
        }
    }

    // MARK: - OpenRouter

    private var openRouterCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("OpenRouter balance", systemImage: "creditcard.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if openRouter.error != nil {
                    Text("unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if !openRouter.hasApiKey {
                    Text("no key")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let credits = openRouter.credits {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(credits.remaining, format: .currency(code: "USD"))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("/ \(credits.totalCredits, format: .currency(code: "USD"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                let pct = credits.totalCredits > 0
                    ? credits.remaining / credits.totalCredits
                    : 0
                ProgressView(value: pct)
                    .tint(.indigo)
                    .scaleEffect(y: 1.2)
            } else {
                Text(openRouter.hasApiKey ? "Fetching…" : "Add your key in Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Auto-refresh 10s")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Settings") { openSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }
}
