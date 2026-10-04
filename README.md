# ClipboardX

A fast, native clipboard manager for macOS, written in Swift. It keeps your whole clipboard history, finds things
the way you remember them, and never deletes anything on its own.

> **Status: early.** It is used daily by its author, but expect rough edges. See [Limitations](#limitations).

## Why

- **Search that finds what you meant.** Typing `Togg Lite` finds a clip titled `ToggLite`. Spacing, punctuation, case,
  accents and Turkish letters (`ı İ ş ğ`) are ignored, words match in any order, and small typos still match.
  Queries take a few milliseconds on a library of ~110,000 clips.
- **Your history is yours.** Every change is appended to an event log; the search index is derived and can be rebuilt
  at any time. History is never deleted automatically.
- **Native.** SwiftUI and AppKit, Liquid Glass on macOS 26 and later, no web views, no network access.

## Features

- Menu-bar app. `⇧⌘V` opens a shelf at the bottom of the screen (falls back to `⌥⌘V` if another app owns `⇧⌘V`).
- Cards for text, links, images and files, pinboards with colors, `⌘1…9` quick paste, `⇧` for plain text.
- Arrow keys to move, `⌘←` / `⌘→` to switch pinboards, `Return` to paste, `Esc` to close.
- Skips content that apps mark as confidential or transient (password managers), and a list of ignored apps.
- Incremental backup to iCloud Drive every ten minutes, with a completeness check.
- Importer for the local database of another clipboard manager (see below), with a full verification pass.

## Build and run

Requires macOS 14 or later and a recent Swift toolchain.

```sh
swift test                                  # run the test suite
./scripts/build-app.sh                      # builds build/ClipboardX.app, ad-hoc signed
SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh   # or sign with your certificate
open build/ClipboardX.app
```

Pasting into other apps needs the **Accessibility** permission (System Settings → Privacy & Security). Without it,
ClipboardX puts the item on the clipboard and you press `⌘V` yourself.

The library lives in `~/ClipboardX-library` (override with the `CLIPBOARDX_LIBRARY` environment variable).

## How it works

```
~/ClipboardX-library/
  log/        append-only JSONL event log, one set of segment files per device   <- source of truth
  blobs/      content-addressed payloads (SHA-256), immutable, LZFSE-compressed  <- source of truth
  index.sqlite  search index and query model (FTS5 trigram)                      <- derived, rebuildable
```

Backups copy the log segments and pack the blobs into large immutable files, so syncing folders never produces
conflicts. Restoring a backup into an empty folder reproduces the library exactly.

## Importing from another clipboard manager

`cx-import` can read the local Core Data store of a supported clipboard manager that you have installed and move
**your own** history into ClipboardX: it works on a read-only snapshot, never touches the original, can be re-run
without creating duplicates, and ends with a verification report that compares every item.

```sh
swift run -c release cx-import import --snapshot <snapshot.sqlite> --external <_EXTERNAL_DATA> --out ~/ClipboardX-library
swift run -c release cx-import verify --snapshot <snapshot.sqlite> --external <_EXTERNAL_DATA> --out ~/ClipboardX-library
```

Take the snapshot with `sqlite3 "file:<db>?mode=ro" "VACUUM INTO '<snapshot.sqlite>'"` while the other app is idle.

## Limitations

- **No sync between Macs yet.** iCloud is used for *backup* only; merging the libraries of two machines is not built.
- No deleting of clips, and limited pinboard management (no rename, delete, reorder or color picker).
- No Paste-Stack-style multi-paste, no customizable shortcuts, no link previews.
- The library and its backups are **not encrypted**.
- Not notarized. Do not run it side by side with another clipboard manager: they interfere with each other's
  shortcuts and paste events.
- The UI layer has no automated tests; the core library has about 93% line coverage.

## Not affiliated

ClipboardX is an independent project. It is not affiliated with, endorsed by, or derived from the source code of any
other clipboard manager. Product names mentioned belong to their owners.

## License

MIT, see [LICENSE](LICENSE).
