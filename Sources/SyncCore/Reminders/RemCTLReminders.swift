import CryptoKit
import Foundation
import os

/// `RemindersBackend` over RemCTL (`remctl`, whose signed Capability Host holds the Reminders permission).
/// The app itself never needs Reminders access.
///
/// - Writes and list lookups go through one long-lived `remctl mcp serve` session.
/// - Reads use one `remctl export --json` run (all reminders, completed included). MCP tool results are
///   capped, which cuts a full export to a fraction of the rows, so the export runs as a one-shot process.
///   Rows name their list by title; lists that share a title are told apart with one `export --list-id` run each.
/// - A write whose answer is lost is never sent again: the reminder is re-read to see whether it landed.
/// - RemCTL has no modification date, so modification times are synthesized: a digest per reminder id and per
///   field (`SyncField`) is kept in memory and in `remctl-observed.json`. A field whose digest is new or changed
///   is stamped with the time it was first seen that way; an unchanged one keeps its stamp. `lastModified` is the
///   same for the reminder as a whole. Conflict resolution therefore has the resolution of the poll interval, and
///   the first run after install treats every reminder as modified "now".
/// - There is no push, so `changes()` polls the export and yields when the watched lists' content changes.
public actor RemCTLReminders: RemindersBackend {
    struct FieldStamp: Codable, Equatable { var hash: String; var stamp: Date }
    /// One reminder in `remctl-observed.json`. `fields` is missing in files written before per-field stamps; such an
    /// entry seeds every field with its one `stamp` (see `observe(item:)`).
    struct Observed: Codable, Equatable {
        var hash: String
        var stamp: Date
        var fields: [String: FieldStamp]?
    }

    private let transport: any RemCTLTransport
    private let stateURL: URL
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.oliverames.ThingsRemindersSync", category: "RemCTL")

    private var pollSeconds: Double
    private var watched: Set<String> = []
    /// Lists whose sections are read (`remctl show`, because the export rows carry no section).
    private var sectionLists: Set<String> = []
    private var groceryLists: Set<String> = []
    /// Section names per list id, from `get_list`. Dropped whenever the lists are re-read, so it lives for one pass or poll.
    private var sectionCache: [String: [(id: String, name: String)]] = [:]
    /// Sections created by writes since the engine last asked (`takeCreatedSections`).
    private var createdSections: [CreatedReminderSection] = []
    private var executablePath: String?
    private var titleToIds: [String: [String]] = [:]
    private var idToTitle: [String: String] = [:]
    /// Reminder id -> list id, from the last export. Rows only carry a list title, so this is what places a reminder
    /// whose list shares its title with another list.
    private var knownLists: [Int: String] = [:]
    private var observed: [String: Observed] = [:]
    private var observedLoaded = false
    private var versionDetail = "Not checked yet"

    public init(executablePath: String? = nil, pollSeconds: Int = 10, stateDirectory: URL = StateStore.defaultDirectory) {
        self.init(transport: LiveRemCTLTransport(executablePath: executablePath), executablePath: executablePath,
                  pollSeconds: Double(pollSeconds), stateDirectory: stateDirectory)
    }

    init(transport: any RemCTLTransport, executablePath: String? = nil, pollSeconds: Double = 10,
         stateDirectory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.executablePath = executablePath
        self.pollSeconds = pollSeconds
        self.stateURL = stateDirectory.appendingPathComponent("remctl-observed.json")
        self.clock = clock
    }

    // MARK: Configuration

    /// Text for the UI: "Ready via RemCTL 2.5.0", or why RemCTL is unavailable.
    public func statusDetail() -> String { versionDetail }

    /// Applies settings changes. A new path restarts the RemCTL session.
    public func configure(executablePath: String?, pollSeconds: Int) async {
        self.pollSeconds = max(1, Double(pollSeconds))
        let path = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (path?.isEmpty ?? true) ? nil : path
        if normalized != self.executablePath {
            self.executablePath = normalized
            await transport.setExecutablePath(normalized)
        }
    }

    /// The list ids `changes()` watches. Empty means every list.
    public func setWatchedLists(_ ids: [String]) { watched = Set(ids) }

    /// The list ids whose reminders should carry their Reminders section (project-mode lists that sync sections).
    /// Reading a section needs one `remctl show` run per list, so other lists are left out.
    public func setSectionLists(_ ids: [String]) { sectionLists = Set(ids) }

    // MARK: Access

    public func access() async -> RemindersAccess {
        do {
            _ = try await refreshLists()
            let version = await transport.serverVersion()
            versionDetail = version.map { "Ready via RemCTL \($0)" } ?? "Ready via RemCTL"
            return .granted
        } catch {
            versionDetail = error.localizedDescription
            return .denied
        }
    }

    /// Nothing to prompt for: re-checks RemCTL.
    public func requestAccess() async throws -> RemindersAccess { await access() }

    // MARK: Reading

    public func lists() async throws -> [ReminderList] { try await refreshLists() }

    public func reminders(inLists listIds: [String]) async throws -> [ReminderItem] {
        _ = try await refreshLists()
        let wanted = Set(listIds)
        let rows = try await exportRows()
        let lists = try await listsOfRows(rows, needed: wanted)
        let sections = try await loadSections(for: wanted)
        return observe(rows, lists: lists, sections: sections, sectionsLoaded: wanted.intersection(sectionLists))
            .filter { wanted.contains($0.listId) }
    }

    // MARK: Writing

    public func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                       section: String?, recurrence: RepeatRule?) async throws -> ReminderItem {
        guard let numericList = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
        var args: [String: JSONValue] = ["title": .string(title), "list_id": .number(Double(numericList))]
        let sectionName = writableSection(section, listId: listId)
        if let sectionName {
            args["private"] = true
            args.merge(try await sectionArguments(sectionName, listId: listId)) { $1 }
        }
        if !notes.isEmpty { args["notes"] = .string(notes) }
        if let due, let spec = Self.dueSpec(due) {
            args["due"] = .string(spec.due)
            if let alarm = spec.alarm { args["alarm"] = .string(alarm) }
        }
        if let recurrence {
            guard let due, let spec = RemCTLRecurrence.spec(for: recurrence, due: due) else {
                throw RemCTLError.tool("RemCTL cannot write this repeat rule (it needs a due date and a rule RemCTL can express)")
            }
            args["recurrence"] = .string(spec)
        }
        loadObservedIfNeeded()
        let knownBefore = Set(observed.keys)
        var created: JSONValue
        do {
            created = try await transport.callTool("create_reminder", arguments: args)
        } catch let error as RemCTLError where error.kind == .uncertain {
            // The answer was lost, so the reminder may exist. Never create again: look for it instead. When it cannot
            // be found the error stands, and the engine pairs by title if it shows up later.
            guard let found = try await findCreated(title: title, listId: listId, knownBefore: knownBefore) else { throw error }
            logger.warning("create_reminder was not confirmed; found the new reminder \(found, privacy: .public) by re-reading")
            created = ["id": .number(Double(found)), "status": "partial"]
        }
        guard let id = created["id"]?.int else { throw RemCTLError.tool("RemCTL did not return the new reminder id") }
        // From here on the reminder exists. A failure in a later step must not lose its id, or the next pass would
        // create it a second time: the item is returned as it is and the engine retries what is missing.
        if let sectionName, created["status"]?.string == "partial" {
            // The reminder exists but the private section step failed: finish with an update, never create twice.
            var retry: [String: JSONValue] = ["reminder_id": .number(Double(id)), "private": true]
            if let extra = try? await sectionArguments(sectionName, listId: listId) { retry.merge(extra) { $1 } }
            if (try? await transport.callTool("update_reminder", arguments: retry)) != nil { noteCreated(retry, sectionName, listId) }
        } else if let sectionName {
            noteCreated(args, sectionName, listId)
        }
        if sectionName != nil { sectionCache[listId] = nil }
        var isCompleted = false
        if completed {
            do {
                try await setCompletion(id, completed: true, date: recurrence == nil ? completionDate : nil, before: nil)
                isCompleted = true
            } catch {
                logger.error("Created reminder \(id, privacy: .public) but could not complete it: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            return try await fetch(id: id, listHint: listId)
        } catch {
            logger.error("Created reminder \(id, privacy: .public) but could not read it back: \(error.localizedDescription, privacy: .public)")
            knownLists[id] = listId
            return observe(item: ReminderItem(id: String(id), listId: listId, title: title, notes: notes, due: due, completed: isCompleted,
                                              completionDate: isCompleted ? completionDate : nil, isRepeating: recurrence != nil,
                                              section: sectionLists.contains(listId) ? sectionName : nil, recurrence: recurrence))
        }
    }

    /// The id of a reminder that a lost `create_reminder` answer may have made: the only reminder with that title in
    /// the list that was not there at the last read. Nil when there is none, or more than one.
    private func findCreated(title: String, listId: String, knownBefore: Set<String>) async throws -> Int? {
        let rows = try await exportRows()
        let lists = try await listsOfRows(rows, needed: [listId])
        let hits = rows.compactMap(Row.init).filter {
            !$0.isSubtask && $0.title == title && lists[$0.id] == listId && !knownBefore.contains(String($0.id))
        }
        return hits.count == 1 ? hits[0].id : nil
    }

    /// `set_completion`, sent once. When the answer is lost the reminder is re-read: a completion that landed shows as
    /// the wanted state, or (a repeating reminder, which advances instead) as a due date that moved on from `before`.
    /// RemCTL itself never repeats an uncertain completion of a repeating reminder, because each one advances the series.
    private func setCompletion(_ id: Int, completed: Bool, date: Date?, before: Row?) async throws {
        var args: [String: JSONValue] = ["reminder_id": .number(Double(id)), "completed": .bool(completed)]
        if completed, let date { args["completion_date"] = .string(Self.localISO(date)) }
        do {
            _ = try await transport.callTool("set_completion", arguments: args)
        } catch let error as RemCTLError where error.kind == .uncertain {
            let after = try await row(id: id)
            let advanced = completed && after.isRepeating && before != nil && before?.due != after.due
            guard after.completed == completed || advanced else { throw error }
        }
    }

    public func update(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        guard let numeric = Int(id) else { throw RemCTLError.tool("Reminder not found") }
        var current = numeric
        var fields: [String: JSONValue] = [:]
        if let title = patch.title { fields["title"] = .string(title) }
        if let notes = patch.notes { fields["notes"] = .string(notes) }   // "" clears the notes
        if let due = patch.due {
            // Only the due date is sent. RemCTL itself moves an alarm that sat at the old due time (or removes it when
            // the due becomes all-day or is cleared) and leaves every other alarm alone; an explicit `alarm` would
            // replace them, and `alarm: clear` removes them all (early and custom alerts included).
            if let due, let spec = Self.dueSpec(due) {
                fields["due"] = .string(spec.due)
                // A reminder with no alarm at all gets one at the new time, so a newly timed due still notifies.
                if let alarm = spec.alarm, try await row(id: numeric).hasAlarms == false { fields["alarm"] = .string(alarm) }
            } else {
                fields["due"] = "clear"
            }
        }
        if let recurrence = patch.recurrence {
            if let rule = recurrence {
                // The due day the rule applies to: the one this patch sets, else the reminder's current one.
                var dueNow: DueDate?
                if let due = patch.due { dueNow = due } else { dueNow = try await row(id: numeric).due }
                guard let spec = RemCTLRecurrence.spec(for: rule, due: dueNow) else {
                    throw RemCTLError.tool("RemCTL cannot write this repeat rule")
                }
                fields["recurrence"] = .string(spec)
            } else {
                fields["recurrence"] = "clear"
            }
        }
        if let listId = patch.listId {
            guard let numericList = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
            fields["list_id"] = .number(Double(numericList))
        }
        // Priority is a plain field: "high", "medium", "low" or "none".
        if let priority = patch.priority { fields["priority"] = .string(priority.rawValue) }
        // Rich link, flag, tags and subtasks are private metadata writes. Without `private` RemCTL would append the
        // link to the notes, so `private` always travels with them. A rich link can only be added, never replaced or
        // cleared (viticci/remctl#79); the engine only sends one for a reminder that has none.
        var privateFields: [String: JSONValue] = [:]
        if let url = patch.url { privateFields["url"] = .string(url) }
        if let flagged = patch.flagged { privateFields["flagged"] = .bool(flagged) }
        if let tags = patch.tags {
            // `set_tags` replaces every tag and takes ONE comma-separated string; `clear_tags` removes them all.
            if tags.contains(where: { $0.contains(",") }) { throw RemCTLError.tool("RemCTL cannot write a tag whose name contains a comma") }
            // Reminders tags hold no whitespace, so each goes out in the form it will be stored in, and once.
            let sent = TagEnvironment.reminderTags(tags)
            if sent.isEmpty { privateFields["clear_tags"] = true } else { privateFields["set_tags"] = .string(sent.joined(separator: ",")) }
        }
        if let subtasks = patch.addSubtasks, !subtasks.isEmpty { privateFields["subtasks"] = .array(subtasks.map { .string($0) }) }
        // Assignment in a shared list (`--assign` / `--unassign`). No read shows it, so nothing is read back.
        if let assignee = patch.assignee {
            if let assignee { privateFields["assign"] = .string(assignee) } else { privateFields["unassign"] = true }
        }
        if !privateFields.isEmpty {
            fields.merge(privateFields) { $1 }
            fields["private"] = true
        }
        if !fields.isEmpty {
            fields["reminder_id"] = .number(Double(numeric))
            var result: JSONValue = .null
            do {
                result = try await transport.callTool("update_reminder", arguments: fields)
            } catch let error as RemCTLError where error.kind == .uncertain {
                // Never sent again (subtasks would be added twice, a move could copy twice). The reminder is re-read:
                // when it shows what was written the write landed; otherwise the error stands and the next pass retries.
                guard patch.addSubtasks?.isEmpty ?? true, patch.listId == nil,
                      try await plainFieldsLanded(patch, id: numeric) else { throw error }
            }
            // A move into a shared list (or one EventKit rejects) copies the reminder: the result carries the
            // new id (plus `oldId`), and everything after the move must use it.
            if let newId = result["id"]?.int { current = newId }
        }
        // `.some(nil)` (remove from section) is not possible with RemCTL 2.5.0: nothing is sent and the
        // returned item still shows its section, which is how the engine notices (docs/SPEC.md).
        if case .some(.some(let wanted)) = patch.section {
            let listId: String?
            if let moved = patch.listId { listId = moved } else { listId = try await listIdOfReminder(current) }
            if let listId, let name = writableSection(wanted, listId: listId) {
                var args: [String: JSONValue] = ["reminder_id": .number(Double(current)), "private": true]
                args.merge(try await sectionArguments(name, listId: listId)) { $1 }
                do {
                    _ = try await transport.callTool("update_reminder", arguments: args)
                } catch let error as RemCTLError where error.kind == .uncertain {
                    let now = try await row(id: current)
                    guard Self.sectionKey(now.section ?? "") == Self.sectionKey(name) else { throw error }
                }
                noteCreated(args, name, listId)
                sectionCache[listId] = nil
            }
        }
        if let completed = patch.completed {
            // Read first: RemCTL rejects a completion date on a recurring reminder, and the due date before the write
            // is what tells whether an unconfirmed completion of one landed.
            var before: Row?
            if completed { before = try await row(id: current) }
            try await setCompletion(current, completed: completed, date: before?.isRepeating == false ? patch.completionDate : nil,
                                    before: before)
        }
        var item = try await fetch(id: current, listHint: patch.listId)
        // Private (ReminderKit) writes land a moment after the call returns, so an immediate read can still show
        // the old tags, flag or link (seen live on 2026-11-09: 5 of 7 tag writes read back stale, all had landed).
        // Re-read briefly before the engine decides a field did not take.
        if !privateFields.isEmpty {
            for delay in privateReadBackDelays where !Self.privateFieldsLanded(patch, in: item) {
                try await Task.sleep(for: delay)
                item = try await fetch(id: current, listHint: patch.listId)
            }
        }
        return item
    }

    /// Waits between re-reads after a private write.
    private var privateReadBackDelays: [Duration] = [.milliseconds(300), .milliseconds(700), .milliseconds(1500)]
    func setPrivateReadBackDelays(_ delays: [Duration]) { privateReadBackDelays = delays }

    /// True when a re-read shows every plain field of the patch (title, notes, due, repeat) as written.
    private func plainFieldsLanded(_ patch: ReminderPatch, id: Int) async throws -> Bool {
        let now = try await row(id: id)
        if let title = patch.title, now.title != title { return false }
        if let notes = patch.notes, now.notes != notes { return false }
        if let due = patch.due, now.due != due { return false }
        if let priority = patch.priority, now.priority != priority { return false }
        if let recurrence = patch.recurrence {
            if let rule = recurrence { if now.recurrence?.key != rule.key { return false } } else if now.isRepeating { return false }
        }
        return true
    }

    /// Reminders stores a tag without whitespace and treats tags that differ only in case as one tag, so what was
    /// sent and what reads back compare by `TagEnvironment.key`.
    static func tagKeys(_ tags: [String]) -> Set<String> { Set(tags.map(TagEnvironment.key).filter { !$0.isEmpty }) }

    static func privateFieldsLanded(_ patch: ReminderPatch, in item: ReminderItem) -> Bool {
        if let tags = patch.tags, tagKeys(tags) != tagKeys(item.tags) { return false }
        if let flagged = patch.flagged, flagged != item.flagged { return false }
        if patch.url != nil, item.url == nil { return false }
        return true
    }

    public func delete(id: String) async throws {
        guard let numeric = Int(id) else { return }
        do {
            _ = try await transport.callTool("delete_reminder", arguments: ["reminder_id": .number(Double(numeric))])
        } catch let error as RemCTLError where error.kind == .tool && error.message.lowercased().contains("not found") {
            return   // already gone
        } catch let error as RemCTLError where error.kind == .uncertain {
            // Not sent again: the delete landed when the reminder can no longer be read.
            if (try? await row(id: numeric)) != nil { throw error }
        }
        observed[id] = nil
        persistObserved()
    }

    // MARK: Sections

    private static func sectionKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The section name to write, or nil when there is nothing to write (blank name, or a Groceries list,
    /// which auto-categorizes: sections there are read-only).
    private func writableSection(_ name: String?, listId: String) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !groceryLists.contains(listId) else { return nil }
        return trimmed
    }

    private func sections(ofList listId: String) async throws -> [(id: String, name: String)] {
        if let cached = sectionCache[listId] { return cached }
        guard let numeric = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
        let result = try await transport.callTool("get_list", arguments: ["list_id": .number(Double(numeric))])
        let found = (result["sections"]?.array ?? []).compactMap { entry -> (id: String, name: String)? in
            guard let name = entry["name"]?.string else { return nil }
            return (entry["id"]?.string ?? "", name)
        }
        sectionCache[listId] = found
        return found
    }

    /// `section` for an existing section (`section_id` when several share the name), else `new_section`.
    private func sectionArguments(_ name: String, listId: String) async throws -> [String: JSONValue] {
        let key = Self.sectionKey(name)
        let hits = try await sections(ofList: listId).filter { Self.sectionKey($0.name) == key }
        if hits.count > 1, !hits[0].id.isEmpty { return ["section_id": .string(hits[0].id)] }
        if let hit = hits.first { return ["section": .string(hit.name)] }
        return ["new_section": .string(name)]
    }

    /// Records a section the write just created (`new_section` was sent and the call succeeded).
    private func noteCreated(_ args: [String: JSONValue], _ name: String, _ listId: String) {
        guard args.keys.contains("new_section") else { return }
        let c = CreatedReminderSection(listId: listId, name: name)
        if !createdSections.contains(c) { createdSections.append(c) }
    }

    public func takeCreatedSections() async -> [CreatedReminderSection] {
        let taken = createdSections
        createdSections = []
        return taken
    }

    /// `remctl section-delete NAME --list-id N --force --private --json`. A section that is already gone is fine.
    public func deleteSection(name: String, listId: String) async throws {
        guard let numeric = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
        do {
            _ = try await transport.runCLI(["section-delete", name, "--list-id", String(numeric), "--force", "--private", "--json"])
        } catch let error as RemCTLError where error.message.lowercased().contains("not found") {
            // already gone
        }
        sectionCache[listId] = nil
    }

    private func listIdOfReminder(_ id: Int) async throws -> String? {
        let current = try await row(id: id)
        return try? await resolveList(of: current, hint: nil)
    }

    /// Reminder id to section name for the given lists, from `remctl show --completed` (the export has no sections).
    /// A failure throws, so a pass never mistakes "could not read" for "no section".
    /// `show` costs ~1.8 s per list, so one `remctl sections --json` call (~0.8 s, keyed by list title)
    /// first finds the lists that have any sections; lists without sections need no `show` at all.
    private func loadSections(for lists: Set<String>) async throws -> [Int: String] {
        var map: [Int: String] = [:]
        let candidates = lists.intersection(sectionLists)
        guard !candidates.isEmpty else { return map }
        let overview = try await transport.runCLI(["sections", "--json"])
        guard let byTitle = overview.object else { throw RemCTLError.tool("Unexpected sections output from RemCTL") }
        let sectioned = Set(byTitle.compactMap { title, value -> [String]? in
            (value.array?.isEmpty ?? true) ? nil : (titleToIds[title] ?? [])
        }.flatMap { $0 })
        for list in candidates.intersection(sectioned).sorted() {
            let output = try await transport.runCLI(["show", "--list-id", list, "--completed", "--json"])
            guard let rows = output.array ?? output["items"]?.array else {
                throw RemCTLError.tool("Unexpected show output from RemCTL for list \(list)")
            }
            for json in rows {
                if let id = json["id"]?.int, let name = json["section"]?.string,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { map[id] = name }
            }
        }
        return map
    }

    // MARK: Changes

    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { await self.pollLoop(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pollLoop(_ continuation: AsyncStream<Void>.Continuation) async {
        var last: (scope: Set<String>, digest: String)?
        while !Task.isCancelled {
            do {
                _ = try await refreshLists()
                let scope = watched
                let rows = try await exportRows()
                let lists = try await listsOfRows(rows, needed: scope)
                // Cheap change probe: hash the raw export rows of the watched lists. It never reads
                // sections and never touches the observed-modification stamps (a poll without sections
                // would flip every sectioned reminder's hash and fake edits). A move between sections
                // alone does not change the export, so it syncs at the next full reconcile.
                let digest = Self.sha(rows.filter { row in
                    scope.isEmpty || row["id"]?.int.flatMap { lists[$0] }.map(scope.contains) == true
                }.map { $0.serialized() }.sorted().joined(separator: "\n"))
                if let last, last.scope == scope, last.digest != digest { continuation.yield() }
                last = (scope, digest)
            } catch {
                logger.error("Reminders poll failed: \(error.localizedDescription, privacy: .public)")
            }
            do { try await Task.sleep(for: .seconds(pollSeconds)) } catch { return }
        }
    }

    private func digest(of items: [ReminderItem]) -> String {
        let joined = items.sorted { $0.id < $1.id }.map { "\($0.id):\(observed[$0.id]?.hash ?? "")" }.joined(separator: "|")
        return Self.sha(joined)
    }

    // MARK: Lists and rows

    private func refreshLists() async throws -> [ReminderList] {
        let result = try await transport.callTool("lists", arguments: [:])
        var lists: [ReminderList] = []
        var byTitle: [String: [String]] = [:]
        var groceries: Set<String> = []
        for entry in result["items"]?.array ?? [] {
            guard let numeric = entry["id"]?.int, let title = entry["title"]?.string, entry["isGroup"]?.flag != true else { continue }
            let id = String(numeric)
            let isGroceries = entry["isGroceries"]?.flag == true
            if isGroceries { groceries.insert(id) }
            lists.append(ReminderList(id: id, title: title, colorHex: entry["color"]?["hex"]?.string, allowsModifications: true,
                                      isGroceries: isGroceries))
            byTitle[title, default: []].append(id)
        }
        titleToIds = byTitle
        groceryLists = groceries
        sectionCache = [:]
        idToTitle = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.title) })
        return lists
    }

    private struct Row {
        var id: Int
        var title: String
        var list: String?
        var notes: String
        var due: DueDate?
        var completed: Bool
        var completionDate: Date?
        var isRepeating: Bool
        var recurrence: RepeatRule?
        var isSubtask: Bool
        var parentId: Int?
        var deepLink: String?
        var section: String?
        var url: String?
        var tags: [String]
        var flagged: Bool
        var priority: ReminderPriority
        /// `get_reminder` only (the export does not list alarms): the reminder has at least one alarm of any kind.
        var hasAlarms: Bool

        init?(_ json: JSONValue) {
            guard let id = json["id"]?.int else { return nil }
            self.id = id
            title = json["title"]?.string ?? ""
            list = json["list"]?.string
            notes = json["notes"]?.string ?? ""
            let allDay = json["allDay"]?.flag ?? false
            let display = json["displayDate"]?.string
            due = json["dueDate"]?.string.flatMap { RemCTLReminders.parseDue($0, allDay: allDay, displayDate: display) }
            hasAlarms = !(json["alarms"]?.array ?? []).isEmpty
            completed = json["completed"]?.flag ?? false
            completionDate = json["completionDate"]?.string.flatMap(RemCTLReminders.parseLocal)
            isRepeating = json["recurrence"].map { !$0.isNull } ?? false
            let dueDay = due
            recurrence = json["recurrence"].flatMap { $0.isNull ? nil : RemCTLRecurrence.rule(from: $0, due: dueDay) }
            isSubtask = json["isSubtask"]?.flag ?? false
            parentId = json["parentID"]?.int
            url = json["url"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            tags = (json["tags"]?.array ?? []).compactMap(\.string)
            flagged = json["flagged"]?.flag ?? false
            // "none", "low", "medium" or "high"; anything else reads as none.
            priority = json["priority"]?.string.flatMap(ReminderPriority.init(rawValue:)) ?? .none
            deepLink = json["deepLink"]?.string
            section = json["section"]?.string
        }
    }

    private func row(id: Int) async throws -> Row {
        let json = try await transport.callTool("get_reminder", arguments: ["reminder_id": .number(Double(id))])
        guard let row = Row(json) else { throw RemCTLError.tool("Reminder not found") }
        return row
    }

    /// The list id for a row's list title, or nil when the title is unknown or shared by several lists.
    private func listId(forTitle title: String?) -> String? {
        guard let title, let ids = titleToIds[title], ids.count == 1 else { return nil }
        return ids[0]
    }

    private func fetch(id: Int, listHint: String?) async throws -> ReminderItem {
        let row = try await row(id: id)
        let list = try await resolveList(of: row, hint: listHint)
        knownLists[id] = list
        return observe(item: Self.item(row, listId: list, section: sectionLists.contains(list) ? row.section : nil))
    }

    /// The list a `get_reminder` row is in: the hint, else the only list with the row's title, else (a title shared
    /// by several lists) the list the reminder was last exported in, as long as that list still has that title.
    private func resolveList(of row: Row, hint: String?) async throws -> String {
        if let hint { return hint }
        if listId(forTitle: row.list) == nil, titleToIds[row.list ?? ""] == nil { _ = try await refreshLists() }
        if let unique = listId(forTitle: row.list) { return unique }
        if let known = knownLists[row.id], idToTitle[known] == row.list { return known }
        throw RemCTLError.tool("Could not tell which Reminders list \"\(row.list ?? "")\" is; its title is not unique")
    }

    /// Reminder id -> list id for the export rows. A row only names its list by title, so when several lists share a
    /// title each of them is exported by id (`remctl export --list-id N`) to place its rows. `needed` limits that extra
    /// work to titles that involve one of those lists (empty: all). A needed row that cannot be placed throws: a pass
    /// must never read "could not tell which list" as "the list is empty", which would look like deletions.
    private func listsOfRows(_ rows: [JSONValue], needed: Set<String>) async throws -> [Int: String] {
        var map: [Int: String] = [:]
        var shared: Set<String> = []
        for json in rows {
            guard let id = json["id"]?.int, let title = json["list"]?.string, let ids = titleToIds[title] else { continue }
            if ids.count == 1 { map[id] = ids[0] } else { shared.insert(title) }
        }
        for title in shared.sorted() {
            let ids = titleToIds[title] ?? []
            guard needed.isEmpty || !needed.isDisjoint(with: ids) else { continue }
            for list in ids.sorted() {
                let output = try await transport.runCLI(["export", "--list-id", list, "--json"])
                guard let own = output.array ?? output["items"]?.array else {
                    throw RemCTLError.tool("Unexpected export output from RemCTL for list \(list)")
                }
                for json in own { if let id = json["id"]?.int { map[id] = list } }
            }
            if rows.contains(where: { $0["list"]?.string == title && $0["id"]?.int.map { map[$0] == nil } == true }) {
                throw RemCTLError.tool("Could not tell which of the Reminders lists named \"\(title)\" a reminder is in")
            }
        }
        knownLists.merge(map) { $1 }
        return map
    }

    private func exportRows() async throws -> [JSONValue] {
        let output = try await transport.runCLI(["export", "--json"])
        if let rows = output.array { return rows }
        if output["truncated"]?.flag == true { throw RemCTLError.tool("RemCTL truncated the export") }
        if let rows = output["items"]?.array { return rows }
        throw RemCTLError.tool("Unexpected export output from RemCTL")
    }

    // MARK: Synthesized modification time

    /// Maps export rows to items (skipping subtasks and rows without a known list), stamps `lastModified`, and
    /// prunes stored hashes for reminders that no longer exist. `sectionsLoaded` are the section-mirroring lists whose
    /// sections this read loaded: rows of the other such lists are left alone, because hashing them without their
    /// section would stamp every sectioned reminder there as modified now.
    private func observe(_ rows: [JSONValue], lists: [Int: String], sections: [Int: String], sectionsLoaded: Set<String>) -> [ReminderItem] {
        var items: [ReminderItem] = []
        var seen: Set<String> = []
        // Subtask rows are not reminders of their own: each is listed on its parent (checklist items in Things).
        var subtasks: [Int: [ReminderSubtask]] = [:]
        for json in rows {
            guard let row = Row(json), row.isSubtask, let parent = row.parentId else { continue }
            subtasks[parent, default: []].append(ReminderSubtask(id: String(row.id), title: row.title, completed: row.completed))
        }
        for json in rows {
            guard let row = Row(json) else { continue }
            seen.insert(String(row.id))
            if row.isSubtask { continue }
            guard let list = lists[row.id] else { continue }
            if sectionLists.contains(list), !sectionsLoaded.contains(list) { continue }
            let section = sectionLists.contains(list) ? sections[row.id] : nil
            items.append(observe(item: Self.item(row, listId: list, section: section, subtasks: subtasks[row.id] ?? []),
                                 subtasksKnown: true, persist: false))
        }
        for id in observed.keys where !seen.contains(id) { observed[id] = nil }
        persistObserved()
        return items
    }

    /// Stamps the item and each of its fields. `subtasksKnown` is true for export reads only: a `get_reminder` row
    /// does not list subtasks, so a single read leaves the subtask stamp alone.
    private func observe(item: ReminderItem, subtasksKnown: Bool = false, persist: Bool = true) -> ReminderItem {
        loadObservedIfNeeded()
        let hash = Self.contentHash(item)
        let now = clock()
        let old = observed[item.id]
        let unchanged = old?.hash == hash
        let stamp = unchanged ? old!.stamp : now
        // A field with no stamp yet (an entry from before per-field stamps, or subtasks first read now) is as old as
        // the reminder's one stamp when the reminder is otherwise unchanged; else it cannot be told apart from an edit.
        var fields = old?.fields ?? [:]
        for (field, value) in Self.fieldDigests(item) where subtasksKnown || field != .checklist {
            if let known = fields[field.rawValue] {
                if known.hash != value { fields[field.rawValue] = FieldStamp(hash: value, stamp: now) }
            } else {
                fields[field.rawValue] = FieldStamp(hash: value, stamp: stamp)
            }
        }
        observed[item.id] = Observed(hash: hash, stamp: stamp, fields: fields)
        var result = item
        result.lastModified = stamp
        result.fieldModified = fields.mapValues(\.stamp)
        if persist { persistObserved() }
        return result
    }

    private func loadObservedIfNeeded() {
        guard !observedLoaded else { return }
        observedLoaded = true
        if let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode([String: Observed].self, from: data) {
            observed = stored
        }
    }

    private var lastPersisted: [String: Observed] = [:]

    private func persistObserved() {
        loadObservedIfNeeded()
        guard observed != lastPersisted else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(observed).write(to: stateURL, options: .atomic)
            lastPersisted = observed
        } catch {
            logger.error("Could not save remctl-observed.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Mapping and formatting helpers

    private static func item(_ row: Row, listId: String, section: String?, subtasks: [ReminderSubtask] = []) -> ReminderItem {
        ReminderItem(id: String(row.id), externalId: row.deepLink, listId: listId, title: row.title, notes: row.notes,
                     due: row.due, completed: row.completed, completionDate: row.completionDate,
                     lastModified: nil, isRepeating: row.isRepeating, section: section, recurrence: row.recurrence,
                     url: row.url, tags: row.tags, flagged: row.flagged, subtasks: subtasks,
                     parentId: row.parentId.map(String.init), priority: row.priority)
    }

    static func contentHash(_ item: ReminderItem) -> String {
        let due = item.due.map { "\($0.day)/\($0.minutes.map(String.init) ?? "-")" } ?? "-"
        let completion = item.completionDate.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        var parts = [item.title, item.notes, due, item.completed ? "1" : "0", completion, item.listId]
        if let rule = item.recurrence { parts.append("rule:" + stableDescription(rule)) } else if item.isRepeating { parts.append("rule:?") }
        if let section = item.section { parts.append(section) }   // appended only when set, so hashes of unsectioned items are unchanged
        // The same holds for the fields below: items without a link, tags, flag or subtasks keep their old hash.
        if let url = item.url { parts.append("url:" + url) }
        if !item.tags.isEmpty { parts.append("tags:" + item.tags.sorted().joined(separator: ",")) }
        if item.flagged { parts.append("flagged") }
        if item.priority != .none { parts.append("priority:" + item.priority.rawValue) }
        // Subtasks are left out on purpose: `get_reminder` rows do not list them, and the stamp only decides which side's
        // edit is newer; subtasks merge without it.
        return sha(parts.joined(separator: "\u{1F}"))
    }

    /// A short digest of each field's value (the file never holds the text itself).
    static func fieldDigests(_ item: ReminderItem) -> [SyncField: String] {
        let sep = "\u{1F}"
        let due = item.due.map { "\($0.day)/\($0.minutes.map(String.init) ?? "-")" } ?? "-"
        let completion = item.completionDate.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let values: [SyncField: String] = [
            .title: item.title,
            .notes: item.notes,
            .due: due,
            .completion: (item.completed ? "1" : "0") + sep + completion,
            .placement: item.listId + sep + (item.section ?? ""),
            .rule: item.recurrence.map(stableDescription) ?? (item.isRepeating ? "?" : ""),
            .url: item.url ?? "",
            .tags: item.tags.sorted().joined(separator: ","),
            .flagged: item.flagged ? "1" : "0",
            .checklist: item.subtasks.map { $0.title + sep + ($0.completed ? "1" : "0") }.sorted().joined(separator: sep + sep),
        ]
        return values.mapValues { String(sha($0).prefix(16)) }
    }

    /// Deterministic text for a rule (Swift's `hashValue` changes on every launch and these hashes are persisted).
    private static func stableDescription(_ rule: RepeatRule) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(rule)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    private static func sha(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `2026-11-09T09:00:00` (local). With `allDay` the time part is ignored, unless `displayDate` (the time
    /// Reminders shows the item at, from an alert on the due day) carries a time on that same day: Reminders then
    /// shows "Nov 9, 9:00 AM", so the item is read as due at that time.
    static func parseDue(_ text: String, allDay: Bool, displayDate: String? = nil) -> DueDate? {
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard let day = parts.first, day.count == 10, day.split(separator: "-").count == 3 else { return nil }
        if allDay, let displayDate, let shown = parseDue(displayDate, allDay: false), shown.day == day,
           let minutes = shown.minutes, minutes > 0 {
            return shown
        }
        guard !allDay, parts.count == 2 else { return DueDate(day: day) }
        let time = parts[1].split(separator: ":").prefix(2).compactMap { Int($0) }
        guard time.count == 2 else { return DueDate(day: day) }
        return DueDate(day: day, minutes: time[0] * 60 + time[1])
    }

    /// `2026-10-15T15:58:16.078038` or `2026-11-09T09:00:00`, in the local time zone.
    static func parseLocal(_ text: String) -> Date? {
        let halves = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard halves.count == 2 else { return nil }
        let date = halves[0].split(separator: "-").compactMap { Int($0) }
        let timeText = halves[1].split(separator: ".", maxSplits: 1).map(String.init)
        let time = timeText[0].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, time.count >= 2 else { return nil }
        let nanos = timeText.count > 1 ? Int((Double("0." + timeText[1]) ?? 0) * 1e9) : 0
        let components = DateComponents(year: date[0], month: date[1], day: date[2], hour: time[0], minute: time[1],
                                        second: time.count > 2 ? time[2] : 0, nanosecond: nanos)
        return Calendar.current.date(from: components)
    }

    /// `2026-11-09T09:00:00`, local.
    static func localISO(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The `due` argument, plus an `alarm` at the same instant for timed dues so Reminders notifies
    /// (mirrors the Things reminder).
    static func dueSpec(_ due: DueDate) -> (due: String, alarm: String?)? {
        guard due.day.split(separator: "-").count == 3 else { return nil }
        guard let minutes = due.minutes else { return (due.day, nil) }
        let hhmm = String(format: "%02d:%02d", minutes / 60, minutes % 60)
        return ("\(due.day) \(hhmm)", "\(due.day)T\(hhmm):00")
    }
}
