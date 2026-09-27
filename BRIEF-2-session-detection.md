# Brief 2: detect real terminal sessions and list them

## What to build
The overlay's strip must show the AI coding sessions that are actually running in terminals on this Mac, instead of the three fake ones.

A "session" means one agent that a person started in a terminal. The agents are Claude Code (`claude`), Codex (`codex`), Cursor's agent (`cursor-agent`), opencode (`opencode`) and Kiro (`kiro`). For example, if three Terminal or Warp tabs each run `claude`, the strip shows three sessions.

Sub-agents are **not** sessions. A sub-agent is an agent that another agent starts, such as a Claude session running `claude -p` or `codex exec` as a child process. Skip any agent process whose parent chain includes another agent process. Also skip anything with no terminal attached (no TTY), because that is a background job rather than a terminal session.

## Where things are now
- The project is in `~/Development/ai-usage-tracker`. It's a SwiftUI macOS app with an Xcode project generated from `project.yml`, the app code in `App/` and modules in `Packages/`. None of it is committed yet. Read it first, get it building, and make the first commit before changing anything.
- It was built against an older design. The current design is the Paper file "AI Usage Tracker" (id `01M32D1WEA9QK3QQ1A3M3H2RSG`), page **Overlay**, frames 1 to 7. Exports are in `~/.claude/proof/ai-usage-tracker/2026-09-21-v7/`, named 1.png to 7.png. Frame 1 is the resting half-strip and frame 2 is the full strip on hover. Update the strip to frames 1 and 2 as part of this work, because that is where the list shows. The panels (frames 3 to 7) can stay on fake data for now.
- `BRIEF.md` in the same folder is the first brief, which covers the look, the Clean Architecture layers and the rule that fake data sits behind a repository protocol. Keep to it.

## What to detect for each session
- **Agent:** which of the five agents it is.
- **Folder:** the process's working directory (`lsof -a -p <pid> -d cwd -Fn`, or the libproc API `proc_pidinfo` with `PROC_PIDVNODEPATHINFO`).
- **Project and task label:** the git repository name and current branch in that folder. The three-letter label in the ring comes from the branch or folder name (for example `feat/image-gen-v2` gives IMG). Add a simple rule table the owner can edit later. Fall back to the first three letters of the folder name.
- **Time running:** from the process start time.
- **Terminal:** the TTY and the terminal app that owns it (Warp, Terminal, iTerm, Ghostty, tmux), shown in the session panel.
- **Claude Code extra:** each running Claude Code session writes a small file under `~/.claude/sessions/`. Read it to get the session id, then find the matching transcript in `~/.claude/projects/<folder-name>/<session-id>.jsonl`. Context, tokens and status come in a later step, so for now only link the session to its transcript.

Refresh every 6 seconds. A session that ends disappears from the strip. A new one appears without restarting the app.

## Rules
- **Never move the mouse or type into anything.** No System Events, AppleScript clicks, CGEvent or cliclick. The owner uses this Mac while you work, and the last session moved their pointer. Test states with the `--state` launch argument and `scripts/capture-states.sh`, which launches the app into a state and screenshots only its window.
- Read-only: detection must never write to, signal or kill another process.
- Put detection behind the existing repository protocol, as a new `ProcessSessionRepository` in the Data layer, so the fake repository still works for `--state` screenshots.
- Unit-test the pure parts with recorded fixtures rather than live processes:
  - parsing process lists
  - filtering out sub-agents (a `claude` whose parent is a `claude` is dropped; a `claude` whose parent is `zsh` is kept)
  - deriving labels
  - matching a session to its transcript

  Build the fixtures from real `ps -Ao pid,ppid,tty,lstart,command` output on this Mac.
- Start every xcodebuild with `~/.claude/tools/ok-build.sh`. Other sessions build iOS apps on this machine, and two builds at once overload it.
- Commit as you go on a branch, with small commits.

## Done when
- With the real repository selected, the strip lists exactly the agent sessions running in terminals right now, with no sub-agents and no background jobs. Check the list against `ps` output captured at the same moment, and save both.
- Starting a new `claude` in a terminal adds a ring within 6 seconds, and quitting it removes the ring.
- The strip matches Paper frames 1 and 2.
- The tests pass.
- Proof is saved in `~/.claude/proof/ai-usage-tracker/build-2/`: window screenshots of the rest and hover states with real sessions, the matching `ps` capture, and the test summary.
