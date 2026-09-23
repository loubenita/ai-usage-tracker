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
- **Your usual pace.** The same measure over all your main Claude Code transcripts from the last 7 days. It is read in the background with the rest of the week's history, and refreshed every minute. The comparison is left out until there is at least an hour of work to compare with. Each agent has its own usual pace, so a Codex session is compared with your Codex sessions.
- **When the context will be full.** How fast the context has grown since it was last compacted, carried forward from now.

Transcripts are read as they grow: each refresh reads only the lines added since the last one.

## Reading Codex usage

Codex writes each session to a rollout file, `~/.codex/sessions/<year>/<month>/<day>/rollout-….jsonl`. A running `codex` process is matched to the rollout in its folder that was written to since it started.

- **Tokens.** Each `token_count` event is one model request. OpenAI counts cached input inside the input count, so the app takes it out and shows it as a cache read. Reasoning is already inside the output count, so it is not added again.
- **Context.** The request's tokens out of the model's window, both from the same event.
- **Limits.** Each event also carries Codex's plan limits. A 300-minute window is the 5-hour limit and a 10,080-minute window the weekly one. On 21 September this Mac's plan had only the weekly one, at 94%.
- **Waiting for your reply.** Codex writes `task_started` and `task_complete`. After `task_complete`, the session is waiting.

## Reading Cursor Agent usage

Cursor keeps each chat in a small SQLite database, `~/.cursor/chats/<MD5 of the folder>/<chat id>/store.db`. It records no token count per reply, only the chat's current context, so a Cursor session shows its context, model and number of prompts, and nothing in Today or This week. A chat on Cursor's Auto model saves its model as "default"; the app shows it as "Auto", as Cursor does.

The app opens the database read-only while Cursor is writing to it. SQLite lets a reader and a writer share a database, and the reader never changes it.

## Reading Kiro usage

Kiro CLI keeps each session in `~/.kiro/sessions/cli/<session id>.json`, with its model, context window and, for each request, the tokens and how full the context was. The field names come from [tokscale](https://github.com/junhoyeo/tokscale)'s Kiro reader, because Kiro was not installed on the Mac this was written on. Kiro's Auto agent reports zero tokens, which the app shows as unknown rather than zero. When a session leaves out its context window, the app uses 200k, the window of Kiro's Auto agent, as tokscale does.

Kiro's installer puts two programs on your Mac: `kiro-cli`, which you type, and `kiro-cli-chat`, which runs the chat, inside `/Applications/Kiro CLI.app`. The app recognises both and counts the pair as one session. Older versions of Kiro CLI kept conversations in a database, `~/Library/Application Support/kiro-cli/data.sqlite3`, which the app does not read.

Each request in a session file also says what it cost in credits, under `metering_usage`. The app adds these up per session, per day and for the month.

**The plan** is not on your Mac: Kiro keeps it on its servers. So every 5 minutes, when `kiro-cli` is installed, the app runs this, the way Kiro's own tool reports usage:

```sh
kiro-cli chat --no-interactive "/usage"
```

From what it prints, the app reads the plan's name, the credits used out of the allowance, the percentage, and the reset date. For example, `Credits (2,100.50 of 5,000 covered in plan)` gives 2,900 credits left. The patterns follow [CodexBar](https://github.com/steipete/CodexBar)'s Kiro reader, which knows two layouts of this output. The app only asks and changes nothing in Kiro. It runs the command in a folder of its own, so the chat Kiro opens to answer is never counted as your work, and it stops the command after 20 seconds. If Kiro is not signed in, or the output has no numbers, the last plan read stays on screen.

## Today, This week and Month

Today, This week and Month count every session since the 1st of the month, or of the last week when that reaches further back, not only the ones open now: Claude Code transcripts and their sub-agents' transcripts, Codex rollouts and Kiro sessions. A month of transcripts can be several gigabytes: on 22 September, on the Mac this was built on, 4.9 GB in 910 files. So what was read is saved between launches, in `~/Library/Application Support/AIUsageTracker/history-cache.json` (23 MB that day). For each transcript and rollout it keeps the path, how far it was read, the file's number on the disk, and each reply once, by its message id. On the next launch the app picks up from there and reads only what each file gained. A file that got shorter, or was replaced by a new file under the same path, is read again from the start.

| | First read of the history |
|---|---|
| First launch, with no cache | 66 s in the Debug build (38 s in Release) |
| Every launch after, from the cache | 1.6 s |

Only on the very first launch, before any cache exists, do the panels say the history is still being read, so the totals are too low for now; the totals are rebuilt every 10 seconds until it is done. After that the history is read again every minute, taking only what the files gained, and saved again when anything grew, while the totals are rebuilt from it every 10 minutes.

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

- **Each agent's ring has its own colour,** so you can tell a Codex session from a Claude one at a glance. The colours are all cool ones, so none of them can be mistaken for the amber "waiting for you" dot or the red "context nearly full" ring, which still take over when they apply.
- **Antigravity** runs as a desktop app, not in a terminal. Starting a conversation in it means typing into its window. It saves its conversations in `~/.gemini/antigravity/conversations/` as encrypted files: they look completely random, with no readable text, so the app cannot read their usage.

- **The limits list shows every window every agent shares,** as a share used rather than left: "Claude 5-hour 62%, frees up 16:40", "Codex week 95%, frees up Thu". A window at 85% or more turns amber, so the one about to run out stands out. Kiro's monthly plan, in credits, is a row like any other.
- **An agent's own view leads with its limits and its pace:** "Week limit 48%, frees up Thu 09:00 · in 2d 18h", and under it "On pace to end the week at about 90%." The pace comes from how fast the readings have been rising.
- **The charts** count the chosen agent's tokens: a bar a day on Week, a bar a week on Month. For an agent that reports no tokens, such as Cursor, they count hours instead.
- **Anything without data is left out, not shown as 0.** A number, row or whole section the agent did not report is hidden: a Codex session shows no Spent, a session that started no sub-agents has no sub-agents section, and an agent with no limits says "no data" once instead of drawing empty bars. In the table, where a column must stay for the other agents, the cell says "n/a".

- **Cost** is only shown where the price is known. The app has the Claude API list prices. It has no prices for Codex models, and Cursor and Kiro bill by plan and credits, so their cost is left out rather than guessed.
- **The strip's limit** is the limit of the agent with the most sessions open. A session's panel lists its own agent's limits only: a Codex panel never shows Claude's 5-hour limit.
- **Monthly limits.** Only Kiro's plan is monthly. Claude and Codex report none, so they have no monthly bar on real data.
- **Budgets.** There is no setting for a daily budget yet, so on real data Today shows no budget and the week chart has no budget line. The made-up data has $9 and 2.6M-token budgets, to show how they would look.
- **Where the time went** lists the biggest pieces of work by working time — the gaps between replies, up to five minutes each — and adds up the rest in one row, such as "4 more". Time is used rather than cost, so agents whose price is unknown count for as much as the others.
- **Sub-agents** are the agents a session started itself. Claude Code keeps each one's transcript in `<session id>/subagents/` beside the session's own. Their tokens and cost count in the session's Spent and Tokens, and the section says what share they are. They are left out of the session's pace, which measures what the session itself is doing.

## Architecture

The code follows Clean Architecture, in three layers inside the Swift package `Packages/UsageKit`. Each layer depends only on the one inside it.

- **UsageDomain:** the data types and the rules, such as how pace, labels and titles are worked out. It has no macOS or file access.
- **UsageData:** where the data comes from. `ProcessSessionRepository` reads real sessions, with one reader per agent's files (`ClaudeTranscript`, `CodexRollout`, `CursorChat`, `KiroSession`) and `UsageHistory` for the week. `FakeUsageRepository` supplies the made-up data.
- **UsagePresentation:** turns the rules' results into the text on screen, and holds the SwiftUI views.

The tests use Swift Testing. Session detection is tested against a recorded process list in `Packages/UsageKit/Tests/UsageDataTests/Fixtures`, never against live processes.
