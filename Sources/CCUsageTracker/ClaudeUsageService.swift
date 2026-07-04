import Foundation
import CCUsageCore

/// Reads usage state by scanning `~/.claude/cc-usage-tracker/sessions/`,
/// where each Claude Code session writes its own snapshot file. Aggregates
/// per-session snapshots into one account-level snapshot (max percentage per
/// reset window). No JSONL parsing, no token math — the percentages are
/// pre-calculated by Claude Code and handed to us verbatim.
final class ClaudeUsageService {
    static let stateDirName = "cc-usage-tracker"
    static let sessionsDirName = "sessions"

    let sessionsDirURL: URL

    init(sessionsDirURL: URL? = nil) {
        if let sessionsDirURL {
            self.sessionsDirURL = sessionsDirURL
        } else {
            self.sessionsDirURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/\(Self.stateDirName)/\(Self.sessionsDirName)")
        }
    }

    var stateExists: Bool {
        let s = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirURL, includingPropertiesForKeys: nil)) ?? []
        return s.contains { $0.pathExtension == "json" }
    }

    /// Scans session files, decodes each, and aggregates. Returns nil when no
    /// session file carries any rate-limit window.
    func readSnapshot() -> UsageSnapshot? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirURL, includingPropertiesForKeys: nil)) ?? []
        let snapshots: [SessionSnapshot] = urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let s = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
            else { return nil }
            return s
        }
        pruneStale(urls: urls)
        return ClaudeUsageCore.aggregate(snapshots: snapshots)
    }

    // ponytail: bounded cleanup — drop session files older than 7 days so the
    // directory can't grow without limit. Upgrade: per-session TTL if needed.
    private func pruneStale(urls: [URL]) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for url in urls where url.pathExtension == "json" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}