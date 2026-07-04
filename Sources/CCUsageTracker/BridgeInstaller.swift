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
    private let backupKey = "bridge.previousStatusLineCommand"

    /// File the bridge reads at runtime to know what to chain to.
    static let prevCommandPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/cc-usage-tracker/prev-command.txt").path

    // MARK: - State

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.bridgePath)
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

    /// Writes the bridge script, patches `~/.claude/settings.json`'s
    /// `statusLine.command` to invoke it, and backs up the previous value.
    func install() throws {
        guard Self.jqAvailable() else { throw InstallError.jqMissing }

        try writeBridgeScript()

        guard let settings = Self.readSettingsJSON() else { throw InstallError.settingsUnreadable }

        var mutable = settings
        let prevCommand = (mutable["statusLine"] as? [String: Any])?["command"] as? String
        if let prevCommand, prevCommand != bridgeCommand {
            UserDefaults.standard.set(prevCommand, forKey: backupKey)
        }

        // Persist the previous command for the bridge to chain to at runtime.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: Self.prevCommandPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
            let prev = UserDefaults.standard.string(forKey: backupKey)
                ?? (try? String(contentsOfFile: Self.prevCommandPath, encoding: .utf8))
                ?? ""
            if !prev.isEmpty {
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
        UserDefaults.standard.removeObject(forKey: backupKey)
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

    /// The bridge: reads stdin, extracts rate_limits to state.json, then chains
    /// to the user's previous statusline command and forwards its stdout.
    private static let bridgeScript = #"""
#!/bin/bash
# CC Usage Tracker bridge — installed by the menu bar app.
# Reads Claude Code statusline JSON, persists rate_limits to state.json, then
# chains to the user's previous statusline command and forwards stdout.
set -euo pipefail
INPUT=$(cat)

STATE_DIR="${HOME}/.claude/cc-usage-tracker"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state.json"
PREV_FILE="$STATE_DIR/prev-command.txt"

# Extract rate_limits fields (absent for API plans / before first API response).
FIVE_PCT=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null || true)
FIVE_RST=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at       // empty' 2>/dev/null || true)
WEEK_PCT=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null || true)
WEEK_RST=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at       // empty' 2>/dev/null || true)
MODEL=$(echo "$INPUT"    | jq -r '.model.display_name // empty'           2>/dev/null || true)
SESSION=$(echo "$INPUT"  | jq -r '.session_id // empty'                    2>/dev/null || true)

# Only persist when this payload carries rate_limits; otherwise leave the last
# known-good state.json untouched. Multiple Claude Code sessions share this
# file; for the same reset window take the higher percentage so a slower
# session never clobbers the busier one's value.
if [ -n "$FIVE_PCT" ] || [ -n "$WEEK_PCT" ]; then
    TMP="$STATE_FILE.tmp"
    # Read existing values to compare windows and keep the higher usage.
    CUR_F5P=""; CUR_F5R=""; CUR_WP=""; CUR_WR=""
    if [ -f "$STATE_FILE" ]; then
        CUR_F5P=$(jq -r '.five_hour.used_percentage // empty' "$STATE_FILE" 2>/dev/null || true)
        CUR_F5R=$(jq -r '.five_hour.resets_at       // empty' "$STATE_FILE" 2>/dev/null || true)
        CUR_WP=$(jq  -r '.seven_day.used_percentage // empty' "$STATE_FILE" 2>/dev/null || true)
        CUR_WR=$(jq  -r '.seven_day.resets_at       // empty' "$STATE_FILE" 2>/dev/null || true)
    fi
    # For each window: if resets_at matches, keep the higher percentage; if the
    # incoming resets_at is newer (or we have no current value), take incoming.
    jq -n \
      --arg now "$(date +%s)" \
      --arg f5p "$FIVE_PCT" --arg f5r "$FIVE_RST" \
      --arg wp  "$WEEK_PCT" --arg wr  "$WEEK_RST" \
      --arg m "$MODEL" --arg s "$SESSION" \
      --arg cf5p "$CUR_F5P" --arg cf5r "$CUR_F5R" \
      --arg cwp  "$CUR_WP"  --arg cwr  "$CUR_WR" \
      '
      def best_pct(new_p; new_r; cur_p; cur_r):
        if (new_p|tonumber?) == null then null
        elif (cur_p|tonumber?) == null then (new_p|tonumber)
        elif new_r == cur_r then [(new_p|tonumber), (cur_p|tonumber)] | max
        elif (new_r|tonumber? // 0) > (cur_r|tonumber? // 0) then (new_p|tonumber)
        else (cur_p|tonumber)
        end;
      {
        updated_at: ($now|tonumber),
        model: $m,
        session_id: $s,
        five_hour: { used_percentage: best_pct($f5p; $f5r; $cf5p; $cf5r),
                     resets_at:       ($f5r|tonumber?) // null },
        seven_day: { used_percentage: best_pct($wp; $wr; $cwp; $cwr),
                     resets_at:       ($wr|tonumber?) // null }
      }' > "$TMP" 2>/dev/null && mv "$TMP" "$STATE_FILE" || rm -f "$TMP"
fi

# Chain to the previous statusline command, forwarding its stdout unchanged.
PREV=""
[ -f "$PREV_FILE" ] && PREV=$(cat "$PREV_FILE")
if [ -n "$PREV" ]; then
    echo "$INPUT" | bash -c "$PREV"
fi
"""#
}
