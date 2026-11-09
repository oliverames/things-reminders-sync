import Foundation
import Testing
@testable import SyncCore

// Explicit teardown of one list, and removal of completed copies.

private func appWorld() -> World {
    World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: nil, targetTitle: "Alpha")])
}

/// L1 synced into an app-created project with a mix of items:
/// "Both" existed on both sides (original pair), "From reminder" became a Things copy, "From Things" a reminder copy.
private func mixedWorld() async throws -> World {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    await w.things.add(projectTask("PX"))
    await w.things.add(todo("t1", "Both", project: "PX"))
    await w.reminders.add(reminder("r1", "L1", "Both"))
    try await w.sync()                                    // first link: "Both" pairs
    await w.reminders.add(reminder("r2", "L1", "From reminder"))
    await w.things.add(todo("t3", "From Things", project: "PX"))
    try await w.sync()
    #expect(w.links.links.count == 3)
    return w
}

private func engine(_ w: World) -> SyncEngine { SyncEngine(things: w.things, reminders: w.reminders) }

private func preview(_ w: World, _ id: String = "L1") async throws -> TeardownPreview {
    let snapshot = try await w.things.refresh().snapshot
    let items = try await w.reminders.reminders(inLists: ["L1"])
    return Teardown.preview(listId: id, config: w.config, store: w.links, snapshot: snapshot, reminders: items, groceryLists: [])
}

@Test func teardownRemovesCopiesOnTheRightSideAndKeepsOriginals() async throws {
    var w = try await mixedWorld()
    let p = try await preview(w)
    #expect(p.thingsTodosToTrash == 1 && p.remindersToDelete == 1 && p.originalsKept == 1)
    await w.things.clearRecords()

    let report = try await engine(w).teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: false)
    #expect(report.completed && report.thingsTrashed == 1 && report.remindersDeleted == 1)
    let thingsCopy = try #require(w.links.links.first { $0.copySide == .things })
    let reminderCopy = try #require(w.links.links.first { $0.copySide == .reminders })
    #expect(await w.things.trashCalls() == [thingsCopy.thingsId])                    // Things: trash, never a delete
    #expect(await w.things.task(thingsCopy.thingsId)?.trashed == true)
    #expect(await w.reminders.deletes == [reminderCopy.reminderId])
    #expect(await w.things.task("t1")?.trashed == false && w.links.links.contains { $0.reminderId == "r1" })
    #expect(await w.reminders.item("r1") != nil)                                     // the original pair survives on both sides
    #expect(await w.things.task(reminderCopy.thingsId)?.trashed == false)            // the original to-do of a reminder copy stays
    // Every removal is logged; links, first-link marker are gone; the mapping is off but kept.
    #expect(report.log.filter { $0.level == .change }.count == 2)
    #expect(report.links.links.isEmpty && report.links.linkedMappings["L1"] == nil)
    #expect(report.config.mappings.count == 1 && report.config.mappings[0].enabled == false)
    #expect(await w.things.deletedAreas.isEmpty)
}

@Test func teardownWithoutRemoveCopiesOnlyDropsTheLinks() async throws {
    let w = try await mixedWorld()
    await w.things.clearRecords()
    let report = try await engine(w).teardown(config: w.config, links: w.links, listId: "L1", removeCopies: false, removeMapping: false)
    #expect(report.thingsTrashed == 0 && report.remindersDeleted == 0 && report.containersRemoved == 0)
    #expect(await w.things.updates.isEmpty)
    #expect(await w.reminders.deletes.isEmpty)
    #expect(report.links.links.isEmpty && report.links.linkedMappings.isEmpty)
    #expect(await w.things.all().count == 3)
    #expect(await w.reminders.all(in: "L1").count == 3)
}

@Test func removeMappingDropsTheMappingAndParkedAndDetachedMarks() async throws {
    var w = try await mixedWorld()
    let first = w.links.links[0]
    w.links.links.removeAll { $0.id == first.id }
    w.links.parkedLinks = [first]
    w.links.detachedThingsIds = [first.thingsId, "elsewhere"]
    w.links.detachedReminderIds = [first.reminderId, "other"]
    let report = try await engine(w).teardown(config: w.config, links: w.links, listId: "L1", removeCopies: false, removeMapping: true)
    #expect(report.config.mappings.isEmpty)
    #expect(report.links.parkedLinks.isEmpty && report.links.links.isEmpty)
    #expect(report.links.detachedThingsIds.contains("elsewhere") == true)
    #expect(report.links.detachedReminderIds.contains(first.reminderId) == false)
    #expect(report.links.detachedThingsIds.contains(first.thingsId) == false)
}

@Test func teardownRemovesAppCreatedContainersOnlyWhenEmpty() async throws {
    // Only copies in an app-created project and heading: everything goes, project and heading to the Trash.
    var w = appWorld()
    await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
    await w.reminders.add(reminder("r2", "L1", "Two"))
    try await w.sync()
    let project = try #require(w.config.mappings[0].targetId)
    let heading = try #require(w.links.ownedThings.first { $0.kind == .heading }?.id)
    await w.reminders.addSection("L1", "Mine")
    w.links.ownedSections = [OwnedReminderSection(listId: "L1", name: "Plans")]
    await w.reminders.addSection("L1", "Plans")
    let p = try await preview(w)
    #expect(p.thingsTodosToTrash == 2 && p.thingsContainersToRemove == 2 && p.remindersSectionsToRemove == 1)
    await w.things.clearRecords()
    let report = try await engine(w).teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: false)
    #expect(report.completed && report.containersRemoved == 2 && report.sectionsRemoved == 1)
    #expect(await w.reminders.sectionDeletes == ["L1:Plans"])   // the user's "Mine" section stays
    let trashed = await w.things.trashCalls()
    #expect(Set(trashed).isSuperset(of: [project, heading]) && trashed.count == 4)
    #expect(report.links.ownedThings.isEmpty)
    #expect(await w.things.all().count == 2)                                           // still there, in the Trash
    #expect(report.config.mappings[0].targetId == nil)                                 // the removed project is no longer the target

    // An original in the app-created project keeps it alive; a user section is never deleted.
    var m = appWorld()
    await m.reminders.add(reminder("r1", "L1", "Copy"))
    try await m.sync()
    let proj = try #require(m.config.mappings[0].targetId)
    await m.things.add(todo("tu", "User's own", project: proj))                         // unlinked, still counts
    let kept = try await engine(m).teardown(config: m.config, links: m.links, listId: "L1", removeCopies: true, removeMapping: false)
    #expect(kept.thingsTrashed == 1 && kept.containersRemoved == 0)
    #expect(kept.links.ownedThings.contains { $0.id == proj })
    #expect(kept.config.mappings[0].targetId == proj)
}

@Test func userCreatedTargetIsNeverRemoved() async throws {
    let w = try await mixedWorld()
    let report = try await engine(w).teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: true)
    #expect(report.containersRemoved == 0)
    #expect(await w.things.task("PX")?.trashed == false)
}

@Test func teardownIsNotHeldBackByTheDeletionSafetyLimit() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    await w.things.add(projectTask("PX"))
    for i in 0..<14 { await w.reminders.add(reminder("r\(i)", "L1", "Item \(i)")) }
    try await w.sync()
    #expect(w.links.links.count == 14 && w.links.links.allSatisfy { $0.copySide == .things })
    // A normal pass holds back this many deletions (limit 10) ...
    for l in w.links.links { await w.reminders.remove(l.reminderId) }
    let held = try await w.sync()
    #expect(held.deletionsHeld)
    // ... the confirmed teardown does not.
    var w2 = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    await w2.things.add(projectTask("PX"))
    for i in 0..<14 { await w2.reminders.add(reminder("r\(i)", "L1", "Item \(i)")) }
    try await w2.sync()
    let report = try await SyncEngine(things: w2.things, reminders: w2.reminders)
        .teardown(config: w2.config, links: w2.links, listId: "L1", removeCopies: true, removeMapping: false)
    #expect(report.thingsTrashed == 14 && report.completed)
    #expect(await w2.things.trashCalls().count == 14)
}

@Test func completedCopiesAreRemovedOnTheRightSideAndNotRecreated() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    w.config.includeCompletedOnFirstLink = true
    await w.things.add(projectTask("PX"))
    await w.things.add(todo("t1", "Done both", project: "PX", status: .completed))
    await w.reminders.add(reminder("r1", "L1", "Done both", done: true))                  // original pair
    await w.reminders.add(reminder("r2", "L1", "Done in reminders", done: true))          // -> Things copy
    await w.things.add(todo("t3", "Done in Things", project: "PX", status: .completed))   // -> reminder copy
    await w.reminders.add(reminder("r4", "L1", "Open one"))
    try await w.sync()
    #expect(w.links.links.filter(\.copiedCompleted).count == 2)
    let report = try await engine(w).removeCompletedCopies(config: w.config, links: w.links)
    #expect(report.thingsTrashed == 1 && report.remindersDeleted == 1 && report.completed)
    #expect(await w.things.task("t1")?.trashed == false)   // original pair kept
    #expect(await w.reminders.item("r1") != nil)
    #expect(await w.things.task("t3")?.trashed == false)                                    // the original of a reminder copy stays
    #expect(await w.reminders.item("r2") != nil)
    #expect(report.links.links.count == 2 && report.links.links.allSatisfy { !$0.copiedCompleted })
    w.links = report.links
    w.config.includeCompletedOnFirstLink = false
    let after = try await w.sync()
    #expect(after.createdInThings == 0 && after.createdInReminders == 0)
}

// MARK: Serialized with sync passes

/// Forwards to a `FakeReminders` but can hold `reminders(inLists:)` open, like a slow pass.
actor GatedReminders: RemindersBackend {
    let inner: FakeReminders
    private var blocked = false
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    init(_ inner: FakeReminders) { self.inner = inner }
    func block() { blocked = true }
    func release() { blocked = false; waiting?.resume(); waiting = nil }
    func access() async -> RemindersAccess { await inner.access() }
    func requestAccess() async throws -> RemindersAccess { try await inner.requestAccess() }
    func lists() async throws -> [ReminderList] { try await inner.lists() }
    func reminders(inLists ids: [String]) async throws -> [ReminderItem] {
        reads += 1
        if blocked { await withCheckedContinuation { waiting = $0 } }
        return try await inner.reminders(inLists: ids)
    }
    func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                section: String?) async throws -> ReminderItem {
        try await inner.create(title: title, notes: notes, due: due, completed: completed, completionDate: completionDate, listId: listId, section: section)
    }
    func update(id: String, patch: ReminderPatch) async throws -> ReminderItem { try await inner.update(id: id, patch: patch) }
    func delete(id: String) async throws { try await inner.delete(id: id) }
    nonisolated func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private struct StubCredentials: CredentialStore {
    func save(email: String, password: String) throws {}
    func load(email: String) throws -> String? { "pw" }
    func loadAccount() throws -> Credentials? { Credentials(email: "a@b.c", password: "pw") }
    func delete(email: String) throws {}
}

@MainActor
@Test func stopSyncingWaitsForTheRunningPass() async throws {
    let w = try await mixedWorld()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StateStore(directory: dir)
    try store.saveConfig(w.config)
    try store.saveLinks(w.links)
    let gated = GatedReminders(w.reminders)
    await gated.block()
    let things = w.things
    let coordinator = SyncCoordinator(dependencies: .init(
        stateStore: store, credentials: StubCredentials(), reminders: gated, remctl: nil,
        makeThings: { _, _ in things }, verifyThings: { _, _ in "key" }, runsObservers: false))
    await things.clearRecords()

    let pass = Task { @MainActor in await coordinator.start() }              // pass 1 stops inside the Reminders read
    while await gated.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(coordinator.teardownPreview(listId: "L1").copyCount >= 0)
    let stop = Task { @MainActor in await coordinator.stopSyncing(listId: "L1", removeCopies: true, removeMapping: true) }
    try await Task.sleep(for: .milliseconds(200))
    #expect(await gated.reads == 1)                                          // the teardown has not started reading
    #expect(await things.trashCalls().isEmpty)
    await gated.release()
    await pass.value
    await stop.value
    #expect(await things.trashCalls().count == 1)                            // the Things copy, once the pass was done
    #expect(await w.reminders.deletes.count == 1)
    #expect(coordinator.config.mappings.isEmpty)
    #expect(store.loadLinks().links.isEmpty)
}
