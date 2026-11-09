# Worklog

## 2026-11-09: audit fixes (uncommitted when written)

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
