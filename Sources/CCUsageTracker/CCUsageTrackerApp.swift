import SwiftUI
import CCUsageCore

@main
struct CCUsageTrackerApp: App {
    @StateObject private var usageStore = UsageStore.shared
    @StateObject private var openRouter = OpenRouterService.shared
    @StateObject private var settings = SettingsStore.shared

    init() {
        // Start reading state.json immediately — don't wait for AppDelegate,
        // which may fire late or never for a menu-bar-only app.
        UsageStore.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView(
                store: usageStore,
                openRouter: openRouter,
                settings: settings
            )
        } label: {
            MenuBarLabelView(
                snapshot: usageStore.snapshot,
                isStale: usageStore.isStale,
                weeklyHealth: usageStore.snapshot.map {
                    UsageHealth(percentage: $0.sevenDay.usedPercentage.map { $0/100 },
                                warnAt: settings.warnThreshold,
                                dangerAt: settings.dangerThreshold)
                } ?? .unavailable
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: settings, openRouter: openRouter)
        }
    }
}
