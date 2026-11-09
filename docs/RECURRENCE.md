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
