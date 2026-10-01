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
| `--state rest\|hover\|drag\|open-session\|open-session-details\|open-today\|open-week\|open-month` | Opens straight into that state, so you can take screenshots without using the mouse. `open-session` opens a session's panel and `open-session-details` reveals its disclosure; `open-today`, `open-week` and `open-month` open the usage panel on that period; `drag` shows the compact strip while it is being moved. Uses the made-up data unless `--data real` is also given |
| `--session <id>` | With `--state open-session`, which session to open, such as `claude-code-35056` |
| `--agent claude-code\|codex\|cursor\|kiro\|opencode` | With the `open-` states, shows that agent alone in the usage panel instead of all of them |
| `--data real\|fake` | Picks real sessions or the made-up data |

Scripts:

- `scripts/capture-states.sh <folder>` saves a screenshot of every state, using the made-up data. Add `real` after the folder to capture your real sessions instead. It stops only the copy of the app it started, so a copy you are running is left alone; `APP=<path to a .app>` captures another copy.
- `scripts/capture-glass.sh <folder> <name>` proves the glass: it puts a picture behind the overlay's corner of the screen and captures that area, so what is behind the window shows through. A capture of the window alone has nothing behind it.
- `scripts/probe-start-quit.sh <folder>` checks that a new session appears on the strip within 7 seconds, and disappears when it quits.
- `scripts/install.sh` installs the app from the latest release, as described in [the README](../README.md#install).
- `scripts/set-version.sh <version>` sets the version in `project.yml` and `App/Info.plist` and adds one to the build number.
- `scripts/release.sh <version>` builds the app signed by loubenita and zips it for a release. See [Making a release](#making-a-release).
- `scripts/claude-statusline.sh` is a Claude Code status line that saves Claude's limits for the app. See [Claude's limits](../README.md#claudes-limits).

### Making a release

Run the **Release** workflow: on GitHub, open **Actions**, choose **Release**, then **Run workflow** on `main`. Its one field is the version, such as `1.4.0`. Leave it empty to release the next minor version after the latest release, so `0.2.1` is followed by `0.3.0`.

The workflow:

1. Checks the version is newer than the latest release.
2. Sets it with `scripts/set-version.sh`, which also adds one to the build number.
3. Runs the tests.
4. Builds the app signed by the certificate in the `SIGNING_CERTIFICATE_P12` secret, with `scripts/release.sh`.
5. Commits the new version to `main` as "Release <version>" and tags it `v<version>`.
6. Publishes the GitHub release, titled "AI Usage Tracker <version>", with `AIUsageTracker.zip`. Its notes have the install steps, the zip's SHA-256 and the pull requests merged since the last release. Edit the release on GitHub to add more.

If `main` changes while it runs, it pushes nothing and releases nothing; run it again.

#### Signing secrets, set up once

The workflow signs with loubenita's Apple Development certificate (team C6F25575D8), as the earlier releases were. Signing with the same certificate keeps the permission macOS gave the app to talk to Terminal. Add two secrets under **Settings > Secrets and variables > Actions**:

1. In Keychain Access, find the "Apple Development" certificate under **My Certificates**, right-click it, choose **Export**, save it as a `.p12` file, and give it a password.
2. Copy the file as base64 with `base64 -i Certificates.p12 | pbcopy`. Paste it into a secret named `SIGNING_CERTIFICATE_P12`.
3. Put the password in a secret named `SIGNING_CERTIFICATE_PASSWORD`.
4. Delete the `.p12` file.

#### By hand

1. `scripts/set-version.sh <version>`.
2. `SIGN_IDENTITY="Apple Development: …" scripts/release.sh <version>`. It builds the app signed by loubenita's Apple Development certificate (team C6F25575D8), checks the signature, and zips the app to `build/release/AIUsageTracker.zip`.
3. Commit the version change, then publish: `gh release create v<version> build/release/AIUsageTracker.zip --title "AI Usage Tracker <version>"`.
