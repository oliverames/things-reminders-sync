import Foundation

/// In-memory Things database built from history change maps.
struct ThingsDatabase: Sendable {
    struct Row: Sendable {
        var task: ThingsTask
        var hasRule = false
        var hasTemplates = false
        /// The raw `rr` of a template, kept so a rule rewrite can preserve its anchors.
        var rawRule: JSONValue?
    }

    var tasks: [String: Row] = [:]
    var areas: [String: ThingsArea] = [:]
    var tags: [String: ThingsTag] = [:]
    /// Checklist items by their own id, with the parent task id (`ts`).
    struct ChecklistRow: Sendable { var taskId: String?; var item: ThingsChecklistItem }
    var checklistItems: [String: ChecklistRow] = [:]
    var latestServerIndex = 0

    var snapshot: ThingsSnapshot {
        var byTask: [String: [ThingsChecklistItem]] = [:]
        for row in checklistItems.values { if let t = row.taskId { byTask[t, default: []].append(row.item) } }
        return ThingsSnapshot(tasks: tasks.mapValues { row in
            var task = row.task
            if let items = byTask[task.id] { task.checklist = items.sorted { ($0.index, $0.id) < ($1.index, $1.id) } }
            return task
        }, areas: areas, tags: tags)
    }

    /// Applies one history item. Returns the task ids it touched.
    @discardableResult
    mutating func apply(_ map: ThingsChangeMap) -> Set<String> {
        var touched = Set<String>()
        for (id, change) in map {
            if change.t == 2 {
                if tasks.removeValue(forKey: id) != nil { touched.insert(id) }
                if let parent = checklistItems[id]?.taskId { touched.insert(parent) }   // a removed checklist item changes its to-do
                areas.removeValue(forKey: id)
                tags.removeValue(forKey: id)
                checklistItems.removeValue(forKey: id)
                continue
            }
            let p = change.p
            if change.e.hasPrefix("Task") {
                // Create replaces; update merges.
                let before = change.t == 0 ? nil : tasks[id]
                var row = before ?? Row(task: ThingsTask(id: id, title: "", start: .anytime))
                Self.mergeTask(&row, p)
                Self.stampFields(&row, before: before)
                tasks[id] = row
                touched.insert(id)
            } else if change.e.hasPrefix("ChecklistItem") {
                var row = change.t == 0 ? ChecklistRow(taskId: nil, item: ThingsChecklistItem(id: id, title: "")) : (checklistItems[id] ?? ChecklistRow(taskId: nil, item: ThingsChecklistItem(id: id, title: "")))
                if let v = p["tt"] { row.item.title = v.string ?? "" }
                if let v = p["ss"] { row.item.completed = (v.int ?? 0) != 0 }
                if let v = p["ix"] { row.item.index = v.double ?? 0 }
                if let v = p["ts"] { row.taskId = v.array?.first?.string }
                checklistItems[id] = row
                // A checklist change is a change of its to-do: without this a checked item waits for the full reconcile.
                if let parent = row.taskId {
                    touched.insert(parent)
                    // The item's `md` is the checklist's time (a removal carries none, so it leaves the time alone).
                    if let md = p["md"]?.double, tasks[parent] != nil {
                        tasks[parent]!.task.fieldModified = (tasks[parent]!.task.fieldModified ?? [:])
                            .merging([SyncField.checklist.rawValue: Date(timeIntervalSince1970: md)]) { $1 }
                    }
                }
            } else if change.e.hasPrefix("Area") {
                var area = change.t == 0 ? ThingsArea(id: id, title: "") : (areas[id] ?? ThingsArea(id: id, title: ""))
                if let tt = p["tt"] { area.title = tt.string ?? "" }
                if let tg = p["tg"] { area.tagIds = (tg.array ?? []).compactMap(\.string) }
                areas[id] = area
            } else if change.e.hasPrefix("Tag") {
                var tag = change.t == 0 ? ThingsTag(id: id, title: "") : (tags[id] ?? ThingsTag(id: id, title: ""))
                if let tt = p["tt"] { tag.title = tt.string ?? "" }
                if let pn = p["pn"] { tag.parentId = pn.array?.first?.string }
                tags[id] = tag
            }
        }
        return touched
    }

    static func mergeTask(_ row: inout Row, _ p: [String: JSONValue]) {
        func day(_ v: JSONValue) -> String? { v.double.map(ThingsDates.day(fromTimestamp:)) }
        func date(_ v: JSONValue) -> Date? { v.double.map { Date(timeIntervalSince1970: $0) } }
        func firstId(_ v: JSONValue) -> String? { v.array?.first?.string }

        if let v = p["tt"] { row.task.title = v.string ?? "" }
        if let v = p["nt"] { row.task.notes = mergeNotes(row.task.notes, v) }
        if let v = p["tp"] { row.task.kind = v.int.flatMap(ThingsTaskKind.init(rawValue:)) ?? .todo }
        if let v = p["ss"] { row.task.status = v.int.flatMap(ThingsStatus.init(rawValue:)) ?? .open }
        if let v = p["tr"] { row.task.trashed = v.flag }
        if let v = p["st"] { row.task.start = v.int.flatMap(ThingsStart.init(rawValue:)) ?? .anytime }
        if let v = p["sb"] { row.task.evening = v.int == 1 }
        if let v = p["sr"] { row.task.startDate = day(v) }
        if let v = p["ato"] { row.task.reminderSeconds = v.int }
        if let v = p["dd"] { row.task.deadline = day(v) }
        if let v = p["pr"] { row.task.projectId = firstId(v) }
        if let v = p["agr"] { row.task.headingId = firstId(v) }
        if let v = p["ar"] { row.task.areaId = firstId(v) }
        if let v = p["tg"] { row.task.tagIds = (v.array ?? []).compactMap(\.string) }
        if let v = p["cd"] { row.task.creationDate = date(v) }
        if let v = p["md"] { row.task.modificationDate = date(v) }
        if let v = p["sp"] { row.task.stopDate = date(v) }
        if let v = p["rr"] {
            row.hasRule = !v.isNull
            row.rawRule = v.isNull ? nil : v
            row.task.recurrence = v.isNull ? nil : ThingsRepeat.rule(from: v)
        }
        if let v = p["rt"] {
            row.hasTemplates = !(v.array ?? []).isEmpty
            row.task.templateId = firstId(v)
        }
        if let v = p["tir"] { row.task.nextDay = day(v) }
        if let v = p["icsd"] { row.task.instanceDay = day(v) }
        if let v = p["icc"] { row.task.instancesCreated = v.int }
        row.task.isRepeating = row.hasRule || row.hasTemplates
    }

    /// The synced fields a to-do's own history items can change (the checklist is stamped from its items).
    static let taskFields: [SyncField] = [.title, .notes, .due, .completion, .placement, .tags, .rule]

    /// Records, per field, the `md` of the history item that last changed its value. `row` is the task after the item
    /// was merged, `before` the task as it was (nil for a create, which stamps every field). A key an item repeats
    /// with the value the task already had is not a change. An item without `md` counts as the last known `md`.
    static func stampFields(_ row: inout Row, before: Row?) {
        let after = row.task
        guard let before else {
            guard let stamp = after.modificationDate ?? after.creationDate else { return }
            row.task.fieldModified = Dictionary(uniqueKeysWithValues: taskFields.map { ($0.rawValue, stamp) })
            return
        }
        let old = before.task
        var map = after.fieldModified ?? [:]
        // A task without times yet (its create was not in the history read): every field is as old as the task was.
        if let seed = old.modificationDate ?? old.creationDate {
            for field in taskFields where map[field.rawValue] == nil { map[field.rawValue] = seed }
        }
        if let stamp = after.modificationDate {
            func changed(_ field: SyncField) -> Bool {
                switch field {
                case .title: return old.title != after.title
                case .notes: return old.notes != after.notes
                // A template's due is its next day (`tir`) until Things has made an occurrence.
                case .due: return old.due != after.due || old.nextDay != after.nextDay || old.reminderSeconds != after.reminderSeconds
                case .completion: return old.status != after.status || old.stopDate != after.stopDate
                case .placement: return old.projectId != after.projectId || old.headingId != after.headingId || old.areaId != after.areaId
                case .tags: return old.tagIds != after.tagIds
                case .rule: return before.rawRule != row.rawRule || before.hasTemplates != row.hasTemplates
                case .flagged, .url, .checklist: return false
                }
            }
            for field in taskFields where changed(field) { map[field.rawValue] = stamp }
        }
        row.task.fieldModified = map.isEmpty ? nil : map
    }

    /// `nt` is `{_t:"tx", t:1, v:text}` (full text) or `{t:2, ps:[{p,l,r}]}` (patches against the old text).
    static func mergeNotes(_ existing: String, _ nt: JSONValue) -> String {
        if let v = nt["v"]?.string { return v }
        if let ps = nt["ps"]?.array { return applyNotePatches(existing, ps) }
        return existing
    }

    /// Patches address UTF-16 code units, like the JS string the client was verified with.
    static func applyNotePatches(_ text: String, _ patches: [JSONValue]) -> String {
        var units = Array(text.utf16)
        for patch in patches {
            let start = min(max(patch["p"]?.int ?? 0, 0), units.count)
            let length = max(patch["l"]?.int ?? 0, 0)
            let end = min(start + length, units.count)
            let replacement = Array((patch["r"]?.string ?? "").utf16)
            units.replaceSubrange(start..<end, with: replacement)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

extension ThingsChange {
    /// Decodes one history item (`{uuid: {t, e, p}}`). Entries that are not objects are skipped.
    static func parseMap(_ value: JSONValue) throws -> ThingsChangeMap {
        guard let object = value.object else { throw ThingsCloudError.decoding("history item is not an object") }
        var map: ThingsChangeMap = [:]
        for (id, entry) in object {
            guard let entry = entry.object else { continue }
            map[id] = ThingsChange(t: entry["t"]?.int ?? 1, e: entry["e"]?.string ?? "", p: entry["p"]?.object ?? [:])
        }
        return map
    }
}
