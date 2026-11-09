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
- **Synthesized modification time:** RemCTL rows carry no modification date. The app keeps a content
  hash per reminder id (title, notes, due, completed, completion date, list) in memory and in
  `~/Library/Application Support/ThingsRemindersSync/remctl-observed.json`. A new or changed hash stamps
  `lastModified = now`; an unchanged one keeps its stored stamp. Conflict resolution ("later modification
  wins") therefore has the resolution of the poll interval, and the first run treats every reminder as
  modified at that moment. The same holds after sleep or a restart: a reminder edited in the meantime is
  stamped when the app next reads it. A read of some lists never stamps the rows of a section-mirroring
  list whose sections that read did not load (hashing them without their section would mark every
  sectioned reminder there as modified now).
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

## Field mapping

| Reminders | Things |
|---|---|
| title | `tt` |
| notes (plain text) + rich link | notes (Markdown, link as a trailing line), see Field fidelity |
| due all-day day | When = that day (`sr`), no reminder |
| due day + time | When = that day, reminder `ato` = that time |
| no due date | Anytime; but leave a Things item in Someday alone, and leave Today/Evening alone if it has no time |
| completed + completionDate | `ss 3` + `sp` |
| not completed | `ss 0`, `sp` null |
| (Things canceled) | completed in Reminders |
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
| priority, urgent, early reminders, alarms other than the due time, location, images, assignee | none | preserved |
| none | deadline (`dd`), This Evening, checklist items when checklist writes are off | preserved |

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
Reminders notes replaces the Things notes, with that plain text, verbatim. Both edited: the later modification wins and a
`.warning` is logged. First link: Things keeps its text when both have text, an empty note never replaces a filled one, and the links are united.
Existing linked items with plain notes render to themselves; items whose Markdown was copied verbatim by older versions stay as
they are until one side is edited.

**Flagged.** Resolved by title against the existing Things tags; if no tag has that title nothing is synced, nothing is created,
and one `.info` is logged per full pass. Two-way: the side that differs from the agreed value wins (a missing agreed value reads
as unflagged, so an upgrade unites flags and removes none). Written with `update --private flagged`.

**Tags.** Only titles that already exist in Things (matched without case, because Reminders treats tags that differ only in case
as one; this app never creates a tag for a reminder's tag; titles with a comma are skipped
because `set_tags` takes one comma-separated string), minus the flagged tag and every tag a tag-mode list owns. Set merge against the
agreed titles: a title added on a side is added to the other, a title removed from a side is removed from the other, and a
conflict cannot arise. A Reminders tag with no Things counterpart is preserved and never removed. Reminders is written with
`--private --set-tags` carrying the full resulting set (or `--clear-tags`).

**Subtasks and checklists.** Items pair by trimmed, case-insensitive title and sync title-to-title (a rename is a delete plus an add), with completion
(`ss` 3, canceled counts as done). Added on a side: added on the other; agreed before and now missing on a side: removed on the
other; completion differs: the side that changed wins, first sight completed wins. Things to Reminders (add with `--private --subtasks`,
complete or delete by the subtask's own id) is always on. Reminders to Things checklist writes (create, complete, delete; rename
exists in the client) are behind the config flag `syncChecklists` (default off): until the completion and deletion shapes have been
sampled from the app, the engine writes no checklist item. Checklist items are read from history whatever the flag says. After
Reminders subtask writes the reminder is re-read and any item that did not take keeps its old fingerprint entry (a failed add never
turns into a delete in Things). A subtask added from Things is created open, and completed on the next pass.

`ChecklistItem3` as Things 3.24.2 wrote it (three items added with the `things:///add` URL scheme,
read back from history): `{"tt":"Alpha","ss":0,"sp":null,"ix":-518,"ts":["<task id>"],"lt":false,
"cd":<now>,"md":<now>,"xx":{"_t":"oo","sn":{}}}`. Items sort by `ix` ascending (the app used -518,
-310, 0 for Alpha, Beta, Gamma). The client writes the same keys (new items get `ix` after the last existing one); completion
is `ss` 3 with `sp`, and removal a `t` 2 tombstone, both still to be sampled from the app before `syncChecklists` is enabled. The validator
checks every checklist key it writes (exactly one parent id in `ts`, `ss` in 0/2/3, finite `ix`, timestamps). The parent to-do
was written in the same commit as `Task7`, with `md` set on create (so `md` on creates is safe).

### Repeating items

A repeating reminder pairs with a Things repeat TEMPLATE (`repeatMode` `.template`); the rule syncs
both ways and the app never creates an occurrence (Things generates them from `icsd`). Shapes and the
validator are in docs/RECURRENCE.md; code in `Engine/RepeatSync.swift`.

- Completing the occurrence in Things completes the reminder without a date, so it advances itself.
  A reminder whose due moves to the rule's next occurrence (same time of day) is an advance: the open
  occurrence for the old day is completed. Any other due change is a reschedule.
- Rule edits copy the changed side's rule; both changed means the later edit wins. A counted end
  (`rc`/`count`) is masked when comparing, because Reminders decrements it on each completion.
- Fallback A (a Things rule Reminders cannot hold, such as after completion): the template gets no
  reminder and its occurrences sync as plain pairs. Fallback B (a Reminders rule with no verified
  Things shape): Things gets a plain to-do for the current occurrence, replaced when the reminder
  advances (`repeatMode` `.reminderRepeats`).
- A template that stops repeating clears the reminder's rule; a reminder that stops repeating unlinks
  the pair. Deleting the reminder trashes the template and its open occurrences.
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

Things deadline and attachments, and Reminders priority, alarms, location, images and assignee, are not synced and are never
cleared.

## Link state and conflict rules

Persist a `LinkRecord` per pair: reminder id (+ external id), Things id, mapping id, and the
**fingerprint** last written to both sides: title, notes (plus the reminder's notes and link), due, completed, completion day, group, tags, flag and checklist. Store
state as JSON under `~/Library/Application Support/ThingsRemindersSync/` (config.json, links.json,
log.json), written atomically.

For each linked pair on a pass:

1. Compute the current fingerprint of each side.
2. Neither changed → nothing. One side changed → copy its changed fields to the other side.
3. Both changed → per field, the side with the later modification date wins. That date is per item, not per
   field: Things `md` is the last change to anything on the to-do, and the Reminders time is synthesized (see
   Change detection), so it is the moment the app first saw the change. A field edited later on one side can
   therefore lose to an unrelated later edit of the same item on the other side. Log a `.warning` naming the item.
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
  "Sync sections as headings" toggle), **Options** (Things poll interval, Reminders poll interval, reconcile interval, include completed on first
  link (saving it off offers to remove the completed copies), propagate deletes, open at login via `SMAppService.mainApp`), **Activity** (log, newest
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
