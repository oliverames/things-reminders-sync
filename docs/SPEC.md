# Things Reminders Sync: specification

A self-contained macOS menu bar app that keeps chosen Apple Reminders lists and Things 3 in two-way
sync. No third-party dependencies, no server, no helper processes: one `.app` built from this
SwiftPM package. Owner: Oliver Ames. Runs on his always-on Mac (home-server, macOS 27) or his
MacBook Pro.

## Change detection

- **Reminders → app (push):** EventKit posts `EKEventStoreChanged` whenever the Reminders database
  changes, including changes synced in from iPhone. It does not say what changed, so the app
  re-reads the mapped lists (debounced ~1 s) and diffs against the last synced fingerprints.
- **Things → app:** Things Cloud has no third-party push. Every `pollSeconds` (default 15) the app
  calls `GET /version/1/history/{key}` (one small request) and pulls only new history items when the
  head moved. Changed task ids come from the pulled change maps.
- **Reconcile:** every `reconcileMinutes` (default 10), and on launch, wake, and "Sync Now", run a
  full two-way pass over every enabled mapping. This catches anything missed while asleep.

## Things Cloud protocol

Port from the working, live-verified JavaScript client:
`~/Developer/Projects/things3-mcp-server/src/things-client.js` (read it; do not modify it).
Essentials:

- Base `https://cloud.culturedcode.com`. Headers from `commonHeaders()` in the JS: `Authorization:
  Password <encoded>` (see `encodePassword`), `User-Agent`, `things-client-info`, etc.
- Account: `GET /version/1/account/{email}` → `history-key`. 401 means a bad password.
- History head: `GET /version/1/history/{key}` → `latest-server-index`.
- Items: `GET /version/1/history/{key}/items?start-index=N` → `items` (array of change maps),
  `current-item-index` (the server HEAD, not the end of the page). Pages are capped (~1,039 items):
  advance `start` by the number of items received, never by `current-item-index`.
- Commit: `POST /version/1/history/{key}/commit?ancestor-index=N&_cnt=1` with headers `Schema: 301`,
  `App-Id: com.culturedcode.ThingsMac`, `App-Instance-Id` (use `-things-reminders-sync`),
  `Push-Priority: 5`. Body: `{ "<uuid>": { "t": 0|1|2, "e": "Task6", "p": {...} } }`
  (t 0 create, 1 update, 2 delete). On 409/412 refetch the head and retry once.
- Change maps: entity `e` is versioned (`Task6`, `Task7` from the 3.24 Mac app, `Area3`, `Tag4`,
  `ChecklistItem3`, `Settings5`). Decode any `Task*` as a task. Keys: `tt` title, `nt` note object
  (`{_t:"tx", t:1, ch:crc32, v:text}` full, or `t:2` with `ps` patches: see `applyNotePatches`),
  `tp` type, `ss` status (0 open, 2 canceled, 3 completed), `sp` stop date, `tr` trashed, `st` start,
  `sb` evening, `sr`/`tir` start date (unix seconds at midnight UTC), `ato` reminder seconds after
  local midnight, `dd` deadline, `pr`/`agr`/`ar` project/heading/area id arrays, `tg` tag ids,
  `cd`/`md` creation/modification (unix seconds, fractional), `rr`/`rt` recurrence.
  Merge `p` into the entity on t 1; replace on t 0; remove on t 2.
- Scheduling rules: see `schedulingFields` and `withReminder` in the JS. A start date today or
  earlier is `st 1` with `sr = tir = day`; a future date is `st 2` with `sr = tir = day`; no date is
  `st 1, sr null, tir null` (Anytime). A reminder time needs a start date.

### IDs and validation (this crashed Things on 2026-11-09; do not regress)

A Things id is a 16-byte UUID in Bitcoin-style base58 (alphabet
`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`; each leading zero byte encodes as a
leading `1`). Things decodes every id into 16 bytes and traps on anything larger. Generate ids by
encoding 16 random bytes. Before every commit, validate: each entity id and each id in `pr`, `agr`,
`ar`, `tg`, `ts`, `rt`, `dl`, `pn` decodes to exactly 16 bytes; `cd`, `md`, `sp`, `lai` are finite
unix seconds in [0, 4102444800]; `sr`, `tir`, `dd` are also midnight UTC. Refuse the whole commit
otherwise. Port `isThingsId` / `validateChangeMap` from the JS and its tests.

## Mapping model

Each enabled `ListMapping` links one Reminders list to one Things target:

| Mode | Things items in scope | New Reminders item becomes |
|---|---|---|
| `project` | open-or-done to-dos whose project is the target (directly or via a heading) | to-do in that project |
| `area` | to-dos directly in the area (no project) | to-do in that area |
| `tag` | to-dos carrying the tag, anywhere | Inbox to-do with that tag |

If `targetId` is nil, create the project/area/tag named `targetTitle` (project inside
`projectAreaId` when set) on the first sync and store the new id back in the config.
A Things item that matches several mappings belongs to the first one in `config.mappings` order.
Only to-dos sync: never projects, headings, checklist items, or repeating to-dos (`isRepeating`
either side). Things items that are trashed are out of scope except as deletions of linked pairs.

## Field mapping

| Reminders | Things |
|---|---|
| title | `tt` |
| notes (plain text) | notes (Markdown passes through untouched) |
| due all-day day | When = that day (`sr`), no reminder |
| due day + time | When = that day, reminder `ato` = that time |
| no due date | Anytime; but leave a Things item in Someday alone, and leave Today/Evening alone if it has no time |
| completed + completionDate | `ss 3` + `sp` |
| not completed | `ss 0`, `sp` null |
| (Things canceled) | completed in Reminders |
| list | placement per the mapping (moving between mapped lists moves between targets, and back) |

Things deadline, tags (other than the mapping tag), priority, flags, subtasks/checklists, and
attachments are not synced.

## Link state and conflict rules

Persist a `LinkRecord` per pair: reminder id (+ external id), Things id, mapping id, and the
**fingerprint** last written to both sides: title, notes, due, completed, completion day. Store
state as JSON under `~/Library/Application Support/ThingsRemindersSync/` (config.json, links.json,
log.json), written atomically.

For each linked pair on a pass:

1. Compute the current fingerprint of each side.
2. Neither changed → nothing. One side changed → copy its changed fields to the other side.
3. Both changed → per field, the side with the later modification date wins (Reminders
   `lastModifiedDate`, Things `md`). Log a `.warning` naming the item.
4. After a successful write, store the new fingerprint, so the echo from the other side is a no-op.
   This is the loop guard; there are no other flags.

Unlinked items in scope: a new item on one side creates its partner on the other. On the first link
of a mapping, pair existing open items by exact (trimmed, case-insensitive) title before creating
anything, so turning a mapping on never duplicates. Completed items are only linked on first link
when `includeCompletedOnFirstLink`. After first link, newly completed unlinked items are ignored.

Deletions (only when `propagateDeletes`): a linked reminder that disappears → trash the Things
to-do (never a permanent delete). A linked Things to-do that is trashed or deleted → delete the
reminder. An item that moves out of scope (to an unmapped list, out of the mapped project) → drop
the link and leave both items alone. Never delete anything that was not linked.

Safety limits: if one pass would delete or trash more than 10 items or more than 25% of a mapping's
links, skip those deletions, log an `.error`, and set phase to `.error` until the user runs Sync
Now. Never empty the Things Trash. Never touch Reminders lists that are not mapped.

## App

- Menu bar only (`LSUIElement`). Menu: status line (phase, last sync time), Sync Now, Pause/Resume,
  Settings…, Quit.
- Settings window tabs: **Account** (Things Cloud email/password, verify, sign out; Reminders
  access status + request button), **Lists** (every Reminders list with an enable toggle, a mode
  picker, a target picker of existing Things projects/areas/tags plus "New …" with a title, and the
  linked-item count), **Options** (poll interval, reconcile interval, include completed on first
  link, propagate deletes, open at login via `SMAppService.mainApp`), **Activity** (log, newest
  first, with levels).
- Credentials in the Keychain (generic password, service `com.oliverames.ThingsRemindersSync`).
- Bundle id `com.oliverames.ThingsRemindersSync`, display name "Things Reminders Sync",
  `NSRemindersFullAccessUsageDescription` set, signed with the Developer ID identity
  (stable TCC identity across rebuilds), built by `scripts/build-app.sh`.

## Module ownership

| Path | Owner | Notes |
|---|---|---|
| `Sources/SyncCore/Model/SharedTypes.swift` | orchestrator | contracts; do not change without approval |
| `Sources/SyncCore/ThingsCloud/` | Things agent | client, base58 ids, validation, database decode, change builders; implements `ThingsBackend` |
| `Sources/SyncCore/Reminders/` | engine agent | `EventKitReminders: RemindersBackend` |
| `Sources/SyncCore/Engine/` | engine agent | `SyncEngine` (pure logic against the two protocols), link store, fingerprints |
| `Sources/SyncCore/App/SyncCoordinator.swift` | engine agent | fill in bodies; public API is fixed |
| `Sources/SyncCore/App/Keychain.swift`, `StateStore.swift` | engine agent | |
| `Sources/ThingsRemindersSync/` | UI agent | SwiftUI app, menu, settings |
| `scripts/build-app.sh`, `Resources/` | UI agent | bundle, Info.plist, signing, icon |
| `Tests/SyncCoreTests/` | each agent its own files | `ThingsCloud*Tests.swift`, `Engine*Tests.swift` |

Tests use Swift Testing (`import Testing`). Unit tests never touch the network, the real Keychain,
or real Reminders. No test fixtures may contain Oliver's real task data.
