import Foundation
import Testing
@testable import SyncCore

// Field fidelity, part 2: flagged, tags and subtasks (docs/SPEC.md "Field fidelity").

private let early = Date(timeIntervalSince1970: 1_000)
private let late = Date(timeIntervalSince1970: 9_000_000_000)

private func world(syncChecklists: Bool = false, flaggedTitle: String = "Important", tags: [(String, String)] = [("G1", "Important"), ("G2", "Home"), ("G3", "Work")]) async -> World {
    var w = World()
    w.config.syncChecklists = syncChecklists
    w.config.flaggedTagTitle = flaggedTitle
    await w.things.add(projectTask("P1"))
    for (id, title) in tags { await w.things.addTag(id, title) }
    return w
}

private func pair(_ w: inout World, notes: String = "", tags: [String] = [], checklist: [ThingsChecklistItem] = []) async throws -> (t: String, r: String) {
    var t = todo("t1", "Task", project: "P1", tags: tags, notes: notes)
    t.checklist = checklist
    await w.things.add(t)
    try await w.sync()
    return ("t1", w.links.links[0].reminderId)
}

@Suite struct FlaggedTests {
    @Test func flagIsMirroredAsTheTagBothWays() async throws {
        var w = await world()
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.flagged = true; $0.lastModified = late }
        let r1 = try await w.sync()
        #expect(r1.updatedInThings == 1 && r1.updatedInReminders == 0)
        #expect(await w.things.task(tid)?.tagIds == ["G1"])
        #expect(try await w.sync().changeCount == 0)
        await w.reminders.edit(rid) { $0.flagged = false; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.tagIds == [])
        // Things side.
        await w.things.edit(tid) { $0.tagIds = ["G1"]; $0.modificationDate = late }
        try await w.sync()
        #expect(await w.reminders.item(rid)?.flagged == true)
        #expect(try await w.sync().changeCount == 0)
        await w.things.edit(tid) { $0.tagIds = []; $0.modificationDate = late }
        try await w.sync()
        #expect(await w.reminders.item(rid)?.flagged == false)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func noMatchingTagMeansNothingHappensAndItIsLoggedOnce() async throws {
        var w = await world(flaggedTitle: "Nope")
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.flagged = true; $0.lastModified = late }
        let report = try await w.sync()
        #expect(await w.things.task(tid)?.tagIds == [])
        #expect(report.updatedInThings == 0)
        #expect(await w.things.tags.count == 3)   // never creates the tag
        #expect(report.log.filter { $0.message.contains("Flags are not synced") }.count == 1)
        #expect(await w.reminders.item(rid)?.flagged == true)
    }

    @Test func theTagTitleComesFromTheConfig() async throws {
        var w = await world(flaggedTitle: "Home")
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.flagged = true; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.tagIds == ["G2"])
    }

    @Test func existingFlaggedItemsCarryOverOnFirstLinkWithoutUnflagging() async throws {
        var w = await world()
        await w.things.add(todo("t1", "A", project: "P1", tags: ["G1"]))
        await w.things.add(todo("t2", "B", project: "P1"))
        var a = reminder("r1", "L1", "A"); a.flagged = false
        var b = reminder("r2", "L1", "B"); b.flagged = true
        await w.reminders.add(a); await w.reminders.add(b)
        try await w.sync()
        #expect(await w.reminders.item("r1")?.flagged == true)
        #expect(await w.things.task("t2")?.tagIds == ["G1"])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func newCopiesCarryTheFlagBothWays() async throws {
        var w = await world()
        var r = reminder("r1", "L1", "From reminders"); r.flagged = true
        await w.reminders.add(r)
        await w.things.add(todo("t2", "From things", project: "P1", tags: ["G1"]))
        try await w.sync()
        #expect(await w.things.all().first { $0.title == "From reminders" }?.tagIds == ["G1"])
        let copy = try #require(await w.reminders.all(in: "L1").first { $0.title == "From things" })
        #expect(copy.flagged)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aFlagWriteThatDidNotTakeIsRetried() async throws {
        var w = await world()
        let (tid, rid) = try await pair(&w)
        await w.reminders.setIgnores(flag: true)
        await w.things.edit(tid) { $0.tagIds = ["G1"]; $0.modificationDate = late }
        let r1 = try await w.sync()
        #expect(r1.log.contains { $0.message.contains("did not take the flag") })
        await w.reminders.setIgnores()
        try await w.sync()
        #expect(await w.reminders.item(rid)?.flagged == true)
        #expect(try await w.sync().changeCount == 0)
    }
}

@Suite struct TagTests {
    @Test func onlyTagsThatExistInThingsSyncAndOthersAreKept() async throws {
        var w = await world()
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.tags = ["Home", "Nowhere"]; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.tagIds == ["G2"])
        #expect(await w.things.tags.count == 3)   // "Nowhere" was not created
        #expect(await w.reminders.item(rid)?.tags == ["Home", "Nowhere"])
        #expect(try await w.sync().changeCount == 0)
        // Things gains Work: Reminders gets it and keeps the tag Things does not know.
        await w.things.edit(tid) { $0.tagIds += ["G3"]; $0.modificationDate = late }
        try await w.sync()
        #expect(Set(await w.reminders.item(rid)?.tags ?? []) == ["Home", "Nowhere", "Work"])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func removalsFlowBothWaysButNeverTouchUnmatchedTags() async throws {
        var w = await world()
        let (tid, rid) = try await pair(&w, tags: ["G2", "G3"])
        await w.reminders.edit(rid) { $0.tags = ["Home", "Work", "Nowhere"]; $0.lastModified = late }
        try await w.sync()
        #expect(try await w.sync().changeCount == 0)
        // Reminders drops Work: Things drops it too.
        await w.reminders.edit(rid) { $0.tags = ["Home", "Nowhere"]; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.tagIds == ["G2"])
        #expect(try await w.sync().changeCount == 0)
        // Things drops Home: Reminders drops it and still keeps Nowhere.
        await w.things.edit(tid) { $0.tagIds = []; $0.modificationDate = late }
        try await w.sync()
        #expect(await w.reminders.item(rid)?.tags == ["Nowhere"])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aTagWithoutAThingsCounterpartIsNeverRemoved() async throws {
        var w = await world()
        let (_, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.tags = ["Solo"]; $0.lastModified = late }
        try await w.sync()
        await w.reminders.clearPatches()
        try await w.sync(); try await w.sync()
        #expect(await w.reminders.item(rid)?.tags == ["Solo"])
        #expect(await w.reminders.patches.isEmpty)
    }

    @Test func upgradeUnitesTagsWithoutRemovingAnything() async throws {
        var w = await world()
        await w.things.add(todo("t1", "A", project: "P1", tags: ["G2"]))
        var r = reminder("r1", "L1", "A"); r.tags = ["Work", "Solo"]
        await w.reminders.add(r)
        try await w.sync()
        #expect(Set(await w.reminders.item("r1")?.tags ?? []) == ["Work", "Solo", "Home"])
        #expect(Set(await w.things.task("t1")?.tagIds ?? []) == ["G2", "G3"])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func theFlaggedTagAndTheListsOwnTagAreExcluded() async throws {
        var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .tag, targetId: "G9", targetTitle: "Mapped")])
        for (id, title) in [("G1", "Important"), ("G2", "Home"), ("G9", "Mapped")] { await w.things.addTag(id, title) }
        await w.things.add(todo("t1", "A", tags: ["G9", "G1", "G2"]))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        let item = try #require(await w.reminders.item(rid))
        #expect(item.tags == ["Home"])   // neither "Mapped" nor "Important" becomes a Reminders tag
        #expect(item.flagged)            // the flagged tag maps to the flag instead
        // A Reminders tag with the mapping tag's title is not pushed to Things either.
        await w.reminders.edit(rid) { $0.tags = ["Home", "Mapped"]; $0.lastModified = late }
        try await w.sync()
        #expect(Set(await w.things.task("t1")?.tagIds ?? []) == ["G9", "G1", "G2"])
    }

    @Test func newCopiesCarryMappedTags() async throws {
        var w = await world()
        var r = reminder("r1", "L1", "From reminders"); r.tags = ["Work", "Solo"]
        await w.reminders.add(r)
        await w.things.add(todo("t2", "From things", project: "P1", tags: ["G2"]))
        try await w.sync()
        #expect(await w.things.all().first { $0.title == "From reminders" }?.tagIds == ["G3"])
        #expect(await w.reminders.all(in: "L1").first { $0.title == "From things" }?.tags == ["Home"])
        #expect(try await w.sync().changeCount == 0)
    }
}

private func item(_ id: String, _ title: String, done: Bool = false, ix: Double = 0) -> ThingsChecklistItem {
    ThingsChecklistItem(id: id, title: title, completed: done, index: ix)
}

@Suite struct SubtaskTests {
    @Test func subtaskRowsAreNeverLinkedAsToDos() async throws {
        var w = await world()
        var child = reminder("r2", "L1", "Child")
        child.parentId = "r1"
        var parent = reminder("r1", "L1", "Parent")
        parent.subtasks = [ReminderSubtask(id: "r2", title: "Child")]
        await w.reminders.add(parent); await w.reminders.add(child)
        try await w.sync()
        #expect(w.links.links.map(\.reminderId) == ["r1"])
        #expect(await w.things.all().map(\.title) == ["Parent"])
    }

    @Test func thingsChecklistBecomesSubtasksEvenWithChecklistWritesOff() async throws {
        var w = await world()
        let (tid, rid) = try await pair(&w, checklist: [item("c1", "Alpha"), item("c2", "Beta", done: true)])
        #expect(await w.reminders.item(rid)?.subtasks.map(\.title) == ["Alpha", "Beta"])
        // The completed one is completed in Reminders on the next pass (a subtask is created open).
        try await w.sync()
        #expect(await w.reminders.item(rid)?.subtasks.map(\.completed) == [false, true])
        #expect(try await w.sync().changeCount == 0)
        // Things completes and deletes.
        await w.things.edit(tid) { $0.checklist = [item("c1", "Alpha", done: true)]; $0.modificationDate = late }
        try await w.sync()
        #expect(await w.reminders.item(rid)?.subtasks == [ReminderSubtask(id: "S1", title: "Alpha", completed: true)])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func remindersSubtasksStayInRemindersWhileChecklistWritesAreOff() async throws {
        var w = await world(syncChecklists: false)
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.subtasks = [ReminderSubtask(id: "S9", title: "Mine")]; $0.lastModified = late }
        await w.things.clearRecords()
        try await w.sync(); try await w.sync()
        #expect(await w.things.task(tid)?.checklist == [])
        #expect(await w.things.updates.isEmpty)
        #expect(await w.reminders.item(rid)?.subtasks.map(\.title) == ["Mine"])
    }

    @Test func remindersSubtasksSyncToThingsWhenEnabled() async throws {
        var w = await world(syncChecklists: true)
        let (tid, rid) = try await pair(&w)
        await w.reminders.edit(rid) { $0.subtasks = [ReminderSubtask(id: "S9", title: "Mine"), ReminderSubtask(id: "S8", title: "Done", completed: true)]; $0.lastModified = late }
        try await w.sync()
        let items = try #require(await w.things.task(tid)?.checklist)
        #expect(items.map(\.title) == ["Mine", "Done"] && items.map(\.completed) == [false, true])
        #expect(try await w.sync().changeCount == 0)
        // Completion and deletion in Reminders.
        await w.reminders.edit(rid) { $0.subtasks = [ReminderSubtask(id: "S9", title: "Mine", completed: true)]; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.checklist.map(\.title) == ["Mine"])
        #expect(await w.things.task(tid)?.checklist.map(\.completed) == [true])
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aSubtaskAddThatDidNotTakeNeverDeletesTheThingsItem() async throws {
        var w = await world(syncChecklists: true)
        await w.reminders.setIgnores(subtasks: true)
        let (tid, rid) = try await pair(&w, checklist: [item("c1", "Alpha")])
        #expect(await w.reminders.item(rid)?.subtasks == [])
        #expect(w.links.links[0].fingerprint.checklist == [])   // not recorded as agreed
        // Several passes later the Things item is still there; once RemCTL takes the write everything converges.
        try await w.sync(); try await w.sync()
        #expect(await w.things.task(tid)?.checklist.map(\.title) == ["Alpha"])
        await w.reminders.setIgnores()
        try await w.sync()
        #expect(await w.reminders.item(rid)?.subtasks.map(\.title) == ["Alpha"])
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.things.task(tid)?.checklist.map(\.title) == ["Alpha"])
    }

    @Test func newCopiesCarrySubtasksAndChecklists() async throws {
        var w = await world(syncChecklists: true)
        var r = reminder("r1", "L1", "From reminders"); r.subtasks = [ReminderSubtask(id: "S7", title: "One")]
        await w.reminders.add(r)
        var t = todo("t2", "From things", project: "P1"); t.checklist = [item("c1", "Two")]
        await w.things.add(t)
        try await w.sync()
        #expect(await w.things.all().first { $0.title == "From reminders" }?.checklist.map(\.title) == ["One"])
        #expect(await w.reminders.all(in: "L1").first { $0.title == "From things" }?.subtasks.map(\.title) == ["Two"])
        #expect(try await w.sync().changeCount == 0)
    }
}

@Suite struct ChecklistGateTests {
    @Test func nothingIsWrittenToThingsChecklistsByDefault() async throws {
        var w = await world()   // syncChecklists is off
        #expect(w.config.syncChecklists == false)
        var r = reminder("r1", "L1", "From reminders"); r.subtasks = [ReminderSubtask(id: "S7", title: "One")]
        await w.reminders.add(r)
        try await w.sync()
        let created = await w.things.created
        #expect(created.count == 1 && created[0].checklist.isEmpty)
        // A subtask added, completed and removed in Reminders later still produces no Things checklist write.
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.subtasks = [ReminderSubtask(id: "S7", title: "One", completed: true), ReminderSubtask(id: "S8", title: "Two")]; $0.lastModified = late }
        try await w.sync()
        await w.reminders.edit(rid) { $0.subtasks = []; $0.lastModified = late }
        try await w.sync()
        let updates = await w.things.updates
        #expect(updates.allSatisfy { $0.1.checklist == nil })
    }

    @Test func oldConfigAndFingerprintFilesDecode() throws {
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(#"{"mappings":[],"pollSeconds":15}"#.utf8))
        #expect(config.flaggedTagTitle == "Important" && config.syncChecklists == true)
        let fp = try JSONDecoder().decode(Fingerprint.self, from: Data(#"{"title":"a","notes":"n","completed":false}"#.utf8))
        #expect(fp.remindersNotes == nil && fp.url == nil && fp.flagged == nil && fp.tags == nil && fp.checklist == nil)
        #expect(fp.dueIsDeadline == nil && fp.priorityHigh == nil && fp.eveningFor == nil && fp.thingsSomeday == nil)
        let full = Fingerprint(title: "a", notes: "n", due: nil, completed: false, completionDay: nil, remindersNotes: "m", url: "https://x.example/",
                               flagged: true, tags: ["T"], checklist: [.init(title: "c", done: true)])
        #expect(try JSONDecoder().decode(Fingerprint.self, from: JSONEncoder().encode(full)) == full)
        // Things and Reminders values saved before this change decode too.
        let item = try JSONDecoder().decode(ReminderItem.self, from: Data(#"{"id":"1","listId":"L","title":"t","notes":"","completed":false,"isRepeating":false}"#.utf8))
        #expect(item.priority == ReminderPriority.none)
    }
}
