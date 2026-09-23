# AI Usage Tracker: build brief (interface only, fake data)

## What to build
A native macOS overlay that shows AI coding sessions on the right edge of the desktop. The agents it covers include Claude, Codex, Cursor, Kiro, Antigravity and opencode. This first build is **the interface only, with fake data**. It does not collect real usage yet.

## The design
- The design lives in the Paper design tool. The file is called "AI Usage Tracker" (Paper file id `01M32D1WEA9QK3QQ1A3M3H2RSG`), and the frames to build are on its **Overlay** page (page id `p-4-0`).
- Read exact sizes, colours and spacing through the Paper MCP tools (`get_jsx`, `get_computed_styles`). Don't measure them from screenshots.
- The page has five frames, which cover the three states of the overlay:
  1. **At rest** (frame `C2 · Glass edge · rest`). A floating glass capsule about 60pt wide sits 8pt in from the right edge of the screen, centred vertically. It shows one item per session:
     - a 36pt ring showing how full the session's context is, with a three-letter label inside for what the session is working on (VID, IMG or BUG)
     - the time spent, under the ring
     - an amber dot when the session is waiting for the user
     - a red ring when its context is more than about 85% full

     Below the sessions are a divider, a small bar for the 5-hour usage limit and the text "5h 62%".
  2. **Hover** (frame `C2 · Glass edge · hover`). Hovering an item highlights it and shows a glass card to its left. The card shows the task title, the time, the status, "agent · project", the context used, today's cost, and the 5-hour limit bar with its reset time.
  3. **Open** (frames `open · Session`, `open · Today` and `open · This week`). Clicking an item opens a 340pt glass panel to the left of the strip, with three tabs: **Session**, **Today** and **This week**. Session is the default. Every tab shows the same header: the ring, the task title, "agent · project" and the time. The status row also appears on every tab.
- Exported images of every state are in `~/.claude/proof/ai-usage-tracker/2026-09-21-c2-glass/`. The files are c2-rest.png, c2-hover.png, c2-open-session.png, c2-open-today.png and c2-open-week.png.
- The saved-data format is defined on the Paper page **Data model**. An example file is at `~/.claude/research/ai-usage-tracker/data-model.example.jsonl`. It has three kinds of record: a *turn* (one model reply, with its tokens and cost), a *limit* (a usage-limit reading, such as the 5-hour window at 62%) and a *session* (a session starting or ending). A field set to null means the agent did not report it, which is different from zero. Base the domain types on this format.

## Look
- Use the real macOS glass material, the macOS 26 Liquid Glass effect (`.glassEffect`), falling back to `.ultraThinMaterial`. Don't copy the gradients in the Paper file. They only imitate glass because Paper can't draw real blur.
- Use the system font (SF Pro) with tabular figures, so digits don't shift width. Text is white on the glass.
- Colours: amber #FFB23E means "needs you" or "over budget". Red #FF6B5E means "context nearly full".

## Behaviour
- The overlay is a borderless floating panel (an `NSPanel`). It appears on every Space, never takes keyboard focus from the app you are using, and the app has no Dock icon (set it up as an accessory app).
- Hovering an item shows its card. Clicking an item opens the panel. Clicking the same item again, pressing Esc or clicking outside closes it.
- Timers update once a second with no digit animation. The amber "needs you" dot slowly pulses (1.6 seconds per pulse) until the item is hovered. With the system's Reduce Motion setting on, the dot stays solid instead.

## Fake data
The numbers must agree across tabs. For example, the Image generation session's $1.10 in the Session tab must match its row in the Today tab. There are three Claude sessions:

| Session | Time | Context | Notes |
|---|---|---|---|
| MS · Video generation | 1:47 | 71% | |
| MS · Image generation | 0:23 | 34% | Waiting for you; details below |
| OpenKitchen · Bug fixes | 0:58 | 92% | Context nearly full |

Image generation details:
- Cost: $1.10.
- Tokens: 280k in total (input 52k, output 14k, cache read 200k, cache write 14k).
- Started 14:05, 18 turns so far.
- Model: Opus 5. Branch: feat/image-gen-v2.

Shared numbers:

| Measure | Value |
|---|---|
| Spent today | $4.20 of a $9 budget |
| Tokens today | 1.2M of a 2.6M budget |
| 5-hour limit | 62% used, resets 16:40 |
| Weekly limit | 48% used, 3 days left |
| Monthly limit | 64% used, 10 days left |

Every other number is in the Paper frames. Serve the fake data through a repository protocol, so a real data collector can replace it later without changing the views.

## Engineering
- Write it in Swift and SwiftUI, targeting macOS 26.
- Follow Clean Architecture, with three layers:
  - **Domain:** the entities, plus use cases that do the maths.
  - **Data:** the fake repository.
  - **Presentation:** view models and views.
- Write unit tests for every calculated number:
  - tokens per hour
  - the time when context will be full
  - how far over budget the day will end
  - each session's share of spend
  - every percentage
- Start every `xcodebuild` command with `~/.claude/tools/ok-build.sh`. It makes sure only one build runs at a time, because two builds at once overload this laptop.
- Make this folder a git repository. Add a README that names the Paper file above as the source of the design.

## Done when
- The app launches and shows the resting strip on the right edge of the screen.
- Hover works, and clicking opens the panel with all three tabs working on fake data, matching the Paper frames.
- The tests pass.
- There's a screenshot of each state in `~/.claude/proof/ai-usage-tracker/build/`, next to the matching Paper export so the two can be compared.
