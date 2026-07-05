#!/usr/bin/env bash
# Self-check for the installed statusline bridge.
# Feeds three fake Claude Code payloads (different session_ids, same reset
# window, ascending percentages) and asserts each session gets its own file
# with the right values. Runs entirely under a throwaway HOME so it never
# touches the user's real ~/.claude state. Run after `build-app.sh` + opening
# the app (which installs the bridge to ~/.claude/cc-usage-bridge.sh).
set -euo pipefail

REAL_HOME="$(dscl . -read "/Users/$(whoami)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
REAL_BRIDGE="$REAL_HOME/.claude/cc-usage-bridge.sh"

[ -f "$REAL_BRIDGE" ] || { echo "FAIL: bridge not installed at $REAL_BRIDGE"; exit 1; }

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

SESSIONS_DIR="$TMP_HOME/.claude/cc-usage-tracker/sessions"
PREV_FILE="$TMP_HOME/.claude/cc-usage-tracker/prev-command.txt"
BRIDGE="$TMP_HOME/.claude/cc-usage-bridge.sh"
mkdir -p "$SESSIONS_DIR"
cp "$REAL_BRIDGE" "$BRIDGE"
chmod +x "$BRIDGE"

# Chain to a no-op so the test doesn't depend on a real renderer.
echo 'true' > "$PREV_FILE"

emit() {  # session_id five_pct five_rst week_pct week_rst
  jq -cn \
    --arg s "$1" \
    --argjson f5p "$2" --argjson f5r "$3" \
    --argjson wp "$4" --argjson wr "$5" \
    '{session_id:$s, model:{display_name:"test"},
      rate_limits:{five_hour:{used_percentage:$f5p,resets_at:$f5r},
                   seven_day:{used_percentage:$wp,resets_at:$wr}}}'
}

emit A 30 1000 21 2000 | bash "$BRIDGE" >/dev/null
emit B 70 1000 23 2000 | bash "$BRIDGE" >/dev/null
emit C 92 1000 25 2000 | bash "$BRIDGE" >/dev/null

assert_eq() { [ "$2" = "$3" ] || { echo "FAIL: $1 — got $2, want $3"; exit 1; }; }

A=$(jq -r '.five_hour.used_percentage' "$SESSIONS_DIR/A.json")
B=$(jq -r '.five_hour.used_percentage' "$SESSIONS_DIR/B.json")
C=$(jq -r '.five_hour.used_percentage' "$SESSIONS_DIR/C.json")
assert_eq "A.pct" "$A" "30"
assert_eq "B.pct" "$B" "70"
assert_eq "C.pct" "$C" "92"

# Concurrent writers must not corrupt any file.
for i in $(seq 1 20); do
  emit "concurrent-$i" "$((i % 100))" 1000 10 2000 | bash "$BRIDGE" >/dev/null &
done
wait
for i in $(seq 1 20); do
  jq -e '.five_hour.used_percentage != null' "$SESSIONS_DIR/concurrent-$i.json" >/dev/null \
    || { echo "FAIL: concurrent-$i.json missing/invalid"; exit 1; }
done

echo "PASS: bridge writes one valid file per session, concurrent writers safe."
