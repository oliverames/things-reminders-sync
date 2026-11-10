# Worklog

## 2026-11-09: assignee tags, sections as projects, and the repeat rule-edit fix

Engine work, no UI. Tests: `swift test --parallel`, 416 passing (was 399). Nothing was run against the real apps,
RemCTL or Things Cloud, and nothing was committed. No new Things wire shape is written.

- `assigneeTags` (per list, default `{}`): a mapped tag on a linked to-do assigns its reminder to the sharee;
  removing the tag clears it. Things to Reminders only, because RemCTL cannot read an assignment. `ReminderPatch`
  gained `assignee`; RemCTL writes `assign` or `unassign` with `private`. Two fingerprint fields (`assignee`,
  `assigneeFailed`) keep later passes quiet and hold back a failed write until the tags change. Details:
  `docs/SPEC.md`, "Assignee tags". Tests: `EngineAssigneeTests.swift`.
- `sectionsAsProjects` (per list, default `false`, area mode): sections mirror projects inside the area on the
  existing section code. `sectionsActive`, `thingsGroup` and `placement(forGroup:in:)` now cover both forms, and
  `matches` decides which projects of the area belong to the list. Created projects go in the ledger as kind
  `project` and the existing cleanup removes them when empty. Details: `docs/SPEC.md`, "Sections as projects".
  Tests: `EngineSectionProjectsTests.swift`.
- Fixed the defect noted under "Known and left alone" in the per-list preferences entry below: in `templateExtras` a due change that comes with a changed rule is a
  rule edit, so the open occurrence is moved instead of completed. Regression test:
  `ruleAndDueChangedTogetherIsARuleEditNotACompletion`, which fails without the fix.

Decisions worth knowing:

- "Key order" for two mapped tags is sorted key order. A JSON object has none, and the app saves `config.json`
  with sorted keys.
- A project of the area that matches no section is out of scope, but a linked to-do moved into it stays linked
  and creates the section. From then on the project mirrors that section and its other to-dos sync too.
- A project that another list targets is never used as a section project, so a section of the same name gets a
  second project of that name in the area.
- An empty Reminders section is invisible to the engine, so it does not make a project match.

Known and left alone: a `.reminderRepeats` pair keeps no agreed rule in its fingerprint, so a rule and date
changed together can still read as an advance there. An assignment whose write ended uncertain counts as failed.

Not verified: `assign` and `unassign` against a real RemCTL and a shared list (the argument names come from
RemCTL's published tool schema), and the project moves against the real Things apps.

## 2026-11-09: six optional native field mappings in the engine

Engine and client work, no UI. Tests: `swift test --parallel`, 399 passing (was 361). Nothing was run against the
real apps, RemCTL or Things Cloud, and nothing was committed. Details are in `docs/SPEC.md`, "Native field
mappings"; the tests are in `EngineNativeFieldTests.swift` and `ThingsCloudNativeFieldTests.swift`.

Every key is optional in `config.json` and defaults to the old behavior. Per list: `dueMapsTo`,
`eveningFromHour`, `canceledBecomes`, `syncSomeday`. Global: `priorityTag`, `createMissingTags`.

- `dueMapsTo: deadline` maps the due date to the Things deadline and leaves the When alone. The due time stays in
  Reminders. Repeating pairs keep the When. A list that changes mode settles each date once as on a first link.
- `priorityTag` maps priority high to an existing tag by the flag's rule. `ReminderItem` and `ReminderPatch`
  gained `priority`; RemCTL reads it from the export and writes the plain `priority` argument.
- `eveningFromHour` puts a reminder due today at or after the hour in This Evening, once per due date.
- `canceledBecomes: deleted` and `syncSomeday: false` remove a reminder through `pendingDeletes`, so the safety
  limit holds. The Someday case parks the link until the to-do leaves Someday.
- `createMissingTags` creates a Things tag for a reminder tag that has none and records it in the ledger.

New Things shapes in the Swift client, each copied from the JavaScript client and covered by the validator: a
deadline (`dd`) on create and update, and This Evening (`st` 1, `sb` 1, `sr` = `tir` = today) on create and
update. The `Tag4` create was already there. The client refuses This Evening for any day but today.

Decisions worth knowing:

- The two reminder-removing options are deletions, so they need deletes to be propagated for the list and do
  nothing in a list that is one-way from Reminders or on the first pass after a pause.
- Only a move to Someday that the app saw happen removes a reminder (`thingsSomeday` in the fingerprint). This is
  what keeps `undatedArriveAs: someday` from deleting the reminder it was just created from.
- A tag added in Things sets priority high even when the reminder was low or medium. Low and medium are never
  written otherwise.
- A date chosen in Things is never moved to This Evening by the app.
- The ledger cleanup keeps an app-created tag while any reminder still carries a tag of that title. Without that,
  a tag no to-do ended up carrying would be removed and created again on every full pass.
- Four fingerprint fields were added (`dueIsDeadline`, `priorityHigh`, `eveningFor`, `thingsSomeday`); old
  `links.json` files decode with them absent.

Not verified: the deadline and This Evening writes against the real Things apps, and the `priority` argument
against a real RemCTL. The shapes match the JavaScript client and RemCTL's published tool schema.

## 2026-11-09: second repeat samples matched, and per-list preferences in the engine

Two pieces of engine work, no UI. Tests: `swift test --parallel`, 361 passing (was 319). Nothing was run against
the real apps, and nothing was committed.

Second sampling session (Things 3.24.2, history indexes after 1716; both samples are in `docs/RECURRENCE.md`):

- Rule edit that moves the next day: the client now writes `md`, `rr`, `tir` and `icsd` and nothing else. `rr`
  keeps the old `sr` and takes `ia` from the `tir` the template had before the edit (it used to keep the old
  `ia`). `ato` is added only when the reminder time changed in the same edit, which is the app's own combination.
  `ti` is never written.
- Stop: `stopRepeating` now creates each of the template's checklist items again on the new to-do with the
  sampled keys and tombstones the template's own items, in the same commit. Notes and tags were already copied;
  the sample confirms them, including the notes checksum. `stopRepeating` returns the new checklist item ids
  (`ThingsStopResult`), so the engine keeps the agreed checklist instead of forgetting it, for a stop made in
  either app.
- Not sampled: a completed checklist item on a stopped template (the app carries `ss` and `sp` over), and a
  template with a reminder time (`ato` stays null as in both samples).

Per-list preferences on `ListMapping` (`docs/SPEC.md`, "Per-list preferences"): `direction`, `paused`,
`propagateDeletes`, `undatedArriveAs`, `alwaysTag`, `includeCompletedOnFirstLink`, `syncChecklists`. Every key is
optional and defaults to the old behavior. Tests are in `EnginePerListTests.swift`.

- One-way lists never write to the source. A receiver edit is ignored until the source changes that field.
- A paused list is skipped by passes, polls and cleanup. `links.json` gained `pausedMappings`, so the first full
  pass after a resume deletes nothing.
- `undatedArriveAs: today` needed one new fingerprint field (`undatedThingsDay`), so the to-do's start day is not
  copied to the reminder as a due date. `someday` uses the JavaScript client's verified `st` 2 shape.
- Decisions worth knowing: a delete on the receiving side unlinks the pair and the source item is not copied
  again; a one-way list from Things does not move to-dos on a retarget and ignores `alwaysTag`; a first link in a
  one-way list writes the source's values but never lets an empty source value clear the receiver's.
- Known and left alone: when a reminder's rule and due date change together and the new date happens to be the
  new rule's next occurrence, `templateExtras` still reads it as an advance and completes the open occurrence.

## 2026-11-09: repeat edits brought in line with new Things samples

Things 3.24.2 was sampled for a checklist reopen, a to-do made repeating, a rule edit, pause and resume, and Stop
(history indexes 1688 to 1700). All samples are in `docs/RECURRENCE.md`; the reopen is in `docs/SPEC.md`.
Tests: `swift test --parallel`, 319 passing. Nothing was run against the real apps.

- Rule edit: the rewritten `rr` now takes `ia` from the template's `tir` and keeps the old `sr`, as sampled. It
  used to keep the old `ia`. A rule edit that also moves the next day keeps the old `ia` (not sampled).
- Repeat removed in Reminders: the pair used to be unlinked and the template kept repeating. The client now has
  `stopRepeating`, which sends the sampled Stop commit, and the engine moves the link to a plain to-do.
- Which to-do (follow-up): with one open occurrence the link moves to that occurrence and the new next-day to-do is
  trashed with the ordinary trash update, so Things no longer shows two to-dos of the same title on one day. With
  none, the link moves to the new to-do as before. With several, the occurrence on the reminder's due day is linked
  when exactly one matches, otherwise the earliest; the rest stay unlinked and get their own reminders on the next
  pass. A failed trash write is reported and the extra to-do is kept out of Reminders. See `docs/RECURRENCE.md`.
- Stop in Things: a tombstoned template used to delete the reminder. The database now remembers the `tir` of a
  tombstoned template, and the engine clears the reminder's repeat and links it to the plain to-do Things made.
- Pause: read as an ordinary update, so the pair stays. Checklist reopen already matched the sample.
- The validator needed no change. The app still writes `Task6` where Things 3.24 writes `Task7`.
- Not sampled, so not copied in the Stop commit: a reminder time (`ato`) and checklist items. Notes and tags are
  copied from the template, which the sample neither confirms nor contradicts (its template had none).

## 2026-11-09: per-field conflict resolution (audit finding M8)

A field both sides changed now goes to the side that changed that field later, instead of comparing one time
per item. A dry run on home-server against live data planned no changes. Tests: `swift test --parallel`, 304 passing; new ones in `PerFieldConflictTests.swift`.

- Things: `ThingsDatabase.stampFields` records, per field, the `md` of the history item that last changed its value
  (`ThingsTask.fieldModified`, read through `modified(_:)`). A create stamps every field; a checklist item's `md`
  stamps its to-do's checklist. It compares values, not keys, so a client that resends an unchanged key moves no time.
- Reminders: `remctl-observed.json` keeps a digest and stamp per field next to the old hash and stamp
  (`ReminderItem.fieldModified`). An old file decodes and seeds every field from its one stamp. Polls still write nothing.
- Merge: title, due date, completion, section, notes text, a move between lists, and a template pair's due and rule
  use the field's two times; the tie still goes to Things. Flag, tags, checklist and first-link rules are unchanged.
  Items without field times (the test fakes) fall back to the item time, so the old tests hold.
- No Things Cloud write shape changed. README and SPEC state the per-field rule and its limit: a Reminders time is
  when the app first saw the change, exact to the poll interval and late after sleep or a restart.
- Not verified against the real apps: whether Things always sends `md` on updates from every client, and whether a
  checklist change also moves its to-do's `md`.

## 2026-11-09: checklist writes on by default

Completing, renaming and removing a checklist item in the Things 3.24.2 Mac app was read back from history index 1644
(shapes in `docs/SPEC.md`). They match what the client writes, so `syncChecklists` now defaults to on and subtasks sync
both ways. Reopening a completed item is still unsampled.

## 2026-11-09: audit fixes (commit `1496abe`)

Fixes for the code audit and the write-parity audit against the JavaScript connector. Tests: `swift test --parallel`.
Each fix has a test in `Tests/SyncCoreTests/AuditFixTests.swift` or `RemCTLRemindersTests.swift`.

- Duplicates: a "New…" target is created only after both sides were read (H1). A create that landed but was lost
  is paired by title on the next pass, and `create` returns the reminder even when a follow-up step fails (H4).
- Reminders reads: lists that share a title are read by list id; a read that cannot place its rows fails the pass (H2).
  `displayDate` on the due day is read as the time (M3). Reading one list no longer re-stamps other sectioned lists (M7).
- Reminders writes: a write with no answer is never resent; the reminder is re-read instead (H3). Due writes no longer
  send `alarm: clear` (M4). Tags match without case (M10).
- Things writes: `sb` is only written for a to-do in This Evening that changes day, and a same-day time change writes
  `ato` alone (M5). References are checked against the database before a commit (M6). Tag and notes writes are built
  from the current to-do, and a stale commit is rebuilt (M9). Leaving the Inbox writes `st 1`, entering it `st 0`;
  area and tag tombstones strip references first, and the Trash counts as content for areas and tags (parity, L2).
- Repeats: an item given a repeat after linking stays linked (M1). A failed replacement no longer advances the
  reminder twice (M2). A new time reaches the template (M11).
- Smaller: the deletion count limit covers the whole pass (L1), `mailto:` style links (L3), link prefix match (L4),
  a log line when first-link notes are replaced (L5), checklist changes sync on the next poll (L6), README drift (L7).
- Documented instead of changed: conflicts use one time per item, and the Reminders time is when the app saw the
  change (M8). Declined: M12 (no failing input can be shown; RemCTL advances one occurrence per completion).
- Not verified against the real apps: nothing here was run against Things Cloud or RemCTL. Open points: what
  RemCTL's explicit `alarm` does to other alarms (so it is only sent for a reminder with none), and how Reminders
  shows an all-day reminder with an alert once Things moves it to another day.

## 2026-11-09: v0.1.0, first public release

- Tag `v0.1.0`; the asset is `ThingsRemindersSync-0.1.0.zip`, with SHA-256
  `a5084112fb06b1f4817bd98a30131f7e5ab7d1fbdcad7edd1f2c9ac0ea895830`.
- Signed with `Developer ID Application: Oliver Ames (84M4ZF255G)`.
  Notarized with the Ames Consulting App Store Connect API key, and Apple
  accepted it (submission `ae786363-f8ab-4b83-82e0-6e3eb28badb1`). Built with
  `scripts/release.sh`.
- Verified the published asset itself: the downloaded zip passes
  `spctl --assess` as "Notarized Developer ID", `stapler validate` succeeds,
  the version reads 0.1.0, and the release checksum matches the local one.
- The always-on Mac now runs the released build, which is signed by
  84M4ZF255G, and `build-app.sh` defaults to that identity, so later deploys
  keep the same signature. Changing the signing team invalidates the Keychain
  item's access list. An SSH session can't write to the login Keychain, so the
  item was re-added from the GUI session with a one-shot LaunchAgent that runs
  `security add-generic-password -T <app>`, with the password passed in a
  temporary file that is deleted afterwards. After that, the app read the item
  with no prompt and synced a title change.
