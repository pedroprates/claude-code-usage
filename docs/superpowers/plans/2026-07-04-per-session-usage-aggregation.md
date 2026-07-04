# Per-Session Usage Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the multi-writer race in the CC Usage Tracker by having each Claude Code session write its own snapshot file, and aggregating (max percentage per reset window) in the menu-bar app.

**Architecture:** The statusline collector writes `~/.claude/cc-usage-tracker/sessions/<session_id>.json` atomically — one file per session, so no two sessions contend. The Swift app scans that directory, groups each rate-limit window by `resets_at`, and displays the max `used_percentage` in the current (latest `resets_at`) window. Because an account-usage percentage is monotonic inside one reset window, the max is the least-stale observation; when `resets_at` advances, the window rolls forward and the value may fall. This is "Option 1 — Recommended" from `INVESTIGATION.html`, plus the two necessary cleanup items (active-command verification, dedup of the standalone/embedded collector).

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 14), SwiftPM, bash + `jq` for the statusline collector, XCTest for the aggregation logic.

## Global Constraints

- macOS 14+ deployment target (Package.swift `platforms: [.macOS(.v14)]`).
- The collector must remain a self-contained bash script at runtime (the installed bridge lives at `~/.claude/cc-usage-bridge.sh` and cannot depend on repo files).
- `jq` is at `/opt/homebrew/bin/jq` in the collector scripts (match existing `scripts/ccstatusline`).
- Never commit on `main` — branch first (per project CLAUDE.md).
- Never use `git add -a` — stage only files you actively worked on.
- Surgical changes only: touch only what each task requires; match existing style.

---

## File Structure

- **Create** `Sources/CCUsageCore/Aggregator.swift` — pure aggregation: `SessionSnapshot` decode type + `aggregate(snapshots:)` returning `UsageSnapshot?`. No Foundation filesystem calls; fully testable.
- **Move** `Sources/CCUsageTracker/Models.swift` → `Sources/CCUsageCore/Models.swift` (unchanged contents) so the library holding the aggregator also holds the model types it returns. The executable target depends on this library.
- **Modify** `Package.swift` — add `CCUsageCore` library target and `CCUsageTrackerTests` test target; executable depends on `CCUsageCore`.
- **Modify** `Sources/CCUsageTracker/ClaudeUsageService.swift` — read session files from `sessions/` and call `ClaudeUsageCore.aggregate`; drop the single-file `state.json` decode path.
- **Modify** `Sources/CCUsageTracker/UsageStore.swift` — watch the `sessions/` directory instead of `state.json`'s parent; expose `bridgeActivated`.
- **Modify** `Sources/CCUsageTracker/BridgeInstaller.swift` — rewrite the embedded `bridgeScript` to write per-session files (drops the read–compare–merge block); add `isActivated` (active `statusLine.command` routes through the bridge).
- **Modify** `Sources/CCUsageTracker/Views/SettingsView.swift` — show a "bypassed" state when installed but not activated.
- **Delete** `scripts/ccstatusline` — superseded by the app-installed bridge (dedup; the bridge chains to the previous statusline command, preserving terminal rendering).
- **Create** `Tests/CCUsageTrackerTests/AggregationTests.swift` — TDD tests for `aggregate(snapshots:)`.
- **Create** `scripts/test-bridge.sh` — feeds payloads to the installed bridge and asserts per-session files are written.

Files that gain one `import CCUsageCore` line (because `Models.swift` moved): `ClaudeUsageService.swift`, `UsageStore.swift`, `CCUsageTrackerApp.swift`, `Views/UsagePanelView.swift`, `Views/SettingsView.swift`, `Views/MenuBarLabelView.swift`, `Views/LimitRowView.swift`. Add the import only where the compiler errors direct you; do not touch otherwise.

---

## Task 1: Library target + failing aggregation tests

**Files:**
- Create: `Sources/CCUsageCore/Aggregator.swift`
- Move: `Sources/CCUsageTracker/Models.swift` → `Sources/CCUsageCore/Models.swift`
- Modify: `Package.swift`
- Create: `Tests/CCUsageTrackerTests/AggregationTests.swift`

**Interfaces:**
- Produces: `ClaudeUsageCore.SessionSnapshot` (Decodable), `ClaudeUsageCore.aggregate(snapshots: [SessionSnapshot]) -> UsageSnapshot?`.

- [ ] **Step 1: Create a branch**

```bash
cd /Users/pedroprates/projects/cc_usage
git checkout -b fix/per-session-aggregation
```

- [ ] **Step 2: Move Models.swift into a new CCUsageCore library target**

Create the directory and move the file (contents unchanged):

```bash
mkdir -p Sources/CCUsageCore
git mv Sources/CCUsageTracker/Models.swift Sources/CCUsageCore/Models.swift
```

- [ ] **Step 3: Rewrite Package.swift with the library + test targets**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCUsageTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CCUsageCore",
            path: "Sources/CCUsageCore"
        ),
        .executableTarget(
            name: "CCUsageTracker",
            dependencies: ["CCUsageCore"],
            path: "Sources/CCUsageTracker",
            resources: [
                // None yet. Assets.xcassets would go here when wrapping as .app.
            ]
        ),
        .testTarget(
            name: "CCUsageTrackerTests",
            dependencies: ["CCUsageCore"],
            path: "Tests/CCUsageTrackerTests"
        )
    ]
)
```

- [ ] **Step 4: Add `import CCUsageCore` where the build breaks**

Run the build and let the compiler name the files:

```bash
swift build 2>&1 | grep "error: use of unresolved identifier\|error: cannot find\|Models"
```

Add `import CCUsageCore` at the top of each file the compiler flags as missing `RateLimit`/`UsageSnapshot`/`UsageHealth`. Expect: `ClaudeUsageService.swift`, `UsageStore.swift`, `CCUsageTrackerApp.swift`, `Views/UsagePanelView.swift`, `Views/SettingsView.swift`, `Views/MenuBarLabelView.swift`, `Views/LimitRowView.swift`. Do not edit anything else.

Run: `swift build`
Expected: BUILD SUCCEEDED (no behavior change yet — Models just moved).

- [ ] **Step 5: Write the failing aggregation tests**

Create `Tests/CCUsageTrackerTests/AggregationTests.swift`:

```swift
import XCTest
@testable import CCUsageCore

final class AggregationTests: XCTestCase {
    // SessionSnapshot(window:value:) is a tiny test helper built inline below.
    func snap(_ pct5: Double?, _ rst5: Double?,
              _ pctW: Double?, _ rstW: Double?,
              updatedAt: Double, id: String) -> SessionSnapshot {
        func win(_ p: Double?, _ r: Double?) -> SessionSnapshot.Window? {
            (p == nil && r == nil) ? nil
                : .init(used_percentage: p, resets_at: r)
        }
        return SessionSnapshot(
            updated_at: updatedAt,
            model: "claude-test",
            session_id: id,
            five_hour: win(pct5, rst5),
            seven_day: win(pctW, rstW)
        )
    }

    func testMaxPercentageWinsWithinSameResetWindow() {
        let snaps = [
            snap(55, 1000, 21, 2000, updatedAt: 10, id: "A"),
            snap(75, 1000, 23, 2000, updatedAt: 11, id: "B"),
            snap(92, 1000, 25, 2000, updatedAt: 12, id: "C")
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 92)
        XCTAssertEqual(agg?.fiveHour.resetsAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 25)
    }

    func testNewerResetWindowReplacesEvenWhenLower() {
        let snaps = [
            snap(92, 1000, 25, 2000, updatedAt: 10, id: "A"),
            snap(4, 2000, 5, 4000, updatedAt: 11, id: "B")  // newer window
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 4)
        XCTAssertEqual(agg?.fiveHour.resetsAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 5)
    }

    func testArbitraryOrderKeepsMaxWithinWindow() {
        let snaps = [
            snap(92, 1000, nil, nil, updatedAt: 1, id: "C"),
            snap(30, 1000, nil, nil, updatedAt: 2, id: "A"),
            snap(70, 1000, nil, nil, updatedAt: 3, id: "B")
        ]
        XCTAssertEqual(ClaudeUsageCore.aggregate(snapshots: snaps)?.fiveHour.usedPercentage, 92)
    }

    func testWindowsAggregatedIndependently() {
        // five_hour present in A only; seven_day present in B only.
        let snaps = [
            snap(55, 1000, nil, nil, updatedAt: 10, id: "A"),
            snap(nil, nil, 30, 2000, updatedAt: 11, id: "B")
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 55)
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 30)
    }

    func testOneWindowAbsentFromAllPayloads() {
        let snaps = [snap(55, 1000, nil, nil, updatedAt: 10, id: "A")]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 55)
        XCTAssertNil(agg?.sevenDay.usedPercentage)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClaudeUsageCore.aggregate(snapshots: []))
    }

    func testNoWindowDataReturnsNil() {
        let snaps = [snap(nil, nil, nil, nil, updatedAt: 10, id: "A")]
        XCTAssertNil(ClaudeUsageCore.aggregate(snapshots: snaps))
    }

    func testUpdatedAtIsMaxAcrossSnapshots() {
        let snaps = [
            snap(55, 1000, nil, nil, updatedAt: 10, id: "A"),
            snap(60, 1000, nil, nil, updatedAt: 30, id: "B"),
            snap(58, 1000, nil, nil, updatedAt: 20, id: "C")
        ]
        XCTAssertEqual(ClaudeUsageCore.aggregate(snapshots: snaps)?.updatedAt,
                       Date(timeIntervalSince1970: 30))
    }
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `swift test --filter AggregationTests`
Expected: FAIL — `ClaudeUsageCore.aggregate` and `SessionSnapshot` do not exist (compile error).

- [ ] **Step 7: Commit the failing tests**

```bash
git add Package.swift Sources/CCUsageCore/ Tests/ Sources/CCUsageTracker/
git commit -m "test: add aggregation tests + CCUsageCore library target"
```

---

### Task 2: Implement the aggregator

**Files:**
- Create: `Sources/CCUsageCore/Aggregator.swift`

**Interfaces:**
- Produces: `SessionSnapshot` (Decodable, used by Task 3) and `aggregate(snapshots:) -> UsageSnapshot?`.

- [ ] **Step 1: Write the minimal implementation**

Create `Sources/CCUsageCore/Aggregator.swift`:

```swift
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
```

Note: `Models.swift` types (`RateLimit`, `UsageSnapshot`) are in the same `CCUsageCore` module, so no import is needed inside the library. Mark them `public` is **not** required because `aggregate` returns them and callers are in another module — so they must be `public`. Add `public` to `RateLimit`, `UsageSnapshot`, and their initializers in `Sources/CCUsageCore/Models.swift` now (properties can stay `let` without `public` only if not seen externally; they ARE seen externally, so mark them `public`):

```swift
public struct RateLimit: Equatable {
    public let usedPercentage: Double?
    public let resetsAt: Date?
    public init(usedPercentage: Double?, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
    public var isAvailable: Bool { usedPercentage != nil }
}

public struct UsageSnapshot: Equatable {
    public let fiveHour: RateLimit
    public let sevenDay: RateLimit
    public let updatedAt: Date
    public let model: String?
    public let sessionId: String?
}
```

Leave `UsageHealth` as-is (internal) — it is only used inside the executable target.

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter AggregationTests`
Expected: PASS (all 8 tests).

- [ ] **Step 3: Commit**

```bash
git add Sources/CCUsageCore/Aggregator.swift Sources/CCUsageCore/Models.swift
git commit -m "feat: pure per-session usage aggregation"
```

---

### Task 3: ClaudeUsageService reads session files

**Files:**
- Modify: `Sources/CCUsageTracker/ClaudeUsageService.swift`

**Interfaces:**
- Consumes: `CCUsageCore.aggregate(snapshots:)`, `CCUsageCore.SessionSnapshot` (from Task 2).
- Produces: `sessionsDirURL` (used by Task 4); `readSnapshot()` now returns the aggregate.

- [ ] **Step 1: Rewrite ClaudeUsageService to read sessions/**

Replace the entire file contents with:

```swift
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: BUILD SUCCEEDED. (If `stateURL` references remain in `UsageStore.swift`, leave them — Task 4 rewrites that file. If the build fails only on `UsageStore` referencing `service.stateURL`, proceed to Task 4 before re-checking the build.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CCUsageTracker/ClaudeUsageService.swift
git commit -m "feat: service scans per-session files and aggregates"
```

---

### Task 4: UsageStore watches the sessions directory

**Files:**
- Modify: `Sources/CCUsageTracker/UsageStore.swift`

**Interfaces:**
- Consumes: `service.sessionsDirURL` (from Task 3).
- Produces: `refresh()` reads the aggregate; the file watch points at `sessions/`.

- [ ] **Step 1: Update UsageStore**

In `Sources/CCUsageTracker/UsageStore.swift`:

1. Add `import CCUsageCore` at the top (alongside `import Foundation`).
2. In `beginWatching()` and `startFileWatch()`, replace `service.stateURL.deletingLastPathComponent()` with `service.sessionsDirURL` (two occurrences). Create the sessions directory in `beginWatching`:

```swift
private func beginWatching() {
    try? FileManager.default.createDirectory(
        at: service.sessionsDirURL, withIntermediateDirectories: true)
    startFileWatch()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refresh() }
    }
}

private func startFileWatch() {
    fileSource?.cancel()
    let dir = service.sessionsDirURL
    let fd = open(dir.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .delete, .rename],
        queue: .main
    )
    src.setEventHandler { [weak self] in self?.refresh() }
    src.setCancelHandler { close(fd) }
    src.resume()
    fileSource = src
}
```

3. In `refresh()`, update only the debug line to reflect the new source (the `snapshot`/`bridgeInstalled` lines stay as they are; `bridgeActivated` is added in Task 6):

```swift
func refresh() {
    snapshot = service.readSnapshot()
    bridgeInstalled = BridgeInstaller.shared.isInstalled

    // Debug: write diagnostic to /tmp so we can verify the app is reading sessions
    let debug = "refresh at \(Date()) — snapshot: \(snapshot != nil) — fiveHour: \(snapshot?.fiveHour.usedPercentage ?? -1) — bridge: \(bridgeInstalled)"
    try? debug.write(toFile: "/tmp/cc-usage-debug.log", atomically: true, encoding: .utf8)
}
```

Leave `isStale`, notifications, and everything else untouched.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: BUILD SUCCEEDED (Task 3 removed `stateURL` and this task replaced its last two call sites; nothing else references `stateURL`).

- [ ] **Step 3: Commit**

```bash
git add Sources/CCUsageTracker/UsageStore.swift
git commit -m "feat: UsageStore watches the sessions directory"
```

---

### Task 5: Bridge collector writes per-session files

**Files:**
- Modify: `Sources/CCUsageTracker/BridgeInstaller.swift` (the `bridgeScript` literal, lines ~153–222)
- Delete: `scripts/ccstatusline`

**Interfaces:**
- Produces: a collector that writes `~/.claude/cc-usage-tracker/sessions/<session_id>.json` atomically and still chains to the previous statusline command.

- [ ] **Step 1: Replace the embedded bridgeScript**

In `Sources/CCUsageTracker/BridgeInstaller.swift`, replace the entire `private static let bridgeScript = #""" ... """#` block with:

```swift
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
```

Key changes vs. the old embedded script: writes to `sessions/<session_id>.json`; uses a PID-suffixed temp name (`.$$`) so concurrent writers cannot collide on the temp file; the read–compare–merge block is gone (the app aggregates now).

- [ ] **Step 2: Delete the duplicated standalone collector**

```bash
git rm scripts/ccstatusline
```

This is the "remove the duplicated embedded/standalone implementations" cleanup from the investigation. The app-installed bridge is now the only collector; it chains to the previous statusline command (the user's terminal renderer), so terminal output is preserved. The orphaned `/usr/local/bin/ccstatusline` on the machine is left in place (harmless); Task 6's active-command check will surface the bypass and re-install routes through the bridge.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/CCUsageTracker/BridgeInstaller.swift scripts/ccstatusline
git commit -m "feat: bridge writes one file per session; drop standalone collector"
```

---

### Task 6: Detect and surface when the bridge is bypassed

**Files:**
- Modify: `Sources/CCUsageTracker/BridgeInstaller.swift` (add `isActivated`)
- Modify: `Sources/CCUsageTracker/UsageStore.swift` (add `bridgeActivated`)
- Modify: `Sources/CCUsageTracker/Views/SettingsView.swift` (show bypassed state)

**Interfaces:**
- Produces: `BridgeInstaller.isActivated: Bool`, `UsageStore.bridgeActivated: Bool`.

- [ ] **Step 1: Add isActivated to BridgeInstaller**

In `Sources/CCUsageTracker/BridgeInstaller.swift`, next to the existing `var isInstalled: Bool { ... }`, add:

```swift
    /// True when the active `statusLine.command` in ~/.claude/settings.json
    /// routes through this bridge. The investigation found the app's
    /// `isInstalled` checked only file existence, so a status-line change that
    /// pointed the command elsewhere left the app silently bypassed.
    var isActivated: Bool {
        guard let settings = Self.readSettingsJSON() else { return false }
        let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String
        return cmd?.contains(Self.bridgePath) == true
    }
```

`readSettingsJSON()` is already `private static`; `isActivated` is in the same type so it can call it. `bridgePath` is the absolute path `~/.claude/cc-usage-bridge.sh`; `bridgeCommand` is `"bash \(bridgePath)"`, so checking `cmd.contains(bridgePath)` matches both the `bash <path>` form and a direct path form.

- [ ] **Step 2: Add bridgeActivated to UsageStore**

In `Sources/CCUsageTracker/UsageStore.swift`:

1. Next to `@Published private(set) var bridgeInstalled: Bool = false`, add:

```swift
@Published private(set) var bridgeActivated: Bool = false
```

2. In `refresh()`, set it after `bridgeInstalled`:

```swift
func refresh() {
    snapshot = service.readSnapshot()
    bridgeInstalled = BridgeInstaller.shared.isInstalled
    bridgeActivated = BridgeInstaller.shared.isActivated

    // Debug: write diagnostic to /tmp so we can verify the app is reading sessions
    let debug = "refresh at \(Date()) — snapshot: \(snapshot != nil) — fiveHour: \(snapshot?.fiveHour.usedPercentage ?? -1) — bridge: \(bridgeInstalled)/\(bridgeActivated)"
    try? debug.write(toFile: "/tmp/cc-usage-debug.log", atomically: true, encoding: .utf8)
}
```

- [ ] **Step 3: Show the bypassed state in SettingsView**

In `Sources/CCUsageTracker/Views/SettingsView.swift`, the status row currently reads `bridgeInstalled ? "Installed" : "Not installed"`. Replace that line's text logic so a bypassed bridge is visible. Find the `Text(bridgeInstalled ? "Installed" : "Not installed")` line and replace with:

```swift
                        Text(bridgeInstalled
                             ? (store.bridgeActivated ? "Installed" : "Installed (bypassed)")
                             : "Not installed")
```

If `SettingsView` does not already hold a reference to `UsageStore`, add `@EnvironmentObject` / `let store: UsageStore` matching how `UsagePanelView` obtains it (check `UsagePanelView.swift` for the established pattern and copy it — do not invent a new one). If `SettingsView` already reads `bridgeInstalled` from a local `@State` mirroring `BridgeInstaller.shared.isInstalled`, also mirror `bridgeActivated` the same way (set it in the same `.onAppear` / refresh call where `bridgeInstalled` is set).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Sources/CCUsageTracker/BridgeInstaller.swift Sources/CCUsageTracker/UsageStore.swift Sources/CCUsageTracker/Views/SettingsView.swift
git commit -m "feat: detect and surface when the bridge is bypassed"
```

---

### Task 7: Shell test for the bridge

**Files:**
- Create: `scripts/test-bridge.sh`

This is the lazy self-check for the non-Swift part: it feeds payloads to the installed bridge and asserts per-session files appear. It is not a unit framework — plain `assert`.

- [ ] **Step 1: Write the test script**

Create `scripts/test-bridge.sh`:

```bash
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

rm -f "$SESSIONS_DIR"/*.json 2>/dev/null || true

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
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/test-bridge.sh
```

- [ ] **Step 3: Run it (after the app has been built + opened once so the bridge is installed)**

Run: `./scripts/test-bridge.sh`
Expected: `PASS: bridge writes one valid file per session, concurrent writers safe.`

- [ ] **Step 4: Commit**

```bash
git add scripts/test-bridge.sh
git commit -m "test: bridge per-session write self-check"
```

---

### Task 8: End-to-end verification

**Files:** none (verification only).

This task maps directly to the "Acceptance checks for a future fix" section of `INVESTIGATION.html`. Run each by feeding payloads into the live `sessions/` directory (or via the bridge) and reading the menu-bar value.

- [ ] **Step 1: Build and install the app**

```bash
./build-app.sh
open "$HOME/Applications/CC Usage Tracker.app"
```

- [ ] **Step 2: Re-install the bridge from the app's Settings view**

Open the app → Settings → Uninstall, then Install. This writes the new per-session bridge and sets `statusLine.command` to `bash ~/.claude/cc-usage-bridge.sh`. Confirm Settings shows "Installed" (not "Installed (bypassed)").

- [ ] **Step 3: Acceptance — monotonic within a window**

With one reset timestamp, feed three snapshots 30% / 70% / 92% in arbitrary order:

```bash
D="$HOME/.claude/cc-usage-tracker/sessions"
mkdir -p "$D"
for pair in "A:30" "B:70" "C:92"; do
  s="${pair%:*}"; p="${pair#*:}"
  jq -n --arg s "$s" --argjson p "$p" \
    '{updated_at:0, model:"t", session_id:$s,
      five_hour:{used_percentage:$p, resets_at:1000},
      seven_day:{used_percentage:null, resets_at:null}}' > "$D/$s.json"
done
```

Wait ≤10s (poll) or trigger a refresh. Expected: menu bar shows 92%.

- [ ] **Step 4: Acceptance — newer window drops the value**

```bash
D="$HOME/.claude/cc-usage-tracker/sessions"
jq -n '{updated_at:0, model:"t", session_id:"D",
       five_hour:{used_percentage:4, resets_at:2000},
       seven_day:{used_percentage:null, resets_at:null}}' > "$D/D.json"
```

Expected: menu bar drops to 4%; `resetsAt` reflects the new window (2000), never paired with the old (1000).

- [ ] **Step 5: Acceptance — idle sessions cannot lower the value**

Leave A/B/C files (55% era) untouched while only D advances to a higher value in the *same* window 2000:

```bash
jq -n '{updated_at:1, model:"t", session_id:"D",
       five_hour:{used_percentage:50, resets_at:2000},
       seven_day:{used_percentage:null, resets_at:null}}' > "$D/D.json"
# A/B/C still hold resets_at:1000 → excluded from the current window (2000).
```

Expected: menu bar shows 50% (D's value), not 30/70/92 from the old window.

- [ ] **Step 6: Acceptance — bypass is reported**

Change the status-line renderer away from the bridge:

```bash
# Back up first; restore after.
cp ~/.claude/settings.json /tmp/settings.bak
jq '.statusLine.command = "echo bypassed"' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

Open the app → Settings. Expected: "Installed (bypassed)". Restore: `cp /tmp/settings.bak ~/.claude/settings.json`.

- [ ] **Step 7: Acceptance — windows independent, one absent**

```bash
D="$HOME/.claude/cc-usage-tracker/sessions"
rm -f "$D"/*.json
jq -n '{updated_at:0, model:"t", session_id:"X",
       five_hour:{used_percentage:55, resets_at:1000},
       seven_day:{used_percentage:null, resets_at:null}}' > "$D/X.json"
jq -n '{updated_at:0, model:"t", session_id:"Y",
       five_hour:{used_percentage:null, resets_at:null},
       seven_day:{used_percentage:21, resets_at:2000}}' > "$D/Y.json"
```

Expected: 5-hour shows 55%, weekly shows 21% (one window absent per payload does not break the other).

- [ ] **Step 8: Final commit (if any verification surfaced fixes)**

If steps 3–7 surfaced code fixes, stage and commit them. Otherwise no commit.

```bash
git status   # confirm clean
```

---

## Verification summary

- **Unit:** `swift test --filter AggregationTests` — 8 tests covering max-in-window, newer-window-replaces, arbitrary order, independent windows, absent window, empty, no-data, updatedAt.
- **Bridge:** `./scripts/test-bridge.sh` — three sessions get distinct valid files; 20 concurrent writers leave every file valid.
- **End-to-end:** Task 8 steps 3–7 reproduce each acceptance check from `INVESTIGATION.html` against the live app.
- **Build:** `swift build` and `./build-app.sh` both succeed.

## Notes / assumptions

- Claude Code `session_id` is filename-safe (hex). The bridge falls back to `no-session.json` if absent, accepting that this single fallback file may contend (rare; pre-first-response payloads carry no `rate_limits` anyway and are skipped).
- The old `~/.claude/cc-usage-tracker/state.json` is no longer read or written. It is left on disk; deleting it is out of scope (surgical changes).
- `refreshInterval: 10` in `~/.claude/settings.json` is harmless now: idle sessions rewrite their *own* file, and aggregation takes the max per window, so periodic republishing cannot lower the value. No setting change required (Option 3 from the investigation becomes unnecessary).
