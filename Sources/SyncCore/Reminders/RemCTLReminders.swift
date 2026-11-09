import CryptoKit
import Foundation
import os

/// `RemindersBackend` over RemCTL (`remctl`, whose signed Capability Host holds the Reminders permission).
/// The app itself never needs Reminders access.
///
/// - Writes and list lookups go through one long-lived `remctl mcp serve` session.
/// - Reads use one `remctl export --json` run (all reminders, completed included). MCP tool results are
///   capped, which cuts a full export to a fraction of the rows, so the export runs as a one-shot process.
/// - RemCTL has no modification date, so `lastModified` is synthesized: a content hash per reminder id
///   (title, notes, due, completion, list) is kept in memory and in `remctl-observed.json`. When a hash is
///   new or changed the item is stamped with the time it was first seen that way; otherwise the stored
///   stamp is kept. Conflict resolution therefore has the resolution of the poll interval, and the first
///   run after install treats every reminder as modified "now".
/// - There is no push, so `changes()` polls the export and yields when the watched lists' content changes.
public actor RemCTLReminders: RemindersBackend {
    private struct Observed: Codable, Equatable { var hash: String; var stamp: Date }

    private let transport: any RemCTLTransport
    private let stateURL: URL
    private let clock: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.oliverames.ThingsRemindersSync", category: "RemCTL")

    private var pollSeconds: Double
    private var watched: Set<String> = []
    private var executablePath: String?
    private var titleToIds: [String: [String]] = [:]
    private var idToTitle: [String: String] = [:]
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
        return observe(try await exportRows()).filter { wanted.contains($0.listId) }
    }

    // MARK: Writing

    public func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String) async throws -> ReminderItem {
        guard let numericList = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
        var args: [String: JSONValue] = ["title": .string(title), "list_id": .number(Double(numericList))]
        if !notes.isEmpty { args["notes"] = .string(notes) }
        if let due, let spec = Self.dueSpec(due) {
            args["due"] = .string(spec.due)
            if let alarm = spec.alarm { args["alarm"] = .string(alarm) }
        }
        let created = try await transport.callTool("create_reminder", arguments: args)
        guard let id = created["id"]?.int else { throw RemCTLError.tool("RemCTL did not return the new reminder id") }
        if completed {
            var done: [String: JSONValue] = ["reminder_id": .number(Double(id)), "completed": true]
            if let completionDate { done["completion_date"] = .string(Self.localISO(completionDate)) }
            _ = try await transport.callTool("set_completion", arguments: done)
        }
        return try await fetch(id: id, listHint: listId)
    }

    public func update(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        guard let numeric = Int(id) else { throw RemCTLError.tool("Reminder not found") }
        let reminderId: JSONValue = .number(Double(numeric))
        var fields: [String: JSONValue] = [:]
        if let title = patch.title { fields["title"] = .string(title) }
        if let notes = patch.notes { fields["notes"] = .string(notes) }   // "" clears the notes
        if let due = patch.due {
            if let due, let spec = Self.dueSpec(due) {
                fields["due"] = .string(spec.due)
                fields["alarm"] = .string(spec.alarm ?? "clear")   // an all-day due must not keep a stale alarm
            } else {
                fields["due"] = "clear"
                fields["alarm"] = "clear"
            }
        }
        if let listId = patch.listId {
            guard let numericList = Int(listId) else { throw RemCTLError.tool("Reminders list not found") }
            fields["list_id"] = .number(Double(numericList))
        }
        if !fields.isEmpty {
            fields["reminder_id"] = reminderId
            _ = try await transport.callTool("update_reminder", arguments: fields)
        }
        if let completed = patch.completed {
            var done: [String: JSONValue] = ["reminder_id": reminderId, "completed": .bool(completed)]
            // RemCTL rejects a completion date on a recurring reminder.
            if completed, let date = patch.completionDate, try await row(id: numeric).isRepeating == false {
                done["completion_date"] = .string(Self.localISO(date))
            }
            _ = try await transport.callTool("set_completion", arguments: done)
        }
        return try await fetch(id: numeric, listHint: patch.listId)
    }

    public func delete(id: String) async throws {
        guard let numeric = Int(id) else { return }
        do {
            _ = try await transport.callTool("delete_reminder", arguments: ["reminder_id": .number(Double(numeric))])
        } catch let error as RemCTLError where error.kind == .tool && error.message.lowercased().contains("not found") {
            return   // already gone
        }
        observed[id] = nil
        persistObserved()
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
                let items = observe(try await exportRows())
                let scope = watched
                let digest = digest(of: items.filter { scope.isEmpty || scope.contains($0.listId) })
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
        for entry in result["items"]?.array ?? [] {
            guard let numeric = entry["id"]?.int, let title = entry["title"]?.string, entry["isGroup"]?.flag != true else { continue }
            let id = String(numeric)
            lists.append(ReminderList(id: id, title: title, colorHex: entry["color"]?["hex"]?.string, allowsModifications: true))
            byTitle[title, default: []].append(id)
        }
        titleToIds = byTitle
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
        var isSubtask: Bool
        var deepLink: String?

        init?(_ json: JSONValue) {
            guard let id = json["id"]?.int else { return nil }
            self.id = id
            title = json["title"]?.string ?? ""
            list = json["list"]?.string
            notes = json["notes"]?.string ?? ""
            let allDay = json["allDay"]?.flag ?? false
            due = json["dueDate"]?.string.flatMap { RemCTLReminders.parseDue($0, allDay: allDay) }
            completed = json["completed"]?.flag ?? false
            completionDate = json["completionDate"]?.string.flatMap(RemCTLReminders.parseLocal)
            isRepeating = json["recurrence"].map { !$0.isNull } ?? false
            isSubtask = json["isSubtask"]?.flag ?? false
            deepLink = json["deepLink"]?.string
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
        if listId(forTitle: row.list) == nil, listHint == nil { _ = try await refreshLists() }
        guard let list = listHint ?? listId(forTitle: row.list) else {
            throw RemCTLError.tool("Could not tell which Reminders list \"\(row.list ?? "")\" is; its title is not unique")
        }
        return observe(item: Self.item(row, listId: list))
    }

    private func exportRows() async throws -> [JSONValue] {
        let output = try await transport.runCLI(["export", "--json"])
        if let rows = output.array { return rows }
        if output["truncated"]?.flag == true { throw RemCTLError.tool("RemCTL truncated the export") }
        if let rows = output["items"]?.array { return rows }
        throw RemCTLError.tool("Unexpected export output from RemCTL")
    }

    // MARK: Synthesized modification time

    /// Maps export rows to items (skipping subtasks and lists whose title is ambiguous), stamps
    /// `lastModified`, and prunes stored hashes for reminders that no longer exist.
    private func observe(_ rows: [JSONValue]) -> [ReminderItem] {
        var items: [ReminderItem] = []
        var seen: Set<String> = []
        var skipped: Set<String> = []
        for json in rows {
            guard let row = Row(json) else { continue }
            seen.insert(String(row.id))
            if row.isSubtask { continue }
            guard let list = listId(forTitle: row.list) else {
                if let title = row.list, (titleToIds[title]?.count ?? 0) > 1 { skipped.insert(title) }
                continue
            }
            items.append(observe(item: Self.item(row, listId: list), persist: false))
        }
        for title in skipped { logger.warning("Skipping reminders in \(title, privacy: .public): several lists share that title") }
        for id in observed.keys where !seen.contains(id) { observed[id] = nil }
        persistObserved()
        return items
    }

    private func observe(item: ReminderItem, persist: Bool = true) -> ReminderItem {
        loadObservedIfNeeded()
        let hash = Self.contentHash(item)
        var stamp = observed[item.id]?.stamp ?? clock()
        if observed[item.id]?.hash != hash {
            stamp = clock()
            observed[item.id] = Observed(hash: hash, stamp: stamp)
        }
        var result = item
        result.lastModified = stamp
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

    private static func item(_ row: Row, listId: String) -> ReminderItem {
        ReminderItem(id: String(row.id), externalId: row.deepLink, listId: listId, title: row.title, notes: row.notes,
                     due: row.due, completed: row.completed, completionDate: row.completionDate,
                     lastModified: nil, isRepeating: row.isRepeating)
    }

    static func contentHash(_ item: ReminderItem) -> String {
        let due = item.due.map { "\($0.day)/\($0.minutes.map(String.init) ?? "-")" } ?? "-"
        let completion = item.completionDate.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return sha([item.title, item.notes, due, item.completed ? "1" : "0", completion, item.listId].joined(separator: "\u{1F}"))
    }

    private static func sha(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `2026-11-09T09:00:00` (local). With `allDay` the time part is ignored.
    static func parseDue(_ text: String, allDay: Bool) -> DueDate? {
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard let day = parts.first, day.count == 10, day.split(separator: "-").count == 3 else { return nil }
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
