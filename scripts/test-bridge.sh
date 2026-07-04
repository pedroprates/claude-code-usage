#!/usr/bin/env bash
# Self-check for the installed statusline bridge.
# Feeds three fake Claude Code payloads (different session_ids, same reset
# window, ascending percentages) and asserts each session gets its own file
# with the right values. Run after `build-app.sh` + opening the app (which
# installs the bridge to ~/.claude/cc-usage-bridge.sh).
set -euo pipefail

BRIDGE="${HOME}/.claude/cc-usage-bridge.sh"
SESSIONS_DIR="${HOME}/.claude/cc-usage-tracker/sessions"
PREV_FILE="${HOME}/.claude/cc-usage-tracker/prev-command.txt"

[ -f "$BRIDGE" ] || { echo "FAIL: bridge not installed at $BRIDGE"; exit 1; }

# Chain to a no-op so the test doesn't depend on a real renderer.
mkdir -p "$(dirname "$PREV_FILE")"
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

rm -f "$SESSIONS_DIR"/A.json "$SESSIONS_DIR"/B.json "$SESSIONS_DIR"/C.json "$SESSIONS_DIR"/concurrent-*.json 2>/dev/null || true

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