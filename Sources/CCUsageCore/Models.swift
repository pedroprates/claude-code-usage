import Foundation

// MARK: - Rate limit

/// A single rate-limit window as reported by Claude Code's statusline feed.
/// `used_percentage` is 0–100, pre-calculated by Anthropic. `resets_at` is the
/// Unix epoch second at which the window resets, or nil if not provided.
public struct RateLimit: Equatable {
    public let usedPercentage: Double?     // nil = not available (API plan / pre-first-response)
    public let resetsAt: Date?

    public init(usedPercentage: Double?, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var isAvailable: Bool { usedPercentage != nil }
}

// MARK: - Snapshot

/// Canonical usage state, sourced from `~/.claude/cc-usage-tracker/state.json`,
/// which is written by the statusline bridge on every Claude Code assistant
/// message. `updatedAt` is when the bridge last wrote the file (epoch seconds).
public struct UsageSnapshot: Equatable {
    public let fiveHour: RateLimit
    public let sevenDay: RateLimit
    public let updatedAt: Date
    public let model: String?
    public let sessionId: String?

    public init(fiveHour: RateLimit, sevenDay: RateLimit, updatedAt: Date, model: String?, sessionId: String?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
        self.model = model
        self.sessionId = sessionId
    }
}

// MARK: - Health

public enum UsageHealth: Equatable {
    case ok, warn, danger, unavailable

    public init(percentage: Double?, warnAt: Double = 0.60, dangerAt: Double = 0.85) {
        guard let p = percentage else { self = .unavailable; return }
        if p >= dangerAt { self = .danger }
        else if p >= warnAt { self = .warn }
        else { self = .ok }
    }

    /// 0–1 value for progress fill, nil if unavailable.
    public var fillValue: Double? {
        switch self {
        case .ok, .warn, .danger: return nil  // caller uses the percentage directly
        case .unavailable: return nil
        }
    }

    public var colorHex: String {
        switch self {
        case .ok: return "30d158"
        case .warn: return "ffd60a"
        case .danger: return "ff453a"
        case .unavailable: return "8e8e93"
        }
    }
}