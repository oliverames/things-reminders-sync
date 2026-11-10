import Foundation
import Testing
@testable import SyncCore

// Per-list preferences (docs/SPEC.md "Per-list preferences"): direction, paused, and the per-list overrides.

private func mapping(_ list: String = "L1", _ project: String? = "P1", direction: SyncDirection = .twoWay, paused: Bool = false) -> ListMapping {
    ListMapping(id: list, listTitle: list, mode: .project, targetId: project, targetTitle: "Proj", direction: direction, paused: paused)
}

/// Two lists on two projects, both with the given direction. Tags for the flag and tag tests exist in Things.
private func world(_ direction: SyncDirection = .twoWay) async -> World {
    let w = World(lists: ["L1", "L2"], mappings: [mapping("L1", "P1", direction: direction), mapping("L2", "P2", direction: direction)])
    await w.things.add(projectTask("P1"))
    await w.things.add(projectTask("P2"))
    for (id, title) in [("G1", "Important"), ("G2", "Home"), ("G3", "Work"), ("G9", "Synced")] { await w.things.addTag(id, title) }
    return w
}

private func thingsWrites(_ w: World) async -> Int {
    let updates = await w.things.updates.count, created = await w.things.created.count, stops = await w.things.stops.count
    return updates + created + stops
}

private func reminderWrites(_ w: World) async -> Int {
    let patches = await w.reminders.patches.count, deletes = await w.reminders.deletes.count
    return patches + deletes
}

// MARK: - Config

@Suite("Per-list preferences: config")
struct PerListConfigTests {
    @Test func aMappingFromAnOldConfigFileDecodesWithDefaultsThatChangeNothing() throws {
        let old = #"{"mappings":[{"id":"7","listTitle":"Home","enabled":true,"mode":"project","targetId":"P1","targetTitle":"Home","awaitingTarget":false,"syncSections":true}],"pollSeconds":15}"#
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(old.utf8))
        let m = try #require(config.mappings.first)
        #expect(m.direction == .twoWay && !m.paused && m.propagateDeletes == nil && m.undatedArriveAs == .anytime)
        #expect(m.alwaysTag == nil && m.includeCompletedOnFirstLink == nil && m.syncChecklists == nil)
        #expect(m == ListMapping(id: "7", listTitle: "Home", targetId: "P1", targetTitle: "Home"), "the same mapping as before the preferences existed")
        #expect(m.isLive && config.watchedListIds == ["7"] && config.sectionListIds == ["7"])
    }

    @Test func thePreferencesRoundTripUnderTheirJSONNames() throws {
        let json = #"{"id":"7","listTitle":"Home","targetTitle":"Home","direction":"remindersToThings","paused":true,"propagateDeletes":false,"undatedArriveAs":"someday","alwaysTag":"Synced","includeCompletedOnFirstLink":true,"syncChecklists":false}"#
        let m = try JSONDecoder().decode(ListMapping.self, from: Data(json.utf8))
        #expect(m.direction == .remindersToThings && m.paused && m.propagateDeletes == false && m.undatedArriveAs == .someday)
        #expect(m.alwaysTag == "Synced" && m.includeCompletedOnFirstLink == true && m.syncChecklists == false)
        #expect(try JSONDecoder().decode(ListMapping.self, from: JSONEncoder().encode(m)) == m)
        #expect(SyncDirection.allCases.map(\.rawValue) == ["twoWay", "remindersToThings", "thingsToReminders"])
        #expect(UndatedArrival.allCases.map(\.rawValue) == ["anytime", "someday", "today"])
        #expect(!m.isLive)
    }

    @Test func aPausedListIsNeitherWatchedNorReadForSections() {
        let config = SyncConfig(mappings: [mapping("L1"), mapping("L2", "P2", paused: true)])
        #expect(config.watchedListIds == ["L1"] && config.sectionListIds == ["L1"] && config.pausedListIds == ["L2"])
    }
}

// MARK: - Direction

@Suite("Per-list preferences: direction")
struct DirectionTests {
    @Test func twoWayIsTheDefaultAndCopiesBothWays() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "From Reminders"))
        await w.things.add(todo("t1", "From Things", project: "P1"))
        let r = try await w.sync()
        #expect(r.createdInThings == 1 && r.createdInReminders == 1 && w.links.links.count == 2)
    }

    @Test func remindersToThingsCreatesOnlyInThings() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "From Reminders"))
        await w.things.add(todo("t1", "Made in Things", project: "P1"))
        let r = try await w.sync()
        #expect(r.createdInThings == 1 && r.createdInReminders == 0 && w.links.links.count == 1)
        #expect(await w.reminders.all(in: "L1").map(\.title) == ["From Reminders"], "the to-do made on the receiving side gets no reminder")
        #expect(await reminderWrites(w) == 0)
        #expect(try await w.sync().changeCount == 0, "and it stays unlinked")
        #expect(w.links.links.count == 1, "and it stays unlinked")
    }

    @Test func thingsToRemindersCreatesOnlyInReminders() async throws {
        var w = await world(.thingsToReminders)
        await w.reminders.add(reminder("r1", "L1", "Made in Reminders"))
        await w.things.add(todo("t1", "From Things", project: "P1"))
        let r = try await w.sync()
        #expect(r.createdInThings == 0 && r.createdInReminders == 1 && w.links.links.count == 1)
        #expect(await w.things.all().map(\.title) == ["From Things"])
        #expect(await thingsWrites(w) == 0)
        #expect(try await w.sync().changeCount == 0)
        #expect(w.links.links.count == 1)
    }

    @Test func aReceiverEditIsIgnoredUntilTheSourceChangesThatField() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "Pay rent", due: DueDate(day: "2026-12-01")))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        await w.things.clearRecords()

        // An edit in Things (the receiver): nothing is written to either side, on this pass or the next.
        await w.things.edit(tid) { $0.title = "Pay the rent"; $0.startDate = "2026-12-05" }
        for _ in 0..<2 {
            #expect(try await w.sync().changeCount == 0)
            #expect(await reminderWrites(w) == 0)
            #expect(await thingsWrites(w) == 0, "the app does not fight the edit")
        }
        #expect(await w.reminders.item("r1")?.title == "Pay rent")
        #expect(await w.things.task(tid)?.title == "Pay the rent")

        // The source changes another field: only that field is copied, the ignored edits stay.
        await w.reminders.edit("r1") { $0.notes = "By transfer" }
        try await w.sync()
        var t = try #require(await w.things.task(tid))
        #expect(t.notes == "By transfer" && t.title == "Pay the rent" && t.startDate == "2026-12-05")

        // The source changes the edited fields: its values are applied again.
        await w.reminders.edit("r1") { $0.title = "Pay rent now"; $0.due = DueDate(day: "2026-12-02") }
        try await w.sync()
        t = try #require(await w.things.task(tid))
        #expect(t.title == "Pay rent now" && t.startDate == "2026-12-02")
        #expect(await reminderWrites(w) == 0, "Reminders is never written")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func thingsToRemindersMirrorsTheSameRule() async throws {
        var w = await world(.thingsToReminders)
        await w.things.add(todo("t1", "Pay rent", project: "P1", startDate: "2026-12-01"))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.reminders.clearPatches()

        await w.reminders.edit(rid) { $0.title = "Pay the rent"; $0.due = DueDate(day: "2026-12-05") }
        for _ in 0..<2 {
            #expect(try await w.sync().changeCount == 0)
            #expect(await thingsWrites(w) == 0)
            #expect(await reminderWrites(w) == 0)
        }
        #expect(await w.things.task("t1")?.title == "Pay rent")

        await w.things.edit("t1") { $0.title = "Pay rent now" }
        try await w.sync()
        let r = try #require(await w.reminders.item(rid))
        #expect(r.title == "Pay rent now" && r.due == DueDate(day: "2026-12-05"), "the due date was not changed in Things, so the reminder's stays")
        #expect(await thingsWrites(w) == 0, "Things is never written")
    }

    @Test func completionFollowsTheDirection() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "A"))
        await w.reminders.add(reminder("r2", "L1", "B"))
        try await w.sync()
        let a = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        let b = try #require(w.links.links.first { $0.reminderId == "r2" }).thingsId
        // Completed on the receiver: ignored.
        await w.things.edit(a) { $0.status = .completed; $0.stopDate = Date() }
        // Completed on the source: copied.
        await w.reminders.edit("r2") { $0.completed = true; $0.completionDate = Date() }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.completed == false)
        #expect(await reminderWrites(w) == 0)
        #expect(await w.things.task(b)?.status == .completed)
        #expect(try await w.sync().changeCount == 0)
        // The source reopening what both now hold open or done still flows.
        await w.reminders.edit("r2") { $0.completed = false; $0.completionDate = nil }
        try await w.sync()
        #expect(await w.things.task(b)?.status == .open)
    }

    @Test func deletesFlowOnlyFromTheSource() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "A"))
        await w.reminders.add(reminder("r2", "L1", "B"))
        try await w.sync()
        let a = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        let b = try #require(w.links.links.first { $0.reminderId == "r2" }).thingsId
        await w.things.edit(a) { $0.trashed = true }      // deleted on the receiver
        await w.reminders.remove("r2")                    // deleted on the source
        let r = try await w.sync()
        #expect(r.deletedInReminders == 0 && r.deletedInThings == 1 && r.unlinked == 1)
        #expect(await w.reminders.item("r1") != nil, "the reminder is kept")
        #expect(await reminderWrites(w) == 0, "the reminder is kept")
        #expect(await w.things.task(b)?.trashed == true)
        #expect(w.links.links.isEmpty)
        let again = try await w.sync()
        #expect(again.changeCount == 0, "the kept reminder is not copied to Things again")
    }

    @Test func thingsToRemindersKeepsTheToDoWhenItsReminderIsDeleted() async throws {
        var w = await world(.thingsToReminders)
        await w.things.add(todo("t1", "A", project: "P1"))
        await w.things.add(todo("t2", "B", project: "P1"))
        try await w.sync()
        let ra = try #require(w.links.links.first { $0.thingsId == "t1" }).reminderId
        let rb = try #require(w.links.links.first { $0.thingsId == "t2" }).reminderId
        await w.reminders.remove(ra)
        await w.things.edit("t2") { $0.trashed = true }
        let r = try await w.sync()
        #expect(r.deletedInThings == 0 && r.deletedInReminders == 1 && r.unlinked == 1)
        #expect(await w.things.task("t1")?.trashed == false)
        #expect(await thingsWrites(w) == 0)
        #expect(await w.reminders.item(rb) == nil)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func notesFlagTagsAndSubtasksGoOneWayFromReminders() async throws {
        var w = await world(.remindersToThings)
        var r1 = reminder("r1", "L1", "Task", notes: "n")
        r1.tags = ["Home"]; r1.flagged = true; r1.subtasks = [ReminderSubtask(id: "s1", title: "A")]
        await w.reminders.add(r1)
        try await w.sync()
        let tid = w.links.links[0].thingsId
        var t = try #require(await w.things.task(tid))
        #expect(t.notes == "n" && Set(t.tagIds) == ["G1", "G2"] && t.checklist.map(\.title) == ["A"])
        await w.things.clearRecords()

        // Edits in Things: notes, a tag and the flag removed, an item completed, an item added.
        await w.things.edit(tid) {
            $0.notes = "changed in Things"; $0.tagIds = []
            $0.checklist[0].completed = true
            $0.checklist.append(ThingsChecklistItem(id: "z", title: "Z", index: 9))
        }
        for _ in 0..<2 {
            #expect(try await w.sync().changeCount == 0)
            #expect(await reminderWrites(w) == 0)
            #expect(await thingsWrites(w) == 0)
        }
        let kept = try #require(await w.reminders.item("r1"))
        #expect(kept.notes == "n" && kept.tags == ["Home"] && kept.flagged && kept.subtasks.map(\.title) == ["A"] && !kept.subtasks[0].completed)

        // Edits in Reminders reach Things; what Things changed elsewhere is not put back.
        await w.reminders.edit("r1") {
            $0.notes = "n2"; $0.tags = ["Home", "Work"]
            $0.subtasks.append(ReminderSubtask(id: "s2", title: "B"))
        }
        try await w.sync()
        t = try #require(await w.things.task(tid))
        #expect(t.notes == "n2" && t.tagIds == ["G3"], "Work is added; Home and the flag, removed in Things, are not put back")
        #expect(t.checklist.map(\.title) == ["A", "Z", "B"] && t.checklist[0].completed, "B is added; Z and the completed A stay")
        #expect(await reminderWrites(w) == 0)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func notesFlagTagsAndChecklistGoOneWayFromThings() async throws {
        var w = await world(.thingsToReminders)
        var t1 = todo("t1", "Task", project: "P1", tags: ["G1", "G2"], notes: "n")
        t1.checklist = [ThingsChecklistItem(id: "c1", title: "A")]
        await w.things.add(t1)
        try await w.sync()
        let rid = w.links.links[0].reminderId
        var r = try #require(await w.reminders.item(rid))
        #expect(r.notes == "n" && r.tags == ["Home"] && r.flagged && r.subtasks.map(\.title) == ["A"])
        await w.reminders.clearPatches()

        await w.reminders.edit(rid) {
            $0.notes = "changed in Reminders"; $0.tags = []; $0.flagged = false
            $0.subtasks[0].completed = true
            $0.subtasks.append(ReminderSubtask(id: "sz", title: "Z"))
        }
        for _ in 0..<2 {
            #expect(try await w.sync().changeCount == 0)
            #expect(await thingsWrites(w) == 0)
            #expect(await reminderWrites(w) == 0)
        }
        await w.things.edit("t1") { $0.notes = "n2"; $0.tagIds = ["G1", "G2", "G3"] }
        try await w.sync()
        r = try #require(await w.reminders.item(rid))
        #expect(r.notes == "n2" && r.tags == ["Work"] && !r.flagged, "Work is added; Home and the flag, removed in Reminders, are not put back")
        #expect(r.subtasks.map(\.title) == ["A", "Z"] && r.subtasks[0].completed)
        #expect(await thingsWrites(w) == 0)
    }

    @Test func aFirstLinkAppliesTheSourceAndNeverWritesIt() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "pay rent", notes: "", due: DueDate(day: "2026-12-01")))
        await w.things.add(todo("t1", "Pay Rent", project: "P1", notes: "Things notes", startDate: "2026-12-09"))
        await w.reminders.add(reminder("r2", "L1", "No date"))
        await w.things.add(todo("t2", "No date", project: "P1", startDate: "2026-12-09"))
        let r = try await w.sync()
        #expect(r.linked == 2 && r.createdInThings == 0 && r.createdInReminders == 0)
        #expect(await reminderWrites(w) == 0)
        let t1 = try #require(await w.things.task("t1"))
        #expect(t1.title == "pay rent" && t1.startDate == "2026-12-01", "the source's title and date are applied")
        #expect(t1.notes == "Things notes", "a source with no notes leaves the receiver's alone")
        #expect(await w.things.task("t2")?.startDate == "2026-12-09", "and a source with no date leaves the receiver's date alone")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aMoveOnTheReceivingSideIsIgnoredAndOneOnTheSourceIsFollowed() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        await w.things.clearRecords()
        await w.things.edit(tid) { $0.projectId = "P2" }          // moved in Things, the receiver
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.reminders.item("r1")?.listId == "L1")
        #expect(await reminderWrites(w) == 0)
        #expect(await thingsWrites(w) == 0)
        #expect(w.links.links[0].mappingId == "L1" && w.links.parkedLinks.isEmpty)

        await w.things.edit(tid) { $0.projectId = "P1" }
        await w.reminders.edit("r1") { $0.listId = "L2" }         // moved in Reminders, the source
        try await w.sync()
        #expect(await w.things.task(tid)?.projectId == "P2")
        #expect(w.links.links[0].mappingId == "L2")
        #expect(await reminderWrites(w) == 0)
    }

    @Test func aTemplatePairFollowsTheDirection() async throws {
        let weekly = RepeatRule(frequency: .weekly, weekdays: [1])
        func repeatingWorld(_ direction: SyncDirection) async throws -> World {
            var w = await world(direction)
            await w.things.add(ThingsTask(id: "TPL", title: "Water", start: .someday, projectId: "P1", isRepeating: true, recurrence: weekly,
                                          nextDay: "2026-11-23", instanceDay: "2026-11-23", instancesCreated: 1))
            await w.things.add(ThingsTask(id: "OCC", title: "Water", startDate: "2026-11-16", projectId: "P1", isRepeating: true, templateId: "TPL"))
            await w.reminders.add(ReminderItem(id: "r1", listId: "L1", title: "Water", due: DueDate(day: "2026-11-16"), isRepeating: true, recurrence: weekly))
            try await w.sync()
            #expect(w.links.links.first?.repeatMode == .template)
            await w.things.clearRecords(); await w.reminders.clearPatches()
            return w
        }
        // One way from Reminders: an occurrence completed in Things does not advance the reminder.
        var a = try await repeatingWorld(.remindersToThings)
        await a.things.edit("OCC") { $0.status = .completed; $0.stopDate = Date() }
        #expect(try await a.sync().changeCount == 0)
        #expect(await reminderWrites(a) == 0)
        #expect(await a.reminders.item("r1")?.due == DueDate(day: "2026-11-16"))

        // One way from Things: a reminder that loses its repeat does not stop the template, and a new rule in Things is written.
        var b = try await repeatingWorld(.thingsToReminders)
        await b.reminders.edit("r1") { $0.isRepeating = false; $0.recurrence = nil }
        #expect(try await b.sync().changeCount == 0)
        #expect(await thingsWrites(b) == 0)
        #expect(await b.things.task("TPL")?.isTemplate == true)
        #expect(b.links.links.first?.repeatMode == .template)
        let daily = RepeatRule(frequency: .daily)
        await b.things.edit("TPL") { $0.recurrence = daily }
        try await b.sync()
        #expect(await b.reminders.item("r1")?.recurrence == daily)
        #expect(await thingsWrites(b) == 0)
    }

    @Test func retargetingMovesToDosOnlyWhereTheAppMayWriteThings() async throws {
        // One way from Reminders: Things is the receiver, so linked to-dos move to the new project as before.
        var a = await world(.remindersToThings)
        await a.reminders.add(reminder("r1", "L1", "A"))
        try await a.sync()
        let tid = a.links.links[0].thingsId
        await a.things.add(projectTask("P3"))
        a.config.mappings[0].targetId = "P3"
        let moved = try await a.sync()
        #expect(moved.unlinked == 0 && a.links.links.count == 1)
        #expect(await a.things.task(tid)?.projectId == "P3")
        #expect(await reminderWrites(a) == 0)

        // One way from Things: nothing in Things is moved; the pairs left in the old project are parked.
        var b = await world(.thingsToReminders)
        await b.things.add(todo("t1", "A", project: "P1"))
        try await b.sync()
        await b.things.add(projectTask("P3"))
        await b.things.add(todo("t9", "In the new project", project: "P3"))
        b.config.mappings[0].targetId = "P3"
        await b.reminders.clearPatches()
        let r = try await b.sync()
        #expect(await thingsWrites(b) == 0)
        #expect(await b.things.task("t1")?.projectId == "P1")
        #expect(r.unlinked == 1 && r.createdInReminders == 1 && r.deletedInReminders == 0)
        #expect(b.links.parkedLinks.count == 1 && b.links.links.map(\.thingsId) == ["t9"])
        #expect(await b.reminders.all(in: "L1").count == 2, "the reminder of the to-do left behind is kept")
    }

    @Test func theDeletionLimitAndTheLedgerHoldInAOneWayList() async throws {
        var w = await world(.remindersToThings)
        for i in 0..<12 { await w.reminders.add(reminder("r\(i)", "L1", "Item \(i)", section: i == 0 ? "Errands" : nil)) }
        try await w.sync()
        let heading = try #require(w.links.ownedThings.first { $0.kind == .heading && $0.title == "Errands" }?.id, "a heading made for a section is in the ledger")
        for i in 0..<11 { await w.reminders.remove("r\(i)") }
        let held = try await w.sync()
        #expect(held.deletionsHeld && held.deletedInThings == 0 && w.links.links.count == 12)
        let forced = try await w.sync(force: true)
        #expect(forced.deletedInThings == 11 && w.links.links.count == 1)
        #expect(await w.things.task(heading)?.trashed == true, "the emptied app-created heading is cleaned up as in a two-way list")
        #expect(await reminderWrites(w) == 0)
    }

    @Test func teardownRemovesTheCopiesOfAOneWayList() async throws {
        var w = await world(.remindersToThings)
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        let report = try await SyncEngine(things: w.things, reminders: w.reminders)
            .teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: false)
        #expect(report.completed && report.thingsTrashed == 1 && report.remindersDeleted == 0)
        #expect(await w.things.task(tid)?.trashed == true)
        #expect(await w.reminders.item("r1") != nil)
        #expect(report.links.links.isEmpty && report.config.mappings[0].enabled == false)
    }
}

// MARK: - Paused

@Suite("Per-list preferences: paused")
struct PausedTests {
    private func linked() async throws -> World {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "A"))
        await w.reminders.add(reminder("r2", "L1", "B"))
        await w.things.add(todo("t3", "C", project: "P1"))
        try await w.sync()
        #expect(w.links.links.count == 3)
        await w.things.clearRecords(); await w.reminders.clearPatches()
        return w
    }

    @Test func aPausedListIsSkippedAndKeepsItsLinks() async throws {
        var w = try await linked()
        let before = w.links.links
        w.config.mappings[0].paused = true
        await w.reminders.edit("r1") { $0.title = "A edited" }
        await w.reminders.remove("r2")
        await w.things.edit("t3") { $0.trashed = true }
        await w.reminders.add(reminder("r9", "L1", "New in Reminders"))
        await w.things.add(todo("t9", "New in Things", project: "P1"))
        for scope in [SyncScope.full, .targeted(thingsIds: ["t3", "t9"], remindersChanged: true)] {
            let r = try await w.sync(scope)
            #expect(r.changeCount == 0 && !r.deletionsHeld)
            #expect(await thingsWrites(w) == 0)
            #expect(await reminderWrites(w) == 0)
        }
        #expect(w.links.links == before && w.links.pausedMappings == ["L1"])
        #expect(await w.reminders.all(in: "L1").count == 3, "r1, the reminder of the trashed to-do and the new one; nothing was deleted or copied")
        #expect(await w.things.all().count == 4)
    }

    @Test func nothingIsDeletedWhenThePausedListResumes() async throws {
        var w = try await linked()
        let a = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        let b = try #require(w.links.links.first { $0.reminderId == "r2" }).thingsId
        let c = try #require(w.links.links.first { $0.thingsId == "t3" }).reminderId
        w.config.mappings[0].paused = true
        try await w.sync()
        await w.reminders.remove("r2")                          // deleted while paused
        await w.things.edit("t3") { $0.trashed = true }         // deleted while paused
        await w.reminders.edit("r1") { $0.title = "A edited" }  // edited while paused

        w.config.mappings[0].paused = false
        // A targeted pass comes first: it still deletes nothing.
        let first = try await w.sync(.targeted(thingsIds: [], remindersChanged: true))
        #expect(first.deletedInThings == 0 && first.deletedInReminders == 0)
        let r = try await w.sync()
        #expect(r.deletedInThings == 0 && r.deletedInReminders == 0 && !r.deletionsHeld)
        #expect(await w.things.task(b)?.trashed == false, "the to-do of the reminder deleted meanwhile is kept")
        #expect(await w.reminders.item(c) != nil, "and so is the reminder of the to-do deleted meanwhile")
        #expect(await w.things.task(a)?.title == "A edited", "edits made meanwhile sync")
        #expect(w.links.links.map(\.reminderId) == ["r1"] && w.links.pausedMappings.isEmpty)
        #expect(try await w.sync().changeCount == 0, "the survivors are not copied again")

        // From here on a deletion is a deletion again.
        await w.reminders.remove("r1")
        #expect(try await w.sync().deletedInThings == 1)
    }

    @Test func aPausedListGetsNoTargetAndNoCleanup() async throws {
        // No target is created for a paused "New…" list.
        var fresh = World(mappings: [ListMapping(id: "L1", listTitle: "L1", targetTitle: "New project", paused: true)])
        try await fresh.sync()
        #expect(await fresh.things.projectsCreated == 0)
        #expect(fresh.config.mappings[0].targetId == nil)

        // An app-created heading that empties while its list is paused is left alone until the list resumes.
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "A", section: "Errands"))
        try await w.sync()
        let heading = try #require(w.links.ownedThings.first { $0.kind == .heading }?.id)
        let tid = w.links.links[0].thingsId
        w.config.mappings[0].paused = true
        await w.things.edit(tid) { $0.headingId = nil; $0.projectId = "P1" }
        try await w.sync()
        #expect(await w.things.task(heading)?.trashed == false)
        #expect(w.links.ownedThings.contains { $0.id == heading })
        w.config.mappings[0].paused = false
        try await w.sync()
        #expect(await w.things.task(heading)?.trashed == true)
    }

    @Test func aPausedListDoesNotCountTowardsTheDeletionLimitAndIsNotRetargeted() async throws {
        var w = await world()
        for i in 0..<30 {
            await w.reminders.add(reminder("a\(i)", "L1", "A \(i)"))
            await w.reminders.add(reminder("b\(i)", "L2", "B \(i)"))
        }
        try await w.sync()
        #expect(w.links.links.count == 60)
        for i in 0..<6 { await w.reminders.remove("a\(i)"); await w.reminders.remove("b\(i)") }
        // Six in each list is twelve in the pass, over the limit of ten. With L2 paused only L1's six count.
        w.config.mappings[1].paused = true
        await w.things.add(projectTask("P3"))
        w.config.mappings[1].targetId = "P3"
        await w.things.clearRecords()
        let r = try await w.sync()
        #expect(!r.deletionsHeld && r.deletedInThings == 6)
        #expect(await w.things.updates.allSatisfy { $0.1.placement == nil }, "the paused list's to-dos are not moved to its new target")
        #expect(w.links.links.filter { $0.mappingId == "L2" }.count == 30)
    }

    @Test func teardownOfAPausedListStillRemovesItsCopies() async throws {
        var w = try await linked()
        w.config.mappings[0].paused = true
        try await w.sync()
        #expect(w.links.pausedMappings == ["L1"])
        let report = try await SyncEngine(things: w.things, reminders: w.reminders)
            .teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: true)
        #expect(report.completed && report.thingsTrashed == 2 && report.remindersDeleted == 1)
        #expect(report.links.links.isEmpty && report.links.pausedMappings.isEmpty && report.config.mappings.map(\.id) == ["L2"])
    }

    @Test func removingCompletedCopiesLeavesAPausedListAndAListThatWantsThemAlone() async throws {
        var w = World(lists: ["L1", "L2", "L3"], mappings: [mapping("L1", "P1"), mapping("L2", "P2"), mapping("L3", "P3")])
        for p in ["P1", "P2", "P3"] { await w.things.add(projectTask(p)) }
        w.config.includeCompletedOnFirstLink = true
        for l in ["L1", "L2", "L3"] { await w.reminders.add(reminder("done-\(l)", l, "Done \(l)", done: true)) }
        try await w.sync()
        #expect(w.links.links.filter(\.copiedCompleted).count == 3)
        w.config.includeCompletedOnFirstLink = false
        w.config.mappings[1].paused = true
        w.config.mappings[2].includeCompletedOnFirstLink = true
        #expect(Teardown.completedCopyLinks(w.links, config: w.config).map(\.mappingId) == ["L1"])
        let report = try await SyncEngine(things: w.things, reminders: w.reminders).removeCompletedCopies(config: w.config, links: w.links)
        #expect(report.thingsTrashed == 1 && report.links.links.map(\.mappingId).sorted() == ["L2", "L3"])
    }
}

// MARK: - Overrides and arrival

@Suite("Per-list preferences: overrides")
struct PerListOverrideTests {
    @Test func propagateDeletesCanBeSetPerList() async throws {
        for (global, own, deletes) in [(true, nil, true), (true, false, false), (false, nil, false), (false, true, true)] as [(Bool, Bool?, Bool)] {
            var w = await world()
            w.config.propagateDeletes = global
            w.config.mappings[0].propagateDeletes = own
            await w.reminders.add(reminder("r1", "L1", "A"))
            try await w.sync()
            let tid = w.links.links[0].thingsId
            await w.reminders.remove("r1")
            let r = try await w.sync()
            #expect((r.deletedInThings == 1) == deletes && (r.unlinked == 1) == !deletes, "global \(global), list \(String(describing: own))")
            #expect(await w.things.task(tid)?.trashed == deletes)
        }
    }

    @Test func includeCompletedOnFirstLinkCanBeSetPerList() async throws {
        for (global, own, linked) in [(false, nil, false), (false, true, true), (true, nil, true), (true, false, false)] as [(Bool, Bool?, Bool)] {
            var w = await world()
            w.config.includeCompletedOnFirstLink = global
            w.config.mappings[0].includeCompletedOnFirstLink = own
            await w.reminders.add(reminder("r1", "L1", "Done", done: true))
            let r = try await w.sync()
            #expect((r.createdInThings == 1) == linked, "global \(global), list \(String(describing: own))")
        }
    }

    @Test func syncChecklistsCanBeSetPerList() async throws {
        for (global, own, writes) in [(true, nil, true), (true, false, false), (false, nil, false), (false, true, true)] as [(Bool, Bool?, Bool)] {
            var w = await world()
            w.config.syncChecklists = global
            w.config.mappings[0].syncChecklists = own
            var r1 = reminder("r1", "L1", "Task")
            r1.subtasks = [ReminderSubtask(id: "s1", title: "A")]
            await w.reminders.add(r1)
            try await w.sync()
            let tid = w.links.links[0].thingsId
            #expect(await w.things.task(tid)?.checklist.map(\.title) == (writes ? ["A"] : []), "global \(global), list \(String(describing: own))")
            await w.reminders.edit("r1") { $0.subtasks.append(ReminderSubtask(id: "s2", title: "B")) }
            try await w.sync()
            #expect(await w.things.task(tid)?.checklist.map(\.title) == (writes ? ["A", "B"] : []))
        }
    }

    @Test func anUndatedReminderArrivesInAnytimeByDefault() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        let draft = try #require(await w.things.created.first)
        #expect(draft.when == nil && !draft.someday)
        #expect(await w.things.task(w.links.links[0].thingsId)?.start == .anytime)
        #expect(w.links.links[0].fingerprint.undatedThingsDay == nil)
    }

    @Test func anUndatedReminderCanArriveInSomeday() async throws {
        var w = await world()
        w.config.mappings[0].undatedArriveAs = .someday
        await w.reminders.add(reminder("r1", "L1", "Undated"))
        await w.reminders.add(reminder("r2", "L1", "Dated", due: DueDate(day: "2026-12-01")))
        try await w.sync()
        let created = await w.things.created
        let undated = try #require(created.first { $0.title == "Undated" }), dated = try #require(created.first { $0.title == "Dated" })
        #expect(undated.when == nil && undated.someday)
        #expect(dated.when == DueDate(day: "2026-12-01") && !dated.someday, "a reminder with a due date is not affected")
        let tid = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        #expect(await w.things.task(tid)?.start == .someday)
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.reminders.item("r1")?.due == nil)
    }

    @Test func anUndatedReminderCanArriveInTodayWithoutGettingADueDate() async throws {
        var w = await world()
        w.config.mappings[0].undatedArriveAs = .today
        await w.reminders.add(reminder("r1", "L1", "Undated"))
        try await w.sync()
        let today = day(0)
        #expect(await w.things.created.first?.when == DueDate(day: today))
        let tid = w.links.links[0].thingsId
        #expect(w.links.links[0].fingerprint.undatedThingsDay == today && w.links.links[0].fingerprint.due == nil)
        await w.reminders.clearPatches(); await w.things.clearRecords()
        for _ in 0..<2 {
            #expect(try await w.sync().changeCount == 0)
            #expect(await reminderWrites(w) == 0)
            #expect(await thingsWrites(w) == 0)
        }
        #expect(await w.reminders.item("r1")?.due == nil)
        #expect(await w.things.task(tid)?.startDate == today)

        // Moving the to-do to another day is a date like any other, and so is a due date set in Reminders.
        await w.things.edit(tid) { $0.startDate = "2026-12-24" }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.due == DueDate(day: "2026-12-24"))
        #expect(w.links.links[0].fingerprint.undatedThingsDay == nil)
    }

    @Test func aDueDateSetInRemindersReplacesTheTodayArrival() async throws {
        var w = await world()
        w.config.mappings[0].undatedArriveAs = .today
        await w.reminders.add(reminder("r1", "L1", "Undated"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        await w.reminders.edit("r1") { $0.due = DueDate(day: "2026-12-24", minutes: 600) }
        try await w.sync()
        let t = try #require(await w.things.task(tid))
        #expect(t.startDate == "2026-12-24" && t.reminderSeconds == 36000 && w.links.links[0].fingerprint.undatedThingsDay == nil)
    }

    @Test func thePreferenceNeverChangesAnExistingToDo() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "Undated"))
        try await w.sync()
        await w.things.clearRecords()
        w.config.mappings[0].undatedArriveAs = .today
        #expect(try await w.sync().changeCount == 0)
        w.config.mappings[0].undatedArriveAs = .someday
        #expect(try await w.sync().changeCount == 0)
        #expect(await thingsWrites(w) == 0)
    }

    @Test func alwaysTagIsAddedOnCreateAndAtLinkTimeAndNeverSynced() async throws {
        var w = await world()
        w.config.mappings[0].alwaysTag = "synced"                         // the tag is titled "Synced"
        await w.reminders.add(reminder("r1", "L1", "From Reminders"))
        await w.things.add(todo("t2", "From Things", project: "P1"))
        await w.reminders.add(reminder("r3", "L1", "On both sides"))
        await w.things.add(todo("t3", "On both sides", project: "P1", tags: ["G2"]))
        await w.reminders.add(reminder("r4", "L2", "Other list"))
        try await w.sync()
        let created = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        #expect(await w.things.task(created)?.tagIds == ["G9"], "on create")
        #expect(await w.things.task("t2")?.tagIds == ["G9"], "when a reminder is made for a to-do")
        #expect(await w.things.task("t3")?.tagIds == ["G2", "G9"], "when two existing items are linked")
        let other = try #require(w.links.links.first { $0.reminderId == "r4" }).thingsId
        #expect(await w.things.task(other)?.tagIds == [], "only for the list that asks for it")
        for r in await w.reminders.all(in: "L1") { #expect(!r.tags.contains("Synced"), "never a Reminders tag") }
        #expect(w.links.links.allSatisfy { !($0.fingerprint.tags ?? []).contains("Synced") })
        #expect(try await w.sync().changeCount == 0)

        // Removed by hand in Things: the app does not put it back, and it never removes it itself.
        await w.things.edit("t2") { $0.tagIds = [] }
        await w.reminders.edit("r3") { $0.tags = [] }                     // the Home tag is removed in Reminders
        await w.things.clearRecords()
        try await w.sync()
        #expect(await w.things.task("t2")?.tagIds == [])
        #expect(await w.things.task("t3")?.tagIds == ["G9"])
    }

    @Test func alwaysTagNeedsAnExistingTagAndIsNotWrittenOneWayFromThings() async throws {
        var w = await world()
        w.config.mappings[0].alwaysTag = "No such tag"
        await w.reminders.add(reminder("r1", "L1", "A"))
        let r = try await w.sync()
        #expect(await w.things.task(w.links.links[0].thingsId)?.tagIds == [], "no tag is created")
        #expect(await w.things.tags.count == 4, "no tag is created")
        #expect(r.log.contains { $0.level == .info && $0.message.contains("No such tag") })

        var b = await world(.thingsToReminders)
        b.config.mappings[0].alwaysTag = "Synced"
        await b.things.add(todo("t1", "A", project: "P1"))
        try await b.sync()
        #expect(await b.things.task("t1")?.tagIds == [])
        #expect(await thingsWrites(b) == 0)
    }

    @Test func aPairThatMovesIntoAListGetsItsTag() async throws {
        var w = await world()
        w.config.mappings[1].alwaysTag = "Synced"
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        #expect(await w.things.task(tid)?.tagIds == [])
        await w.reminders.edit("r1") { $0.listId = "L2" }
        try await w.sync()
        #expect(await w.things.task(tid)?.projectId == "P2")
        #expect(await w.things.task(tid)?.tagIds == ["G9"])
    }
}

// MARK: - Stop with a checklist (docs/RECURRENCE.md, second sampling session)

@Suite("Stop keeps the checklist")
struct StopChecklistTests {
    private let weekly = RepeatRule(frequency: .weekly, weekdays: [1])

    private func pair() async throws -> World {
        var w = World()
        await w.things.add(projectTask("P1"))
        var tpl = ThingsTask(id: "TPL", title: "Water", start: .someday, projectId: "P1", isRepeating: true, recurrence: weekly,
                             nextDay: "2026-11-23", instanceDay: "2026-11-23", instancesCreated: 0)
        tpl.checklist = [ThingsChecklistItem(id: "c1", title: "A", index: 0), ThingsChecklistItem(id: "c2", title: "B", index: 1)]
        await w.things.add(tpl)
        try await w.sync()
        try await w.sync()
        #expect(w.links.links.first?.repeatMode == .template)
        #expect(w.links.links.first?.fingerprint.checklist == [.init(title: "A", done: false), .init(title: "B", done: false)])
        await w.things.clearRecords(); await w.reminders.clearPatches()
        return w
    }

    @Test func aReminderThatStopsRepeatingKeepsItsChecklistOnTheNewToDo() async throws {
        var w = try await pair()
        let rid = w.links.links[0].reminderId
        // The repeat is removed and a subtask is completed in the same pass.
        await w.reminders.edit(rid) { $0.isRepeating = false; $0.recurrence = nil; $0.subtasks[0].completed = true }
        let r = try await w.sync()
        #expect(r.failures == 0)
        let link = try #require(w.links.links.first)
        let plain = try #require(await w.things.task(link.thingsId))
        #expect(link.thingsId != "TPL" && !plain.isRepeating)
        #expect(plain.checklist.map(\.title) == ["A", "B"] && plain.checklist.map(\.completed) == [true, false])
        #expect(!plain.checklist.contains { ["c1", "c2"].contains($0.id) }, "the items are new ones, as Things makes them")
        #expect(link.fingerprint.checklist == [.init(title: "A", done: true), .init(title: "B", done: false)])
        let subtasks = try #require(await w.reminders.item(rid)?.subtasks)
        #expect(subtasks.map(\.title) == ["A", "B"], "no subtask is added or removed")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aTemplateStoppedInThingsKeepsTheAgreedChecklist() async throws {
        var w = try await pair()
        let rid = w.links.links[0].reminderId
        await w.things.stopInThings("TPL", newId: "N1")
        // A subtask removed in Reminders meanwhile is removed from the new to-do, because the agreed items still hold.
        let gone = try #require(await w.reminders.item(rid)?.subtasks.first { $0.title == "B" }?.id)
        await w.reminders.edit(rid) { r in r.subtasks.removeAll { $0.id == gone } }
        try await w.sync()
        let link = try #require(w.links.links.first { $0.reminderId == rid })
        #expect(link.thingsId == "N1" && link.fingerprint.checklist != nil)
        try await w.sync()
        #expect(await w.things.task("N1")?.checklist.map(\.title) == ["A"])
        #expect(await w.reminders.item(rid)?.subtasks.map(\.title) == ["A"])
        #expect(try await w.sync().changeCount == 0)
    }
}
