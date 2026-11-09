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
        try await withLock { try await refreshLocked() }
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

    private func commit(_ changes: ThingsChangeMap) async throws {
        guard !changes.isEmpty else { return }
        try ThingsChangeValidator.validate(changes)
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
            if attempt < 1 {
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
            try await commit([id: change])
            return id
        }
    }

    public func updateTodo(id: String, patch: ThingsTodoPatch) async throws {
        try await withLock {
            if database == nil { _ = try await refreshLocked() }
            if database?.tasks[id] == nil { _ = try await refreshLocked() } // created elsewhere since the last pull
            guard let current = database?.tasks[id]?.task else { throw ThingsCloudError.notFound("to-do \(id)") }
            guard !patch.isEmpty else { return }

            let nowDate = now()
            let nowTs = nowDate.timeIntervalSince1970
            var p: [String: JSONValue] = ["md": .number(nowTs)]
            if let title = patch.title { p["tt"] = .string(title) }
            if let notes = patch.notes { p["nt"] = ThingsChanges.noteObject(notes) }
            if let when = patch.when {
                p.merge(try ThingsChanges.scheduling(when, today: today())) { $1 }
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
            if let placement = patch.placement { p.merge(ThingsChanges.containers(placement)) { $1 } }
            if patch.addTagIds != nil || patch.removeTagIds != nil {
                var tags = current.tagIds
                for tag in patch.addTagIds ?? [] where !tags.contains(tag) { tags.append(tag) }
                let remove = Set(patch.removeTagIds ?? [])
                tags.removeAll { remove.contains($0) }
                if tags != current.tagIds { p["tg"] = ThingsChanges.idArray(tags) }
            }
            if let trashed = patch.trashed { p["tr"] = .bool(trashed) }
            try await commit([id: ThingsChange(t: 1, e: ThingsEntity.task, p: p)])
        }
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

    /// Permanently deletes an area (t 2). A missing area is already gone.
    public func deleteArea(id: String) async throws {
        try await withLock {
            if database == nil || database?.areas[id] == nil { _ = try await refreshLocked() }
            guard database?.areas[id] != nil else { return }
            try await commit([id: ThingsChange(t: 2, e: ThingsEntity.area, p: [:])])
        }
    }

    /// Permanently deletes a tag (t 2). A missing tag is already gone.
    public func deleteTag(id: String) async throws {
        try await withLock {
            if database == nil || database?.tags[id] == nil { _ = try await refreshLocked() }
            guard database?.tags[id] != nil else { return }
            try await commit([id: ThingsChange(t: 2, e: ThingsEntity.tag, p: [:])])
        }
    }
}
