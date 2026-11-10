import Foundation

enum ThingsEntity {
    static let task = "Task6"
    static let area = "Area3"
    static let tag = "Tag4"
    static let checklistItem = "ChecklistItem3"
}

// MARK: - Calendar days

enum ThingsDates {
    private static func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// `YYYY-MM-DD` -> unix seconds at midnight UTC (the form Things stores for `sr`, `tir`, `dd`).
    static func timestamp(forDay day: String) throws -> Double {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            throw ThingsCloudError.invalidChange(["invalid date \"\(day)\", use YYYY-MM-DD"])
        }
        let cal = calendar(TimeZone(identifier: "UTC")!)
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
              cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d) else {
            throw ThingsCloudError.invalidChange(["invalid date \"\(day)\""])
        }
        return date.timeIntervalSince1970
    }

    /// Unix seconds -> `YYYY-MM-DD` in UTC.
    static func day(fromTimestamp ts: Double) -> String {
        format(Date(timeIntervalSince1970: ts), in: TimeZone(identifier: "UTC")!)
    }

    static func today(in zone: TimeZone, now: Date) -> String { format(now, in: zone) }

    private static func format(_ date: Date, in zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Change builders (the wire format lives here and only here)

enum ThingsChanges {
    static func noteObject(_ text: String) -> JSONValue {
        .object(["_t": "tx", "t": 1, "ch": .number(text.isEmpty ? 0 : Double(ThingsCRC32.checksum(text))), "v": .string(text)])
    }

    static let emptyXX: JSONValue = .object(["sn": .object([:]), "_t": "oo"])

    static func idArray(_ ids: [String]) -> JSONValue { .array(ids.map { .string($0) }) }

    static func number(_ d: Double?) -> JSONValue { d.map { .number($0) } ?? .null }

    /// Scheduling fields for a "When". `nil` is Anytime. A day today or earlier is `st 1`, a later day is
    /// `st 2`; `sr` and `tir` carry the day, `ato` the reminder (minutes * 60) or null.
    static func scheduling(_ when: DueDate?, today: String) throws -> [String: JSONValue] {
        guard let when else {
            return ["st": 1, "sb": 0, "sr": nil, "tir": nil, "ato": nil]
        }
        let ts = try ThingsDates.timestamp(forDay: when.day)
        var ato: JSONValue = nil
        if let minutes = when.minutes {
            guard (0..<1440).contains(minutes) else {
                throw ThingsCloudError.invalidChange(["reminder minutes \(minutes) is outside 0..<1440"])
            }
            ato = .number(Double(minutes * 60))
        }
        return ["st": .number(when.day > today ? 2 : 1), "sb": 0, "sr": .number(ts), "tir": .number(ts), "ato": ato]
    }

    /// Scheduling keys for an UPDATE of an existing to-do: only what the new "When" changes.
    /// - Same day, another time: `ato` alone. The start state is untouched, so a to-do stays in This Evening.
    /// - Another day, or no day: `st`, `sr`, `tir`, `ato`; and `sb 0` only when the to-do is in This Evening now
    ///   (This Evening belongs to today's date, so it ends when the day changes). `sb` is never written otherwise.
    static func schedulingUpdate(_ when: DueDate?, today: String, current: ThingsTask) throws -> [String: JSONValue] {
        var keys = try scheduling(when, today: today)
        keys["sb"] = nil
        if when?.day == current.startDate { return ["ato": keys["ato"] ?? .null] }
        if current.evening { keys["sb"] = 0 }
        return keys
    }

    static let inboxScheduling: [String: JSONValue] = ["st": 0, "sb": 0, "sr": nil, "tir": nil, "ato": nil]

    /// Someday with no date, as the JavaScript client writes `when: "someday"`: `st` 2 with `sr` and `tir` null.
    static let somedayScheduling: [String: JSONValue] = ["st": 2, "sb": 0, "sr": nil, "tir": nil, "ato": nil]

    /// Container keys for a placement. A to-do in a project carries no area.
    static func containers(_ placement: ThingsPlacement) -> [String: JSONValue] {
        switch placement {
        case .inbox: return ["pr": [], "agr": [], "ar": []]
        case let .project(id): return ["pr": idArray([id]), "agr": [], "ar": []]
        case let .area(id): return ["pr": [], "agr": [], "ar": idArray([id])]
        // A to-do in a heading belongs to its project through the heading.
        case let .heading(id): return ["pr": [], "agr": idArray([id]), "ar": []]
        }
    }

    /// Full `Task6` create payload with every key the Mac app writes.
    static func taskCreate(title: String, notes: String, type: Int, scheduling: [String: JSONValue],
                           containers: [String: JSONValue], tags: [String], completed: Bool,
                           completionDate: Date?, now: Date, extra: [String: JSONValue] = [:]) -> ThingsChange {
        let nowTs = now.timeIntervalSince1970
        var sp: Double?
        if completed {
            sp = nowTs
            if let completionDate, completionDate.timeIntervalSince1970 <= nowTs { sp = completionDate.timeIntervalSince1970 }
        }
        var p: [String: JSONValue] = [
            "tt": .string(title), "nt": noteObject(notes), "tp": .number(Double(type)),
            "ss": completed ? 3 : 0, "sp": number(sp), "tr": false,
            "dd": nil, "tg": idArray(tags), "ix": 0, "ti": 0, "cd": .number(nowTs), "md": .number(nowTs),
            // Defaults Things writes on every new task.
            "dds": nil, "rt": [], "rmd": nil, "dl": [], "icp": false, "do": 0, "lai": nil, "lt": false,
            "icc": 0, "icsd": nil, "rp": nil, "acrd": nil, "rr": nil, "xx": emptyXX,
        ]
        p.merge(scheduling) { $1 }
        p.merge(containers) { $1 }
        p.merge(extra) { $1 }
        return ThingsChange(t: 0, e: ThingsEntity.task, p: p)
    }

    /// Scheduling keys of a repeating template: `st 2`, `sr` null, `tir` and `icsd` the first occurrence day, `ato`
    /// the reminder time. Things generates the occurrences itself when `icsd` arrives.
    static func templateScheduling(_ first: DueDate) throws -> [String: JSONValue] {
        let ts = try ThingsDates.timestamp(forDay: first.day)
        var ato: JSONValue = nil
        if let minutes = first.minutes {
            guard (0..<1440).contains(minutes) else {
                throw ThingsCloudError.invalidChange(["reminder minutes \(minutes) is outside 0..<1440"])
            }
            ato = .number(Double(minutes * 60))
        }
        return ["st": 2, "sb": 0, "sr": nil, "tir": .number(ts), "icsd": .number(ts), "ato": ato]
    }

    /// A checklist item of a template being stopped: its id, the id of its copy, and what the copy carries over.
    struct StopChecklistItem { var id: String; var newId: String; var title: String; var status: Int; var stopDate: Double? }

    /// The entries Things 3.24.2 wrote for Items > Repeat > Stop (docs/RECURRENCE.md), as one change map: a plain
    /// to-do for the template's next day (`sr` = `tir` = that day, `st` 2, `lt` true, `md` null), `rt []` and nothing
    /// else on each open occurrence, and a tombstone for the template. Title, notes, tags and container are the
    /// template's. Each checklist item of the template (`checklist`, in order) is created again for the new to-do
    /// (`lt` true, `md` null, `cd` the new to-do's, `ix` 0, 1, ..., `ss` and `sp` the item's own) and the template's
    /// own item is tombstoned.
    static func stopRepeating(templateId: String, template: ThingsTask, tags: [String], openOccurrences: [String],
                              checklist: [StopChecklistItem] = [], newId: String, now: Date) throws -> ThingsChangeMap {
        guard let day = template.nextDay else {
            throw ThingsCloudError.invalidChange(["repeating to-do \(templateId) has no next day, so there is nothing to continue as a plain to-do"])
        }
        let ts = JSONValue.number(try ThingsDates.timestamp(forDay: day))
        func ids(_ id: String?) -> JSONValue { idArray(id.map { [$0] } ?? []) }
        let plain = taskCreate(
            title: template.title, notes: template.notes, type: 0,
            scheduling: ["st": 2, "sb": 0, "sr": ts, "tir": ts, "ato": nil],
            containers: ["pr": ids(template.projectId), "agr": ids(template.headingId), "ar": ids(template.areaId)],
            tags: tags, completed: false, completionDate: nil, now: now, extra: ["lt": true, "md": nil])
        var map: ThingsChangeMap = [newId: plain, templateId: ThingsChange(t: 2, e: ThingsEntity.task, p: [:])]
        for id in openOccurrences { map[id] = ThingsChange(t: 1, e: ThingsEntity.task, p: ["rt": []]) }
        for (i, item) in checklist.enumerated() {
            map[item.newId] = ThingsChange(t: 0, e: ThingsEntity.checklistItem, p: [
                "ix": .number(Double(i)), "cd": .number(now.timeIntervalSince1970), "ts": idArray([newId]), "sp": number(item.stopDate),
                "ss": .number(Double(item.status)), "xx": emptyXX, "tt": .string(item.title), "md": nil, "lt": true,
            ])
            map[item.id] = checklistDelete()
        }
        return map
    }

    /// `ChecklistItem3` exactly as Things 3.24.2 writes one (docs/SPEC.md): `ts` is the parent task, items sort by `ix`.
    /// Completion is `ss` 3 with `sp`, like a to-do.
    static func checklistCreate(taskId: String, title: String, completed: Bool, index: Double, now: Date) -> ThingsChange {
        let nowTs = now.timeIntervalSince1970
        return ThingsChange(t: 0, e: ThingsEntity.checklistItem, p: [
            "tt": .string(title), "ss": completed ? 3 : 0, "sp": completed ? .number(nowTs) : .null, "ix": .number(index),
            "ts": idArray([taskId]), "lt": false, "cd": .number(nowTs), "md": .number(nowTs), "xx": emptyXX,
        ])
    }

    static func checklistUpdate(_ p: [String: JSONValue], now: Date) -> ThingsChange {
        var p = p
        p["md"] = .number(now.timeIntervalSince1970)
        return ThingsChange(t: 1, e: ThingsEntity.checklistItem, p: p)
    }

    static func checklistDelete() -> ThingsChange { ThingsChange(t: 2, e: ThingsEntity.checklistItem, p: [:]) }

    static func areaCreate(title: String) -> ThingsChange {
        ThingsChange(t: 0, e: ThingsEntity.area, p: ["tt": .string(title), "tg": [], "ix": 0, "xx": emptyXX])
    }

    static func tagCreate(title: String, parentId: String?) -> ThingsChange {
        ThingsChange(t: 0, e: ThingsEntity.tag, p: [
            "tt": .string(title), "sh": nil, "pn": idArray(parentId.map { [$0] } ?? []), "ix": 0, "xx": emptyXX,
        ])
    }
}
