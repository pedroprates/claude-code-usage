import Foundation
import SwiftUI

/// User-tunable settings persisted in UserDefaults, observable for SwiftUI.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("warnThreshold") var warnThreshold: Double = 0.60
    @AppStorage("dangerThreshold") var dangerThreshold: Double = 0.85
    @AppStorage("notificationsEnabled") var notificationsEnabled: Bool = false

    private init() {}
}
