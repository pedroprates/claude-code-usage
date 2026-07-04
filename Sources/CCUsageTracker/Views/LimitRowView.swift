import SwiftUI
import CCUsageCore

/// Reusable row: label · percentage · progress bar · reset time.
struct LimitRowView: View {
    let title: String
    let tag: String
    let limit: RateLimit
    let health: UsageHealth
    let dimmed: Bool
    /// `true` for the 5-hour window (HH:MM format), `false` for weekly (day HH:MM).
    let shortFormat: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(tag)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(percentText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: health.colorHex))
            }

            ProgressView(value: progressValue)
                .tint(Color(hex: health.colorHex))
                .scaleEffect(y: 1.4)

            HStack(spacing: 6) {
                Text(resetsText)
                Spacer()
                if dimmed {
                    Text("stale")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .opacity(dimmed ? 0.55 : 1.0)
    }

    private var percentText: String {
        guard let pct = limit.usedPercentage else { return "n/a" }
        return "\(Int(pct.rounded()))%"
    }

    private var progressValue: Double {
        guard let pct = limit.usedPercentage else { return 0 }
        return min(max(pct / 100.0, 0), 1)
    }

    private var resetsText: String {
        guard let resets = limit.resetsAt else {
            return limit.isAvailable ? "resets —" : "not available"
        }
        let f = DateFormatter()
        if shortFormat {
            f.dateFormat = "HH:mm"
            return "resets at \(f.string(from: resets))"
        }
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: resets))"
    }
}
