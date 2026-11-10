import Foundation
import SyncCore

/// Backends for `trs-admin dry-run`: reads go to the real service, writes are printed and never sent.
/// Created items get placeholder ids, so later steps in the same pass can refer to them.

actor DryRunThings: ThingsBackend {
    let real: any ThingsBackend
    private var next = 0
    init(real: any ThingsBackend) { self.real = real }

    private func fakeId(_ kind: String) -> String { next += 1; return "DRYRUN-\(kind)-\(next)" }
    private func say(_ s: String) { print("THINGS  \(s)") }

    func refresh() async throws -> ThingsRefreshResult { try await real.refresh() }
    func createTodo(_ d: ThingsTodoDraft) async throws -> String {
        say("create to-do \"\(d.title)\" when=\(d.when.map(describe) ?? "none") placement=\(d.placement) tags=\(d.tagIds)"
            + (d.recurrence.map { " REPEAT=\($0)" } ?? ""))
        return fakeId("todo")
    }
    func updateTodo(id: String, patch: ThingsTodoPatch) async throws { say("update \(id): \(patch)") }
    func stopRepeating(templateId: String) async throws -> String {
        say("STOP repeating \(templateId): delete the template, detach its open occurrences, create a plain to-do for its next day")
        return fakeId("todo")
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
    init(real: any RemindersBackend) { self.real = real }

    private func say(_ s: String) { print("REMIND  \(s)") }

    func access() async -> RemindersAccess { await real.access() }
    func requestAccess() async throws -> RemindersAccess { try await real.requestAccess() }
    func lists() async throws -> [ReminderList] { try await real.lists() }
    func reminders(inLists listIds: [String]) async throws -> [ReminderItem] {
        let items = try await real.reminders(inLists: listIds)
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
        seen[item.id] = item
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
        seen[id] = r
        return r
    }
    func delete(id: String) async throws { say("DELETE \(id) \"\(seen[id]?.title ?? "?")\"") }
    nonisolated func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func takeCreatedSections() async -> [CreatedReminderSection] { [] }
    func deleteSection(name: String, listId: String) async throws { say("DELETE section \"\(name)\" in \(listId)") }
}

private func describe(_ d: DueDate) -> String { d.minutes.map { "\(d.day) \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? d.day }

/// One full pass with writes printed instead of sent. Nothing is saved.
func runDryRun(config: SyncConfig, links: LinkStore, things: any ThingsBackend, reminders: any RemindersBackend) async throws {
    let engine = SyncEngine(things: DryRunThings(real: things), reminders: DryRunReminders(real: reminders))
    let report = try await engine.sync(config: config, links: links, scope: .full)
    print("read: \(report.reminders.count) reminders, \(report.snapshot.tasks.count) Things tasks, \(config.mappings.filter(\.enabled).count) enabled mappings, \(links.links.count) links")
    for entry in report.log { print("[\(entry.level.rawValue)] \(entry.message)") }
    print("DRY RUN: would create \(report.createdInThings) in Things, \(report.createdInReminders) in Reminders; update \(report.updatedInThings) / \(report.updatedInReminders); delete \(report.deletedInThings) / \(report.deletedInReminders); link \(report.linked); unlink \(report.unlinked); failures \(report.failures). Nothing was written or saved.")
}
