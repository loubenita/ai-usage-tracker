# Building and running it

## Requirements

- macOS 26 or later
- To build it yourself: Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `project.yml`

## Build, test and run

```sh
xcodegen                                    # only after editing project.yml
xcodebuild -project AIUsageTracker.xcodeproj -scheme AIUsageTracker \
  -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project AIUsageTracker.xcodeproj -scheme AIUsageTracker \
  -derivedDataPath build/DerivedData test
```

The app is at `build/DerivedData/Build/Products/Debug/AIUsageTracker.app`.

Launch options:

| Option | What it does |
|---|---|
| no options | Shows your real sessions |
| `--state rest\|hover\|drag\|open-session\|open-today\|open-week\|open-month` | Opens straight into that state, so you can take screenshots without using the mouse. `open-session` opens a session's panel; `open-today`, `open-week` and `open-month` open the usage panel on that period; `drag` shows the strip picked up. Uses the made-up data unless `--data real` is also given |
| `--session <id>` | With `--state open-session`, which session to open, such as `claude-code-35056` |
| `--agent claude-code\|codex\|cursor\|kiro\|opencode` | With the `open-` states, shows that agent alone in the usage panel instead of all of them |
| `--data real\|fake` | Picks real sessions or the made-up data |

Scripts:

- `scripts/capture-states.sh <folder>` saves a screenshot of every state, using the made-up data. Add `real` after the folder to capture your real sessions instead. It stops only the copy of the app it started, so a copy you are running is left alone; `APP=<path to a .app>` captures another copy.
- `scripts/capture-glass.sh <folder> <name>` proves the glass: it puts a picture behind the overlay's corner of the screen and captures that area, so what is behind the window shows through. A capture of the window alone has nothing behind it.
- `scripts/probe-start-quit.sh <folder>` checks that a new session appears on the strip within 2 seconds, and disappears when it quits.
- `scripts/install.sh` installs the app from the latest release, as described in [the README](../README.md#install).
- `scripts/release.sh <version>` builds the app signed by loubenita and zips it for a release. See [Making a release](#making-a-release).
- `scripts/claude-statusline.sh` is a Claude Code status line that saves Claude's limits for the app. See [Claude's limits](../README.md#claudes-limits).

### Making a release

1. Set the version in `project.yml`, under `CFBundleShortVersionString`, and run `xcodegen`. `App/Info.plist` is written from `project.yml`, so a version set only in the plist is lost the next time the project is generated.
2. Run `scripts/release.sh <version>`. It builds the app signed by loubenita's Apple Development certificate (team C6F25575D8), checks the signature, and zips the app to `build/release/AIUsageTracker.zip`.
3. Publish it: `gh release create v<version> build/release/AIUsageTracker.zip --title "AI Usage Tracker <version>"`.
