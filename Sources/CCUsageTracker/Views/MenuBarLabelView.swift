import SwiftUI

/// The compact item shown in the macOS menu bar:
/// gradient "C" icon · 5-hour percentage · weekly-status dot.
struct MenuBarLabelView: View {
    let snapshot: UsageSnapshot?
    let isStale: Bool
    let weeklyHealth: UsageHealth

    var body: some View {
        HStack(spacing: 5) {
            Text(primaryText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(primaryColor)
            Circle()
                .fill(Color(hex: weeklyHealth.colorHex))
                .frame(width: 8, height: 8)
        }
        .opacity(isStale ? 0.5 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var primaryText: String {
        guard let pct = snapshot?.fiveHour.usedPercentage else { return "–" }
        return "\(Int(pct.rounded()))%"
    }

    private var primaryColor: Color {
        // Menu bar is always dark — use explicit colors.
        guard let pct = snapshot?.fiveHour.usedPercentage else {
            return Color(white: 0.6)
        }
        switch pct {
        case 85...: return Color(hex: "ff453a")  // red
        case 75...: return Color(hex: "ffd60a")  // yellow
        default: return Color.white              // white for normal
        }
    }

    private var accessibilityLabel: String {
        guard let snapshot, let f = snapshot.fiveHour.usedPercentage else {
            return "Claude usage unavailable"
        }
        let w = snapshot.sevenDay.usedPercentage ?? -1
        return "Claude 5-hour \(Int(f)) percent, weekly \(w >= 0 ? "\(Int(w)) percent" : "unavailable")\(isStale ? ", stale" : "")"
    }
}

// MARK: - Hex color helper

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
