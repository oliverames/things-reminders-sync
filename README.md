# Things Reminders Sync

A menu bar app for macOS that keeps Apple Reminders lists in two-way sync with Things 3 projects, areas, or tags. It talks to Apple Reminders through EventKit and to Things through Things Cloud, so it does not need Things to be running and has no third-party dependencies.

## Requirements

- macOS 26 or later
- A Things Cloud account
- Swift 6.2 toolchain to build from source

## Build

```
scripts/build-app.sh release
```

This builds with SwiftPM and assembles `.build/ThingsRemindersSync.app`. The script signs with the Developer ID identity `Developer ID Application: Oliver Ames (PV3W52NDZ3)` using the hardened runtime. If that identity is missing it falls back to ad-hoc signing with a warning, and macOS will then ask for Reminders access again after each rebuild. Run `scripts/build-app.sh` with no argument for a debug build.

## Install

1. Copy `ThingsRemindersSync.app` to `/Applications` and open it. It appears in the menu bar only.
2. Open Settings from the menu. On the Account tab, sign in to Things Cloud and grant Reminders access.
3. On the Lists tab, turn on the Reminders lists you want to sync and pick a Things project, area, or tag for each, or create a new one.

## How sync works

- Changes in Reminders are pushed as soon as EventKit reports them.
- Things Cloud is checked for new changes every N seconds (10 to 300, default 15). Only new history is pulled.
- A full two-way reconcile runs every few minutes (5 to 120, default 10) to catch anything a notification missed.

## What is synced

Titles, notes, due dates and times, and completion are synced for the lists you enable. Deletes can be propagated in both directions; in Things, deleted items go to the Trash and are never permanently deleted. Repeating items are not synced. See [docs/SPEC.md](docs/SPEC.md) for the full list of what is and is not synced and how each mapping mode behaves.

Your Things Cloud password is stored in the macOS Keychain.
