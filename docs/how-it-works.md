# How it works

The short version is in the [README](../README.md); this is the detail behind it.

## Finding sessions

Once a second, the app reads the list of running processes (from the `ps` command). It keeps a process when all three of these are true:

1. **It is an agent.** Its program is `claude`, `codex`, `cursor-agent`, `opencode`, `kiro`, `kiro-cli` or `kiro-cli-chat`, run directly or through `node`, `bun` or `deno`. A program inside an app whose name has a space, such as `/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat`, counts too, even though `ps` shows the space unquoted. A wrapper script that only mentions `claude` in its arguments does not count.
2. **It has a terminal.** A process with no terminal is a background job.
3. **No other agent started it.** If one did, it is a sub-agent, and it is left out.

For each session the app also finds its folder, its git project and branch (read from the `.git` folder, without running git), and which terminal app it runs in: Warp, Terminal, iTerm, Ghostty or tmux.

The app only reads. It never writes to, signals or stops another process. The one program it runs is `kiro-cli`, to ask for Kiro's plan, as described in [Reading Kiro usage](#reading-kiro-usage).

## Reading Claude Code usage

Each running Claude Code session has a small file in `~/.claude/sessions/` that gives its session id. That id leads to the session's transcript in `~/.claude/projects/`. From the transcript the app works out:

- **Tokens.** Claude Code writes one line for each part of a reply, and every line repeats the whole reply's usage. So each reply is counted once. In the test transcript, counting every line would have doubled the output tokens, from 2,718 to 5,511.
- **Context.** Everything the latest reply read, out of the model's context window.
- **Cost.** From the Claude API list prices. A model not in the price table has its cost left out rather than guessed.
- **Pace.** Tokens per working hour, leaving out cache reads. A cache read is the whole conversation read again for each reply, so it grows with the length of the conversation, not with the work done. In one long session, cache reads were 39.3M of 39.8M tokens. Working time adds up the gaps between replies and leaves out any gap longer than 5 minutes, since that is time spent reading or away.
- **Your usual pace.** The same measure over all your main Claude Code transcripts from the last 7 days. It is read in the background with the rest of the week's history, and refreshed with the totals every minute. The comparison is left out until there is at least an hour of work to compare with. Each agent has its own usual pace, so a Codex session is compared with your Codex sessions.
- **When the context will be full.** How fast the context has grown since it was last compacted, carried forward from now.

Transcripts are read as they grow: each refresh reads only the lines added since the last one.

## Reading Codex usage

Codex writes each session to a rollout file, `~/.codex/sessions/<year>/<month>/<day>/rollout-….jsonl`. A running `codex` process is matched to the rollout in its folder that was written to since it started.

- **Tokens.** Each `token_count` event is one model request. OpenAI counts cached input inside the input count, so the app takes it out and shows it as a cache read. Reasoning is already inside the output count, so it is not added again.
- **Context.** The request's tokens out of the model's window, both from the same event.
- **Limits.** Each event also carries Codex's plan limits. A 300-minute window is the 5-hour limit and a 10,080-minute window the weekly one. On 21 September this Mac's plan had only the weekly one, at 94%.
- **Ready for input.** Codex writes `task_started` and `task_complete`. After `task_complete`, the app knows the last turn ended, but cannot tell who should respond next.

## Reading Cursor Agent usage

Cursor keeps each chat in a small SQLite database, `~/.cursor/chats/<MD5 of the folder>/<chat id>/store.db`. It records no token count per reply, only the chat's current context, so a Cursor session shows its context, model and number of prompts, and nothing in Today or This week. A chat on Cursor's Auto model saves its model as "default"; the app shows it as "Auto", as Cursor does.

The app opens the database read-only while Cursor is writing to it. SQLite lets a reader and a writer share a database, and the reader never changes it.

## Reading Kiro usage

Kiro CLI keeps each session in a file, `~/.kiro/sessions/cli/<session id>.json`. A file with the same name ending in `.jsonl` holds the conversation itself, which the app does not read. The `.json` file holds the session's model, its context window, and one entry for each request you made. The field names were first taken from [tokscale](https://github.com/junhoyeo/tokscale)'s Kiro reader, and then checked against a session file written by a real Kiro install on 1 October 2026. Kiro is not installed on the Mac this app is built on, so the tests use hand-written files with the same field names.

This is what the app reads from each request, and what it does with it:

- **Credits.** Kiro bills in credits, not dollars. The request's `metering_usage` list says what it cost. A request can have several entries, and the app adds up those whose unit is `credit`. Credits are the real measure of Kiro use. The app adds them up per request, per session, per day, per model and for the month.
- **Model.** Each request names the model that answered it, in its own `model` field: `auto`, say, or `claude-opus-4.8`. One session can mix them. So the app uses the request's own model. Only when a request names none does it use the session's model, and failing that `auto`. This is what lets the credits be split by model. For example, a request answered by `auto` that cost 0.1 credits, and another answered by `claude-opus-4.8` that cost 0.75, give two models with 0.1 and 0.75 credits.
- **Tool calls and time taken.** `builtin_tool_uses` is how many tools the request called, and the app adds them up for the "Tool calls" figure. `turn_duration` is how long the request took, written as seconds and nanoseconds: `{"secs": 553, "nanos": 519031792}` is about 553.5 seconds. The app keeps it on each request but does not show it yet. The Time shown is worked out from the gaps between replies, as for every agent.
- **Tokens.** Each request has token counts, but current Kiro builds write every one of them as 0. A 0 here does not mean no tokens were used, so the app treats Kiro's tokens as unknown, not as zero, and shows no token count for Kiro.
- **Context.** `context_usage_percentage` says how full the context was after the request, as a percentage of the context window. The window comes from `model_info.context_window_tokens` in the same file, which is 1,000,000 on current builds. Only when a file leaves it out does the app use 200,000, the window of older builds. For example, 12.561899% of 1,000,000 is 125,619 after rounding. The table shows that as `ctx ~126k`, in faint type, where the tokens would be. It is an estimate of how full the context is now, not of tokens used. The context can shrink when a conversation is compacted, and adding it up over many requests would count the same text again and again. So it is never added into a total, and the "All agents" row leaves it out.

**Which file belongs to a running Kiro.** The app matches a running `kiro-cli` to its session file by folder and by time. It takes the file in the process's folder that changed most recently since the process started. `ps` gives the start only to the whole second, so a file that changed up to 5 seconds before it also counts. Going further back would let the previous session in the same folder be taken for this one. The two folders are tidied before they are compared, so a trailing slash, a `.` or `..` in the path, or a symlink to the folder does not stop a match. For example, a Kiro running in `/Users/me/app` matches a file that says `/Users/me/app/`, and a file that says `/Users/me/work` when that is a link to `/Users/me/app`. When no file matches, the session has no context reading, and its ring shows its short code, such as `HOME`, instead of a number.

Kiro's installer puts two programs on your Mac: `kiro-cli`, which you type, and `kiro-cli-chat`, which runs the chat, inside `/Applications/Kiro CLI.app`. The app recognises both and counts the pair as one session. Older versions of Kiro CLI kept conversations in a database, `~/Library/Application Support/kiro-cli/data.sqlite3`, which the app does not read.

**The plan** is not on your Mac: Kiro keeps it on its servers. So every 5 minutes, when `kiro-cli` is installed, the app runs this, the way Kiro's own tool reports usage:

```sh
kiro-cli chat --no-interactive "/usage"
```

From what it prints, the app reads the plan's name, the credits used out of the allowance, the percentage, and the reset date. For example, `Credits (2,100.50 of 5,000 covered in plan)` gives 2,900 credits left. The patterns follow [CodexBar](https://github.com/steipete/CodexBar)'s Kiro reader, which knows two layouts of this output. The app only asks and changes nothing in Kiro. It runs the command in a folder of its own, so the chat Kiro opens to answer is never counted as your work, and it stops the command after 20 seconds. If Kiro is not signed in, or the output has no numbers, the last plan read stays on screen.

While it runs, that command shows in the process list as a `kiro-cli` with no terminal, which would look like a background session. The app leaves it out: a Kiro process whose folder is named `AIUsageTracker-kiro`, the app's own folder, is never listed as a session. A `kiro-cli` you start from a script, in any other folder, is.

## Today, This week and Month

Today, This week and Month count every session since the 1st of the month, or of the last week when that reaches further back, not only the ones open now: Claude Code transcripts and their sub-agents' transcripts, Codex rollouts and Kiro sessions. A month of transcripts can be several gigabytes: on 22 September, on the Mac this was built on, 4.9 GB in 910 files. So what was read is saved between launches, in `~/Library/Application Support/AIUsageTracker/history-cache.json` (23 MB that day). For each transcript and rollout it keeps the path, how far it was read, the file's number on the disk, and each reply once, by its message id. On the next launch the app picks up from there and reads only what each file gained. A file that got shorter, or was replaced by a new file under the same path, is read again from the start.

| | First read of the history |
|---|---|
| First launch, with no cache | 66 s in the Debug build (38 s in Release) |
| Every launch after, from the cache | 1.6 s |

Only on the very first launch, before any cache exists, do the panels say the history is still being read, so the totals are too low for now; the totals are rebuilt every 10 seconds until it is done. After that the history is read and saved with the totals every minute. The six-second live-session refresh reuses the latest history snapshot, so it never rewrites the large cache.

The totals are built off the main thread, so the overlay stays responsive while they are. Before this, the app rebuilt the whole month on the main thread every second. On the Mac this was built on, on 22 September, with seven sessions open, that took the app's CPU from 67% on average to 6%. The share of the main thread's time spent rebuilding went from 63% to under 1%.

The totals were checked against a separate Python count of the same files, taken just before and just after a screenshot: the app's 63.9M tokens today fell between Python's 56.8M and 65.2M, and its week of Codex tokens matched to the token.

Finished sessions are grouped by the folder and branch the agent recorded, the same way open ones are.

Your usual pace is worked out from the same history, separately for each agent, and from main sessions only: a sub-agent's pace is not yours.

## Claude's limits

Claude Code keeps its plan limits out of its transcripts. It does hand them to the status line, a script Claude Code runs to draw the line under its prompt. `scripts/claude-statusline.sh` is such a script. It saves the limits to `~/Library/Application Support/AIUsageTracker/claude-limits.jsonl` whenever they change, and shows `5h 62% · 7d 48%` under the prompt.

To turn it on, add this to `~/.claude/settings.json`, with the path to your copy of the repository:

```json
"statusLine": { "type": "command", "command": "/path/to/ai-usage-tracker/scripts/claude-statusline.sh" }
```

If you already have a status line, keep it by setting `AIUT_STATUSLINE_NEXT` to its command; the script then shows that instead of its own. Claude Code only passes limits on a Claude subscription, and only after the session's first reply.

## Notes on what is shown

The table of what each agent gives is in the [README](../README.md#what-each-agent-gives).

- **Each agent has a distinct mark and colour,** so provider identity remains visible even when a nearly full ring turns red. The provider name remains in the accessibility label.
- **The ring's number is current context used,** from the same reading as its fill. The expanded rail shows the task, project, branch and active time beside the provider mark. Model and first ask live in the selected session panel. The larger cumulative token count appears only as `Total tokens` there.
- **Antigravity** runs as a desktop app, not in a terminal. Starting a conversation in it means typing into its window. It saves its conversations in `~/.gemini/antigravity/conversations/` as encrypted files: they look completely random, with no readable text, so the app cannot read their usage.

- **The limits list shows available windows by provider and Claude account,** as a share used rather than left. A row shows its window and percentage over a full-width bar; its reset sits below. A reset appears only when the provider supplied it. A limit with no live reading still shows its last one, however old, with the time it was read: "Second · Week limit 100% · Resets Wed 17:00 · in 2d 2h · read 10:32". An account at its limit has no sessions to refresh the reading, so hiding old readings would hide exactly the account that is full. A cached Claude reading saved without a reset time says "Reset time unknown". A window whose reset time has passed, with nothing read since, shows as "Week limit reset" with an empty bar instead of its old percentage. A reset window never counts toward the headline, a pace note or an amber warning. Today omits weekly limits. A window at 85% or more turns amber. Kiro's monthly plan is measured in credits, never mixed with USD.
- **An agent's own view leads with its limits and its pace:** for example, "Week limit 48%" followed by "Resets Thu 09:00 · in 2d 18h" and "On pace to end the week at about 90%." The pace comes from how fast the readings have been rising.
- **The charts** count the chosen agent's tokens: a bar a day on Week, a bar a week on Month. When history has no token counts but has working time, the chart counts hours. Cursor has no period history reader, so its live prompt count does not make a historical chart.
- **Anything without data is left out, not shown as 0.** A number, row or whole section the agent did not report is hidden: a Codex session shows no Spent, a session that started no sub-agents has no sub-agents section, and an agent with no limits has no empty limit bar. In the table, where a column must stay for the other agents, the cell says "n/a". The one exception is an agent that reports no tokens but does report how full its context is, which is Kiro: its cell says `ctx ~126k`, in faint type, as an estimate of the context in use, and it is not counted in the "All agents" row.
- **The models list shares tokens, else credits, else time.** Each model's share is of the tokens when any model reported tokens. When none did but some reported credits, as Kiro does, the share is of the credits, and the model's credits are shown beside its percentage. For example, if Opus billed 60 of Kiro's 72.5 credits, its row reads `Opus 4.8  60 cr  83%`. When no model reported either, the share is of its working time. An agent that bills in credits also has its Credits figure first among its figures.

- **Cost** is only shown where the price is known. The app has the Claude API list prices. It has no prices for Codex models, and Cursor and Kiro bill by plan and credits, so their cost is left out rather than guessed.
- **Account limits live in Usage.** A selected session's panel contains only facts attributable to that session; shared five-hour, weekly and plan limits stay in the Usage panel.
- **Monthly limits.** Only Kiro's plan is monthly. Claude and Codex report none, so they have no monthly bar on real data.
- **Budgets.** There is no setting for a daily budget yet, so on real data Today shows no budget and the week chart has no budget line. The made-up data has $9 and 2.6M-token budgets, to show how they would look.
- **Where the time went** lists the biggest pieces of work by working time — the gaps between replies, up to five minutes each — and adds up the rest in one row, such as "4 more". Time is used rather than cost, so agents whose price is unknown count for as much as the others.
- **Sub-agents** are the agents a session started itself. Claude Code keeps each one's transcript in `<session id>/subagents/` beside the session's own. Their tokens and cost count in the session's `Total spent` and `Total tokens`. Under **Show details**, one summary shows their run count, combined tokens, cost, working time and share of session spend. Sub-agents remain left out of the session's pace, which measures what the main session itself is doing.

## Architecture

The code follows Clean Architecture, in three layers inside the Swift package `Packages/UsageKit`. Each layer depends only on the one inside it.

- **UsageDomain:** the data types and the rules, such as how pace, labels and titles are worked out. It has no macOS or file access.
- **UsageData:** where the data comes from. `ProcessSessionRepository` reads real sessions, with one reader per agent's files (`ClaudeTranscript`, `CodexRollout`, `CursorChat`, `KiroSession`) and `UsageHistory` for the week. `FakeUsageRepository` supplies the made-up data.
- **UsagePresentation:** turns the rules' results into the text on screen, and holds the SwiftUI views.

The tests use Swift Testing. Session detection is tested against a recorded process list in `Packages/UsageKit/Tests/UsageDataTests/Fixtures`, never against live processes.
