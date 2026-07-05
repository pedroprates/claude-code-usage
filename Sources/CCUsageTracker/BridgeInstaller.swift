import Foundation

/// Installs / uninstalls the statusline bridge.
///
/// The bridge is a small bash script at `~/.claude/cc-usage-bridge.sh` that
/// Claude Code invokes as its statusline command. It reads the JSON payload
/// from stdin, extracts `rate_limits`, writes it to `state.json`, then chains
/// to whatever statusline command was previously configured (forwarding stdout
/// unchanged). This lets the user keep their existing statusline output while
/// the menu bar app gets the canonical rate-limit data.
@MainActor
final class BridgeInstaller {
    static let shared = BridgeInstaller()

    static let bridgePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cc-usage-bridge.sh").path

    static let settingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json").path

    /// UserDefaults key for the previous statusLine.command value (for restore).
    private static let backupKey = "bridge.previousStatusLineCommand"

    /// Older builds shipped under the bundle id `CCUsageTracker`; that domain
    /// may still hold the only uncorrupted copy of the previous statusline
    /// command. Used by `recoverPrevCommandIfNeeded`.
    private static let strandedDefaultsDomain = "CCUsageTracker"

    /// Commands that produce no statusline output. The bridge must never chain
    /// to one of these — it would blank out Claude Code's status line.
    private static let noOpCommands: Set<String> = ["", "true", ":"]

    /// File the bridge reads at runtime to know what to chain to.
    static let prevCommandPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cc-usage-tracker/prev-command.txt").path

    /// Conventional statusline script the bridge chains to when no previous
    /// command is recorded. Probed by `recoverPrevCommandIfNeeded`.
    private static let defaultStatuslinePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/statusline.sh").path

    // MARK: - State

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.bridgePath)
    }

    /// True when the active `statusLine.command` in ~/.claude/settings.json
    /// routes through this bridge. The investigation found the app's
    /// `isInstalled` checked only file existence, so a status-line change that
    /// pointed the command elsewhere left the app silently bypassed.
    var isActivated: Bool {
        guard let settings = Self.readSettingsJSON() else { return false }
        let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        return cmd?.contains(Self.bridgePath) == true
    }

    var bridgeCommand: String {
        "bash \(Self.bridgePath)"
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case jqMissing
        case settingsUnreadable
        case settingsUnwritable

        var errorDescription: String? {
            switch self {
            case .jqMissing: return "`jq` is required but was not found on your PATH. Install it with `brew install jq`."
            case .settingsUnreadable: return "Could not read ~/.claude/settings.json."
            case .settingsUnwritable: return "Could not write ~/.claude/settings.json."
            }
        }
    }

    /// Returns the trimmed previous command, or nil when it is empty, a known
    /// no-op (`true`, `:`), or points at this bridge (which would recurse).
    /// Chaining to any of those would blank out Claude Code's status line.
    private func sanitizePrevCommand(_ cmd: String?) -> String? {
        let trimmed = cmd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              !Self.noOpCommands.contains(trimmed),
              !trimmed.contains("cc-usage-bridge")
        else { return nil }
        return trimmed
    }

    /// Persists the previous statusline command to both the runtime file the
    /// bridge chains to and the UserDefaults backup used by `uninstall`.
    private func persistPrevCommand(_ cmd: String) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.prevCommandPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? cmd.write(toFile: Self.prevCommandPath, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(cmd, forKey: Self.backupKey)
    }

    /// One-time recovery of the user's real previous statusline command.
    ///
    /// Earlier builds (or the `test-bridge.sh` self-check) could leave
    /// `prev-command.txt` / the backup key set to a no-op like `true`, which
    /// blanks CC's status line. If we have no valid prev command on record,
    /// probe the older `CCUsageTracker` defaults domain (stranded when the
    /// bundle id changed) and then the conventional `~/.claude/statusline.sh`.
    func recoverPrevCommandIfNeeded() {
        let current = UserDefaults.standard.string(forKey: Self.backupKey)
            ?? (try? String(contentsOfFile: Self.prevCommandPath, encoding: .utf8))
        if sanitizePrevCommand(current) != nil { return }

        if let stranded = UserDefaults(suiteName: Self.strandedDefaultsDomain)?
            .string(forKey: Self.backupKey),
           let valid = sanitizePrevCommand(stranded) {
            persistPrevCommand(valid)
            return
        }

        if FileManager.default.isExecutableFile(atPath: Self.defaultStatuslinePath) {
            persistPrevCommand("bash \(Self.defaultStatuslinePath)")
        }
    }

    /// Rewrites `~/.claude/settings.json`'s `statusLine.command` off then back
    /// on so a Claude Code session that was already running when the bridge
    /// activated picks it up and starts emitting payloads. Without this, a
    /// running session keeps whatever statusLine it had at startup and the menu
    /// bar never receives fresh data. Async sleep keeps the main actor free.
    func reactivate() async throws {
        guard let settings = Self.readSettingsJSON() else { throw InstallError.settingsUnreadable }
        let prev = sanitizePrevCommand(
            UserDefaults.standard.string(forKey: Self.backupKey)
            ?? (try? String(contentsOfFile: Self.prevCommandPath, encoding: .utf8)))

        var off = settings
        if let prev {
            off["statusLine"] = ["type": "command", "command": prev]
        } else {
            off["statusLine"] = nil
        }
        try Self.writeSettingsJSON(off)

        // Brief pause so Claude Code observes the non-bridge state and re-reads.
        try await Task.sleep(nanoseconds: 500_000_000)

        var on = off
        on["statusLine"] = ["type": "command", "command": bridgeCommand]
        try Self.writeSettingsJSON(on)
    }

    /// Writes the bridge script, patches `~/.claude/settings.json`'s
    /// `statusLine.command` to invoke it, and backs up the previous value.
    func install() throws {
        guard Self.jqAvailable() else { throw InstallError.jqMissing }

        try writeBridgeScript()

        guard let settings = Self.readSettingsJSON() else { throw InstallError.settingsUnreadable }

        var mutable = settings
        let prevCommand = sanitizePrevCommand(
            (mutable["statusLine"] as? [String: Any])?["command"] as? String)
        if let prevCommand {
            UserDefaults.standard.set(prevCommand, forKey: Self.backupKey)
        }

        // Persist the previous command for the bridge to chain to at runtime.
        // Empty string (no prev) is fine — the bridge skips the chain step.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.prevCommandPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try (prevCommand ?? "").write(toFile: Self.prevCommandPath, atomically: true, encoding: .utf8)

        mutable["statusLine"] = [
            "type": "command",
            "command": bridgeCommand
        ]

        try Self.writeSettingsJSON(mutable)
    }

    /// Restores the previous `statusLine.command` and removes the bridge script.
    func uninstall() throws {
        if let settings = Self.readSettingsJSON() {
            var mutable = settings
            let prev = sanitizePrevCommand(
                UserDefaults.standard.string(forKey: Self.backupKey)
                ?? (try? String(contentsOfFile: Self.prevCommandPath, encoding: .utf8)))
            if let prev {
                mutable["statusLine"] = [
                    "type": "command",
                    "command": prev
                ]
            } else {
                mutable["statusLine"] = nil
            }
            try? Self.writeSettingsJSON(mutable)
        }
        try? FileManager.default.removeItem(atPath: Self.bridgePath)
        try? FileManager.default.removeItem(atPath: Self.prevCommandPath)
        UserDefaults.standard.removeObject(forKey: Self.backupKey)
    }

    // MARK: - Bridge script

    private func writeBridgeScript() throws {
        let script = Self.bridgeScript
        try script.write(toFile: Self.bridgePath, atomically: true, encoding: .utf8)
        // chmod +x
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.bridgePath)
    }

    // MARK: - jq check

    private static func jqAvailable() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["which", "jq"]
        task.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Settings.json I/O (preserves formatting)

    private static func readSettingsJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)) else {
            return [:]
        }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private static func writeSettingsJSON(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    // MARK: - Embedded bridge script

    private static let bridgeScript = #"""
#!/bin/bash
# CC Usage Tracker bridge — installed by the menu bar app.
# Reads Claude Code statusline JSON, persists rate_limits to one file per
# session (sessions/<session_id>.json), then chains to the user's previous
# statusline command and forwards stdout. One file per session means no two
# Claude processes contend for the same snapshot; the app aggregates them.
set -euo pipefail
INPUT=$(cat)

STATE_DIR="${HOME}/.claude/cc-usage-tracker"
SESSIONS_DIR="$STATE_DIR/sessions"
mkdir -p "$SESSIONS_DIR"
PREV_FILE="$STATE_DIR/prev-command.txt"

# Extract rate_limits fields (absent for API plans / before first API response).
FIVE_PCT=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
FIVE_RST=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at       // empty' 2>/dev/null || true)
WEEK_PCT=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)
WEEK_RST=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at       // empty' 2>/dev/null || true)
MODEL=$(echo "$INPUT"    | jq -r '.model.display_name // empty'           2>/dev/null || true)
SESSION=$(echo "$INPUT"  | jq -r '.session_id // empty'                    2>/dev/null || true)

# Only persist when this payload carries rate_limits. Each session owns its own
# file, so there is no cross-session merge to do — just write atomically.
if [ -n "$FIVE_PCT" ] || [ -n "$WEEK_PCT" ]; then
    [ -n "$SESSION" ] || SESSION="no-session"
    SESSION_FILE="$SESSIONS_DIR/${SESSION}.json"
    TMP="${SESSION_FILE}.tmp.$$"
    jq -n \
      --arg now "$(date +%s)" \
      --arg f5p "$FIVE_PCT" --arg f5r "$FIVE_RST" \
      --arg wp  "$WEEK_PCT" --arg wr  "$WEEK_RST" \
      --arg m "$MODEL" --arg s "$SESSION" \
      '{
        updated_at: ($now|tonumber),
        model: $m,
        session_id: $s,
        five_hour: { used_percentage: ($f5p|tonumber?) // null,
                     resets_at:       ($f5r|tonumber?) // null },
        seven_day: { used_percentage: ($wp |tonumber?) // null,
                     resets_at:       ($wr |tonumber?) // null }
      }' > "$TMP" 2>/dev/null && mv "$TMP" "$SESSION_FILE" || rm -f "$TMP"
fi

# Chain to the previous statusline command, forwarding its stdout unchanged.
PREV=""
[ -f "$PREV_FILE" ] && PREV=$(cat "$PREV_FILE")
if [ -n "$PREV" ]; then
    echo "$INPUT" | bash -c "$PREV"
fi
"""#
}
