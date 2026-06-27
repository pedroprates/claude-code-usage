<div align="center">

# CC Usage Tracker

**A native macOS menu-bar app that surfaces Claude Code's 5-hour and weekly usage limits at a glance.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138.svg)](https://www.swift.org/)
[![Status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)](#status)

<!-- Replace with a real screenshot or GIF of the menu bar item + popover.
     A demo GIF above the fold is the single biggest README conversion lift. -->
<p>
  <em>screenshot placeholder — menu-bar label (5h % + weekly health dot) and the dropdown popover</em>
</p>

[Quick Start](#quick-start) · [Features](#features) · [How it works](#how-it-works) · [Configuration](#configuration) · [Roadmap](#roadmap) · [Contributing](#contributing)

</div>

---

## Status

> [!WARNING]
> This project is **alpha** software. Claude's exact 5-hour and weekly limits are not published by Anthropic and vary with plan and demand. The percentages shown are read directly from Claude Code's own statusline feed — they are an approximation of your remaining headroom, not an authoritative "you will be cut off at X" signal. Same caveat applies to every third-party tracker.

## What it does

A lightweight SwiftUI menu-bar utility that tracks Claude Code's 5-hour and 7-day rolling usage windows, and optionally surfaces your [OpenRouter](https://openrouter.ai/) credit balance. It sits in the menu bar, reads local `~/.claude` data, and respects the macOS Liquid Glass aesthetic.

- **Menu-bar item** — shows the 5-hour window percentage as text, plus a colored dot reflecting the weekly limit's health (green / yellow / red).
- **Dropdown popover** (on click) — full progress bars for both the 5-hour and 7-day rolling windows, plus an OpenRouter balance card.
- **Settings** — adjust warn/danger thresholds, enable notifications, and store an OpenRouter API key in Keychain.
- **Notifications** (opt-in) — fired when a limit crosses the danger threshold.
- **Bridge-aware** — chains transparently onto any existing Claude Code statusline command you already use.

## Quick start

```sh
git clone https://github.com/<your-user>/cc-usage-tracker.git
cd cc-usage-tracker

# 1. Build & install the .app bundle into ~/Applications
./build-app.sh

# 2. Launch it
open "$HOME/Applications/CC Usage Tracker.app"

# 3. On first launch, install the statusline bridge from Settings → "Install bridge"
#    (requires jq — see Prerequisites)
```

Once the bridge is installed, use Claude Code normally. The menu-bar item updates within a few seconds of each assistant response.

## Features

| Feature | Description |
| --- | --- |
| 🟢 5-hour window | Percentage used in the current 5-hour sliding window, straight from Claude Code's feed. |
| 🟡 Weekly window | 7-day rolling usage with a colored health dot (ok / warn / danger / unavailable). |
| 🔔 Notifications | Optional alert when a window crosses the danger threshold. |
| 💸 OpenRouter balance | Live credit balance via `GET https://openrouter.ai/api/v1/credits`. |
| 🔑 Keychain-backed key | OpenRouter API key stored in macOS Keychain (or read from an env var). |
| 🖇️ Non-invasive bridge | Chains to your existing statusline command — your terminal output is unchanged. |
| 🚫 Menu-bar only | `LSUIElement = true` — no Dock icon, no main window. |

## How it works

CC Usage Tracker does **not** parse JSONL logs itself. Instead it relies on a small **statusline bridge** that Claude Code invokes on every assistant turn.

```
 Claude Code                bridge script                 menu-bar app
 ────────────   stdin JSON   ────────────────   state.json   ─────────────
 statusLine  ──────────────▶ ~/.claude/         ────────────▶ reads
 command                        cc-usage-                    ~/.claude/
                                bridge.sh                    cc-usage-tracker/
                                     │                        state.json
                                     │ forwards stdout
                                     ▼
                          your previous statusline command (unchanged terminal output)
```

1. Claude Code sends a JSON payload (including `rate_limits`) to its configured `statusLine.command`.
2. The bridge (`~/.claude/cc-usage-bridge.sh`) extracts `rate_limits.five_hour` and `rate_limits.seven_day` and writes them atomically to `~/.claude/cc-usage-tracker/state.json`.
3. The bridge then pipes the original payload to whatever statusline command you had before, forwarding its stdout unchanged — so your terminal statusline keeps working.
4. The menu-bar app watches `state.json` and refreshes the label + popover.

> [!NOTE]
> The bridge only writes `state.json` when a payload actually carries `rate_limits`. Payloads without them (idle / pre-first-response / API-plan sessions) are passed through untouched, so a quiet session can't clobber the active session's real value across the shared file.

The `used_percentage` values are pre-calculated by Anthropic and forwarded as-is; CC Usage Tracker does not estimate token caps.

## Prerequisites

- **macOS 14 (Sonoma) or newer** — uses `MenuBarExtra` and the `Charts` framework.
- **Swift 5.9+ toolchain** (ships with Xcode 15 / the Swift command-line tools).
- **[`jq`](https://stedolan.github.io/jq/)** — required by the statusline bridge. Install with `brew install jq`.

## Installation

### Option A — `.app` bundle (recommended)

```sh
./build-app.sh        # builds release binary, wraps as .app, installs to ~/Applications
open "$HOME/Applications/CC Usage Tracker.app"
```

To launch at login: **System Settings → General → Login Items → +** and select the `.app`.

### Option B — run from source

```sh
swift run              # debug build, launches immediately
# or
swift build -c release # optimized binary at .build/release/CCUsageTracker
.build/release/CCUsageTracker
```

### Installing the bridge

The app can install the bridge for you from **Settings → Install bridge**. It will:

- write `~/.claude/cc-usage-bridge.sh`,
- back up your current `statusLine.command` and patch `~/.claude/settings.json` to invoke the bridge,
- chain back to your previous command at runtime.

To remove it later, use **Settings → Uninstall bridge** — your original `statusLine.command` is restored.

<details>
<summary><b>Manual / alternative statusline setup</b></summary>

If you already use [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) or another statusline renderer, `scripts/ccstatusline` is a ready-made bridge that persists `state.json` and then hands stdin to the `ccstatusline` node renderer. Point `statusLine.command` at it directly:

```jsonc
// ~/.claude/settings.json
{
  "statusLine": {
    "type": "command",
    "command": "bash /path/to/cc-usage-tracker/scripts/ccstatusline"
  }
}
```

</details>

## Configuration

Open **Settings** (click the menu-bar item → ⚙️) to configure:

| Setting | Default | Description |
| --- | --- | --- |
| Warn threshold | 60% | Weekly window turns yellow at/above this. |
| Danger threshold | 85% | Weekly window turns red; notifications fire. |
| Notifications | Off | Alert when a window crosses the danger threshold. |
| OpenRouter API key | — | Stored in Keychain (account `openrouter-api-key`). |

### Environment variables

| Variable | Purpose |
| --- | --- |
| `OPENROUTER_API_KEY` | If set, the OpenRouter balance card uses this instead of the Keychain entry — handy for headless / shared setups. |

## Project layout

```
cc-usage-tracker/
├── Package.swift
├── build-app.sh                 # builds & installs the .app bundle
├── scripts/
│   └── ccstatusline             # standalone statusline bridge (chains to ccstatusline)
└── Sources/CCUsageTracker/
    ├── CCUsageTrackerApp.swift  # @main, MenuBarExtra scene
    ├── Models.swift             # RateLimit, UsageSnapshot, UsageHealth
    ├── ClaudeUsageService.swift # reads canonical state.json
    ├── OpenRouterService.swift  # /credits fetch
    ├── KeychainStore.swift      # SecItem wrapper
    ├── SettingsStore.swift      # @AppStorage-backed settings
    ├── UsageStore.swift         # refresh bridge + notifications
    ├── BridgeInstaller.swift    # installs/uninstalls the statusline bridge
    └── Views/
        ├── MenuBarLabelView.swift
        ├── UsagePanelView.swift
        ├── LimitRowView.swift
        └── SettingsView.swift
```

## Roadmap

- [x] Menu-bar label with 5h % + weekly health dot
- [x] Dropdown popover with progress bars
- [x] Statusline bridge with pass-through chaining
- [x] OpenRouter balance card
- [x] Keychain-backed API key
- [ ] Sparklines / history graph in the popover
- [ ] FSEvents on `state.json` for instant refresh
- [ ] Localized strings
- [ ] Notarized `.dmg` distribution

## Contributing

Contributions are welcome and appreciated. This is a small, single-binary project — keep PRs focused.

1. Fork the repo and create a branch: `git checkout -b feature/my-change`.
2. Make your change. Keep Swift code formatted and consistent with the surrounding style.
3. Verify it builds: `swift build`.
4. Open a Pull Request describing **what** changed and **why**.

> [!NOTE]
> For bug reports, please include your macOS version, Swift toolchain version (`swift --version`), and the contents of `~/.claude/cc-usage-tracker/state.json` (redacted) if relevant.

## Acknowledgments

- [`ccusage`](https://github.com/ryoppippi/ccusage) — the reference CLI whose windowing logic inspired this project.
- [`ccstatusline`](https://github.com/sirmalloc/ccstatusline) — the terminal statusline renderer that `scripts/ccstatusline` chains to.

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for details.

> [!IMPORTANT]
> No `LICENSE` file exists in this repo yet. Add one (e.g. `curl -s https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt -o LICENSE`) before making the repo public, or swap the badge + this section for your preferred license (Apache-2.0, GPLv3, etc.).
