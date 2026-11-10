import Foundation
import Testing
@testable import SyncCore

// MARK: - Dry run

@Suite struct DryRunTests {
    /// Area mode with sections as projects, through the real RemCTL backend on a fake transport: "A" and "B" sit in
    /// section "Alpha" and their to-dos in project "Alpha". Returns the state the app's passes left behind.
    private func settled(_ fake: FakeRemCTL, _ things: FakeThings, dir: URL) async throws -> (SyncConfig, LinkStore) {
        await fake.put(FakeRemCTL.row(1, "A", ["section": "Alpha"]))
        await fake.put(FakeRemCTL.row(2, "B", ["section": "Alpha"]))
        await fake.put(FakeRemCTL.row(3, "Loose"))
        await fake.setSections(1, ["Alpha"])
        await things.addArea("A1", "Area")
        var config = SyncConfig(mappings: [ListMapping(id: "1", listTitle: "Work", mode: .area, targetId: "A1", targetTitle: "Area",
                                                       sectionsAsProjects: true)])
        var links = LinkStore()
        let app = makeBackend(fake, dir: dir)
        await app.apply(config)   // what SyncCoordinator.applyRemindersConfig does
        var last = SyncReport(config: config, links: links)
        for _ in 0..<3 {
            last = try await SyncEngine(things: things, reminders: app).sync(config: config, links: links, scope: .full)
            config = last.config; links = last.links
        }
        #expect(last.changeCount == 0 && links.links.count == 3)
        return (config, links)
    }

    @Test func settledSectionedListPlansNothingAndSavesNothing() async throws {
        let fake = FakeRemCTL(), things = FakeThings(), dir = tempDir()
        let (config, links) = try await settled(fake, things, dir: dir)
        let stateFile = dir.appendingPathComponent("remctl-observed.json")
        let stateBefore = try Data(contentsOf: stateFile)
        let thingsWrites = await things.updates.count + things.created.count

        // A fresh backend nobody configured, as trs-admin builds it: the wrapper must set it up like the app does.
        let dry = RemCTLReminders(transport: fake, stateDirectory: dir, savesObservedState: false)
        let result = try await DryRun.run(config: config, links: links, things: things, reminders: dry)

        #expect(result.writes.isEmpty)
        #expect(result.report.changeCount == 0 && result.report.removedContainers == 0 && result.report.failures == 0)
        #expect(result.report.reminders.first { $0.title == "A" }?.section == "Alpha")
        #expect(await fake.cliCalls.contains(["show", "--list-id", "1", "--completed", "--json"]))
        #expect(try Data(contentsOf: stateFile) == stateBefore)
        #expect(await things.updates.count + things.created.count == thingsWrites)
    }

    /// The fault this guards: the same pass over a backend that reads no sections plans to pull the to-dos out of
    /// their projects.
    @Test func withoutTheSectionSetupThePlanIsNotEmpty() async throws {
        let fake = FakeRemCTL(), things = FakeThings(), dir = tempDir()
        let (config, links) = try await settled(fake, things, dir: dir)
        let unconfigured = RemCTLReminders(transport: fake, stateDirectory: dir, savesObservedState: false)
        let plan = DryRunPlan()
        let engine = SyncEngine(things: DryRunThings(real: things, plan: plan), reminders: DryRunReminders(real: unconfigured, plan: plan))
        _ = try await engine.sync(config: config, links: links, scope: .full)
        #expect(!plan.lines.isEmpty)
    }

    @Test func plannedWritesAreRecordedAndNotSent() async throws {
        var w = World()
        await w.things.add(projectTask("P1"))
        await w.reminders.add(reminder("r1", "L1", "Buy milk"))
        let result = try await DryRun.run(config: w.config, links: w.links, things: w.things, reminders: w.reminders)
        #expect(result.writes.count == 1 && result.writes[0].hasPrefix("THINGS  create to-do \"Buy milk\""))
        #expect(await w.things.created.isEmpty)
        #expect(try await w.sync().createdInThings == 1)   // the real pass does what the plan said
    }
}

// MARK: - Held deletions

private func twoListWorld() async throws -> World {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "Family", mode: .project, targetId: "P1", targetTitle: "Family"),
        ListMapping(id: "L2", listTitle: "Chores", mode: .project, targetId: "P2", targetTitle: "Chores")])
    await w.things.add(projectTask("P1")); await w.things.add(projectTask("P2"))
    for i in 1...12 { await w.things.add(todo("a\(i)", "Family \(i)", project: "P1")) }   // copies land in Reminders
    for i in 1...6 { await w.reminders.add(reminder("b\(i)", "L2", "Chore \(i)")) }       // copies land in Things
    try await w.sync()
    for i in 1...12 { await w.things.edit("a\(i)") { $0.trashed = true } }                 // 12 reminders to delete
    for i in 1...5 { await w.reminders.remove("b\(i)") }                                   // 5 to-dos to trash
    return w
}

@Suite struct HeldDeletionsTests {
    @Test func reportSaysWhatIsHeldPerListAndSide() async throws {
        var w = try await twoListWorld()
        let r = try await w.sync()
        #expect(r.deletionsHeld && r.deletedInThings == 0 && r.deletedInReminders == 0)
        let family = try #require(r.heldDeletions.first { $0.mappingId == "L1" })
        #expect(family.remindersToDelete == 12 && family.todosToTrash == 0 && family.count == 12)
        #expect(family.titles.count == 5 && family.titles.allSatisfy { $0.hasPrefix("Family ") })
        #expect(family.summary == "12 deletions waiting in Family")
        #expect(family.detail == "Delete 12 reminders")
        #expect(family.confirmationMessage.contains("and 7 more"))
        let chores = try #require(r.heldDeletions.first { $0.mappingId == "L2" })
        #expect(chores.remindersToDelete == 0 && chores.todosToTrash == 5 && chores.titles.count == 5)
        #expect(chores.detail == "Move 5 to-dos to the Trash" && !chores.confirmationMessage.contains("more"))
    }

    @Test func confirmingOneListAppliesOnlyThatList() async throws {
        let w = try await twoListWorld()
        let engine = SyncEngine(things: w.things, reminders: w.reminders)
        let r = try await engine.sync(config: w.config, links: w.links, scope: .full, forceDeletionsIn: ["L1"])
        #expect(r.deletedInReminders == 12 && r.deletedInThings == 0)
        #expect(r.heldDeletions.map(\.mappingId) == ["L2"])
        #expect(await w.reminders.all(in: "L1").isEmpty)
    }

    @Test func mergeKeepsReplacesAndClears() {
        func held(_ id: String, _ n: Int) -> HeldDeletions {
            HeldDeletions(mappingId: id, listTitle: id, remindersToDelete: n, todosToTrash: 0, titles: [])
        }
        var report = SyncReport(config: SyncConfig(), links: LinkStore())
        let current = [held("A", 12), held("B", 11)]
        // A targeted pass that held nothing leaves the notices alone.
        #expect(HeldDeletions.merged(current, report: report, forcedAll: false, forcedLists: [], fullPass: false) == current)
        // A list held again takes the new count; a confirmed list goes.
        report.heldDeletions = [held("B", 13)]
        #expect(HeldDeletions.merged(current, report: report, forcedAll: false, forcedLists: ["A"], fullPass: false) == [held("B", 13)])
        // Sync Now, and a clean full pass that found nothing to hold, clear everything.
        report.heldDeletions = []
        #expect(HeldDeletions.merged(current, report: report, forcedAll: true, forcedLists: [], fullPass: true).isEmpty)
        #expect(HeldDeletions.merged(current, report: report, forcedAll: false, forcedLists: [], fullPass: true).isEmpty)
        // A full pass with failures proves nothing about the other lists.
        report.failures = 1
        #expect(HeldDeletions.merged(current, report: report, forcedAll: false, forcedLists: [], fullPass: true) == current)
    }

    private struct Creds: CredentialStore {
        func save(email: String, password: String) throws {}
        func load(email: String) throws -> String? { "pw" }
        func loadAccount() throws -> Credentials? { Credentials(email: "a@b.c", password: "pw") }
        func delete(email: String) throws {}
    }

    @MainActor
    @Test func coordinatorShowsTheHoldAndApplyDeletionsClearsOneList() async throws {
        let w = try await twoListWorld()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        try store.saveConfig(w.config)
        try store.saveLinks(w.links)
        let things = w.things
        let coordinator = SyncCoordinator(dependencies: .init(
            stateStore: store, credentials: Creds(), reminders: w.reminders, remctl: nil,
            makeThings: { _, _ in things }, verifyThings: { _, _ in "key" }, runsObservers: false))
        await coordinator.start()
        #expect(coordinator.heldDeletions.map(\.listTitle) == ["Chores", "Family"])
        #expect(coordinator.heldDeletions(forList: "L1")?.count == 12)
        #expect(await w.reminders.all(in: "L1").count == 12)

        await coordinator.applyHeldDeletions(listId: "L1")
        #expect(await w.reminders.all(in: "L1").isEmpty)
        #expect(coordinator.heldDeletions.map(\.mappingId) == ["L2"])       // Chores stays held ("Not Now")
        if case .error = coordinator.phase {} else { Issue.record("phase should still report the hold") }

        await coordinator.syncNow()                                          // Sync Now still lifts the limit for everything
        #expect(coordinator.heldDeletions.isEmpty && coordinator.phase == .idle)
    }
}
