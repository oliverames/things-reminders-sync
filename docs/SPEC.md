# Things Reminders Sync: specification

A self-contained macOS menu bar app that keeps chosen Apple Reminders lists and Things 3 in two-way
sync. No third-party Swift dependencies and no server: one `.app` built from this SwiftPM package,
which reads and writes Reminders through the separately installed RemCTL CLI. Designed to run on an
always-on Mac.

## Change detection

- **Reminders → app (poll):** RemCTL has no change notification. Every `remindersPollSeconds`
  (default 10, 5 to 120) the app runs `remctl export --json` (all reminders, completed included),
  hashes the content of the enabled lists' rows, and syncs when that hash changed (the first poll is a
  baseline). Changes synced in from iPhone show up the same way.
- **Synthesized modification time:** RemCTL rows carry no modification date. The app keeps, per reminder id,
  a content hash with one stamp (title, notes, due, completed, completion date, list) and a digest with its
  own stamp for each field: title, notes, due, completion, placement (list and section), repeat rule, link,
  tags, flag and subtasks. They live in memory and in
  `~/Library/Application Support/ThingsRemindersSync/remctl-observed.json`. A field whose digest is new or
  changed is stamped `now`; an unchanged one keeps its stamp. `lastModified` is the same for the whole
  reminder. A field's time is therefore when the app first noticed the change: accurate to the poll interval
  while the app runs, and later than the real edit after sleep or a restart, because a field edited in the
  meantime is stamped when the app next reads it. The first run treats every field as modified at that
  moment. Stamps are written by reads and by the read-back after a write, never by the change poll, which
  only hashes the export. Subtasks are stamped by export reads only (a single `get_reminder` row does not
  list them). A read of some lists never stamps the rows of a section-mirroring list whose sections that
  read did not load (hashing them without their section would mark every sectioned reminder there as
  modified now). A file from before per-field stamps (one hash and one stamp per reminder) still decodes:
  each field of an otherwise unchanged reminder starts from that one stamp, and a reminder that changed
  while the old version ran has every field stamped now.
- **Things modification time per field:** while history is folded into to-dos, each field (title, notes,
  When day and reminder time, completion, placement, tags, repeat rule) records the `md` of the history
  item that last changed its value; a create stamps every field. A key an item repeats with the value the
  to-do already has does not count, and an item without `md` counts as the last known `md`. A checklist
  item's own `md` is the time of its to-do's checklist (a removal carries none). The flag is a tag and the
  link is a line of the notes, so they use the tag and notes times. A field with no time of its own falls
  back to the to-do's `md`, then its creation date.
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
  serialized, 30 s timeout, restart on EOF/crash/timeout, stderr drained). After a restart a call is sent again only
  when that is safe: the reads (`lists`, `get_reminder`, `get_list`), and any call that failed before its request
  line was written. A write that was sent and got no answer throws `.uncertain` and is never sent again. The backend
  then re-reads: `create_reminder` looks for the one new reminder with that title in the list, `set_completion`
  checks the completed state (for a repeating reminder, whether the due date moved on), `update_reminder` checks
  title, notes, due and repeat (a write with `subtasks` or a list move is never assumed), `delete_reminder` checks
  that the reminder is gone. What cannot be confirmed stays an error and the next pass decides from a fresh read.
  Once `create_reminder` has returned an id, a failure in a later step (completion, read-back) no longer loses the
  reminder: it is returned as it is. Tools used: `lists`,
  `create_reminder`, `update_reminder`, `set_completion`, `delete_reminder`, `get_reminder`, `get_list` (section names).
  Link, flag, tags and subtasks are written by `update_reminder` with `private: true`: `url`, `flagged`, `set_tags` (ONE comma-separated
  string) or `clear_tags`, `subtasks` (array of titles). A subtask is otherwise a reminder: complete, rename or delete it by its own id.
- Reads: `remctl export --json` as a one-shot process, because MCP tool results are capped (about 170 KB,
  which cuts the export to roughly a third of the rows). Rows name their list by title only. A title that one
  list has maps to its id through the latest `lists` result. A title shared by several lists is settled by id:
  each of those lists is exported on its own (`remctl export --list-id N --json`) and its rows are placed in it.
  If that fails, or a row still cannot be placed, the read throws. A read never returns a list as empty because
  its rows could not be placed, since the engine would take that for deletions.
  Subtask rows (`isSubtask`, `parentID`) are never items: each is listed on its parent as `subtasks`. Rows also carry `url` (rich
  link), `tags` and `flagged`. Ids are RemCTL's numeric ids as strings.
- Due dates: `dueDate` plus `allDay` map to `DueDate` (the time part is ignored when all-day). An all-day row
  whose `displayDate` (the time Reminders shows the item at, from an alert) is on the due day with a time of day
  is read as due at that time. A new timed reminder is created with an `alarm` at the same instant (mirroring the
  Things reminder). A due date UPDATE sends `due` only: RemCTL itself moves an alarm that sat at the old due time,
  or removes it when the due becomes all-day or is cleared, and leaves every other alarm alone. `alarm: clear` is
  never sent, because it removes every alarm. The one exception: a reminder with no alarm at all (`alarms` in
  `get_reminder`) that gets a timed due also gets an `alarm` at that instant, so it notifies. Any `recurrence` means repeating (see "Repeating items"). Completion uses `set_completion`,
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
  (t 0 create, 1 update, 2 delete). On 409/412 refetch the head and retry once. A to-do update is not resent
  as it was: the client pulls what the other client wrote and builds the change again from the current to-do.
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
- Updates carry only what changes (`ThingsChanges.schedulingUpdate`, `ThingsCloudClient.updateChanges`):
  - A new time on the same day writes `ato` alone, as the JavaScript client does for a reminder-only edit.
  - Another day, or no day, writes `st`, `sr`, `tir`, `ato`. `sb 0` is added only when the to-do is in This Evening
    (`sb 1`) at that moment. `sb` is never written otherwise, so a sync does not take a to-do out of This Evening.
  - A move (`pr`/`agr`/`ar`) of an Inbox to-do (`st 0`) into a project, area or heading also writes `st 1`, as the
    JavaScript client does (it also writes `sb 0`; this client leaves `sb` alone, an Inbox to-do has none).
    `.inbox` placement writes `st 0` for an Anytime to-do without a start date. A dated to-do, a Someday to-do and a
    repeating template keep their `st`: the Inbox holds no dated to-dos, and the others stay where the user put them.
  - `tg` is the whole list and `nt` the whole text, so before a tag or notes write the client pulls new history and
    builds from the to-do as it is then. Tag ids that no longer exist are dropped. A notes write names the notes it
    was planned against (`notesBase`); if the to-do's notes changed in Things since, the write is refused
    (`changedMeanwhile`) and the next pass merges again. History pulled for a write is reported by the next `refresh()`.
- Area and tag tombstones: `deleteArea` writes `{ar: [], md}` on every task that names the area and `deleteTag`
  writes `{tg: <without it>, md}` on every task that carries the tag (trashed tasks included), in the same commit as
  the `t 2` tombstone, as the JavaScript client does. `deleteTag` is refused while an area carries the tag or a tag
  nests under it, because this client writes no `Area3` or `Tag4` update.

### IDs and validation (this crashed Things on 2026-11-09; do not regress)

A Things id is a 16-byte UUID in Bitcoin-style base58 (alphabet
`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`; each leading zero byte encodes as a
leading `1`). Things decodes every id into 16 bytes and traps on anything larger. Generate ids by
encoding 16 random bytes. Before every commit, validate: each entity id and each id in `pr`, `agr`,
`ar`, `tg`, `ts`, `rt`, `dl`, `pn` decodes to exactly 16 bytes; `cd`, `md`, `sp`, `lai` are finite
unix seconds in [0, 4102444800]; `sr`, `tir`, `dd` are also midnight UTC. Refuse the whole commit
otherwise. Port `isThingsId` / `validateChangeMap` from the JS and its tests.

References must also be live (`ThingsChangeValidator.referenceProblems`, run in `commit` against the client's
database): `pr` a project, `agr` a heading, `ts` a to-do, none of them trashed, `ar` an area, `tg` tags. An item
the same commit creates counts, one it deletes does not. A miss is checked once more after pulling new history
(the item may have been created elsewhere), then the commit is refused.

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
with a warning) on the first sync and store the new id back in the config. The target is created only after both
sides have been read, and nothing after those reads can fail the pass, so a pass that cannot read creates nothing
(creating first made a new target on every failed pass). A project whose area, or a heading whose project, no
longer exists is not created; the mapping is skipped with a warning.
A Things item that matches several mappings belongs to the first one in `config.mappings` order, except that heading
mappings are tried before every other mode, so a to-do under a mapped heading is never also claimed by a project
mapping of the same project, wherever that mapping is listed. Several lists may map to different headings of one project.
A heading target exists while it is a non-trashed task of kind heading. Sections are ignored in heading mode.
Only to-dos sync: never projects or headings (checklist items sync as part of their to-do, see Field fidelity). Repeating items sync as rules (see
"Repeating items"). Things items that are trashed are out of scope except as deletions of linked pairs.

## Per-list preferences

Each `ListMapping` carries the preferences below. Every key is optional in `config.json`, and its default is how
the app behaved before the preference existed, so an old file decodes and behaves as before. Code:
`SharedTypes.swift` (`ListMapping`, `SyncDirection`, `UndatedArrival`), `SyncEngine.swift` ("Per-list
preferences"), `FieldFidelity.swift`. Settings edits them in each list's Options sheet (`ListOptionsSheet.swift`); `paused` is a toggle on the list itself.

**`direction`**: `"twoWay"` (default), `"remindersToThings"` or `"thingsToReminders"`. In a one-way list the first
side named is the source and the other the receiver.

- The app never writes to the source: no update, create, completion, move, tag or delete. Every plan passes
  through `enforceDirection`, which drops whatever would be written to the source. The one exception is a
  container the app itself made: creating the target of a "New…" list, and removing an empty container from the
  ownership ledger, still happen in Things.
- A field is copied from source to receiver when the source's value changed since the fingerprint. This holds for
  title, due date, completion, section or heading, notes and link, flag, each tag, each checklist item, a move to
  another list, and a repeat rule.
- A field only the receiver changed is ignored: nothing is written to either side, and the fingerprint keeps the
  source's value. The receiver's edit therefore stays, pass after pass, until the source changes that same field,
  and then the source's value replaces it. Other fields the source changes meanwhile do not touch it.
- Completion follows the same rule. Completing on the receiver does not complete the source. Completing or
  reopening on the source is copied.
- Tags and checklist items are judged one by one: a tag or item added to or removed from the source is added to
  or removed from the receiver; one the receiver gained or lost is ignored.
- Creates flow from the source only. An item created on the receiver gets no partner and stays unlinked. Title
  pairing still links an unlinked receiver item to an unlinked source item of the same title, because the
  alternative is a duplicate.
- Deletes flow from the source only, and only when deletes are propagated for the list. An item deleted on the
  receiver is not deleted on the source and is not created again: the pair is unlinked and the source item is
  marked so it gets no new partner.
- First link (title pairing): the source's title, due date, completion, section, notes, flag, tags and checklist
  are written to the receiver. A source with no value for a field (no due date, not completed, no section, empty
  notes, not flagged) leaves the receiver's value alone. When Reminders is the source and both notes have text,
  the Reminders notes replace the Things notes and a `.warning` names the item.
- Moves: a move of the source item to another synced list is followed. A move of the receiver item is ignored and
  the pair stays in the source item's list. A move of either item to an unsynced place parks the link, as in a
  two-way list. A pair that arrives in another list follows that list's direction from the next pass.
- Repeating pairs: with Reminders as the source, an occurrence completed or moved in Things does not change the
  reminder, a template stopped in Things unlinks the pair, a template that lost its rule leaves the reminder
  repeating (the to-do then stands for the current occurrence), and a to-do given a repeat in Things is not
  followed. With Things as the source, a reminder that advanced, moved or lost its repeat changes nothing in
  Things, the template is never stopped, and a repeat added to a reminder is ignored.
- Retargeting: with Reminders as the source, linked to-dos move to the new target as in a two-way list. With
  Things as the source nothing in Things is moved: pairs whose to-do is still in the old target are parked (both
  items stay), an `.info` says so, and the new target is linked by title.
- Teardown, the deletion safety limit and the ownership ledger work as in a two-way list.

**`paused`**: `true` or `false` (default). A paused list keeps its links, parked links and ledger entries.

- Passes skip it: no target is created for it, its links are not processed, nothing in it is paired, created,
  updated, moved, retargeted or deleted, and its parked links are neither restored nor freed.
- Polls skip it: it is not among the lists RemCTL watches for changes or reads sections for. A Things change in
  its target can still start a pass, and that pass does nothing for the list.
- Cleanup skips it: empty app-created headings, containers and sections recorded for it are left alone, and
  "remove completed copies" leaves its copies alone.
- Its pending deletions do not exist, so they do not count towards the deletion safety limit.
- Resuming: `links.json` remembers that the list was paused (`pausedMappings`) until the first full pass without
  failures after it resumes. Until then a pair with one item missing is never a deletion: the pair is unlinked,
  the surviving item is kept and gets no new partner. Edits made during the pause sync by the usual rules. After
  that pass a deletion is a deletion again.
- An item that moves from another list into a paused list's scope has its link parked, like a move to an
  unsynced place.
- Stopping or removing a paused list works as for any list and clears the paused mark.

**`propagateDeletes`**: `true`, `false` or absent (default). When present it replaces the global
`propagateDeletes` for links of this list.

**`undatedArriveAs`**: `"anytime"` (default), `"someday"` or `"today"`. Used only when the app creates a Things
to-do from an open reminder that has no due date. It never changes a to-do that exists.

- `anytime`: as before. Anytime (`st` 1, no date), or the Inbox (`st` 0) for a tag-mode list.
- `someday`: `st` 2 with `sr` and `tir` null, the shape the JavaScript client writes for `when: "someday"`.
- `today`: the dated create the app already writes, with today as the day (`st` 1, `sr` = `tir` = today). The
  reminder gets no due date from it: the fingerprint records the day (`undatedThingsDay`), and while the to-do
  still starts on that day with no time and the reminder has no due date, the day is not treated as a due date.
  Moving the to-do to another day, giving it a time, or setting a due date in Reminders syncs as usual and ends
  that.

**`alwaysTag`**: a Things tag title, or absent (default). The tag must already exist (exact title first, then
without case); the app never creates it, and logs one `.info` per full pass when it is missing.

- Added to the to-do when the app creates it from a reminder (plain or repeating), when two existing items are
  linked by title, when a reminder is created for a to-do, and when a pair moves into the list.
- Never removed by the app. A tag taken off by hand is not put back.
- Never synced as a tag: it is left out of tag sync for every list, like the flag tag and tag-mode targets.
- Ignored on a `thingsToReminders` list, where the app writes nothing to Things.

**`includeCompletedOnFirstLink`** and **`syncChecklists`**: `true`, `false` or absent (default). When present each
replaces the global setting of the same name for this list. "Remove completed copies" leaves the copies of a list
whose own `includeCompletedOnFirstLink` is `true`.

## Native field mappings

Six optional mappings between fields the two apps hold natively. Four are per list (`ListMapping`), two are global
(`SyncConfig`). Every key is optional in `config.json` and its default is the behavior before the key existed.
Settings edits `flaggedTagTitle`, `priorityTag`, `createMissingTags` and `syncChecklists` on the Options tab. Code: `SharedTypes.swift`, `SyncEngine.swift` (`merge`,
`processLink`, `createThings`, `createReminder`, `runDeletions`), `FieldFidelity.swift` (`buildTagEnvironment`,
`createMissingTags`, `decidePriority`), `ThingsCloudClient.swift`. Tests: `EngineNativeFieldTests.swift`,
`ThingsCloudNativeFieldTests.swift`.

Things shapes. The Swift client wrote neither a deadline nor This Evening before. Both are copied from the
JavaScript client (`things3-mcp-server/src/things-client.js`), which writes them against the live account, and both
pass through `ThingsChangeValidator` (`dd`, `sr` and `tir` must be midnight UTC):

| Write | Keys | Copied from |
|---|---|---|
| Deadline on create | `dd` = midnight UTC of the day, in the full `Task6` create | `buildTaskCreate` |
| Deadline on update | `dd` (a day or null) and `md`, nothing else | `updateTask` (`updates.deadline`) |
| This Evening on create | `st` 1, `sb` 1, `sr` = `tir` = today, `ato` from the due time | `schedulingFields("evening")`, `withReminder` |
| This Evening on update | `st` 1, `sb` 1, `sr` = `tir` = today and `md`; `ato` only when the same patch changes the time | `updateTask` with `when: "evening"` |
| Tag create | `Tag4` with `tt`, `sh` null, `pn` [], `ix` 0, `xx` (the client already wrote this for tag-mode targets) | `createTag` |

The client refuses This Evening for any day but today, and a deadline or This Evening on a repeating template
(the JavaScript client refuses a deadline there too). `sb` 1 is written in no other case.

**`dueMapsTo`** (per list): `"when"` (default) or `"deadline"`.

- With `deadline`, the reminder's due date and the to-do's deadline (`dd`) are the synced pair, compared by day.
  The to-do's When is neither read nor written. A new to-do starts where a reminder with no due date would
  (`undatedArriveAs`). A new reminder takes the deadline as an all-day due date, not the start day.
- A deadline changed in Things moves the reminder to that day and keeps the reminder's time. A due date changed in
  Reminders writes `dd` alone. Clearing either clears the other.
- A due time stays in Reminders only. A change of the time alone, or of the When in Things, is not a change.
- Repeating pairs (`repeatMode` set) keep today's When-based behavior in such a list.
- The fingerprint records the mode (`dueIsDeadline`) and holds the day only. When a list changes mode, each pair
  settles its date once as on a first link: a missing date never replaces a real one, so turning the mode on
  copies existing due dates to deadlines and leaves each When as it is.
- A one-way list copies the date from its source only, as for any field.
- The Things database now stamps the due field when `dd` changes, so a deadline edit has its own time for
  conflicts.

**`eveningFromHour`** (per list): an hour from 0 to 23, or absent (default). A value outside the range is ignored.

- A reminder due today at or after that hour is created in This Evening. A linked plain to-do moves there when its
  reminder is due today at or after the hour and the to-do starts today (or the same patch moves it to today).
- The rule runs once per due date: the fingerprint keeps the due date it was settled for (`eveningFor`). A to-do
  moved out of This Evening by hand is not put back until the reminder's due date changes again.
- Things to Reminders is unchanged. A date that Things supplied (a to-do created there, or a When edited there)
  is recorded as settled and the to-do is left where the user put it.
- Not applied to repeating pairs, to a list that is one-way from Things, or when `dueMapsTo` is `deadline`.

**`canceledBecomes`** (per list): `"completed"` (default) or `"deleted"`.

- With `deleted`, a plain linked to-do that is canceled in Things (and whose reminder is still open and was not
  yet recorded as completed) has its reminder queued in `pendingDeletes`, so the deletion safety limit applies and
  a held deletion is retried. The canceled to-do is kept and gets no new reminder.
- It is a deletion, so it follows the deletion rules: it needs deletes to be propagated for the list, and it does
  nothing in a list that is one-way from Reminders or on the first pass after a pause. In those cases the
  reminder is completed (or left alone in the one-way list) as before.
- A to-do canceled before the option was set keeps its completed reminder.

**`syncSomeday`** (per list): `true` (default) or `false`. Someday means an open to-do with `st` 2 and no start
day that is not a repeating template.

- A to-do in Someday is not copied to Reminders and is not paired by title.
- A plain linked to-do that moves to Someday has its reminder deleted through `pendingDeletes` (same rules as
  above: propagated deletes, not one-way from Reminders, not after a pause, safety limit). After the deletion the
  link is parked with the to-do marked detached. `reattachParkedLinks` keeps it parked while the to-do is in
  Someday; when the to-do leaves Someday the parked link is dropped and the to-do gets a new reminder and link in
  the same pass.
- Only a move that was seen counts: the fingerprint keeps `thingsSomeday`, and the reminder is removed only when it
  was `false` and the to-do is in Someday now. A to-do that was already in Someday when the option was turned off,
  or that arrived there from Reminders (`undatedArriveAs: someday`), keeps its reminder.
- Reminders to Things is unchanged.

**`priorityTag`** (global): a Things tag title, or absent (default, off).

- Works like the flag: the tag is found by exact title, must already exist, and is left out of tag sync. Priority
  "high" and the tag are one on/off value with an agreed state in the fingerprint (`priorityHigh`).
- Reminders high adds the tag. Reminders from high to anything else removes the tag and leaves the priority.
  The tag added in Things sets priority high (whatever the priority was). The tag removed in Things sets "none",
  which can only happen while the reminder is high. Low, medium and none are otherwise never written or compared.
- Ignored, with one `.info` per full pass, when it equals `flaggedTagTitle`, names a missing tag, or names the
  target of a tag-mode list.
- RemCTL: read from the export row's `priority` ("none", "low", "medium", "high"), written as the plain
  `priority` argument of `update_reminder`. It is part of the content hash, so a change starts a pass.

**`createMissingTags`** (global): `false` (default) or `true`.

- Before links are processed, every tag of a reminder whose tags will be written to Things (a linked reminder, or
  an open unlinked one about to get a to-do, in a list that is not one-way from Things) is checked. A tag with no
  Things tag of that title in any case is created (`createTag`, the `Tag4` shape above), added to the tag
  environment, and applied by the normal tag sync in the same pass.
- Each created tag is recorded in the ownership ledger (`ownedThings`, kind `tag`, under the list of the reminder
  that needed it). The ledger cleanup removes it once no task carries it, but not while any reminder still has a
  tag of that title.
- Never for a title that `alwaysTag`, `flaggedTagTitle` or `priorityTag` names, and never for a title with a
  comma (RemCTL cannot write one back).

## Assignee tags

`assigneeTags` (per list): a JSON object from a Reminders sharee to a Things tag title, empty by default (off).
Code: `AssigneeSync.swift`, `RemCTLReminders.update`. Tests: `EngineAssigneeTests.swift`,
`RemCTLFieldFidelityTests.swift`.

- One way only, Things to Reminders. RemCTL shows no assignee in any read (export, show and info rows have no such
  field), so an assignment made in Reminders is never seen and never changes Things.
- The write is `update_reminder` with `private: true` and `assign: <sharee>` (a sharee id, address, objectUUID or `me`)
  or `unassign: true`, RemCTL's `edit --private --assign` and `--unassign`. It only works in a shared list.
- When a linked, open to-do carries a mapped tag (titles compare without case), the reminder is assigned to that
  sharee. When no mapped tag is left, the assignment the app wrote is cleared. An assignment the app never wrote
  is never cleared.
- The fingerprint keeps the last value written (`assignee`), so later passes write nothing. A to-do with two
  mapped tags uses the first key in sorted order (a JSON object has no order of its own, and `config.json` is
  saved with sorted keys) and logs once, when the assignment is written.
- A failed write logs a warning and does not fail the pair. The fingerprint keeps the to-do's tags and the wanted
  sharee at that moment (`assigneeFailed`), and the write is tried again only when either changes.
- The write is its own `update` call after the pair's other writes, so a refused assignment cannot block them.
- The tags are ordinary tags for tag sync. Nothing is written in a list that is one way from Reminders.
- The assignment follows the to-do's tags as read at the start of the pass, so a tag that arrives from Reminders
  in a pass assigns on the next one.

## Field mapping

| Reminders | Things |
|---|---|
| title | `tt` |
| notes (plain text) + rich link | notes (Markdown, link as a trailing line), see Field fidelity |
| due all-day day | When = that day (`sr`), no reminder; or the deadline (`dd`) with `dueMapsTo: deadline` |
| due day + time | When = that day, reminder `ato` = that time |
| no due date | Anytime; but leave a Things item in Someday alone, and leave Today/Evening alone if it has no time |
| completed + completionDate | `ss 3` + `sp` |
| not completed | `ss 0`, `sp` null |
| (Things canceled) | completed in Reminders; deleted with `canceledBecomes: deleted` |
| list | placement per the mapping (moving between mapped lists moves between targets, and back) |
| section (project mode, `syncSections`) | heading title of the to-do in the target project |

### Field fidelity

Each side keeps its own display conventions; a field one side cannot represent is preserved and never cleared by the sync.
Patches carry only the fields that changed (never a whole-item rewrite). Code: `Engine/FieldFidelity.swift`.

`remctl export --json` reports everything below in one call (no per-reminder reads): `url` (the rich link), `tags` (names),
`flagged`, `subtaskCount`, and subtask rows with `isSubtask: true` and `parentID`. Subtask rows are never linked as to-dos:
`RemCTLReminders` folds them into their parent's `subtasks`, and the engine also drops any item that has a `parentId`.

| Reminders | Things | Rule |
|---|---|---|
| rich link (`url`) | a bare URL as the last line of the notes, after a blank line | see "Links" below |
| notes (plain text) | notes (Markdown) | see "Notes" below |
| flagged | the tag titled `flaggedTagTitle` (default "Important") | two-way, see "Flagged" |
| tags | tags with the same title | two-way set merge, existing Things tags only, see "Tags" |
| subtasks (title, completed) | checklist items (`ChecklistItem3`) | see "Subtasks and checklists" |
| priority "high" | the tag titled `priorityTag` (off by default) | two-way like the flag, see "Native field mappings" |
| other priorities, urgent, early reminders, alarms other than the due time, location, images, assignee | none | preserved |
| none | deadline (`dd`) unless `dueMapsTo` is `deadline`, This Evening (written only by `eveningFromHour`), checklist items when checklist writes are off | preserved |

**Fingerprint.** `notes` is the Things notes as last written or seen (trimmed). New optional fields: `remindersNotes` (the
reminder's notes), `url`, `flagged`, `tags` (agreed titles) and `checklist` (agreed title and done pairs). Old state files decode with
them absent, and a missing field reads as "never synced", never as "was removed". Fingerprints are seeded from what was read
back after a write, and a write that did not take (RemCTL reports something other than what was sent) keeps the OLD value of
that field and logs a warning, so the next pass retries it (lessons from Remindian issues #74, #75 and #99). A field never
gets a synthesized value written over user-written text: Reminders is only ever rewritten with the rendering of a changed
Things note, and Things only with text the user edited in Reminders (or with the reminder's link line).

**Links.** The two renderings of one note are `Things notes` and `Reminders notes + rich link`.
- Reminders to Things: Things notes = `NoteFormatting.appendingURL(url, to: notes)` (the line is not added when the URL already
  appears in the notes).
- Things to Reminders: `splitTrailingURL` on the Things notes. When the reminder has no link, the trailing URL becomes the rich
  link (`private` + `url`) and the body (without the line) is the Reminders notes. When it has the same link, the same. When it
  has a different link, the line stays in the Reminders notes as text. RemCTL can only add a rich link, never replace or clear
  one ([viticci/remctl#79](https://github.com/viticci/remctl/issues/79)), so the engine never sends `url` for a reminder that has one.
- A link changed in Reminders replaces the old link line in Things (or is appended when the old one is not the last line);
  the Markdown of the note is left alone. A link that disappears from Reminders removes the line.
- Both sides in sync when each is the rendering of the other, so there is no ping-pong.
- Upgrade: links saved before this change have no `remindersNotes`. Their shared notes are the baseline; a reminder whose link
  already appears in the Things notes is in sync, one whose link is missing from Things gets it appended once.

**Notes.** Things is authoritative for Markdown. Reminders gets `NoteFormatting.plainText(fromMarkdown:)` of the Things body.
Three-way per side against the fingerprint: if the two notes already render to each other nothing is written (including a
Markdown-only edit in Things, whose plain text did not change); a Things edit renders to Reminders; only an actual edit of the
Reminders notes replaces the Things notes, with that plain text, verbatim. Both edited: the later edit of the notes wins (see the conflict rules) and a
`.warning` is logged. First link: Things keeps its text when both have text, an empty note never replaces a filled one, and the links are united.
Existing linked items with plain notes render to themselves; items whose Markdown was copied verbatim by older versions stay as
they are until one side is edited.

**Flagged.** Resolved by title against the existing Things tags; if no tag has that title nothing is synced, nothing is created,
and one `.info` is logged per full pass. Two-way: the side that differs from the agreed value wins (a missing agreed value reads
as unflagged, so an upgrade unites flags and removes none). Written with `update --private flagged`.

**Tags.** Only titles that already exist in Things (matched without case, because Reminders treats tags that differ only in case
as one; this app never creates a tag for a reminder's tag unless `createMissingTags` is on; titles with a comma are skipped
because `set_tags` takes one comma-separated string), minus the flagged tag, the priority tag, each list's `alwaysTag` and every tag a tag-mode list owns. Set merge against the
agreed titles: a title added on a side is added to the other, a title removed from a side is removed from the other, and a
conflict cannot arise. A Reminders tag with no Things counterpart is preserved and never removed. Reminders is written with
`--private --set-tags` carrying the full resulting set (or `--clear-tags`).

**Subtasks and checklists.** Items pair by trimmed, case-insensitive title and sync title-to-title (a rename is a delete plus an add), with completion
(`ss` 3, canceled counts as done). Added on a side: added on the other; agreed before and now missing on a side: removed on the
other; completion differs: the side that changed wins, first sight completed wins. Things to Reminders (add with `--private --subtasks`,
complete or delete by the subtask's own id) is always on. Reminders to Things checklist writes (create, complete, delete; rename
exists in the client) follow the config flag `syncChecklists` (default on since the shapes below were sampled; off means the
engine writes no checklist item). Checklist items are read from history whatever the flag says. After
Reminders subtask writes the reminder is re-read and any item that did not take keeps its old fingerprint entry (a failed add never
turns into a delete in Things). A subtask added from Things is created open, and completed on the next pass.

`ChecklistItem3` as Things 3.24.2 wrote it (three items added with the `things:///add` URL scheme,
read back from history): `{"tt":"Alpha","ss":0,"sp":null,"ix":-518,"ts":["<task id>"],"lt":false,
"cd":<now>,"md":<now>,"xx":{"_t":"oo","sn":{}}}`. Items sort by `ix` ascending (the app used -518,
-310, 0 for Alpha, Beta, Gamma). The client writes the same keys (new items get `ix` after the last existing one). Edits made in
the Things 3.24.2 Mac app on 2026-11-09 were read back from history index 1644: completing an item wrote
`{"t":1,"e":"ChecklistItem3","p":{"ss":3,"md":<now>,"sp":<now>}}`, renaming wrote `{"t":1,...,"p":{"md":<now>,"tt":"Beta renamed"}}`,
and removing wrote `{"t":2,"e":"ChecklistItem3","p":{}}`. Reopening a completed item (cmd-K, sampled the same day) wrote
`{"t":1,"e":"ChecklistItem3","p":{"md":1794274720.19473,"sp":null,"ss":0}}`. The client writes exactly these. The validator
checks every checklist key it writes (exactly one parent id in `ts`, `ss` in 0/2/3, finite `ix`, timestamps). The parent to-do
was written in the same commit as `Task7`, with `md` set on create (so `md` on creates is safe).

### Repeating items

A repeating reminder pairs with a Things repeat TEMPLATE (`repeatMode` `.template`); the rule syncs
both ways and the app never creates an occurrence (Things generates them from `icsd`). Shapes and the
validator are in docs/RECURRENCE.md; code in `Engine/RepeatSync.swift`.

- Completing the occurrence in Things completes the reminder without a date, so it advances itself.
  A reminder whose due moves to the rule's next occurrence (same time of day) is an advance: the open
  occurrence for the old day is completed. Any other due change is a reschedule. A due change that arrives with a
  new rule (the reminder's rule differs from the agreed `rule` in the fingerprint) is a rule edit and never an
  advance, even when the new date is the new rule's next occurrence: the open occurrence is moved to the new date
  and the rule is copied. A `.reminderRepeats` pair keeps no agreed rule, so it cannot tell the two apart.
- Rule edits copy the changed side's rule; both changed means the later edit of the rule wins. A due both sides moved goes
  to the later move (the open occurrence's time on the Things side, else the template's). A counted end
  (`rc`/`count`) is masked when comparing, because Reminders decrements it on each completion.
- Fallback A (a Things rule Reminders cannot hold, such as after completion): the template gets no
  reminder and its occurrences sync as plain pairs. Fallback B (a Reminders rule with no verified
  Things shape): Things gets a plain to-do for the current occurrence, replaced when the reminder
  advances (`repeatMode` `.reminderRepeats`).
- A reminder that stops repeating stops its template with the commit Things' own Stop wrote (docs/RECURRENCE.md,
  `stopRepeating`): the template is deleted for good, its open occurrences are detached, and a plain to-do is
  created for the template's next day, with the template's notes, tags and checklist items (the template's own
  checklist items are deleted in the same commit). With no open occurrence the link moves to that to-do, and the
  agreed checklist stays agreed. With one, the link
  moves to the detached occurrence and the new to-do is trashed with an ordinary update. With several, the
  occurrence on the reminder's due day is linked when exactly one matches, otherwise the earliest; the others
  stay unlinked and get their own reminders on the next pass. The pair is merged as a plain one in the same
  pass, so the reminder's date reaches the linked to-do as an ordinary update. A reminder that is completed and
  no longer repeats, or a template with no next day, unlinks the pair instead.
- A template stopped in Things is a tombstone (`ThingsSnapshot.removedTemplates` keeps the `tir` day it had).
  The reminder's repeat is cleared (`--recurrence clear`), it takes the date of the plain to-do Things created,
  and the link moves to that to-do: the only open, unlinked, non-repeating to-do in the list's target with the
  same title whose `tir` and start day are that day. Things gave that to-do the template's checklist, so the
  agreed checklist items still hold. With no such to-do the tombstone is a deletion, like a trashed template. The occurrences Things detached are plain to-dos and sync as new items.
- A template that loses its rule but still exists clears the reminder's rule. A paused template (`icp` true) is
  still a template and the pair is left as it is. Deleting the reminder trashes the template and its open
  occurrences.
- A new time on the same day for a repeating reminder moves the open occurrence and also writes `ato` on the
  template (`templateMinutes`), so the occurrences Things makes later keep the time.
- A plain pair that becomes repeating stays linked. In Things, a repeat puts the rule on a NEW template and makes
  the linked to-do its first occurrence (or removes it when the first date is in the future): the link moves to
  that template and the reminder gets the rule and the template's next day. When the to-do was removed, the
  template is the only new, unlinked template with the same title in the list's target. In Reminders, a repeat
  turns the pair into a `.reminderRepeats` pair: the to-do stands for the current occurrence. When the reminder
  moves on, the replacement is a template if the rule has a verified Things shape (the pair is then a template
  pair), else a plain to-do again. A Things rule Reminders cannot hold still falls back as above.
- `.reminderRepeats`: as soon as the reminder is on its next occurrence the link is saved with
  `awaitingReplacement`, before the Things writes that can still fail. The next pass then creates the missing
  to-do and does not complete the reminder again (it used to skip an occurrence).

### Sections and headings

Things headings only exist inside projects. A `project` mapping with `syncSections` (default true) mirrors
structure: the reminder's **section** and the to-do's **heading**. The to-do's group is the title of its heading when
that heading is in the target project and not trashed, else none (directly in the project). The reminder's group is its
section. Groups compare trimmed and case-insensitively; writes keep the original spelling. The group is part of the
link fingerprint (`group`; links saved before it existed decode it as none) and merges like any field: one side changed
since the base, copy; both changed, the later move wins (placement time). On first link a group beats none, and two different
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

Things deadline and attachments, and Reminders priority, alarms, location, images and assignee, are not synced and are never
cleared (the assignee is written, never read, when a list sets `assigneeTags`; see "Assignee tags").

#### Sections as projects (`sectionsAsProjects`)

Per list, `false` by default, `area` mode only (ignored in other modes). The same machinery with a project of the
area in place of a heading; `ListMapping.mirrorsSections` is true for both forms. Code: `SyncEngine.swift`
(`matches`, `areaProject`, `project(titled:inArea:mapping:)`, `thingsGroup`, `placement(forGroup:in:)`),
`Ledger.swift` (`taskMatches`). Tests: `EngineSectionProjectsTests.swift`.

- The to-do's group is the title of the project it is in (directly or under one of that project's headings) when
  the project is in the target area, not trashed, and not the target of any list. Loose in the area means no group.
- A group resolves to the oldest open project of that title in the area (case-insensitive), else a new project
  created with the existing `createProject(title:areaId:)` and recorded in the ownership ledger (kind `project`,
  the list's id). No group resolves to the area itself. No new Things shape is written.
- An app-created project that holds no to-dos is trashed by the end-of-pass cleanup like an app-created heading.
  Projects the user made are never recorded and never removed.
- Scope. A to-do loose in the area always belongs to the list. A to-do in a project of the area belongs when the
  project mirrors a section (some reminder of the list is in a section of that name, or the app created the
  section or the project), or when the to-do is already linked through the list. Other projects of the area are
  left alone and their to-dos are not synced. A linked to-do moved into such a project stays linked, and its
  reminder takes a section named like the project (created if missing), which makes the project a mirrored one.
- An empty Reminders section cannot be seen (sections are read from the reminders in them), so a project matches
  only a section that holds a reminder or that the app created.
- A to-do moved out of every project asks for no section; RemCTL cannot clear one, so `stuckSection` applies as above.
- A list retargeted to an area with the option on keeps each linked to-do in the project named like its old group.

## Link state and conflict rules

Persist a `LinkRecord` per pair: reminder id (+ external id), Things id, mapping id, and the
**fingerprint** last written to both sides: title, notes (plus the reminder's notes and link), due, completed, completion day, group, tags, flag and checklist. Store
state as JSON under `~/Library/Application Support/ThingsRemindersSync/` (config.json, links.json,
log.json), written atomically.

For each linked pair on a pass:

1. Compute the current fingerprint of each side.
2. Neither changed → nothing. One side changed → copy its changed fields to the other side.
3. A field both sides changed → the side that changed that field later wins; on a tie Things wins. Each
   side has a time per field (see Change detection): for Things the `md` of the history item that last
   changed the field, for Reminders the moment the app first saw the field change. Title, due date,
   completion, section, notes text, a move to another list and a repeat rule are settled this way. So a
   rename in Things at 10:05 and a new due date in Reminders at 10:06 both survive, where one time per item
   would have given Reminders the title as well. The Reminders time is only as exact as the poll interval,
   and later than the real edit when the Mac was asleep or the app was not running. The flag, tags,
   checklist and the first-link rules use no times (their own rules above). Log a `.warning` naming the item.
4. After a successful write, store the new fingerprint, so the echo from the other side is a no-op.
   This is the loop guard; there are no other flags.

Unlinked items in scope: a new item on one side creates its partner on the other. On the first link
of a mapping, pair existing open items by exact (trimmed, case-insensitive) title before creating
anything, so turning a mapping on never duplicates. Completed items are only linked on first link
when `includeCompletedOnFirstLink`. After first link, newly completed unlinked items are ignored.
The same title pairing runs on every later pass, over every unlinked open item of the list on both sides
whatever started the pass. It catches a partner whose creation landed although the pass lost track of it (a lost
answer, a failed follow-up step, a quit mid-pass): the two are linked instead of each being copied again. A pair
found this way has no `copySide`, so neither item is ever removed as "the app's copy". When notes differ on a
title pairing, the Things notes replace the Reminders notes and a `.warning` names the item.

Deletions (only when `propagateDeletes`): a linked reminder that disappears → trash the Things
to-do (never a permanent delete). A linked Things to-do that is trashed or deleted → delete the
reminder. An item that moves out of scope (to an unmapped list, out of the mapped project) → drop
the link and leave both items alone. Never delete anything that was not linked.

Safety limits: if one pass would delete or trash more than 10 items (in one mapping, or over all mappings
together) or more than 25% of a mapping's links, skip those deletions, log an `.error`, and set phase to
`.error` until the user runs Sync Now. The 25% rule never holds a single deletion in a mapping. Never empty the Things Trash. Never touch Reminders lists that are not mapped.

## Ownership ledger and cleanup

Nothing the app did not create is ever removed. `links.json` carries a ledger (old files decode without it):

- `ownedThings`: Things projects, areas, tags, and headings the app created (id, kind, mapping id, title, date), recorded in
  `ensureTargets` and when a heading is created for a section.
- `ownedSections`: Reminders sections RemCTL created (a `new_section` write that succeeded; the backend reports them through
  `takeCreatedSections`).
- Per link: `copySide` (`.things` when the engine created the to-do from a reminder, `.reminders` when it created the reminder
  from a to-do, nil for title-paired originals or when unknown) and `copiedCompleted` (the copy was made because
  "include completed on first link" brought a completed item over). Parked links keep both.
- `ledgerBackfilled`: set after the one-time inference (`LedgerBackfill`) that fills the ledger for data created before it
  existed, from the activity log, the links, the config, the Things snapshot and the reminders. Ambiguity records nothing:
  an unknown link stays `copySide == nil` (original, never deleted), an unknown container stays unrecorded.

Cleanup, always limited to ledger entries and never to a container a mapping still targets:

- **Retarget:** after linked to-dos move to the new target, an app-created old project/heading (Trash), area, or tag (deleted)
  that holds nothing left is removed. "Empty" for a project or heading means no non-trashed to-dos, open or done (projects:
  directly or under a heading). Areas and tags are deleted for good, so for them the Trash counts: an area is empty when no
  to-do or project names it, trashed or not, and a tag when no task or area carries it and no tag nests under it. The to-dos
  a "stop syncing" run has just moved to the Trash itself do not count. The backend takes the area or tag off every task
  that still names it before the tombstone.
- **Full pass end** (only when the pass had no failures): app-created headings with no non-trashed to-dos go to the Trash, and
  app-created Reminders sections holding no reminders are deleted (`remctl section-delete`). Both are re-read first.
  Groceries lists are skipped.
- **Stop syncing a list** (`SyncCoordinator.stopSyncing`, previewed by `teardownPreview`): always disables the mapping and drops
  its links, parked links, first-link marker and detached marks. With `removeCopies`: each `copySide == .things` to-do goes to
  the Trash (never deleted), each `copySide == .reminders` reminder is deleted (Recently Deleted), originals stay, then the
  mapping's empty app-created containers and sections are removed. `removeMapping` also drops the mapping. Not held back by the
  deletion safety limit (the user confirmed it), serialized with sync passes, every removal logged. If anything fails nothing is
  dropped, so it can be repeated. Parked pairs are dropped, never removed.
- **Include completed off** (`completedCopiesPreview` / `removeCompletedCopies`): the same side rules for links with
  `copiedCompleted`.

## App

- Menu bar only (`LSUIElement`). Menu: status line (phase, last sync time), Sync Now, Pause/Resume,
  Settings…, Quit.
- Settings window tabs: **Account** (Things Cloud email/password, verify, sign out; RemCTL
  status row with a Check Again button and an optional RemCTL path), **Lists** (saving a list off asks "Keep Everything" or "Remove N synced copies…"; each list has "Remove list from sync…"; every Reminders list with an enable toggle, a mode
  picker (Project, Area, Tag, Heading), a target picker of existing Things projects/areas/tags plus "New …" with a title,
  and the linked-item count; Heading mode picks the project first, then one of its headings or "New …"; Project mode has a
  "Sync sections as headings" toggle; each list also has a "Pause syncing" toggle and an "Options…" button that opens a sheet with its preferences under Direction, Dates, Deletes and completed items, Tags and people, and Sections; the row shows "Customized" when any differs from its default; the sheet edits the row's draft, so the row's Save and Revert cover it; tag fields are pickers over existing Things tags; logic in `SettingsSupport.swift`), **Options** (Things poll interval, Reminders poll interval, reconcile interval, include completed on first
  link (saving it off offers to remove the completed copies), propagate deletes, sync checklists, a Tags section with the flag tag, the priority tag (never the same tag as the flag) and create missing tags, open at login via `SMAppService.mainApp`), **Activity** (log, newest
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
or real Reminders. No test fixtures may contain anyone's real task data.

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
| To a list synced to a tag | To-do gets the tag and leaves its project or area (otherwise two lists would claim it). With no start date it goes to the Inbox (`st 0`); a dated or Someday to-do keeps its place in Today, Upcoming or Someday |
| To an unsynced list | Link parked; both items stay. Moving it back relinks it |
| Deleted | To-do moved to the Things Trash |

Parked links restore when both items are in synced places again (the side that moved pulls the other
along). If one item of a parked pair disappears, the other is freed and syncs as a new item. Pairs
unlinked because deletes are not propagated, or because an item repeats, stay detached so nothing is
resurrected.
