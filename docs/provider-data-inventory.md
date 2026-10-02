# Provider data inventory

This is the source-backed list of what AI Usage Tracker can read, calculate, or cannot obtain today. It covers Claude Code, Codex, Cursor Agent, Kiro CLI, Antigravity and OpenCode. No local account identifiers or session content were read for this document.

## Status key

| Status | Meaning |
|---|---|
| **Implemented and observed** | Reader exists and repository fixtures or project evidence support the source shape. This is not a live-account inspection. |
| **Implemented, unverified** | Reader and parser tests exist, but source code says the format was inferred from another tool because a real source was unavailable. |
| **Derivable** | Calculated from reported fields. |
| **Unavailable** | No reader exists. Do not display it as zero. |

`UsageData` reads files and processes. `UsageDomain` builds sessions, totals and forecasts. `UsagePresentation` selects facts for the rail, session panel and Usage.

## Provider summary

| Provider | Session data | Period history | Limits and accounts | Status |
|---|---|---|---|---|
| Claude Code | Tokens, context, USD estimate, activity, state, sub-agents | Main and sub-agent transcripts | Per-profile 5-hour/week via status-line log | Implemented and observed |
| Codex | Tokens, context, model, effort, activity, state | Main and sub-agent rollouts | 5-hour/week when rollout supplies them; no account ID | Implemented and observed |
| Cursor Agent | Current context, model, prompt count | None | None | Database reader implemented and observed |
| Kiro CLI | Credits, per-request model, tool calls, context; tokens unknown (written as 0) | Session JSON files | Monthly plan from `kiro-cli /usage`; no account ID | Session files observed; plan output unverified |
| Antigravity | None | None | None | Unavailable |
| OpenCode | Terminal, folder, project and branch only | None | None | Process detection only |

## Facts shared by terminal sessions

`UsageData/Processes/TerminalAgentFinder.swift` finds `claude`, `codex`, `cursor-agent`, `opencode`, `kiro`, `kiro-cli` and `kiro-cli-chat`, including Node, Bun and Deno launchers. It keeps terminal processes and drops a child agent when an ancestor is already an agent. `ProcessSessionRepository.swift` builds the live session.

| Field | Status | Source and caveat |
|---|---|---|
| Provider, process ID, start time and session lifetime | Implemented and observed | From `ps`. Active and idle duration starts at process start, so it differs from transcript working time. |
| TTY and terminal app | Implemented and observed | `SessionOrigin` identifies Terminal, iTerm, Warp, Ghostty, tmux or unknown. |
| Folder | Implemented and observed | From the process. Claude can fall back to its session file. |
| Project and branch | Derivable | `GitLocator` reads `.git` and `HEAD`, including worktrees. Detached HEAD/non-Git folders have no branch. |
| tmux session, window and pane | Implemented for Claude only | The process identifies tmux for all providers. Only Claude supplies a pane target. |
| Provider session ID and source path | Implemented where a reader exists | Claude, Codex and Kiro have IDs; Cursor has a database path. Never treat them as account IDs. |
| Current state | Provider-reported or derivable | Claude uses session/transcript state; Codex task events; Cursor/Kiro use a 30-second file-quiet rule. OpenCode has no provider activity. |

Antigravity has an `Agent` enum case but no executable mapping or reader. `docs/how-it-works.md` says its desktop conversation files are encrypted.

## Claude Code

Sources: `UsageData/Claude/ClaudeTranscript.swift`, `ClaudeAccounts.swift`, `ClaudeLimitsLog.swift`, `ClaudeAccountCache.swift`, `ClaudePrices.swift`, and `UsageHistory.swift`.

| Field group | Available facts | Status | Caveat |
|---|---|---|---|
| Identity/location | Session ID, person-chosen name, folder/project/branch, TTY/terminal, friendly profile name | Implemented and observed | Generated names are discarded. Profile directory is private internal identity. |
| Model/time | Model, reply time, process time, active/idle time and working time | Implemented and observed | Working time sums reply gaps up to five minutes. |
| Tokens | Input, output, cache read/write, per reply and total | Implemented and observed | Repeated transcript parts are deduplicated by message ID. Missing is not zero. |
| Context/cost | Latest used/window and USD estimate per reply/total | Implemented and observed | Context comes from latest usage plus its reported/known window. Only cost depends on the known-model price table; it is list price, not an invoice. |
| Task/activity | First ask, tool calls, changed files and task label | Implemented and observed | First ask is capped at 200 characters. Task label is local naming, not provider data. |
| State | Working, waiting/idle and state-since | Implemented and observed | A finished turn does not prove who must act next. |
| Sub-agents | Run ID, model, tokens, priced cost, working time and parent roll-up | Implemented and observed | Already included in parent totals; excluded from usual pace. |
| Pace/context forecast | Tokens/hour without cache reads, seven-day comparison and context-full estimate | Derivable | Estimate, not a provider deadline. |
| Limits | 5-hour/week percentage, reset and plan | Implemented when configured | Status-line script must write `claude-limits.jsonl`. Never infer a reset. |

### Multiple Claude accounts

`ClaudeAccounts.swift` finds `.claude` and `.claude-*` profiles. Sessions carry a friendly profile name plus local directory ID. `ClaudeLimitsLog.swift` attaches limits to that profile. `GenerateUsageReport.swift` keeps each account separate in Usage and uses the matching account's five-hour reading for a live session.

`ClaudeAccountCache.swift` accepts `account-*.json` snapshots for up to seven days. It supplies 5-hour/week percentages, profile ID and read time, plus `five_hour_resets_at` and `weekly_resets_at` (epoch seconds) when the status line that wrote it saved them. `UsagePanelPresenter` shows a snapshot at any age, with its read time. A snapshot without a reset time shows "Reset time unknown": never make one up. When a reset time has passed, the window shows as reset instead of its old percentage.

## Codex

Sources: `UsageData/Codex/CodexRollout.swift`, `CodexFiles.swift` and `UsageHistory.swift`.

| Field group | Available facts | Status | Caveat |
|---|---|---|---|
| Identity/location | Rollout ID, folder/project/branch, TTY/terminal | Implemented and observed | Matching uses folder, start time and writes. Resumed sessions can be ambiguous. |
| Model/effort | Current model and latest effort | Implemented and observed | Effort such as `medium` is a setting. |
| Tokens/context | Input excluding cached input, output, cache read/write; request total/window | Implemented and observed | Reasoning is already in output. Context needs `model_context_window`. |
| Task/activity | Task start/complete/abort, first ask, tool calls and changed files | Implemented and observed | Completion does not identify who acts next. |
| Limits | Main plan type plus 300-minute 5-hour and 10,080-minute weekly windows/resets | Implemented when present | Model-specific and unknown-length windows are ignored. No daily/monthly limit is inferred. |
| Cost/credits | None | Unavailable | No price table or estimate. |
| Sub-agents | Included in historical totals | Implemented and observed | Excluded from usual pace. No live parent roll-up exists. |
| Account | None | Unavailable | `plan_type` is not an account ID. |

## Cursor Agent

Source: `UsageData/Cursor/CursorChat.swift`, which opens `~/.cursor/chats/<folder hash>/<chat>/store.db` read-only.

| Field group | Available facts | Status | Caveat |
|---|---|---|---|
| Model/context/prompts | Current model (`default` displays as Auto), context used/window and prompt count | Implemented and observed | Current-chat values only; no per-turn history. |
| State | Working/waiting/idle from database freshness | Derivable | Uses the 30-second quiet threshold. |
| Tokens, cost, credits, task, tools, files and sub-agents | None | Unavailable | No source reader. |
| Today/Week/Month | None | Unavailable | `UsageHistory` scans only Claude, Codex and Kiro. An open Cursor session with no reported usage is not a period total. |
| Limits/accounts | None | Unavailable | No source reader. |

## Kiro CLI

Sources: `UsageData/Kiro/KiroSession.swift`, `KiroPlanReader.swift` and `KiroUsageReport.swift`.

| Field group | Available facts | Status | Caveat |
|---|---|---|---|
| Identity/location | Session ID, folder/project, TTY/terminal | Implemented and observed | Field names checked against a real install's session file. A running `kiro-cli` is matched to its file by folder and by file changes since the process started, with five seconds of margin. The folders are compared after settling a trailing slash, `.`/`..` and symlinks. Branch is derived from folder. |
| Model/context | Per-request model, session model, window, and each request's context percentage as tokens | Implemented and observed | Each request names its own model (`auto`, `claude-opus-4.8`); the session's model is the fallback, then `auto`. The window is `model_info.context_window_tokens` (1,000,000 on current builds); 200,000 applies only when the file leaves it out. Context is current occupancy: shown as `ctx ~126k`, an estimate, and never added into a token total. |
| Tokens | Input/output/cache read/cache write | Unavailable on current builds | Current builds write every count as 0. Zero counts become unknown, so period tokens are unavailable, not 0. If Kiro filled them in, real tokens would work with no estimate. |
| Credits | Per-request credits from `metering_usage` entries of unit `credit`; per-session, per-model, daily and month totals | Implemented and observed | Credits are Kiro's real signal. Credits are not USD. The Usage model rows share by credits when no model has tokens. |
| Tool calls and duration | `builtin_tool_uses` and `turn_duration` per request | Implemented and observed | Tool calls are totalled per period. Duration is kept on each turn and not shown yet. Reply and prompt lengths in characters are read and not used. |
| State | File freshness | Derivable | Same 30-second rule as Cursor. |
| Plan | Name, credits used/allowance when printed, percentage, reset and credits left/day | Implemented, unverified | App runs `kiro-cli chat --no-interactive /usage` at most every five minutes outside the project, times out at 20 seconds and keeps last success. Reset exists only if printed. That process has no terminal and runs in the folder `AIUsageTracker-kiro`; it is never listed as a session. |
| USD, task, changed files, sub-agents and account | None | Unavailable | No source reader. |
| Older Kiro SQLite database | None | Unavailable | `~/Library/Application Support/kiro-cli/data.sqlite3` is explicitly not read. |

The session fields were checked against a session file from a real Kiro install (1 October 2026). Kiro is not installed on the Mac this app is built on, so the tests use hand-written JSON with the same field names and shapes. The plan output is still read with patterns taken from CodexBar and has not been checked against a live `/usage` run.

## Antigravity and OpenCode

| Provider | Available | Unavailable |
|---|---|---|
| Antigravity | Enum case and presentation colour | Detection, session/model/token/context/cost/credit/limit/history/project/account data. |
| OpenCode | Process start, TTY, terminal, folder, project, branch and process-only state | Provider session ID, transcript, model, tokens, context, cost, credits, limits, history, task/activity, sub-agents and account. `ProcessSessionRepository` returns no provider data. |

## Period totals, limits and freshness

`UsageHistory.swift` scans from the earlier of month start and eight days ago. It reads Claude main/sub-agent transcripts, Codex rollouts including sub-agents and Kiro session JSON. The initial scan is incomplete until `isHistoryComplete` becomes true.

| Fact | Providers | Status | Caveat |
|---|---|---|---|
| Session, turn and token totals | Claude/Codex; Kiro sessions, turns and tool calls | Implemented | Nil remains unavailable: Kiro tokens stay nil while it writes zero counts. Kiro's context is kept apart as `AgentPeriodUsage.context`, the latest reading in the period, and is never added into tokens. Cursor only has a live prompt count. |
| USD and credits | Claude USD; Kiro credits | Implemented; Kiro credits observed | USD is an estimate. Do not combine USD and credits. |
| Working time | Claude/Codex/Kiro | Derivable | Per-session gaps capped at five minutes; parallel sessions both count. |
| Model/work splits, pace and usual pace | Claude/Codex/Kiro with sufficient history | Derivable | Model shares use tokens when any model has them, else credits (Kiro), else working time. Pace excludes cache reads. Usual pace uses seven days of main sessions. |
| Context-full and limit forecasts | Sessions/windows with enough data | Derivable | Forecasts are estimates. Calculate reset-based time only after provider supplied a reset. |
| Claude limits | Status-line changed log | Implemented when configured | Per account; cache snapshots are valid up to seven days but contain no reset. |
| Codex limits | Token-count rollout events | Implemented when present | Ignore expired/unsupported windows. |
| Kiro plan | Last successful CLI query | Implemented, unverified | Show read time when stale; failure must not become zero. |

Multiple-account attribution is currently **Claude-only**. Codex gives a plan type but no account ID. Kiro plan output has no account ID. The other readers have neither accounts nor plan data.

## Minimal display recommendation

### Expanded rail

The compact rail shows the top four sessions by USD cost when known, then context fraction and recent activity, followed by `+N` for every hidden live session. This is display policy, not provider data. The expanded rail allows every live session, so it has no top-four cap. Each expanded row needs only provider mark and task, project plus branch when known, state plus active time, and context used/fraction when known. Keep model, cumulative tokens, first ask, tool/file counts, account and breakdowns out. Use equal horizontal and vertical row inset so the selected first row reaches the top edge cleanly.

### Detail panel

Lead with task, provider/state, project/branch and context. Then show Claude USD plus token mix, Codex token mix plus effort, Kiro credits (it has no token mix), Cursor model/context/prompts, or OpenCode terminal/location only. Put first ask, tools, changed files, pace and context forecast in the details control. Show one Claude sub-agent summary and state that it is included in totals. Show the friendly Claude profile name, but keep shared limits out of a single session.

### Usage

Usage owns per-account Claude limits, Codex windows, Kiro plan/credits, reset/freshness labels, Today/Week/Month, model/work splits and charts. Keep USD, tokens and credits in separate columns. An agent with no tokens but a context reading (Kiro) shows `ctx ~126k` in the tokens cell as a faint estimate, outside the "All agents" total. Say “no history reported” for Cursor/OpenCode. Exclude Antigravity until it has a reader.

## Stale documentation claims

| Existing claim | Code evidence | Correction |
|---|---|---|
| README says Codex has only a weekly limit. | `CodexRollout.limitReading` maps 300 minutes to 5-hour and 10,080 to weekly. | Say 5-hour and weekly when present. |
| README says Cursor is counted in Today/Week/Month. | `UsageHistory` has no Cursor scan. | Say live context/prompt count only; no historical totals. |
| `docs/how-it-works.md` says history refreshes every 10 minutes. | `UsageHistory.refreshInterval` is 60 seconds. | Update to one minute. |
| README says Kiro's reader has not been tried on a real Kiro session. | Its session fields were checked against a real install's file; every token count there is 0. | Say the session fields are checked and Kiro's tokens are unknown. Only the plan output is still unverified. |
| README calls Antigravity green “for when it is supported.” | No executable mapping or data reader exists. | Call it unavailable today. |

## Key sources

* `Packages/UsageKit/Sources/UsageData/ProcessSessionRepository.swift` connects discovery, readers and history.
* `Packages/UsageKit/Sources/UsageData/Claude/`, `Codex/`, `Cursor/` and `Kiro/` contain provider readers.
* `Packages/UsageKit/Sources/UsageData/UsageHistory.swift` defines historical coverage.
* `Packages/UsageKit/Sources/UsageDomain/Entities/Records.swift` and `UseCases/GenerateUsageReport.swift` define records, accounts and totals.
* `Packages/UsageKit/Sources/UsagePresentation/ViewModels/OverlayPresenter.swift` and `UsagePanelPresenter.swift` map facts to UI.
* `Packages/UsageKit/Tests/UsageDataTests/` has recorded-source parser tests; it does not inspect live accounts.
