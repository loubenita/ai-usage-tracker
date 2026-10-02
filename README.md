# AI Usage Tracker

A small macOS overlay on the right edge of your screen that shows the AI coding agents running in your terminals: what each session is costing, how full its context is, and which plan limit runs out first. It reads the files Claude Code, Codex, Cursor Agent and Kiro already keep on your Mac, and also lists OpenCode sessions, without usage numbers. It has no Dock icon and no menu bar item. [What's supported](#whats-supported) lists what works for each agent and each terminal, and what does not.

<p align="center">
  <img src="docs/images/session.png" alt="A Claude Code session's panel, showing its spend, tokens, active time, turns and context, open beside the list of seven running sessions" width="690">
</p>

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

<p>
  <img src="docs/images/rail.png" alt="The rail at rest on the right edge of the desktop: four context rings and a +3 count for three more sessions" width="265" align="top">
  &nbsp;&nbsp;
  <img src="docs/images/sessions.png" alt="The rail widened into a list of seven sessions, each with its name, folder, branch, context ring and active time; two rings carry an amber dot" width="250" align="top">
</p>

The rail at rest, and the same rail widened into the list. Two of the seven sessions are ready for input.

- Each ring fills as that session's context fills, turns red when it is nearly full, and carries its agent's colour.
- Inside the ring is the current context in use: the number and the fill describe the same reading. Cumulative session tokens stay in the session panel.
- When the app has no context reading for a session, the ring shows a short code made from the session's name instead, for example `HOME` for a session in your home folder. A Claude Code session has no reading until its first reply, and none again right after `/clear`, which starts a new session. An OpenCode session never has one, and a Kiro session has none while the app cannot find its session file.
- An amber dot means the last agent turn finished and the session is ready for input. The app cannot tell who should respond next.
- Drag the visible handle at the top of the rail to move it up or down. It becomes compact while moving and stays where you drop it. Scrolling the session rows does not move the overlay.

### A session

Click a ring.

It shows only the selected session, including a named Claude account when one is known: what it is doing and where it runs, available spend or credits and tokens, active time and turns, and context with when it may be full at this pace. **Show details** reveals readable token categories, model and effort, pace, first ask, tool and file activity, and location. Input means new uncached text; cache read is context reused from earlier turns, so it can be much larger. Sessions that started sub-agents show their run count, combined tokens, cost, working time and share of session spend in one summary. These runs are already included in the session totals.

<p>
  <img src="docs/images/session-details.png" alt="A session panel with its details shown: input, output, cache read and cache write tokens, one sub-agent run, pace, model, tool calls, files changed, the first ask, when it started and its branch" width="448">
</p>

**Open** brings the session's terminal forward, on the exact window or tab where it can. [Terminals and the Open button](#terminals-and-the-open-button) says what it does in each terminal. Where the app can raise the terminal but cannot pick the tab, the button says **Bring forward** instead. The app never types into a terminal. Its action and observed result are written to `~/Library/Application Support/AIUsageTracker/open.log`.

### Usage

The button under the strip opens the usage panel: every agent, or one, across Today, Week and Month.

It opens by naming what runs out first — "Codex runs out first: 5% of its week is left until Thu 06:57" — then lists available limits by provider and Claude account. Each reading has its window, used share, progress bar, and a reset time when the source supplies one. A limit nobody has read lately still shows its last reading and when it was taken, so an account at 100% stays visible. A limit that has reset since its last reading says so: "Week limit reset · Reset 12:32 · no reading since". Bars turn amber at 85%. Under that: time, tokens and spend for each agent, and where the time went. Picking one agent shows its limits and pace, its numbers, a chart of the period, its models and its work. Today omits weekly limits.

<p>
  <img src="docs/images/usage-week.png" alt="The usage panel for every agent this week: it opens with &quot;Codex has run out of its week until Sat 21:23&quot;, then Claude and Codex limit bars, time, tokens and spend for each agent, and where the time went" width="380" align="top">
  &nbsp;
  <img src="docs/images/usage-today.png" alt="The usage panel for every agent today: Claude's 5-hour limit, today's time, tokens and spend, and where the time went" width="380" align="top">
</p>

Every agent, this week and today. Codex has used all of its week, so the panel opens by saying when it comes back.

Anything an agent does not report is left out rather than shown as zero; in the table, where the column has to stay for the others, the cell says "n/a".

<p>
  <img src="docs/images/usage-week-claude.png" alt="The usage panel for Claude this week: the week limit, spend, tokens, time, sessions, a chart of tokens per day, the models used and where the time went" width="380" align="top">
  &nbsp;
  <img src="docs/images/usage-week-codex.png" alt="The usage panel for Codex this week: the week limit at 100% with when it resets and its pace, tokens, time, sessions, a chart of tokens per day, the models used and where the time went" width="380" align="top">
</p>

One agent at a time. Codex keeps no prices on the Mac, so its view has no spend.

The pictures were taken on a real Mac on 1 October 2026, with some session and folder names blurred.

## Claude's limits

Claude Code keeps its plan limits out of its transcripts, but hands them to the status line. Point yours at the script in this repository and the app can show them. In `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "/path/to/ai-usage-tracker/scripts/claude-statusline.sh" }
```

For multiple Claude accounts, set this status line in each account's `settings.json` under its `CLAUDE_CONFIG_DIR`. The tracker reads each profile's sessions separately and shows each account's limits separately. Set `AIUT_ACCOUNT_NAME` for a readable account label if the directory name is unclear. If the existing `account-usage.py` status line is installed, the tracker also reads its per-account percentage cache; it shows those percentages without inventing reset times.

Until then Usage explains how to turn on Claude limits and leaves out empty limit bars. No login, token or Keychain item is involved anywhere in the app. If you already have a status line, set `AIUT_STATUSLINE_NEXT` to its command and the script prints that instead of its own.

## What's supported

### Agents

The app finds an agent by its program name in your Mac's list of running processes, such as `claude` or `codex`, then reads the files that agent keeps.

| | Claude Code | Codex | Cursor Agent | Kiro CLI | OpenCode | Antigravity |
|---|---|---|---|---|---|---|
| Listed while it runs | Yes | Yes | Yes | Yes | Yes | No |
| Ring colour | The text colour | Light grey | Blue | Violet | Yellow | Unavailable today |
| Context and tokens | Yes | Yes | Context only: Cursor keeps no token count | Context only: current Kiro builds write every token count as 0 | No: the ring shows a code | No: its conversations are encrypted |
| Cost | Yes, at API list prices | No prices available | Billed by plan | Billed in credits | No | No |
| Plan limits | 5-hour and weekly, [with the status line](#claudes-limits) | 5-hour and weekly when present in its own files | No | This month's credits, by asking `kiro-cli` | No | No |
| Counted in Today, Week and Month | Yes, sub-agents included | Yes | No history; live context and prompts only | Yes, in credits | No | No |

- **OpenCode** sessions are listed with their terminal, folder, project and branch only. The app reads none of OpenCode's own files, so it has no model, tokens, cost or history for them.
- **Antigravity** runs as a desktop app rather than in a terminal and encrypts what it saves, so it cannot be tracked.
- **Kiro**'s session fields were checked against a file from a real Kiro install. Its plan output, read by asking `kiro-cli`, has not been checked against a live run.

Not supported for any agent:

- **Agents on another computer**, for example one you reach over SSH. The app reads only this Mac's running processes and files.
- **Names the agent makes up.** A session's title in the strip is the name you gave it. Without one, it is the branch in words, so `feat/session-detection` reads "Session detection", or the folder name on a main branch such as `main` or `develop`. A title Claude Code writes for itself, such as "Paper design overhaul", is not used.
- **Windows and Linux.** The app runs on macOS only.

### Terminals and the Open button

The session panel's **Open** button brings forward the terminal an agent runs in. A TTY, below, is the terminal device an agent reads and writes, such as `/dev/ttys004`: each tab has its own.

| Where the agent runs | What Open does | How it was checked |
|---|---|---|
| Terminal | Selects the window and tab with the session's TTY, and brings Terminal forward | On a real Mac |
| iTerm | Selects the window, tab and split pane with the session's TTY | Automated tests only |
| Warp | Opens the session's own tab, through the link Warp gives each tab | On a real Mac |
| Ghostty | Brings Ghostty forward. The button says **Bring forward**, since Ghostty offers no way to pick a tab | Automated tests only |
| tmux, shown in any of the above | Switches a tmux client to the session's window and pane, then brings forward the window or tab that client runs in: Terminal and iTerm by the client's TTY, Warp by the client's tab link | On a real Mac, in Terminal and Warp |
| tmux, shown inside another tmux session | Also switches the outer session to the pane that shows it, outward up to 4 levels, then brings forward the outermost client's window | On a real Mac |
| Any other terminal, such as kitty, Alacritty, WezTerm or an editor's built-in terminal | Nothing: the session is listed, with no Open button | |
| No terminal, such as a session an agent runs in the background | Nothing: the session is listed, with no Open button | |

- **Warp's tab link.** Warp puts each tab's link in the environment of every process started in that tab, under the name `WARP_FOCUS_URL`, for example `warp://session/0123456789abcdef0123456789abcdef`. The app reads it from the session's process. Only a link of exactly that shape is ever opened. When the link cannot be read, the button says **Bring forward** and Warp only comes forward.
- **A Warp link is only trusted from a process Warp started.** Warp copies the link into everything started from a tab. So a Terminal window opened from a Warp tab, or a tmux server first started in one, carries the link of that tab without being in it.
- **tmux in several terminals.** One tmux server can be shown in several terminals at once. So the window to bring forward is worked out from the tmux client's own process each time Open is clicked.
- **tmux inside tmux.** This covers one tmux session shown in a single tab, with other sessions attached in its windows as watchers. Open on a watched session switches the outer session to that watcher's window, so the session you asked for is the one in view.
- **The real-Mac checks** ran on 1 October 2026 with real Claude Code, Codex and Cursor Agent sessions, with another window or app in front each time.

## More

- [Provider data inventory](docs/provider-data-inventory.md) — fields the app can read or calculate, what is unavailable, how Claude accounts work, and which facts belong in each view.
- [How it works](docs/how-it-works.md) — how sessions are found, what each agent's files give, how a month of history is read and kept, and the architecture.
- [Building and running it](docs/development.md) — build, test, the launch options, the scripts, and how a release is made.
