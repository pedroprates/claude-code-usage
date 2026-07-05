import Foundation
import CCUsageCore
import SwiftUI
import UserNotifications

/// Observable bridge between ClaudeUsageService and SwiftUI views.
///
/// Watches `state.json` via DispatchSource (FSEvents) for instant updates when
/// Claude Code writes a new statusline payload, with a 10s mtime-poll fallback.
/// Exposes `isStale` (≥5 min since `updated_at`) so views can dim.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var bridgeInstalled: Bool = false
    @Published private(set) var bridgeActivated: Bool = false
    @Published private(set) var isReactivating: Bool = false

    private let service: ClaudeUsageService
    private let settings: SettingsStore
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    /// Guards `reactivate()` to once per app launch — it rewrites
    /// ~/.claude/settings.json, so we don't want a tight loop.
    private var hasReactivatedThisSession = false

    /// A snapshot is stale if no Claude Code session has written state.json in
    /// the last 5 minutes.
    var isStale: Bool {
        guard let updated = snapshot?.updatedAt else { return true }
        return Date().timeIntervalSince(updated) > 300
    }

    init(service: ClaudeUsageService = ClaudeUsageService(),
         settings: SettingsStore? = nil) {
        self.service = service
        self.settings = settings ?? .shared
    }

    func start() {
        // Recover a valid previous statusline command before the bridge runs
        // again — earlier builds / the test self-check could leave it as a
        // no-op (`true`) that blanks CC's status line.
        BridgeInstaller.shared.recoverPrevCommandIfNeeded()
        refresh()
        beginWatching()
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-read state.json and update the bridge-installed flag.
    func refresh() {
        snapshot = service.readSnapshot()
        bridgeInstalled = BridgeInstaller.shared.isInstalled
        bridgeActivated = BridgeInstaller.shared.isActivated

        // Debug: write diagnostic to /tmp so we can verify the app is reading sessions
        let debug = "refresh at \(Date()) — snapshot: \(snapshot != nil) — fiveHour: \(snapshot?.fiveHour.usedPercentage ?? -1) — bridge: \(bridgeInstalled)/\(bridgeActivated)"
        try? debug.write(toFile: "/tmp/cc-usage-debug.log", atomically: true, encoding: .utf8)

        // If the bridge is active but no live data is flowing (snapshot stale
        // or missing), nudge Claude Code to re-read settings.json so a running
        // session picks up the bridge. Throttled to once per app launch.
        if bridgeActivated, isStale, !hasReactivatedThisSession {
            hasReactivatedThisSession = true
            Task { await reactivateBridge() }
        }
    }

    private func reactivateBridge() async {
        isReactivating = true
        do {
            try await BridgeInstaller.shared.reactivate()
            // Give the running CC session a moment to write a fresh payload.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refresh()
        } catch {
            hasReactivatedThisSession = false
        }
        isReactivating = false
    }

    // MARK: - File watching

    private func beginWatching() {
        try? FileManager.default.createDirectory(
            at: service.sessionsDirURL, withIntermediateDirectories: true)
        startFileWatch()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startFileWatch() {
        fileSource?.cancel()
        let dir = service.sessionsDirURL
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    // MARK: - Notifications

    private var lastNotified5h: UsageHealth = .ok
    private var lastNotified7d: UsageHealth = .ok

    func evaluateNotifications() {
        guard settings.notificationsEnabled, let snap = snapshot else { return }
        let h5 = UsageHealth(percentage: snap.fiveHour.usedPercentage.map { $0/100 },
                             warnAt: settings.warnThreshold, dangerAt: settings.dangerThreshold)
        let h7 = UsageHealth(percentage: snap.sevenDay.usedPercentage.map { $0/100 },
                             warnAt: settings.warnThreshold, dangerAt: settings.dangerThreshold)

        if h5 == .danger && lastNotified5h != .danger {
            send(title: "Claude 5-hour limit nearly reached",
                 body: "\(Int((snap.fiveHour.usedPercentage ?? 0).rounded()))% used")
        }
        if h7 == .danger && lastNotified7d != .danger {
            send(title: "Claude weekly limit nearly reached",
                 body: "\(Int((snap.sevenDay.usedPercentage ?? 0).rounded()))% used")
        }
        lastNotified5h = h5
        lastNotified7d = h7
    }

    private func send(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}
