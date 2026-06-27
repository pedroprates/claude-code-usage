import Foundation

/// Reads the canonical usage state from `~/.claude/cc-usage-tracker/state.json`,
/// written by the statusline bridge. No JSONL parsing, no token math — the
/// percentages are pre-calculated by Claude Code and handed to us verbatim.
final class ClaudeUsageService {
    static let stateDirName = "cc-usage-tracker"
    static let stateFileName = "state.json"

    let stateURL: URL

    init(stateURL: URL? = nil) {
        if let stateURL {
            self.stateURL = stateURL
        } else {
            self.stateURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/\(Self.stateDirName)/\(Self.stateFileName)")
        }
    }

    var stateExists: Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
    }

    /// Reads and decodes the current snapshot. Returns nil if the file is
    /// missing or unreadable.
    func readSnapshot() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return decode(data: data)
    }

    private func decode(data: Data) -> UsageSnapshot? {
        struct Raw: Decodable {
            let updated_at: Double
            let model: String?
            let session_id: String?
            let five_hour: Window?
            let seven_day: Window?
        }
        struct Window: Decodable {
            let used_percentage: Double?
            let resets_at: Double?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }

        let five = RateLimit(
            usedPercentage: raw.five_hour?.used_percentage,
            resetsAt: raw.five_hour?.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
        let seven = RateLimit(
            usedPercentage: raw.seven_day?.used_percentage,
            resetsAt: raw.seven_day?.resets_at.map { Date(timeIntervalSince1970: $0) }
        )
        return UsageSnapshot(
            fiveHour: five,
            sevenDay: seven,
            updatedAt: Date(timeIntervalSince1970: raw.updated_at),
            model: raw.model?.nilIfEmpty,
            sessionId: raw.session_id?.nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
