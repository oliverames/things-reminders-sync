import Foundation

/// Things Cloud client and in-memory database: a Swift port of the live-verified JavaScript client.
public actor ThingsCloudClient: ThingsBackend {
    private let email: String
    private let timeZone: TimeZone
    private let transport: ThingsCloudTransport
    private let now: @Sendable () -> Date
    private var historyKey: String?
    private var database: ThingsDatabase?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Task ids pulled by a refresh the client ran for its own writes, kept for the next `refresh()` so the caller
    /// that polls for changes still hears about them.
    private var carriedChanges = Set<String>()
    private var carriedReload = false

    public init(email: String, password: String, timeZone: TimeZone = .current, session: URLSession = .shared) {
        self.init(email: email, password: password, timeZone: timeZone, now: { Date() },
                  handler: ThingsCloudTransport.urlSessionHandler(session))
    }

    /// Test seam: inject the HTTP layer and the clock, and optionally a known history key.
    init(email: String, password: String, timeZone: TimeZone = .current, historyKey: String? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, handler: @escaping ThingsRequestHandler) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.timeZone = timeZone
        self.transport = ThingsCloudTransport(password: password, handler: handler)
        self.now = now
        self.historyKey = historyKey
    }

    /// Checks the credentials and returns the account's history key. Throws `.invalidCredentials` on 401.
    public static func verify(email: String, password: String, session: URLSession = .shared) async throws -> String {
        let transport = ThingsCloudTransport(password: password, handler: ThingsCloudTransport.urlSessionHandler(session))
        return try await transport.historyKey(email: email)
    }

    // MARK: Serialization of operations (the poll loop and a sync pass must not interleave)

    private func withLock<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: History

    private func ensureHistoryKey() async throws -> String {
        if let historyKey { return historyKey }
        let key = try await transport.historyKey(email: email)
        historyKey = key
        return key
    }

    private func fetchHead() async throws -> Int {
        let key = try await ensureHistoryKey()
        let (data, _) = try await transport.send("GET", "\(ThingsCloudTransport.base)/version/1/history/\(key)")
        return try JSONValue.parse(data)["latest-server-index"]?.int ?? 0
    }

    public func refresh() async throws -> ThingsRefreshResult {
        try await withLock {
            var result = try await refreshLocked()
            result.changedTaskIds.formUnion(carriedChanges)
            result.fullReload = result.fullReload || carriedReload
            carriedChanges = []; carriedReload = false
            return result
        }
    }

    /// A refresh for the client's own use (before a write that depends on current data).
    private func pull() async throws {
        let result = try await refreshLocked()
        carriedChanges.formUnion(result.changedTaskIds)
        carriedReload = carriedReload || result.fullReload
    }

    private func refreshLocked() async throws -> ThingsRefreshResult {
        let head = try await fetchHead()
        let key = try await ensureHistoryKey()
        var fullReload = false
        if let known = database, head < known.latestServerIndex { database = nil } // history was reset
        if database == nil {
            database = ThingsDatabase()
            fullReload = true
        }
        var db = database!
        var changed = Set<String>()
        var start = db.latestServerIndex
        defer { database = db }

        while start < head {
            let (data, _) = try await transport.send("GET", "\(ThingsCloudTransport.base)/version/1/history/\(key)/items?start-index=\(start)")
            let page = try JSONValue.parse(data)
            let items = page["items"]?.array ?? []
            for item in items { changed.formUnion(db.apply(try ThingsChange.parseMap(item))) }
            // current-item-index is the server head, not the end of this page: a long history comes back in
            // capped pages, so advance by the number of items actually received.
            if items.isEmpty {
                start = max(start, page["current-item-index"]?.int ?? 0)
                break
            }
            start += items.count
            db.latestServerIndex = start
        }
        db.latestServerIndex = max(start, db.latestServerIndex)
        return ThingsRefreshResult(snapshot: db.snapshot, changedTaskIds: changed, fullReload: fullReload)
    }

    // MARK: Commit (every write goes through here, after validation)

    /// `retryStale: false` throws the 409/412 instead of sending the same body again, for a caller that rebuilds its
    /// change from the refreshed database (an update whose content depends on the current task).
    private func commit(_ changes: ThingsChangeMap, retryStale: Bool = true) async throws {
        guard !changes.isEmpty else { return }
        try ThingsChangeValidator.validate(changes)
        // References must point at live items. A miss against the cached database is checked again after a pull,
        // because the item may have been created elsewhere since.
        if database == nil { try await pull() }
        if !ThingsChangeValidator.referenceProblems(in: changes, database: database ?? ThingsDatabase()).isEmpty {
            try await pull()
            let problems = ThingsChangeValidator.referenceProblems(in: changes, database: database ?? ThingsDatabase())
            if !problems.isEmpty { throw ThingsCloudError.invalidChange(problems) }
        }
        let key = try await ensureHistoryKey()
        let body = JSONValue.object(changes.mapValues(\.json)).data()
        var ancestor: Int? = database?.latestServerIndex

        for attempt in 0... {
            let index: Int
            if let ancestor { index = ancestor } else { index = try await fetchHead() }
            let url = "\(ThingsCloudTransport.base)/version/1/history/\(key)/commit?ancestor-index=\(index)&_cnt=1"
            let (data, response) = try await transport.send(
                "POST", url,
                headers: ["Schema": ThingsCloudTransport.schemaVersion, "App-Id": ThingsCloudTransport.appId,
                          "App-Instance-Id": ThingsCloudTransport.appInstanceId, "Push-Priority": ThingsCloudTransport.pushPriority],
                body: body, acceptStatuses: [409, 412])
            if (200..<300).contains(response.statusCode) {
                let head = (try? JSONValue.parse(data))?["server-head-index"]?.int
                // Only our commit landed since the last sync: apply it locally instead of re-pulling.
                if var db = database, let head, head == index + 1, db.latestServerIndex == index {
                    db.apply(changes)
                    db.latestServerIndex = head
                    database = db
                }
                return
            }
            // The index was stale (another client committed): fetch the real head and retry once.
            if attempt < 1, retryStale {
                ancestor = nil
                continue
            }
            throw ThingsCloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Writes

    private func today() -> String { ThingsDates.today(in: timeZone, now: now()) }

    public func createTodo(_ draft: ThingsTodoDraft) async throws -> String {
        try await withLock {
            let id = ThingsID.generate()
            if let rule = draft.recurrence {
                // A repeating TEMPLATE only. Things generates the occurrences itself.
                guard let first = draft.when else { throw ThingsCloudError.invalidChange(["a repeating template needs a first occurrence day"]) }
                guard let rr = ThingsRepeat.rr(for: rule, start: first.day) else {
                    throw ThingsCloudError.invalidChange(["the repeat rule has no verified Things shape"])
                }
                let change = ThingsChanges.taskCreate(
                    title: draft.title, notes: draft.notes, type: 0, scheduling: try ThingsChanges.templateScheduling(first),
                    containers: ThingsChanges.containers(draft.placement), tags: draft.tagIds,
                    completed: false, completionDate: nil, now: now(), extra: ["rr": rr, "icc": 0])
                try await commit([id: change].merging(checklistCreates(taskId: id, draft.checklist, startIndex: 0)) { $1 })
                return id
            }
            let scheduling: [String: JSONValue]
            if draft.when == nil, case .inbox = draft.placement {
                scheduling = ThingsChanges.inboxScheduling
            } else {
                scheduling = try ThingsChanges.scheduling(draft.when, today: today())
            }
            let change = ThingsChanges.taskCreate(
                title: draft.title, notes: draft.notes, type: 0, scheduling: scheduling,
                containers: ThingsChanges.containers(draft.placement), tags: draft.tagIds,
                completed: draft.completed, completionDate: draft.completionDate, now: now())
            try await commit([id: change].merging(checklistCreates(taskId: id, draft.checklist, startIndex: 0)) { $1 })
            return id
        }
    }

    private func checklistCreates(taskId: String, _ items: [ThingsChecklistDraft], startIndex: Double) -> ThingsChangeMap {
        var map: ThingsChangeMap = [:]
        for (i, item) in items.enumerated() {
            map[ThingsID.generate()] = ThingsChanges.checklistCreate(taskId: taskId, title: item.title, completed: item.completed,
                                                                      index: startIndex + Double(i), now: now())
        }
        return map
    }

    /// The commit entries for checklist changes of a to-do. Ids of items to rename, complete or delete must exist.
    /// Create, complete (`ss` 3 + `sp` + `md`), rename (`tt` + `md`) and delete (`t` 2, empty `p`) match what Things 3.24.2
    /// wrote when sampled (docs/SPEC.md), and so does reopening (`ss` 0 + `sp` null + `md`).
    private func checklistWrites(taskId: String, _ changes: [ThingsChecklistChange], existing: [ThingsChecklistItem]) throws -> ThingsChangeMap {
        var map: ThingsChangeMap = [:]
        var next = (existing.map(\.index).max() ?? -1) + 1
        let known = Set(existing.map(\.id))
        func need(_ id: String) throws {
            guard known.contains(id) else { throw ThingsCloudError.notFound("checklist item \(id)") }
        }
        let nowTs = now().timeIntervalSince1970
        // Several changes to one item travel as one update entry.
        func merge(_ id: String, _ p: [String: JSONValue]) {
            var combined = map[id]?.t == 1 ? map[id]!.p : [:]
            combined.merge(p) { $1 }
            map[id] = ThingsChanges.checklistUpdate(combined, now: now())
        }
        for change in changes {
            switch change {
            case let .add(title, completed):
                map[ThingsID.generate()] = ThingsChanges.checklistCreate(taskId: taskId, title: title, completed: completed, index: next, now: now())
                next += 1
            case let .rename(id, title):
                try need(id)
                merge(id, ["tt": .string(title)])
            case let .setCompleted(id, completed):
                try need(id)
                merge(id, ["ss": completed ? 3 : 0, "sp": completed ? .number(nowTs) : .null])
            case let .delete(id):
                try need(id)
                map[id] = ThingsChanges.checklistDelete()
            }
        }
        return map
    }

    public func updateTodo(id: String, patch: ThingsTodoPatch) async throws {
        try await withLock {
            if database == nil { try await pull() }
            // Tags are written as the whole list and notes as the whole text, so both are built from the to-do as it
            // is now, not as it was when the pass started: a tag or note edited in Things meanwhile must survive.
            let needsCurrent = patch.addTagIds != nil || patch.removeTagIds != nil || patch.notes != nil
            if needsCurrent || database?.tasks[id] == nil { try await pull() } // or created elsewhere since the last pull
            guard !patch.isEmpty else {
                guard database?.tasks[id] != nil else { throw ThingsCloudError.notFound("to-do \(id)") }
                return
            }
            do {
                try await commit(try updateChanges(id: id, patch: patch), retryStale: false)
            } catch ThingsCloudError.http(let status, _) where status == 409 || status == 412 {
                // Another client committed in between: read what it wrote and build the change again from that.
                try await pull()
                try await commit(try updateChanges(id: id, patch: patch))
            }
        }
    }

    /// The change map for a to-do update, built from the database as it is now. Carries only the keys the patch changes.
    private func updateChanges(id: String, patch: ThingsTodoPatch) throws -> ThingsChangeMap {
        guard let db = database, let row = db.tasks[id] else { throw ThingsCloudError.notFound("to-do \(id)") }
        let current = row.task
        let existingChecklist = db.checklistItems.values.filter { $0.taskId == id }.map(\.item)

        let nowTs = now().timeIntervalSince1970
        var p: [String: JSONValue] = ["md": .number(nowTs)]
        if let title = patch.title { p["tt"] = .string(title) }
        if let notes = patch.notes {
            if let base = patch.notesBase, base != current.notes {
                throw ThingsCloudError.changedMeanwhile("The notes of \"\(current.title)\"")
            }
            p["nt"] = ThingsChanges.noteObject(notes)
        }
        if let when = patch.when {
            p.merge(try ThingsChanges.schedulingUpdate(when, today: today(), current: current)) { $1 }
        }
        if let completed = patch.completed {
            if completed {
                var sp = nowTs
                if let date = patch.completionDate, date.timeIntervalSince1970 <= nowTs { sp = date.timeIntervalSince1970 }
                p["ss"] = 3
                p["sp"] = .number(sp)
            } else {
                p["ss"] = 0
                p["sp"] = .null
            }
        }
        if let placement = patch.placement {
            p.merge(ThingsChanges.containers(placement)) { $1 }
            // The start state follows the move unless this patch already sets it (as the JavaScript client does):
            // an Inbox to-do filed into a project, area or heading becomes Anytime, and a to-do sent to the Inbox
            // gets `st 0`. A dated to-do, a Someday to-do and a repeating template keep their state: the Inbox holds
            // no dated items, and `st 0` would pull the others out of where the user put them.
            if p["st"] == nil, current.kind == .todo {
                if case .inbox = placement {
                    if current.start == .anytime, current.startDate == nil, !row.hasRule, (patch.when ?? nil) == nil { p["st"] = 0 }
                } else if current.start == .inbox {
                    p["st"] = 1
                }
            }
        }
        if patch.addTagIds != nil || patch.removeTagIds != nil {
            // Ids of tags that no longer exist are dropped rather than written back.
            var tags = current.tagIds.filter { db.tags[$0] != nil }
            for tag in patch.addTagIds ?? [] where !tags.contains(tag) { tags.append(tag) }
            let remove = Set(patch.removeTagIds ?? [])
            tags.removeAll { remove.contains($0) }
            if tags != current.tagIds { p["tg"] = ThingsChanges.idArray(tags) }
        }
        if let trashed = patch.trashed { p["tr"] = .bool(trashed) }
        if patch.recurrence != nil || patch.templateNext != nil || patch.templateMinutes != nil {
            guard row.hasRule else {
                throw ThingsCloudError.invalidChange(["to-do \(id) is not a repeating template"])
            }
            if let rule = patch.recurrence {
                // As Things 3.24.2 wrote a rule edit (docs/RECURRENCE.md): `sr` stays the old rule's, `ia` becomes the
                // template's current next day (`tir`), and nothing but `md` and `rr` is written. An edit that also moves
                // the next day (`templateNext`) was not sampled; there the old `ia` is kept, which is this app's own choice.
                let o = row.rawRule?.object
                var anchors: (ia: Double, sr: Double)?
                if o?["tp"]?.int == 0, let ia = o?["ia"]?.double, let sr = o?["sr"]?.double {
                    let tir = patch.templateNext == nil ? row.task.nextDay.flatMap { try? ThingsDates.timestamp(forDay: $0) } : nil
                    anchors = (tir ?? ia, sr)
                }
                let start = row.task.nextDay ?? current.startDate ?? today()
                guard let rr = ThingsRepeat.rr(for: rule, start: start, anchors: anchors) else {
                    throw ThingsCloudError.invalidChange(["the repeat rule has no verified Things shape"])
                }
                p["rr"] = rr
            }
            if let minutes = patch.templateMinutes {
                if let minutes {
                    guard (0..<1440).contains(minutes) else {
                        throw ThingsCloudError.invalidChange(["reminder minutes \(minutes) is outside 0..<1440"])
                    }
                    p["ato"] = .number(Double(minutes * 60))
                } else {
                    p["ato"] = .null
                }
            }
            if let next = patch.templateNext {
                let scheduling = try ThingsChanges.templateScheduling(next)
                p["tir"] = scheduling["tir"]; p["icsd"] = scheduling["icsd"]; p["ato"] = scheduling["ato"]
            }
        }
        var map: ThingsChangeMap = [id: ThingsChange(t: 1, e: ThingsEntity.task, p: p)]
        if let changes = patch.checklist, !changes.isEmpty {
            map.merge(try checklistWrites(taskId: id, changes, existing: existingChecklist)) { $1 }
        }
        return map
    }

    public func stopRepeating(templateId id: String) async throws -> String {
        try await withLock {
            // The open occurrences are read from the database, so it has to be current.
            try await pull()
            let newId = ThingsID.generate()
            do {
                try await commit(try stopChanges(id: id, newId: newId), retryStale: false)
            } catch ThingsCloudError.http(let status, _) where status == 409 || status == 412 {
                // Another client committed in between (Things may just have made an occurrence): build it again.
                try await pull()
                try await commit(try stopChanges(id: id, newId: newId))
            }
            return newId
        }
    }

    private func stopChanges(id: String, newId: String) throws -> ThingsChangeMap {
        guard let db = database, let row = db.tasks[id], row.hasRule, !row.task.trashed else {
            throw ThingsCloudError.notFound("repeating to-do \(id)")
        }
        var open: [String] = []
        for (oid, o) in db.tasks where o.task.templateId == id && o.task.kind == .todo && o.task.status == .open && !o.task.trashed {
            open.append(oid)
        }
        return try ThingsChanges.stopRepeating(templateId: id, template: row.task, tags: row.task.tagIds.filter { db.tags[$0] != nil },
                                               openOccurrences: open, newId: newId, now: now())
    }

    public func createProject(title: String, areaId: String?) async throws -> String {
        try await withLock {
            let id = ThingsID.generate()
            let placement: ThingsPlacement = areaId.map { .area($0) } ?? .inbox
            let change = ThingsChanges.taskCreate(
                title: title, notes: "", type: 1, scheduling: try ThingsChanges.scheduling(nil, today: today()),
                containers: ThingsChanges.containers(placement), tags: [], completed: false, completionDate: nil, now: now())
            try await commit([id: change])
            return id
        }
    }

    public func createHeading(title: String, projectId: String) async throws -> String {
        try await withLock {
            let id = ThingsID.generate()
            let change = ThingsChanges.taskCreate(
                title: title, notes: "", type: 2, scheduling: try ThingsChanges.scheduling(nil, today: today()),
                containers: ThingsChanges.containers(.project(projectId)), tags: [], completed: false, completionDate: nil, now: now())
            try await commit([id: change])
            return id
        }
    }

    public func createArea(title: String) async throws -> String {
        try await withLock {
            let id = ThingsID.generate()
            try await commit([id: ThingsChanges.areaCreate(title: title)])
            return id
        }
    }

    public func createTag(title: String, parentId: String?) async throws -> String {
        try await withLock {
            let id = ThingsID.generate()
            try await commit([id: ThingsChanges.tagCreate(title: title, parentId: parentId)])
            return id
        }
    }

    /// Permanently deletes an area (t 2). A missing area is already gone. Every task that still names the area
    /// (trashed ones included) first gets `ar []` in the same commit, as the JavaScript client does, so a to-do
    /// restored from the Trash later never points at an area that no longer exists.
    public func deleteArea(id: String) async throws {
        try await withLock {
            try await pull()
            guard let db = database, db.areas[id] != nil else { return }
            let nowTs = now().timeIntervalSince1970
            var map: ThingsChangeMap = [id: ThingsChange(t: 2, e: ThingsEntity.area, p: [:])]
            for (taskId, row) in db.tasks where row.task.areaId == id {
                map[taskId] = ThingsChange(t: 1, e: ThingsEntity.task, p: ["ar": [], "md": .number(nowTs)])
            }
            try await commit(map)
        }
    }

    /// Permanently deletes a tag (t 2). A missing tag is already gone. Every task that still carries the tag (trashed
    /// ones included) first gets its `tg` without it, in the same commit. Refused while an area carries the tag or
    /// another tag nests under it: this client writes no area or tag update, and a tombstone would leave them dangling.
    public func deleteTag(id: String) async throws {
        try await withLock {
            try await pull()
            guard let db = database, db.tags[id] != nil else { return }
            if db.areas.values.contains(where: { $0.tagIds.contains(id) }) || db.tags.values.contains(where: { $0.parentId == id }) {
                throw ThingsCloudError.invalidChange(["tag \(id) is still carried by an area or has tags nested under it"])
            }
            let nowTs = now().timeIntervalSince1970
            var map: ThingsChangeMap = [id: ThingsChange(t: 2, e: ThingsEntity.tag, p: [:])]
            for (taskId, row) in db.tasks where row.task.tagIds.contains(id) {
                map[taskId] = ThingsChange(t: 1, e: ThingsEntity.task,
                                           p: ["tg": ThingsChanges.idArray(row.task.tagIds.filter { $0 != id }), "md": .number(nowTs)])
            }
            try await commit(map)
        }
    }
}
