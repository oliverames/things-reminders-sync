# Recurrence formats (verified 2026-11-09)

Every shape below was produced by the real apps, not inferred: the Things rules by Things 3.24.2 on
macOS 27.3 (set through its Repeat sheet and read back from Things Cloud history), the Reminders
rules by RemCTL 2.5.0 (`remctl add --recurrence ...`, read back with `remctl export --json`). Only
write Things rules whose shape appears here. A malformed Things write can crash the Mac app's sync
(see the 2026-11-09 base58 incident in things3-mcp-server's WORKLOG).

## Things (`rr` on a hidden template to-do)

All samples used a start of Mon 2026-11-09 (`1794182400` = midnight UTC).

| Sample | `rr` |
|---|---|
| Every day | `{"fu":16,"fa":1,"of":[{"dy":0}],"tp":0,"ia":1794182400,"sr":1794182400,"rc":0,"ts":0,"rrv":4,"ed":64092211200}` |
| Every 3 days | same with `"fa":3` |
| Weekly on Monday | `{"fu":256,"fa":1,"of":[{"wd":1}], ...}` |
| Every 2 weeks, Mon and Thu | `{"fu":256,"fa":2,"of":[{"wd":1},{"wd":4}], ...}` |
| Weekdays | `{"fu":256,"fa":1,"of":[{"wd":1},{"wd":2},{"wd":3},{"wd":4},{"wd":5}], ...}` |
| Monthly on the 15th | `{"fu":8,"fa":1,"of":[{"dy":14}], ...}` |
| Monthly on the 1st and 15th | `{"fu":8,"fa":1,"of":[{"dy":0},{"dy":14}], ...}` |
| Monthly, 2nd Tuesday | `{"fu":8,"fa":1,"of":[{"wdo":2,"wd":2}], ...}` |
| Monthly, last Friday | `{"fu":8,"fa":1,"of":[{"wdo":-1,"wd":5}], ...}` |
| Monthly, last day | `{"fu":8,"fa":1,"of":[{"dy":-1}], ...}` |
| Yearly on November 20 | `{"fu":4,"fa":1,"of":[{"dy":19,"mo":10}], ...}` |
| Yearly, 4th Thursday of November | `{"fu":4,"fa":1,"of":[{"wdo":4,"mo":10,"wd":4}], ...}` |
| After completion, every 4 days | `{"fu":16,"fa":4,"of":[],"tp":1,"ia":0,"sr":1794182400,"rc":0,"ts":0,"rrv":4,"ed":64092211200}` |
| Daily, ends after 5 times | `{"fu":16,"fa":1,"of":[{"dy":0}],"tp":0,"ia":1794182400,"sr":1794182400,"rc":5,"ts":0,"rrv":4}` (no `ed`) |
| Daily until 2026-12-31 | `... "rc":0, "ed":1798675200` (end date at midnight UTC) |

Field meanings:

- `fu` unit: 16 day, 256 week, 8 month, 4 year (NSCalendarUnit values). `fa` every N units.
- `of` offsets. `dy` day index: 0 for daily; 0-based day of month for monthly/yearly (`-1` = last
  day). `wd` weekday 0 Sunday … 6 Saturday. `wdo` ordinal of that weekday in the month (1-5, `-1` =
  last). `mo` 0-based month for yearly. `[]` for after-completion.
- `tp` 0 fixed schedule, 1 after completion (`ia` is then 0). `ia` anchor and `sr` start: midnight UTC.
- End: never = `ed` 64092211200 with `rc` 0; after N times = `rc` N and no `ed`; on a date = `ed` that
  date's midnight UTC with `rc` 0. `ts` was 0 in every sample. `rrv` 4.

### Template and occurrences

Setting a repeat makes a NEW hidden template task (new id) holding the rule; the original to-do
becomes the first occurrence (its `rt` = `[templateId]`, `sr`/`tir` = the occurrence day) or, when
the first date is in the future, is deleted. Template fields observed (Things 3.24 wrote `Task7`):

- `rr` the rule, `st` 2, `sr` null, `tir` = next occurrence day, `icsd` = next instance-creation day,
  `icc` = number of instances created so far (0 when none yet), `ato` = reminder seconds (9:00 =
  32400) when "Add reminders" is on, `dd` = 64092211200 when "Add deadlines" is on, plus the usual
  to-do keys (`tt`, `nt`, `pr`/`ar`/`agr`, `tg`, `ix`, `cd`, `md`, ...).
- Occurrences are ordinary to-dos with `rt` = `[templateId]`. Things apps generate each occurrence
  themselves when `icsd` arrives (a template with `icc` 0 and a future `icsd` got its first occurrence
  only when that day came). A sync therefore writes templates only and never fabricates occurrences.

### Edits to an existing repeat (Things 3.24.2 Mac app, 2026-11-09, history indexes 1688 to 1700)

Each change was made in the Mac app and read back from Things Cloud history. `1794182400` is 2026-11-09,
`1794268800` is 2026-11-10. Things wrote entity `Task7`; this app writes `Task6` for every task change, as it
always has (docs/SPEC.md).

**To-do made repeating** (Items > Repeat, daily, OK, on 2026-11-09; the to-do had no date). The to-do becomes
today's occurrence and a new template is created:

    7FxH2V7SdsAwEvq59evaxb {"t":1,"e":"Task7","p":{"tir":1794182400,"md":1794274843.075597,"rt":["LFwb2zkVA7nCqRm1BMEfkk"],"sr":1794182400}}
    LFwb2zkVA7nCqRm1BMEfkk {"t":0,"e":"Task7","p":{"sr":null,"rt":[],"ss":0,"tr":false,"st":2,"tt":"Repeat edit sample","tir":1794268800,"icc":1,"icsd":1794268800,"md":1794274843.07671,"rr":{"of":[{"dy":0}],"rrv":4,"tp":0,"ts":0,"fu":16,"ia":1794182400,"fa":1,"sr":1794182400,"rc":0,"ed":64092211200}, ...}}

The app reads this (the link moves to the template) and never writes it: it creates templates only.

**Rule edited** (Items > Repeat > Edit Rule, daily changed to weekly, OK; the sheet set the weekday to the
template's next day, Tuesday 2026-11-10). Only the template is written, and only `md` and `rr`:

    LFwb2zkVA7nCqRm1BMEfkk {"t":1,"e":"Task7","p":{"md":1794274921.023453,"rr":{"of":[{"wd":2}],"rrv":4,"tp":0,"ts":0,"fu":256,"ia":1794268800,"fa":1,"sr":1794182400,"rc":0,"ed":64092211200}}}

`rr.sr` kept the old rule's `sr` (2026-11-09). `rr.ia` became the template's current `tir` (2026-11-10).
`tir`, `icsd` and `icc` were not written, because the next day did not change. The app writes exactly this when
a reminder's rule changes and its date does not: `md` and `rr`, with the old `sr` and `ia` set to the template's
`tir`. An edit that moves the next day was not sampled. When a rule change and a new next day arrive together
the app writes `md`, `rr`, `tir`, `icsd` and `ato`, and keeps the old `ia`. That is the app's own choice, not a
sampled shape. An old rule that repeats after completion has no `ia` to keep, so the new rule's `ia` and `sr`
are the template's next day; that is also the app's own choice.

**Paused and resumed** (Items > Repeat > Pause, then Resume):

    LFwb2zkVA7nCqRm1BMEfkk {"t":1,"e":"Task7","p":{"icp":true,"md":1794274947.122859}}
    LFwb2zkVA7nCqRm1BMEfkk {"t":1,"e":"Task7","p":{"icp":false,"md":1794274971.49046}}

A paused template is still a template: the app keeps the pair linked and the reminder keeps its rule. The app
never writes `icp` on an existing task.

**Stopped** (Items > Repeat > Stop, confirmed with "Stop It"). One commit with three entries: a new plain to-do
for the next day, the open occurrence detached with no `md`, and the template deleted for good:

    BZyaBocoogxB7WEcbQT7r {"t":0,"e":"Task7","p":{"tp":0,"sr":1794268800,"dds":null,"rt":[],"rmd":null,"ss":0,"tr":false,"dl":[],"icp":false,"st":2,"ar":[],"tt":"Repeat edit sample","do":0,"lai":null,"tir":1794268800,"tg":[],"agr":[],"ix":0,"cd":1794274999.166278,"lt":true,"icc":0,"ti":0,"md":null,"dd":null,"ato":null,"nt":{"_t":"tx","ch":0,"v":"","t":1},"icsd":null,"pr":["XN4eGArARmEF2vzS84p12i"],"rp":null,"acrd":null,"sp":null,"sb":0,"rr":null,"xx":{"sn":{},"_t":"oo"}}}
    7FxH2V7SdsAwEvq59evaxb {"t":1,"e":"Task7","p":{"rt":[]}}
    LFwb2zkVA7nCqRm1BMEfkk {"t":2,"e":"Task7","p":{}}

The app writes this commit (`ThingsCloudClient.stopRepeating`) when the reminder of a template pair loses its
repeat: the same 34 keys on the create, with `lt` true, `md` null, `icsd` null, `rr` null, `ato` null, `st` 2
and `sr` = `tir` = the template's next day; `{"rt":[]}` and nothing else on every open, untrashed occurrence;
and the tombstone. Title, `pr`, `agr` and `ar` are copied from the template. The sampled template had no notes
and no tags, so the sample shows `nt` empty and `tg` `[]`; the app writes the template's own notes and tags
there, which gives the sampled values for a template that has none. Whether Things itself carries notes, tags,
a reminder time or checklist items over to the plain to-do was not sampled. The app leaves `ato` null as
sampled and writes no checklist items in this commit; the reminder's time and subtasks reach the new to-do
afterwards as ordinary updates. The validator needed no change for these entries.

Which to-do the reminder is linked to afterwards depends on the open, untrashed occurrences the template had
when it was stopped. The Stop commit itself is the same in every case.

- None: the reminder is linked to the new plain to-do for the next day.
- One: the reminder is linked to that occurrence, which the commit detached. It is the item the person was
  looking at. The new next-day to-do is then moved to the Trash with the ordinary trash update (`tr` true), so
  Things does not show the item twice. The reminder's date and other fields reach the occurrence as ordinary
  updates in the same pass or the next.
- Two or more: the reminder is linked to the occurrence whose start day is the reminder's due day when exactly
  one matches, otherwise to the earliest. The new next-day to-do is trashed as above. The other occurrences
  stay in Things as plain to-dos and are not linked. They are ordinary unlinked to-dos of the list from then on,
  so the next pass gives each its own reminder, as it does when Stop is done in Things.

The trashed to-do never gets a reminder, because trashed to-dos are outside every list. If the trash write
fails, the pass reports the failure, the to-do stays in Things, and the app marks it so that it is never copied
to Reminders. The trash write is not retried. Stop followed by a trash of the new to-do was not sampled as one
action in Things; each of the two writes was.

## Reminders (RemCTL `recurrence` in `export --json`)

All samples had due 2026-11-10 (all-day).

| RemCTL `--recurrence` | Exported `recurrence` |
|---|---|
| `daily` | `{"frequency":"daily","interval":1}` |
| `daily x3` | `{"frequency":"daily","interval":3}` |
| `weekly` | `{"frequency":"weekly","interval":1}` (weekday taken from the due date) |
| `weekly x2 mon,thu` | `{"frequency":"weekly","interval":2,"daysOfWeek":[2,5],"daysOfWeekDetailed":[{"weekNumber":0,"dayOfTheWeek":2},{"weekNumber":0,"dayOfTheWeek":5}]}` |
| `weekly mon,tue,wed,thu,fri` | `daysOfWeek` `[2,3,4,5,6]` |
| `monthly 15` | `{"frequency":"monthly","interval":1,"daysOfMonth":[15]}` |
| `monthly 1,15` | `"daysOfMonth":[1,15]` |
| `monthly 2nd-tue` | `"daysOfWeekDetailed":[{"dayOfTheWeek":3,"weekNumber":2}],"daysOfWeek":[3]` |
| `monthly last-fri` | `"daysOfWeekDetailed":[{"dayOfTheWeek":6,"weekNumber":-1}]` |
| `yearly` | `{"frequency":"yearly","interval":1}` (date taken from the due date) |

- EventKit weekdays are 1 Sunday … 7 Saturday (Things is 0 … 6). Days of month are 1-based (Things
  `dy` is 0-based).
- RemCTL cannot write "last day of the month" (`monthly -1` is rejected) and has no after-completion
  repeat; Reminders itself has no after-completion repeat. End conditions and yearly nth-weekday
  rules were not sampled from RemCTL.
- Completing a repeating reminder advances the same reminder (same id) to its next occurrence.

## RemCTL write forms and live findings (2026-11-09, RemCTL 2.5.0)

- `--recurrence` (CLI) and `recurrence` (MCP `create_reminder` / `update_reminder`) accept the grammar above AND a
  JSON object in the export shape (`frequency`, `interval`, `daysOfWeek` EventKit 1-7, `daysOfWeekDetailed`,
  `daysOfMonth`, `monthsOfYear`, `count`, `endDate`). The object form writes what the grammar cannot: `{"daysOfMonth":[-1],...}`
  (last day of month), `"endDate":"2026-12-31"` (exports as `"endDate":"2026-12-31T00:00:00"`), `"count":5`
  (exports as `"count":5`), and yearly nth weekday (`daysOfWeekDetailed` + `monthsOfYear` [11]).
  `monthly 5th-fri` and `monthly -1-fri` also work. Unknown keys make the whole value unparseable.
- `count` is the number of occurrences REMAINING: every completion advances the due date and decrements it (5 to 4 to 3).
  The app therefore compares rules with the count masked (`RepeatRule.key`).
- `edit --recurrence clear` (or `none`) removes the repeat; setting a plain rule drops a previous end condition.
  The MCP `update_reminder` accepts `"recurrence": "clear"` too.
- `weekly` / `yearly` without days take the weekday / date from the due date; the app always writes weekdays explicitly
  and only writes a bare `yearly` when the due date is the rule's date.
