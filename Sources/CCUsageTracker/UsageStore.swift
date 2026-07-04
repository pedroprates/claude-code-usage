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

    private let service: ClaudeUsageService
    private let settings: SettingsStore
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?

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

        // Debug: write diagnostic to /tmp so we can verify the app is reading state.json
        let debug = "refresh at \(Date()) — snapshot: \(snapshot != nil) — fiveHour: \(snapshot?.fiveHour.usedPercentage ?? -1) — bridge: \(bridgeInstalled)"
        try? debug.write(toFile: "/tmp/cc-usage-debug.log", atomically: true, encoding: .utf8)
    }

    // MARK: - File watching

    private func beginWatching() {
        // Ensure the directory exists so we can watch its parent for creation.
        let dir = service.stateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // FSEvents on the state file itself.
        startFileWatch()

        // Polling fallback in case FSEvents misses an event (NFS, etc.) or the
        // file is replaced atomically (mv) in a way the source doesn't surface.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func startFileWatch() {
        fileSource?.cancel()

        // Watch the directory: state.json is written via temp+rename, so the
        // file descriptor on the file itself would be invalidated on each write.
        let dir = service.stateURL.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.refresh()
        }
        src.setCancelHandler {
            close(fd)
        }
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
