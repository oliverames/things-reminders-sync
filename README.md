<p align="center">
  <img src="docs/images/icon.png" width="96" height="96" alt="Things Reminders Sync">
</p>

<h1 align="center">Things Reminders Sync</h1>

<p align="center">
  <strong>Two-way sync between Apple Reminders lists and Things 3, from a native menu bar app</strong>
</p>

<p align="center">
  <code>two-way</code> &bull;
  <code>repeat rules both ways</code> &bull;
  <code>4 mapping modes</code> &bull;
  <code>no third-party dependencies</code>
</p>

<p align="center">
  <a href="https://github.com/oliverames/things-reminders-sync/releases/latest">
    <img src="https://img.shields.io/github/v/release/oliverames/things-reminders-sync?style=flat-square&color=f5a542" alt="Release">
  </a>
  <a href="https://github.com/oliverames/things-reminders-sync/actions/workflows/test.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/oliverames/things-reminders-sync/test.yml?style=flat-square&color=f5a542&label=tests" alt="Tests">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-f5a542?style=flat-square" alt="License">
  </a>
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

---

Things Reminders Sync keeps the Apple Reminders lists you choose in step with Things 3, in both directions. Each list maps to a Things project, area, tag, or heading, and titles, notes, dates, completion, repeat rules, links, tags, flags and subtasks carry across. Each app keeps its own conventions, so a link stays a rich link in Reminders and a clickable line in Things.

## Why this exists

Things is where I plan, and Reminders is where everything else lands: Siri, the share sheet, a list someone else in the house can see. Things can import from Reminders, but only one way, and the import removes the reminder. I wanted the two to stay in sync for good, on lists I pick, without retyping anything.

There's no public Things API, so the app talks to Things Cloud directly, the same sync service the Things apps use. That means it works on a Mac where Things isn't even running, which is how I run it, on an always-on Mac at home. It reaches Reminders through [RemCTL](https://github.com/viticci/remctl), so the app itself never needs Reminders permission. That matters on a headless Mac, where macOS sometimes can't show a permission prompt at all.

Writing to an undocumented sync protocol is risky, and I learned that the hard way when a malformed id crashed Things for Mac. So every change is validated before it's sent, and the app only writes record shapes I've watched the real Things app produce. There's more on that below.

## Quick start

1. Install [RemCTL](https://github.com/viticci/remctl) and authorize its Capability Host for Reminders. `remctl doctor` should report `reminders: authorized`.
2. Download `ThingsRemindersSync-<version>.zip` from the [latest release](https://github.com/oliverames/things-reminders-sync/releases/latest), unzip it, and move **Things Reminders Sync** to `/Applications`. It's signed with a Developer ID and notarized by Apple.
3. Open it. It lives in the menu bar only.
4. In **Settings → Account**, sign in to Things Cloud and check that the Reminders row shows a green check.
5. In **Settings → Lists**, turn on the lists you want, pick a Things target for each, and hit **Save**.

Back up your Things data and try a test list first. I mean it.

## The menu bar icon

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/menubar-states-dark.png">
    <img src="docs/images/menubar-states-light.png" width="372" alt="Menu bar icon states: up to date, syncing, paused, needs attention, setup needed">
  </picture>
</p>

The icon is a to-do checkbox with a badge that tells you what sync is doing. From left to right, the states are up to date, syncing, paused, needs attention, and setup needed. It's drawn in code as a template image, so it follows light, dark and tinted menu bars.

## How lists map to Things

| Mode | A Reminders list becomes | Good for |
|---|---|---|
| **Project** | A Things project, and Reminders sections can mirror its headings | A list with an end, like a renovation |
| **Area** | A Things area | An ongoing list, like Personal or Family |
| **Tag** | Every to-do carrying a Things tag, wherever it's filed | A person or a context |
| **Heading** | One heading inside a Things project | Several small lists that belong in one project |

You can change a list's mode or target later. The app moves the items it linked to the new place and removes the containers it created once they're empty, so changing your mind doesn't leave leftovers in either app.

## What syncs

| Reminders | Things | Notes |
|---|---|---|
| Title | Title | |
| Notes (plain text) | Notes (Markdown) | Things keeps the Markdown. Reminders gets a readable plain version, and the Things notes change only when you edit them in Reminders. |
| Rich link | A link on the last line of the notes | Things shows it as a clickable link. |
| Due date and time | When date and reminder time | |
| Completed | Completed | Canceled in Things counts as completed in Reminders. |
| Repeat rule | Repeat rule | Daily, weekly, monthly and yearly rules, including nth weekdays, the last day of the month, and end conditions. |
| Flag | Your **Important** tag | The tag name is a setting. |
| Tags | Tags with the same name | Only tags that already exist in Things, because the app never creates tags. |
| Subtasks | Checklist items | Things to Reminders is on. Reminders to Things stays off until every checklist write is verified against the Things app. |
| Section | Heading | In project mode. |

Fields that only one app has stay put and are never cleared. That covers priority, urgent, early reminders, location alarms, images and assignees in Reminders, and deadlines and This Evening in Things. Every update carries only the fields that changed.

### Repeating items

A repeating reminder pairs with a Things repeating to-do, and the rule syncs both ways. Complete it in either app and the other one moves on to the next date. Things creates the copies of a repeating to-do itself, so the app never makes them for it.

Some rules only one app can express. Reminders has no "repeat after completion," and RemCTL can't write every rule Reminders supports. When that happens, the app syncs the current occurrence as a plain item and logs why.

## How it stays safe

- **Validated writes.** Every Things change is checked before it's sent. Ids have to decode to exactly 16 bytes, dates have to be real calendar days, references have to point at live items, and repeat rules have to match a shape on file in [docs/RECURRENCE.md](docs/RECURRENCE.md). A change that fails isn't sent.
- **A deletion limit.** If one pass would delete more than 10 items or more than a quarter of a list's links, it holds those deletions and waits for you to choose **Sync Now** from the menu.
- **Trash, never purge.** Deleted Things items go to the Trash, and the app never empties it.
- **An ownership ledger.** The app records what it created, so when you change settings it removes only its own copies and never your items.
- **Conflicts by field.** For each field, the later edit wins. RemCTL doesn't report modification times, so the app records when it first saw each change, which is accurate to the poll interval.

## Configuration

Settings live in the app. These are the defaults:

| Setting | Default | Range | What it does |
|---|---|---|---|
| Reminders poll | 10 s | 5 to 120 s | How often the app checks Reminders for changes |
| Things poll | 15 s | 10 to 300 s | How often it checks Things Cloud for new history |
| Full reconcile | 10 min | 5 to 120 min | A complete two-way pass that catches anything a poll missed |
| Propagate deletes | On | | Deleting on one side deletes the partner |
| Include completed on first link | Off | | Whether completed items come across when a list is first turned on |

Your Things Cloud password is stored in the macOS Keychain.

## Requirements

- macOS 26 or later
- A Things Cloud account
- [RemCTL](https://github.com/viticci/remctl) installed at `~/bin/remctl`, `/opt/homebrew/bin/remctl` or `/usr/local/bin/remctl`, or set its path in Settings

## Building from source

```bash
swift test                       # unit tests: fakes only, no network, Keychain or real reminders
scripts/build-app.sh release     # assembles .build/ThingsRemindersSync.app
```

Set `SIGN_IDENTITY` to your own `Developer ID Application: ...` identity and `BUNDLE_ID` to your own bundle id. Without an identity, the app is signed ad hoc. `scripts/release.sh` builds, notarizes, staples and zips a release.

```text
Sources/
  SyncCore/
    Engine/        the sync engine: links, merge rules, repeats, field fidelity, teardown
    ThingsCloud/   Things Cloud client, change builder and the write validator
    Reminders/     the RemCTL backend
    App/           coordinator, state store, Keychain
  ThingsRemindersSync/   the menu bar app (SwiftUI)
  trs-admin/             maintenance CLI, including a dry run that prints every write without sending it
docs/
  SPEC.md          behavior and protocol notes
  RECURRENCE.md    repeat-rule shapes observed from the real apps
```

## Disclaimer

This project isn't affiliated with or endorsed by Cultured Code or Apple. Things Cloud has no public API, and its protocol can change without notice. Use it at your own risk, keep backups, and start with a test list.

## Contributing

Forks and pull requests are welcome. Before you teach the app a new Things Cloud field, record the exact shape the Things app writes for it and add it to the docs with the code. That rule is what keeps this app from crashing anyone's Things.

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

<p align="center">
  <sub>
    Built by <a href="https://ames.consulting">Oliver Ames</a> in Vermont
    &bull; <a href="https://github.com/oliverames">GitHub</a>
    &bull; <a href="https://linkedin.com/in/oliverames">LinkedIn</a>
    &bull; <a href="https://bsky.app/profile/oliverames.bsky.social">Bluesky</a>
  </sub>
</p>
