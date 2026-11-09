# Things Reminders Sync

A menu bar app for macOS that keeps Apple Reminders lists in two-way sync with Things 3 projects, areas, or tags. It talks to Apple Reminders through [RemCTL](https://github.com/viticci/remctl) and to Things through Things Cloud, so it does not need Things to be running and has no third-party Swift dependencies. The app itself holds no Reminders permission, so it also works on a Mac where macOS cannot show permission prompts.

## Requirements

- macOS 26 or later
- A Things Cloud account
- RemCTL (`remctl`) installed at `~/bin/remctl`, `/opt/homebrew/bin/remctl`, or `/usr/local/bin/remctl` (or set its path in Settings), with its Capability Host authorized for Reminders. Run `remctl doctor` to check; it should report `reminders: authorized`.
- Swift 6.2 toolchain to build from source

## Build

```
scripts/build-app.sh release
```

This builds with SwiftPM and assembles `.build/ThingsRemindersSync.app`. Set `SIGN_IDENTITY` to your own `Developer ID Application: ...` identity to sign with the hardened runtime, and `BUNDLE_ID` to use your own bundle identifier; without an identity the script signs ad hoc with a warning. Run `scripts/build-app.sh` with no argument for a debug build.

## Install

1. Copy `ThingsRemindersSync.app` to `/Applications` and open it. It appears in the menu bar only.
2. Open Settings from the menu. On the Account tab, sign in to Things Cloud and confirm the RemCTL row shows "Ready via RemCTL". Use Check Again after installing or authorizing RemCTL.
3. On the Lists tab, turn on the Reminders lists you want to sync and pick a Things project, area, or tag for each, or create a new one.

## How sync works

- RemCTL has no change notifications, so Reminders is polled: every N seconds (5 to 120, default 10) the app runs `remctl export --json` and syncs when the content of an enabled list changed.
- Things Cloud is checked for new changes every N seconds (10 to 300, default 15). Only new history is pulled.
- A full two-way reconcile runs every few minutes (5 to 120, default 10) to catch anything a poll missed.

## What is synced

Titles, notes, due dates and times, and completion are synced for the lists you enable. Deletes can be propagated in both directions; in Things, deleted items go to the Trash and are never permanently deleted. Repeating items sync their repeat rule both ways (a repeating reminder pairs with a Things repeating to-do); rules one app cannot express fall back to syncing the current occurrence. See [docs/SPEC.md](docs/SPEC.md) for the full list of what is and is not synced and how each mapping mode behaves.

RemCTL does not report a modification time, so the app records when it first saw each reminder's current content. Conflicting edits on both sides are therefore resolved to the resolution of the Reminders poll interval.

Your Things Cloud password is stored in the macOS Keychain.

## Disclaimer

This project is not affiliated with or endorsed by Cultured Code or Apple. Things Cloud has no public API: the app uses the same undocumented sync protocol the Things apps use, which can change without notice. A malformed write can make the Things apps fail to sync or crash, so the app validates every change before it commits (see [docs/SPEC.md](docs/SPEC.md)) and only writes record shapes that were observed from the real apps ([docs/RECURRENCE.md](docs/RECURRENCE.md)). Back up your Things data before you first turn on a list, and try it on a test list first.

## Contributing

Forks and pull requests are welcome. `swift test` runs the unit tests, which use fakes and never touch the network, the Keychain, or real reminders. Before adding a new Things Cloud field, record the exact shape the Things app writes for it and add it to the docs alongside the code.

## License

MIT. See [LICENSE](LICENSE).
