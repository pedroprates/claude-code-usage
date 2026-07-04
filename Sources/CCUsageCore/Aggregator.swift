import Foundation

/// One session's usage snapshot, decoded from
/// `~/.claude/cc-usage-tracker/sessions/<session_id>.json`. Shape matches the
/// JSON the statusline collector writes.
public struct SessionSnapshot: Decodable, Equatable {
    public let updated_at: Double
    public let model: String?
    public let session_id: String?
    public let five_hour: Window?
    public let seven_day: Window?

    public struct Window: Decodable, Equatable {
        public let used_percentage: Double?
        public let resets_at: Double?
    }

    public init(updated_at: Double, model: String?, session_id: String?,
                five_hour: Window?, seven_day: Window?) {
        self.updated_at = updated_at
        self.model = model
        self.session_id = session_id
        self.five_hour = five_hour
        self.seven_day = seven_day
    }
}

/// Pure aggregation of per-session snapshots into one account-level snapshot.
/// For each window independently: the current reset window is the max
/// `resets_at`; the displayed percentage is the max `used_percentage` among
/// observations in that window. An account-usage percentage is monotonic
/// inside one window, so the max is the least-stale observation. When
/// `resets_at` advances, the window rolls forward and the value may fall.
public enum ClaudeUsageCore {
    public static func aggregate(snapshots: [SessionSnapshot]) -> UsageSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let fiveHour = aggregateWindow(snapshots: snapshots, window: { $0.five_hour })
        let sevenDay = aggregateWindow(snapshots: snapshots, window: { $0.seven_day })
        guard fiveHour != nil || sevenDay != nil else { return nil }

        let updatedAt = snapshots
            .map { Date(timeIntervalSince1970: $0.updated_at) }
            .max() ?? Date()
        let freshest = snapshots.max { $0.updated_at < $1.updated_at }
        return UsageSnapshot(
            fiveHour: fiveHour ?? RateLimit(usedPercentage: nil, resetsAt: nil),
            sevenDay: sevenDay ?? RateLimit(usedPercentage: nil, resetsAt: nil),
            updatedAt: updatedAt,
            model: freshest?.model,
            sessionId: nil  // aggregate has no single session
        )
    }

    private static func aggregateWindow(
        snapshots: [SessionSnapshot],
        window: (SessionSnapshot) -> SessionSnapshot.Window?
    ) -> RateLimit? {
        let obs: [(pct: Double, rst: Double)] = snapshots.compactMap { snap in
            guard let w = window(snap),
                  let pct = w.used_percentage,
                  let rst = w.resets_at else { return nil }
            return (pct, rst)
        }
        guard let maxRst = obs.map(\.rst).max() else { return nil }
        let pct = obs.filter { $0.rst == maxRst }.map(\.pct).max()
        return RateLimit(usedPercentage: pct,
                         resetsAt: Date(timeIntervalSince1970: maxRst))
    }
}