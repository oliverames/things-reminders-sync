import Foundation

/// In-memory Things database built from history change maps.
struct ThingsDatabase: Sendable {
    struct Row: Sendable {
        var task: ThingsTask
        var hasRule = false
        var hasTemplates = false
    }

    var tasks: [String: Row] = [:]
    var areas: [String: ThingsArea] = [:]
    var tags: [String: ThingsTag] = [:]
    var latestServerIndex = 0

    var snapshot: ThingsSnapshot {
        ThingsSnapshot(tasks: tasks.mapValues(\.task), areas: areas, tags: tags)
    }

    /// Applies one history item. Returns the task ids it touched.
    @discardableResult
    mutating func apply(_ map: ThingsChangeMap) -> Set<String> {
        var touched = Set<String>()
        for (id, change) in map {
            if change.t == 2 {
                if tasks.removeValue(forKey: id) != nil { touched.insert(id) }
                areas.removeValue(forKey: id)
                tags.removeValue(forKey: id)
                continue
            }
            let p = change.p
            if change.e.hasPrefix("Task") {
                // Create replaces; update merges.
                var row = change.t == 0 ? Row(task: ThingsTask(id: id, title: "", start: .anytime)) : (tasks[id] ?? Row(task: ThingsTask(id: id, title: "", start: .anytime)))
                Self.mergeTask(&row, p)
                tasks[id] = row
                touched.insert(id)
            } else if change.e.hasPrefix("Area") {
                var area = change.t == 0 ? ThingsArea(id: id, title: "") : (areas[id] ?? ThingsArea(id: id, title: ""))
                if let tt = p["tt"] { area.title = tt.string ?? "" }
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
        if let v = p["rr"] { row.hasRule = !v.isNull }
        if let v = p["rt"] { row.hasTemplates = !(v.array ?? []).isEmpty }
        row.task.isRepeating = row.hasRule || row.hasTemplates
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
