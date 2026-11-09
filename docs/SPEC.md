# Things Reminders Sync: specification

A self-contained macOS menu bar app that keeps chosen Apple Reminders lists and Things 3 in two-way
sync. No third-party Swift dependencies and no server: one `.app` built from this SwiftPM package,
which reads and writes Reminders through the separately installed RemCTL CLI. Owner: Oliver Ames. Runs on his always-on Mac (home-server, macOS 27) or his
MacBook Pro.

## Change detection

- **Reminders → app (poll):** RemCTL has no change notification. Every `remindersPollSeconds`
  (default 10, 5 to 120) the app runs `remctl export --json` (all reminders, completed included),
  hashes the content of the enabled lists' rows, and syncs when that hash changed (the first poll is a
  baseline). Changes synced in from iPhone show up the same way.
- **Synthesized modification time:** RemCTL rows carry no modification date. The app keeps a content
  hash per reminder id (title, notes, due, completed, completion date, list) in memory and in
  `~/Library/Application Support/ThingsRemindersSync/remctl-observed.json`. A new or changed hash stamps
  `lastModified = now`; an unchanged one keeps its stored stamp. Conflict resolution ("later modification
  wins") therefore has the resolution of the poll interval, and the first run treats every reminder as
  modified at that moment.
- **Things → app:** Things Cloud has no third-party push. Every `pollSeconds` (default 15) the app
  calls `GET /version/1/history/{key}` (one small request) and pulls only new history items when the
  head moved. Changed task ids come from the pulled change maps.
- **Reconcile:** every `reconcileMinutes` (default 10), and on launch, wake, and "Sync Now", run a
  full two-way pass over every enabled mapping. This catches anything missed while asleep.

## Reminders (RemCTL)

`RemCTLReminders: RemindersBackend` (`Sources/SyncCore/Reminders/`). RemCTL (`~/bin/remctl`, then
`/opt/homebrew/bin`, `/usr/local/bin`, or an explicit path in config) must be installed with its signed
Capability Host authorized for Reminders; the app needs no Reminders permission and never prompts.

- Transport: one long-lived `remctl mcp serve` child (JSON-RPC lines on stdio, handshake once, requests
  serialized, 30 s timeout, restart once on EOF/crash/timeout, stderr drained). Tools used: `lists`,
  `create_reminder`, `update_reminder`, `set_completion`, `delete_reminder`, `get_reminder`, `get_list` (section names).
- Reads: `remctl export --json` as a one-shot process, because MCP tool results are capped (about 170 KB,
  which cuts the export to roughly a third of the rows). List titles in rows map to list ids through
  the latest `lists` result; rows in lists whose title is shared by several lists are skipped and logged.
  Subtasks are skipped. Ids are RemCTL's numeric ids as strings.
- Due dates: `dueDate` plus `allDay` map to `DueDate` (the time part is ignored when all-day). A timed due
  is written with an `alarm` at the same instant (mirroring the Things reminder); clearing a due also
  clears the alarm. Any `recurrence` means repeating (not synced). Completion uses `set_completion`,
  omitting `completion_date` for repeating reminders.
- Sections: `remctl export --json` rows carry no `section` (checked against RemCTL 2.5.0); `get_reminder` and
  `remctl show --list-id N --completed --json` do. So for the lists registered with
  `RemCTLReminders.setSectionLists` (enabled project-mode mappings with `syncSections`) every read and poll also runs one
  `show` per such list, and a failed `show` fails the read (a pass must never mistake "could not read" for "no section").
  Writes use `private: true` with `section` (an existing section of the list, matched case-insensitively against
  `get_list`, cached for one pass or poll; `section_id` when several share the name) or `new_section`. After a list move
  (which can copy the reminder and return a new id plus `oldId`) the section is written with a second call on the id
  the move returned. Lists with `isGroceries` (from `lists`) auto-categorize: their sections are read but never written.
- Access: `access()` is `.granted` when the MCP session starts and `lists` succeeds, otherwise `.denied`
  with RemCTL's message in `SyncCoordinator.remindersDetail`.

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
| `project` | open-or-done to-dos whose project is the target (directly or via a heading) | to-do in that project (under the heading named like the reminder's section, see Sections and headings) |
| `heading` | to-dos whose heading is the target (`targetId` is the heading id, `parentProjectId` its project) | to-do under that heading |
| `area` | to-dos directly in the area (no project) | to-do in that area |
| `tag` | to-dos carrying the tag, anywhere | Inbox to-do with that tag |

If `targetId` is nil, create the project/area/tag/heading named `targetTitle` (project inside
`projectAreaId` when set; a heading inside `parentProjectId`, and with no `parentProjectId` the mapping is skipped
with a warning) on the first sync and store the new id back in the config.
A Things item that matches several mappings belongs to the first one in `config.mappings` order, except that heading
mappings are tried before every other mode, so a to-do under a mapped heading is never also claimed by a project
mapping of the same project, wherever that mapping is listed. Several lists may map to different headings of one project.
A heading target exists while it is a non-trashed task of kind heading. Sections are ignored in heading mode.
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
| section (project mode, `syncSections`) | heading title of the to-do in the target project |

### Sections and headings

Things headings only exist inside projects. A `project` mapping with `syncSections` (default true) mirrors
structure: the reminder's **section** and the to-do's **heading**. The to-do's group is the title of its heading when
that heading is in the target project and not trashed, else none (directly in the project). The reminder's group is its
section. Groups compare trimmed and case-insensitively; writes keep the original spelling. The group is part of the
link fingerprint (`group`; links saved before it existed decode it as none) and merges like any field: one side changed
since the base, copy; both changed, the later modification wins. On first link a group beats none, and two different
groups go to Things. With `syncSections` off, groups are ignored and nothing moves between headings or sections.

- To Things: no group places the to-do directly in the project; a group places it under the existing heading of that name
  in the project (oldest first when duplicated) or a heading created on the spot (one per name per pass).
- To Reminders: the section is assigned, or created when the list has none of that name.
- New partners follow: a reminder in section X becomes a to-do under heading X, and the reverse. Moving a linked pair to
  another project-mode list carries the group into the new list, and so does retargeting a mapping to another project.
- **Limitation: RemCTL 2.5.0 cannot remove a reminder from a section.** `section: ""` is ignored ("nothing to update"),
  there is no clear flag, and the CLI has no unsection command (only deleting the whole section, which this app never
  does). When a heading is removed in Things, the reminder stays in its section; the fingerprint stores the Things side
  (no group) plus `stuckSection` (the section the reminder cannot leave), so the reminder still reading that section is
  not seen as a change and nothing loops or moves the to-do back. One `.info` per item is logged. A later section change
  on either side flows normally. A section write that did not take is recorded as it is, so the next pass retries it.
- Groceries lists: sections are read (headings mirror the categories) but never written; Things changes to a heading are
  not copied back, and to-dos created there get no section.

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
- Settings window tabs: **Account** (Things Cloud email/password, verify, sign out; RemCTL
  status row with a Check Again button and an optional RemCTL path), **Lists** (every Reminders list with an enable toggle, a mode
  picker (Project, Area, Tag, Heading), a target picker of existing Things projects/areas/tags plus "New …" with a title,
  and the linked-item count; Heading mode picks the project first, then one of its headings or "New …"; Project mode has a
  "Sync sections as headings" toggle), **Options** (Things poll interval, Reminders poll interval, reconcile interval, include completed on first
  link, propagate deletes, open at login via `SMAppService.mainApp`), **Activity** (log, newest
  first, with levels).
- Credentials in the Keychain (generic password, service `com.oliverames.ThingsRemindersSync`).
- Bundle id `com.oliverames.ThingsRemindersSync`, display name "Things Reminders Sync",
  signed with the Developer ID identity and the hardened runtime, with no Reminders entitlement or usage
  description (RemCTL holds the permission), built by `scripts/build-app.sh`.

## Module ownership

| Path | Owner | Notes |
|---|---|---|
| `Sources/SyncCore/Model/SharedTypes.swift` | orchestrator | contracts; do not change without approval |
| `Sources/SyncCore/ThingsCloud/` | Things agent | client, base58 ids, validation, database decode, change builders; implements `ThingsBackend` |
| `Sources/SyncCore/Reminders/` | engine agent | `RemCTLReminders: RemindersBackend` |
| `Sources/SyncCore/Engine/` | engine agent | `SyncEngine` (pure logic against the two protocols), link store, fingerprints |
| `Sources/SyncCore/App/SyncCoordinator.swift` | engine agent | fill in bodies; public API is fixed |
| `Sources/SyncCore/App/Keychain.swift`, `StateStore.swift` | engine agent | |
| `Sources/ThingsRemindersSync/` | UI agent | SwiftUI app, menu, settings |
| `scripts/build-app.sh`, `Resources/` | UI agent | bundle, Info.plist, signing, icon |
| `Tests/SyncCoreTests/` | each agent its own files | `ThingsCloud*Tests.swift`, `Engine*Tests.swift` |

Tests use Swift Testing (`import Testing`). Unit tests never touch the network, the real Keychain,
or real Reminders. No test fixtures may contain Oliver's real task data.

## Moving items (reference)

"Synced place" means a project, area, tag, or heading that an enabled list maps to.

| Move in Things | Result in Reminders |
|---|---|
| Under another heading, same project | Reminder moves to the matching section (created if missing; lists with sections off ignore headings) |
| Out from under a heading, same project | No change (RemCTL cannot remove a section); logged once, not reverted |
| To another synced project, area, or heading | Reminder moves to that list |
| Gains another synced list's tag | Stays with its list (one list per item; heading mappings first, then list order) |
| To an unsynced place (Inbox, other project or area) | Link parked; both items stay. Moving it back into a synced place relinks it |
| To the Trash | Reminder deleted (Recently Deleted) |

| Move in Reminders | Result in Things |
|---|---|
| To another section | To-do moves under the matching heading (at the next full reconcile) |
| To a list synced to a project, area, or heading | To-do moves there |
| To a list synced to a tag | To-do gets the tag and moves to the Inbox (otherwise two lists would claim it) |
| To an unsynced list | Link parked; both items stay. Moving it back relinks it |
| Deleted | To-do moved to the Things Trash |

Parked links restore when both items are in synced places again (the side that moved pulls the other
along). If one item of a parked pair disappears, the other is freed and syncs as a new item. Pairs
unlinked because deletes are not propagated, or because an item repeats, stay detached so nothing is
resurrected.
