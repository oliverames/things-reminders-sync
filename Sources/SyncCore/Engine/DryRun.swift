import Foundation

/// The writes one dry-run pass would make, in order. `echo` receives each line as it is planned.
public final class DryRunPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let echo: (@Sendable (String) -> Void)?
    public init(echo: (@Sendable (String) -> Void)? = nil) { self.echo = echo }
    public var lines: [String] { lock.withLock { stored } }
    func add(_ line: String) { lock.withLock { stored.append(line) }; echo?(line) }
}

public struct DryRunResult: Sendable {
    public var report: SyncReport
    /// One line per write the pass would have sent. Empty when the next real full pass would change nothing.
    public var writes: [String]
}

/// One full pass against real data with every write recorded instead of sent, for `trs-admin dry-run`.
/// It reads what the app's full pass reads: the same engine, the same saved links (ledger, owned sections, paused
/// mappings), and a RemCTL backend set up from the config exactly as `SyncCoordinator` sets up its own, so sections are
/// read for the lists that mirror them. Nothing is written or saved.
public enum DryRun {
    /// A RemCTL backend for a dry run: it reads the app's observed stamps and never saves them.
    public static func remindersBackend(executablePath: String?) -> RemCTLReminders {
        RemCTLReminders(executablePath: executablePath, savesObservedState: false)
    }

    /// `backfillLog` is the app's saved log, passed like the coordinator passes it: only until the ledger backfill ran.
    public static func run(config: SyncConfig, links: LinkStore, things: any ThingsBackend, reminders: any RemindersBackend,
                           forceDeletions: Bool = false, log: [SyncLogEntry] = [],
                           echo: (@Sendable (String) -> Void)? = nil) async throws -> DryRunResult {
        // Without this the backend reads no sections, and every sectioned reminder looks unsectioned.
        if let remctl = reminders as? RemCTLReminders { await remctl.apply(config) }
        let plan = DryRunPlan(echo: echo)
        let engine = SyncEngine(things: DryRunThings(real: things, plan: plan), reminders: DryRunReminders(real: reminders, plan: plan))
        let report = try await engine.sync(config: config, links: links, scope: .full, forceDeletions: forceDeletions,
                                           backfillLog: links.ledgerBackfilled ? nil : log)
        return DryRunResult(report: report, writes: plan.lines)
    }
}

/// Dry-run backends: reads go to the real service, writes are recorded and never sent.
/// Created items get placeholder ids, so later steps in the same pass can refer to them.

actor DryRunThings: ThingsBackend {
    let real: any ThingsBackend
    private var next = 0
    private let plan: DryRunPlan
    init(real: any ThingsBackend, plan: DryRunPlan) { self.real = real; self.plan = plan }

    private func fakeId(_ kind: String) -> String { next += 1; return "DRYRUN-\(kind)-\(next)" }
    private func say(_ s: String) { plan.add("THINGS  \(s)") }

    func refresh() async throws -> ThingsRefreshResult { try await real.refresh() }
    func createTodo(_ d: ThingsTodoDraft) async throws -> String {
        say("create to-do \"\(d.title)\" when=\(d.when.map(describe) ?? "none") placement=\(d.placement) tags=\(d.tagIds)"
            + (d.recurrence.map { " REPEAT=\($0)" } ?? ""))
        return fakeId("todo")
    }
    func updateTodo(id: String, patch: ThingsTodoPatch) async throws { say("update \(id): \(patch)") }
    func stopRepeating(templateId: String) async throws -> ThingsStopResult {
        say("STOP repeating \(templateId): delete the template and its checklist items, detach its open occurrences, create a plain to-do with the same checklist for its next day")
        return ThingsStopResult(todoId: fakeId("todo"))
    }
    func createProject(title: String, areaId: String?) async throws -> String { say("create project \"\(title)\""); return fakeId("project") }
    func createHeading(title: String, projectId: String) async throws -> String { say("create heading \"\(title)\" in \(projectId)"); return fakeId("heading") }
    func createArea(title: String) async throws -> String { say("create area \"\(title)\""); return fakeId("area") }
    func createTag(title: String, parentId: String?) async throws -> String { say("create tag \"\(title)\""); return fakeId("tag") }
    func deleteArea(id: String) async throws { say("DELETE area \(id)") }
    func deleteTag(id: String) async throws { say("DELETE tag \(id)") }
}

actor DryRunReminders: RemindersBackend {
    let real: any RemindersBackend
    private var seen: [String: ReminderItem] = [:]
    private var next = 0
    /// Reminders the plan deletes. Later reads in the same pass leave them out, as a real pass would see.
    private var deleted: Set<String> = []
    /// Reminders the plan creates or changes, as they would read back.
    private var planned: [String: ReminderItem] = [:]
    private let plan: DryRunPlan
    init(real: any RemindersBackend, plan: DryRunPlan) { self.real = real; self.plan = plan }

    private func say(_ s: String) { plan.add("REMIND  \(s)") }

    func access() async -> RemindersAccess { await real.access() }
    func requestAccess() async throws -> RemindersAccess { try await real.requestAccess() }
    func lists() async throws -> [ReminderList] { try await real.lists() }
    func reminders(inLists listIds: [String]) async throws -> [ReminderItem] {
        var items = try await real.reminders(inLists: listIds).filter { !deleted.contains($0.id) }.map { planned[$0.id] ?? $0 }
        let ids = Set(items.map(\.id))
        items += planned.values.filter { !ids.contains($0.id) && listIds.contains($0.listId) }.sorted { $0.id < $1.id }
        for i in items { seen[i.id] = i }
        return items
    }
    func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                section: String?, recurrence: RepeatRule?) async throws -> ReminderItem {
        say("create \"\(title)\" list=\(listId) due=\(due.map(describe) ?? "none") section=\(section ?? "-")"
            + (recurrence.map { " REPEAT=\($0)" } ?? ""))
        next += 1
        let item = ReminderItem(id: "DRYRUN-\(next)", listId: listId, title: title, notes: notes, due: due, completed: completed,
                                completionDate: completionDate, isRepeating: recurrence != nil, section: section, recurrence: recurrence)
        seen[item.id] = item; planned[item.id] = item
        return item
    }
    func update(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        say("update \(id) \"\(seen[id]?.title ?? "?")\": \(patch)")
        var r = seen[id] ?? ReminderItem(id: id, listId: patch.listId ?? "", title: patch.title ?? "")
        if let v = patch.title { r.title = v }
        if let v = patch.notes { r.notes = v }
        if let v = patch.due { r.due = v }
        if let v = patch.completed { r.completed = v }
        if let v = patch.listId { r.listId = v }
        if let v = patch.section { r.section = v }
        if let v = patch.recurrence { r.recurrence = v; r.isRepeating = v != nil }
        if let v = patch.url { r.url = v }
        if let v = patch.flagged { r.flagged = v }
        if let v = patch.tags { r.tags = v }
        for (i, title) in (patch.addSubtasks ?? []).enumerated() { r.subtasks.append(ReminderSubtask(id: "\(id)-sub\(r.subtasks.count + i)", title: title)) }
        seen[id] = r; planned[id] = r
        return r
    }
    func delete(id: String) async throws {
        say("DELETE \(id) \"\(seen[id]?.title ?? "?")\"")
        deleted.insert(id); planned[id] = nil
    }
    nonisolated func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func takeCreatedSections() async -> [CreatedReminderSection] { [] }
    func deleteSection(name: String, listId: String) async throws { say("DELETE section \"\(name)\" in \(listId)") }
}

private func describe(_ d: DueDate) -> String { d.minutes.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" }.map { "\(d.day) \($0)" } ?? d.day }
