# Contributing to ClipboardX

Thanks for helping. ClipboardX is small on purpose, so a short read here saves everyone time.

## Ground rules

- **Never lose user data.** Anything that deletes or rewrites history must go through a trash with a retention period,
  and must be covered by a test. The event log and blob store are the source of truth; the search index is derived.
- **No real clipboard data in issues, pull requests, tests or screenshots.** Clipboards contain passwords and private
  messages. Use made-up text. `swift run cx-import demo --out <empty folder>` builds a sample library for screenshots.
- **Tests first.** Add a failing test, make it pass, then clean up. The core library (`ClipboardXKit`) is held to
  roughly 90% line coverage; please keep it there.
- **Keep changes small and focused.** One concern per pull request, match the surrounding style, no drive-by reformatting.
- Prefer immutable values and small functions; files stay under about 400 lines.

## Build and test

```sh
swift test                                   # runs the whole suite
./scripts/build-app.sh                       # builds build/ClipboardX.app
open build/ClipboardX.app
```

Requires macOS 14 or later and a recent Swift toolchain. Do not run it next to another clipboard manager while testing:
they interfere with each other's shortcuts and paste events.

## Layout

| Path | What it is |
|---|---|
| `Sources/ClipboardXKit` | Library, event log, blob store, search index, backup, importer. Fully unit tested. |
| `Sources/ClipboardXApp` | The menu-bar app: shelf UI, settings, capture, paste. |
| `Sources/cx-import` | Command-line tool: import, verify, index, search, backup, demo library. |
| `Tests/ClipboardXKitTests` | Tests for the library. |

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we agree on the approach.
2. Fork, branch, commit with a short imperative message (`fix: …`, `feat: …`, `docs: …`).
3. Run `swift test` and describe in the pull request how you checked the change.

Issues labelled **good first issue** are a good place to start.
