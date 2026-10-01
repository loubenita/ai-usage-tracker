# AI Usage Tracker

A small macOS overlay on the right edge of your screen that shows the AI coding agents running in your terminals: what each session is costing, how full its context is, and which plan limit runs out first. It reads the files Claude Code, Codex, Cursor Agent and Kiro already keep on your Mac. It has no Dock icon and no menu bar item.

## Install

Needs macOS 26 or later, on an Apple silicon or Intel Mac.

```sh
curl -fsSL https://raw.githubusercontent.com/loubenita/ai-usage-tracker/main/scripts/install.sh | bash
```

That downloads the [latest release](https://github.com/loubenita/ai-usage-tracker/releases/latest), puts the app in `/Applications`, clears its download flag and opens it.

Or install it by hand:

1. Download `AIUsageTracker.zip` from the [releases page](https://github.com/loubenita/ai-usage-tracker/releases/latest).
2. Open the zip and drag `AIUsageTracker.app` into `/Applications`.
3. Clear the download flag, or macOS will refuse to open the app:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AIUsageTracker.app
   ```

Do the same on each Mac you install it on, and again for each new version you download by hand.

To quit the app, right-click the strip or a panel and choose **Quit**.

### Why the xattr command is needed

- **macOS flags what you download.** A browser, Mail, Messages or AirDrop marks each file it saves with a "quarantine" flag. The flag is an extended attribute named `com.apple.quarantine`, and the app keeps it when you unzip it.
- **A flagged app must be notarized.** The first time you open a flagged app, macOS's Gatekeeper checks that Apple has notarized it. A notarized app is signed with a Developer ID certificate from Apple's paid Developer Program, then sent to Apple to be scanned.
- **This app is signed but not notarized.** It is built from this repository by the [Release workflow](.github/workflows/release.yml), without a Developer ID. So Gatekeeper blocks it: "“AIUsageTracker” Not Opened. Apple could not verify “AIUsageTracker” is free of malware…"
- **`xattr -dr com.apple.quarantine` removes the flag.** `-d` deletes the attribute, and `-r` deletes it from every file inside the app. Without the flag, Gatekeeper does not check the app, and it opens like an app you built yourself. The command changes nothing else: the app itself and Gatekeeper's checks on every other app stay as they are.
- **Only clear the flag on an app you trust.** The source is all in this repository. Each release's notes give the zip's SHA-256, which you can compare with `shasum -a 256 AIUsageTracker.zip`.

Without Terminal: open the app once and let macOS block it. Then go to **System Settings > Privacy & Security**, scroll down to **Security**, click **Open Anyway** next to AIUsageTracker, and confirm with your password. Since macOS 15, right-clicking the app and choosing **Open** no longer gets past Gatekeeper.

## What it shows

### The strip

At rest a rounded glass rail sits just inside the screen's right edge. It shows up to four sessions ranked by known spend, then context use and recent activity, with a "+N" count for the rest. Hold the pointer over it for about a second and the rail widens into a list. Each row shows the agent, task, project and branch when known, active time, and context ring. Full facts stay in the selected session's panel.

- Each ring fills as that session's context fills, turns red when it is nearly full, and carries its agent's colour.
- Inside the ring is the current context in use: the number and the fill describe the same reading. Cumulative session tokens stay in the session panel.
- An amber dot means the last agent turn finished and the session is ready for input. The app cannot tell who should respond next.
- Drag the visible handle at the top of the rail to move it up or down. It becomes compact while moving and stays where you drop it. Scrolling the session rows does not move the overlay.

### A session

Click a ring.

It shows only the selected session, including a named Claude account when one is known: what it is doing and where it runs, available spend or credits and tokens, active time and turns, and context with when it may be full at this pace. **Show details** reveals readable token categories, model and effort, pace, first ask, tool and file activity, and location. Input means new uncached text; cache read is context reused from earlier turns, so it can be much larger. Sessions that started sub-agents show their run count, combined tokens, cost, working time and share of session spend in one summary. These runs are already included in the session totals.

**Open** selects the existing tab and session in Terminal or iTerm by its TTY. For tmux, it selects the session's pane in an attached tmux client and brings the host terminal forward. A tmux session shown inside a pane of another tmux session is selected there too: the outer session is switched to that pane, so the session you asked for is the one in view. Warp and Ghostty sessions say **Bring forward**: the app can raise those terminals, but cannot select an exact tab there. This also limits which Warp tab becomes visible for a tmux session. The app never types into a terminal. Its action and observed result are written to `~/Library/Application Support/AIUsageTracker/open.log`.

### Usage

The button under the strip opens the usage panel: every agent, or one, across Today, Week and Month.

It opens by naming what runs out first — "Codex runs out first: 5% of its week is left until Thu 06:57" — then lists available limits by provider and Claude account. Each reading has its window, used share, progress bar, and a reset time when the source supplies one. Old account readings are labelled instead of shown as current. Bars turn amber at 85%. Under that: time, tokens and spend for each agent, and where the time went. Picking one agent shows its limits and pace, its numbers, a chart of the period, its models and its work. Today omits weekly limits.

Anything an agent does not report is left out rather than shown as zero; in the table, where the column has to stay for the others, the cell says "n/a".

The pictures show the made-up sessions the app ships with, so no real project appears in this repository. Everything here is run against real sessions too.

## Claude's limits

Claude Code keeps its plan limits out of its transcripts, but hands them to the status line. Point yours at the script in this repository and the app can show them. In `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "/path/to/ai-usage-tracker/scripts/claude-statusline.sh" }
```

For multiple Claude accounts, set this status line in each account's `settings.json` under its `CLAUDE_CONFIG_DIR`. The tracker reads each profile's sessions separately and shows each account's limits separately. Set `AIUT_ACCOUNT_NAME` for a readable account label if the directory name is unclear. If the existing `account-usage.py` status line is installed, the tracker also reads its per-account percentage cache; it shows those percentages without inventing reset times.

Until then Usage explains how to turn on Claude limits and leaves out empty limit bars. No login, token or Keychain item is involved anywhere in the app. If you already have a status line, set `AIUT_STATUSLINE_NEXT` to its command and the script prints that instead of its own.

## What each agent gives

| | Claude Code | Codex | Cursor Agent | Kiro CLI | Antigravity |
|---|---|---|---|---|---|
| Ring colour | The text colour | Light grey | Blue | Violet | Unavailable today |
| Context and tokens | Yes | Yes | Context only: Cursor keeps no token count | Yes, except its Auto agent | No: its conversations are encrypted |
| Cost | Yes, at API list prices | No prices available | Billed by plan | Billed in credits | No |
| Plan limits | 5-hour and weekly, [with the status line](#claudes-limits) | 5-hour and weekly when present in its own files | No | This month's credits, by asking `kiro-cli` | No |
| Counted in Today, Week and Month | Yes, sub-agents included | Yes | No history; live context and prompts only | Yes, in credits | No |

Antigravity runs as a desktop app rather than in a terminal and encrypts what it saves, so it cannot be tracked. Kiro's reader is written from other tools' descriptions of Kiro and has not been tried on a real Kiro session.

## More

- [Provider data inventory](docs/provider-data-inventory.md) — fields the app can read or calculate, what is unavailable, how Claude accounts work, and which facts belong in each view.
- [How it works](docs/how-it-works.md) — how sessions are found, what each agent's files give, how a month of history is read and kept, and the architecture.
- [Building and running it](docs/development.md) — build, test, the launch options, the scripts, and how a release is made.
