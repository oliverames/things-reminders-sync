import Foundation
import Testing
@testable import SyncCore

// One test per defect fixed after the 2026-11-09 audit. The finding id is named in each test's comment.

private func world() async -> World {
    let w = World()
    await w.things.add(projectTask("P1"))
    return w
}

private let monday = RepeatRule(frequency: .weekly, weekdays: [1])

@Suite("Audit fixes: engine") struct AuditEngineTests {
    /// H1: a pass that cannot read Reminders must not create the "New…" target, or every failed pass makes one more.
    @Test func aFailedReadCreatesNoTarget() async throws {
        var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: nil, targetTitle: "Renovation")])
        await w.reminders.setFailReads(true)
        for _ in 0..<3 { await #expect(throws: FakeReminders.Failure.self) { try await w.sync() } }
        #expect(await w.things.projectsCreated == 0)
        await w.reminders.setFailReads(false)
        try await w.sync()
        try await w.sync()
        #expect(await w.things.projectsCreated == 1)
        #expect(w.config.mappings[0].targetId != nil && w.links.ownedThings.count == 1)
    }

    /// H4: a reminder whose creation landed although the pass lost it is paired by title on the next pass.
    @Test func aReminderCreateThatLandedButFailedIsNotDuplicated() async throws {
        var w = await world()
        try await w.sync()   // first link done
        await w.things.add(todo("t1", "Call plumber", project: "P1"))
        await w.reminders.setCreateLandsThenFails(true)
        #expect(try await w.sync().failures == 1)
        #expect(w.links.links.isEmpty)
        // Whatever starts the next pass, the two existing items are linked and nothing is copied.
        let r = try await w.sync(.targeted(thingsIds: [], remindersChanged: true))
        #expect(r.linked == 1 && r.createdInThings == 0 && r.createdInReminders == 0)
        #expect(await w.reminders.all(in: "L1").map(\.title) == ["Call plumber"])
        #expect(await w.things.all().map(\.title) == ["Call plumber"])
        #expect(try await w.sync().changeCount == 0)
    }

    /// H4: the same for a Things to-do whose commit landed while the answer was lost.
    @Test func aThingsCreateThatLandedButFailedIsNotDuplicated() async throws {
        var w = await world()
        try await w.sync()
        await w.reminders.add(reminder("r1", "L1", "Call plumber"))
        await w.things.failNextCreate(lands: true)
        #expect(try await w.sync().failures == 1)
        let r = try await w.sync()
        #expect(r.linked == 1 && r.createdInThings == 0 && r.createdInReminders == 0)
        #expect(await w.things.all().count == 1)
        #expect(await w.reminders.all(in: "L1").count == 1)
    }

    /// M1 (Reminders side): giving a synced reminder a repeat keeps the pair, instead of detaching it for good.
    @Test func aReminderGivenARepeatStaysLinked() async throws {
        var w = await world()
        await w.things.add(todo("t1", "Water plants", project: "P1", startDate: "2026-11-16"))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.isRepeating = true; $0.recurrence = monday }
        let r = try await w.sync()
        #expect(r.unlinked == 0 && w.links.links.count == 1)
        #expect(w.links.links[0].repeatMode == .reminderRepeats && w.links.detachedThingsIds.isEmpty)
        // Completing the to-do moves the reminder on once, and Things gets a repeating to-do for the rule.
        await w.things.edit("t1") { $0.status = .completed; $0.stopDate = Date() }
        try await w.sync()
        #expect(await w.reminders.completions.count == 1)
        let link = try #require(w.links.links.first)
        #expect(link.repeatMode == .template && link.thingsId != "t1")
        #expect(await w.things.task(link.thingsId)?.isTemplate == true)
        #expect(await w.reminders.all(in: "L1").count == 1)
        #expect(try await w.sync().changeCount == 0)
    }

    /// M1 (Things side): Things turns the linked to-do into the first occurrence of a new template. The link moves to
    /// the template and the reminder gets the rule; before, the template got a second reminder.
    @Test func aToDoGivenARepeatInThingsKeepsItsReminder() async throws {
        var w = await world()
        await w.things.add(todo("t1", "Water plants", project: "P1", startDate: "2026-11-16"))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.things.add(ThingsTask(id: "TPL", title: "Water plants", start: .someday, projectId: "P1", isRepeating: true,
                                      recurrence: monday, nextDay: "2026-11-23", instanceDay: "2026-11-23", instancesCreated: 1))
        await w.things.edit("t1") { $0.isRepeating = true; $0.templateId = "TPL" }
        let r = try await w.sync()
        #expect(r.unlinked == 0 && r.createdInReminders == 0)
        let all = await w.reminders.all(in: "L1")
        #expect(all.count == 1 && all[0].id == rid && all[0].recurrence == monday && all[0].due?.day == "2026-11-16")
        #expect(w.links.links.count == 1 && w.links.links[0].thingsId == "TPL" && w.links.links[0].repeatMode == .template)
        #expect(try await w.sync().changeCount == 0)
    }

    /// M2: when the replacement to-do cannot be created, the reminder must not be completed a second time.
    @Test func aFailedReplacementDoesNotAdvanceTheReminderTwice() async throws {
        var w = await world()
        // A rule Things cannot hold (unrecognised), so the pair is a plain to-do per occurrence.
        var r1 = reminder("r1", "L1", "Water plants", due: DueDate(day: "2026-11-09"))
        r1.isRepeating = true
        await w.reminders.add(r1)
        try await w.sync()
        let plain = w.links.links[0].thingsId
        #expect(w.links.links[0].repeatMode == .reminderRepeats)
        await w.things.edit(plain) { $0.status = .completed; $0.stopDate = Date() }
        await w.things.failNextCreate(lands: false)
        #expect(try await w.sync().failures == 1)
        #expect(await w.reminders.item("r1")?.due?.day == "2026-11-16")
        try await w.sync()
        #expect(await w.reminders.completions.count == 1, "one Things completion is one advance")
        #expect(await w.reminders.item("r1")?.due?.day == "2026-11-16")
        let link = try #require(w.links.links.first)
        #expect(link.thingsId != plain && !link.awaitingReplacement)
        #expect(await w.things.task(link.thingsId)?.startDate == "2026-11-16")
        #expect(try await w.sync().changeCount == 0)
    }

    /// M6: a "New heading" whose project is gone is not created (it would point at nothing).
    @Test func aHeadingIsNotCreatedInAMissingProject() async throws {
        var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .heading, targetId: nil, targetTitle: "Errands", parentProjectId: "GONE")])
        let r = try await w.sync()
        #expect(await w.things.headingsCreated.isEmpty && w.config.mappings[0].targetId == nil)
        #expect(r.log.contains { $0.level == .warning && $0.message.contains("project no longer exists") })
    }

    /// M10: `#errands` in Reminders and the Things tag "Errands" are one tag. Before, the tag was rewritten on every pass.
    @Test func tagsThatDifferOnlyInCaseAreTheSameTag() async throws {
        var w = await world()
        await w.things.addTag("G1", "Errands")
        await w.things.add(todo("t1", "Task", project: "P1", tags: ["G1"]))
        var r1 = reminder("r1", "L1", "Task")
        r1.tags = ["errands"]
        await w.reminders.add(r1)
        try await w.sync()
        #expect(await w.reminders.patches.allSatisfy { $0.patch.tags == nil })
        #expect(await w.reminders.item("r1")?.tags == ["errands"])
        #expect(w.links.links[0].fingerprint.tags == ["Errands"])
        #expect(try await w.sync().changeCount == 0)
        // Removing it in Reminders removes the Things tag.
        await w.reminders.edit("r1") { $0.tags = [] }
        try await w.sync()
        #expect(await w.things.task("t1")?.tagIds == [])
    }

    /// M11: a new time for a repeating reminder is also written to the template, so later occurrences keep it.
    @Test func aNewTimeOnARepeatingReminderReachesTheTemplate() async throws {
        var w = await world()
        await w.things.add(ThingsTask(id: "TPL", title: "Water plants", start: .someday, reminderSeconds: 9 * 3600, projectId: "P1",
                                      isRepeating: true, recurrence: monday, nextDay: "2026-11-23", instanceDay: "2026-11-23", instancesCreated: 1))
        await w.things.add(ThingsTask(id: "OCC", title: "Water plants", startDate: "2026-11-16", reminderSeconds: 9 * 3600, projectId: "P1",
                                      isRepeating: true, templateId: "TPL"))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.things.clearRecords()
        await w.reminders.edit(rid) { $0.due = DueDate(day: "2026-11-16", minutes: 10 * 60) }
        try await w.sync()
        let updates = await w.things.updates
        #expect(updates.contains { $0.0 == "OCC" && $0.1.when == .some(DueDate(day: "2026-11-16", minutes: 600)) })
        #expect(updates.contains { $0.0 == "TPL" && $0.1.templateMinutes == .some(600) && $0.1.templateNext == nil })
        #expect(await w.things.task("TPL")?.nextDay == "2026-11-23")
        #expect(try await w.sync().changeCount == 0)
    }

    /// L1: the count limit holds for the whole pass, not only per list.
    @Test func theDeletionCountLimitCoversTheWholePass() async throws {
        let lists = ["L1", "L2", "L3"]
        var w = World(lists: lists, mappings: lists.enumerated().map {
            ListMapping(id: $1, listTitle: $1, mode: .project, targetId: "P\($0 + 1)", targetTitle: "Proj")
        })
        for (i, list) in lists.enumerated() {
            await w.things.add(projectTask("P\(i + 1)"))
            for n in 0..<20 { await w.reminders.add(reminder("\(list)-\(n)", list, "Item \(list) \(n)")) }
        }
        try await w.sync()
        #expect(w.links.links.count == 60)
        // Four of twenty per list is under the per-list limits; twelve in one pass is over ten.
        for list in lists { for n in 0..<4 { await w.reminders.remove("\(list)-\(n)") } }
        let held = try await w.sync()
        #expect(held.deletionsHeld && held.deletedInThings == 0)
        #expect(try await w.sync(force: true).deletedInThings == 12)
    }

    /// L5: notes replaced on a first link are named in the log.
    @Test func replacedFirstLinkNotesAreLogged() async throws {
        var w = await world()
        await w.things.add(todo("t1", "Passport", project: "P1", notes: "Things text"))
        await w.reminders.add(reminder("r1", "L1", "Passport", notes: "Renewal form in the blue folder"))
        let r = try await w.sync()
        #expect(await w.reminders.item("r1")?.notes == "Things text")
        #expect(r.log.contains { $0.level == .warning && $0.message.contains("Passport") && $0.message.contains("replaced the Reminders notes") })
    }

    /// L2: an area or tag is deleted for good, so what sits in the Trash still counts as content.
    @Test func trashedContentsKeepAnAreaOrTagAlive() {
        var trashedProject = ThingsTask(id: "P", kind: .project, title: "Old", areaId: "A")
        trashedProject.trashed = true
        var trashedTodo = todo("t", "Old", tags: ["G"])
        trashedTodo.trashed = true
        let snapshot = ThingsSnapshot(tasks: ["P": trashedProject, "t": trashedTodo],
                                      areas: ["A": ThingsArea(id: "A", title: "Area"), "A2": ThingsArea(id: "A2", title: "Tagged", tagIds: ["G2"])],
                                      tags: ["G": ThingsTag(id: "G", title: "Tag"), "G2": ThingsTag(id: "G2", title: "On an area")])
        #expect(!snapshot.isEmpty(.area, id: "A") && !snapshot.isEmpty(.tag, id: "G"))
        #expect(snapshot.isEmpty(.area, id: "A", ignoring: ["P"]) && snapshot.isEmpty(.tag, id: "G", ignoring: ["t"]))
        #expect(!snapshot.isEmpty(.tag, id: "G2"), "a tag an area carries is in use")
    }
}

@Suite("Audit fixes: notes") struct AuditNotesTests {
    /// L3: a rich link without `://` is still the link line when the reminder already has that link.
    @Test func aKnownLinkOfAnySchemeIsTheLinkLine() {
        let notes = "Ask about the invoice\n\nmailto:sam@example.com"
        #expect(NoteFormatting.splitTrailingURL(notes).url == nil)
        let rendered = NotesLink.render(thingsNotes: notes, existingURL: "mailto:sam@example.com")
        #expect(rendered.notes == "Ask about the invoice" && rendered.url == "mailto:sam@example.com")
        #expect(NotesLink.replacingTrailingURL(in: notes, old: "mailto:sam@example.com", new: nil) == "Ask about the invoice")
    }

    /// L4: a longer address that starts with the link is not the link.
    @Test func aLongerAddressDoesNotCountAsTheLink() {
        #expect(NoteFormatting.appendingURL("https://example.com", to: "See https://example.com/login")
                == "See https://example.com/login\n\nhttps://example.com")
        for notes in ["See https://example.com.", "[site](https://example.com)", "https://example.com/", "a https://example.com, b"] {
            #expect(NoteFormatting.appendingURL("https://example.com", to: notes) == notes)
        }
    }
}

@Suite("Audit fixes: Things client") struct AuditThingsClientTests {
    private func lastPatch(_ cloud: FakeThingsCloud, _ id: String) throws -> [String: JSONValue] {
        try #require(try cloud.commitBody(cloud.commits.count - 1)[id]?["p"]?.object)
    }

    /// M5: a time change on the same day writes `ato` alone, so a to-do stays in This Evening. `sb 0` is written only
    /// when a to-do that is in This Evening changes day.
    @Test func schedulingWritesOnlyWhatChanges() async throws {
        let evening = ThingsID.generate(), plain = ThingsID.generate()
        let today = day(2026, 11, 9)
        let cloud = FakeThingsCloud(items: [
            taskItem(evening, ["tt": "e", "tp": 0, "st": 1, "sb": 1, "sr": .number(today), "tir": .number(today)]),
            taskItem(plain, ["tt": "p", "tp": 0, "st": 1, "sb": 0, "sr": .number(today), "tir": .number(today)])])
        let client = cloud.client()
        try await client.updateTodo(id: evening, patch: ThingsTodoPatch(when: .some(DueDate(day: "2026-11-09", minutes: 18 * 60))))
        #expect(try lastPatch(cloud, evening) == ["md": .number(1_794_186_000), "ato": 64800])
        #expect(try await client.refresh().snapshot.tasks[evening]?.evening == true)

        try await client.updateTodo(id: plain, patch: ThingsTodoPatch(when: .some(DueDate(day: "2026-11-12"))))
        let moved = try lastPatch(cloud, plain)
        #expect(Set(moved.keys) == ["md", "st", "sr", "tir", "ato"] && moved["st"] == 2)

        try await client.updateTodo(id: evening, patch: ThingsTodoPatch(when: .some(DueDate(day: "2026-11-12"))))
        #expect(try lastPatch(cloud, evening)["sb"] == 0)
    }

    /// M6: a reference to something that does not exist, or is in the Trash, is refused before anything is sent.
    @Test func referencesMustBeLive() async throws {
        let trashed = ThingsID.generate(), project = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(trashed, ["tr": true]), projectItem(project)])
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) { try await client.createHeading(title: "H", projectId: ThingsID.generate()) }
        await #expect(throws: ThingsCloudError.self) { try await client.createHeading(title: "H", projectId: trashed) }
        await #expect(throws: ThingsCloudError.self) { try await client.createProject(title: "P", areaId: ThingsID.generate()) }
        await #expect(throws: ThingsCloudError.self) { try await client.createTodo(ThingsTodoDraft(title: "t", tagIds: [ThingsID.generate()])) }
        // A project is not a heading.
        await #expect(throws: ThingsCloudError.self) { try await client.createTodo(ThingsTodoDraft(title: "t", placement: .heading(project))) }
        #expect(cloud.commits.isEmpty)
        _ = try await client.createHeading(title: "H", projectId: project)
        #expect(cloud.commits.count == 1)
    }

    /// M9: `tg` is the whole list, so it is built from the to-do as it is now. A tag added in Things during the pass survives.
    @Test func aTagAddedElsewhereSurvivesATagWrite() async throws {
        let task = ThingsID.generate(), a = ThingsID.generate(), b = ThingsID.generate(), c = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(task, ["tt": "t", "tp": 0, "tg": .array([.string(a)])]), tagItem(a), tagItem(b), tagItem(c)])
        let client = cloud.client()
        _ = try await client.refresh()
        cloud.items.append(taskItem(task, ["tg": .array([.string(a), .string(b)])], t: 1))   // the phone adds a tag
        cloud.head += 1
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(addTagIds: [c]))
        #expect(try lastPatch(cloud, task)["tg"] == .array([.string(a), .string(b), .string(c)]))
        // The change pulled for the write is still reported to the poll.
        #expect(try await client.refresh().changedTaskIds.contains(task))
    }

    /// M9: a refused commit (stale index) is rebuilt from the refreshed to-do, not sent again unchanged.
    @Test func aStaleCommitIsRebuiltFromTheCurrentToDo() async throws {
        let task = ThingsID.generate(), a = ThingsID.generate(), b = ThingsID.generate(), c = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(task, ["tt": "t", "tp": 0, "tg": .array([.string(a)])]), tagItem(a), tagItem(b), tagItem(c)])
        let client = cloud.client()
        cloud.commitStatuses = [409]
        cloud.onRefusedCommit = {
            cloud.items.append(taskItem(task, ["tg": .array([.string(a), .string(b)])], t: 1))
            cloud.head += 1
        }
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(addTagIds: [c]))
        #expect(cloud.commits.count == 2)
        #expect(try lastPatch(cloud, task)["tg"] == .array([.string(a), .string(b), .string(c)]))
    }

    /// M9: notes are a full replacement, so they are not written over notes edited in Things since the pass read them.
    @Test func notesEditedElsewhereAreNotOverwritten() async throws {
        let task = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(task, ["tt": "t", "tp": 0, "nt": ThingsChanges.noteObject("old")])])
        let client = cloud.client()
        _ = try await client.refresh()
        cloud.items.append(taskItem(task, ["nt": ThingsChanges.noteObject("edited on the phone")], t: 1))
        cloud.head += 1
        await #expect(throws: ThingsCloudError.changedMeanwhile("The notes of \"t\"")) {
            try await client.updateTodo(id: task, patch: ThingsTodoPatch(notes: "from Reminders", notesBase: "old"))
        }
        #expect(cloud.commits.isEmpty)
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(notes: "from Reminders", notesBase: "edited on the phone"))
        #expect(try lastPatch(cloud, task)["nt"]?["v"] == "from Reminders")
    }

    /// Parity D2 and D3: the start state follows a move into or out of the Inbox.
    @Test func movingBetweenTheInboxAndAContainerSetsTheStartState() async throws {
        let inbox = ThingsID.generate(), anytime = ThingsID.generate(), dated = ThingsID.generate(), someday = ThingsID.generate()
        let project = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(inbox, ["tt": "i", "tp": 0, "st": 0]),
            taskItem(anytime, ["tt": "a", "tp": 0, "st": 1, "pr": .array([.string(project)])]),
            taskItem(dated, ["tt": "d", "tp": 0, "st": 1, "sr": .number(day(2026, 11, 9)), "pr": .array([.string(project)])]),
            taskItem(someday, ["tt": "s", "tp": 0, "st": 2, "pr": .array([.string(project)])]),
            projectItem(project)])
        let client = cloud.client()
        try await client.updateTodo(id: inbox, patch: ThingsTodoPatch(placement: .project(project)))
        let filed = try lastPatch(cloud, inbox)
        #expect(Set(filed.keys) == ["md", "pr", "agr", "ar", "st"] && filed["st"] == 1)

        try await client.updateTodo(id: anytime, patch: ThingsTodoPatch(placement: .inbox))
        let out = try lastPatch(cloud, anytime)
        #expect(out["st"] == 0 && out["pr"] == [] && out["sb"] == nil)

        // The Inbox holds no dated to-dos, and a Someday to-do stays where the user put it.
        try await client.updateTodo(id: dated, patch: ThingsTodoPatch(placement: .inbox))
        #expect(try lastPatch(cloud, dated)["st"] == nil)
        try await client.updateTodo(id: someday, patch: ThingsTodoPatch(placement: .inbox))
        #expect(try lastPatch(cloud, someday)["st"] == nil)
    }

    /// Parity D4: deleting an area or tag first takes it off every task that names it, trashed ones included.
    @Test func tombstonesStripReferencesFirst() async throws {
        let area = ThingsID.generate(), tag = ThingsID.generate(), other = ThingsID.generate()
        let inArea = ThingsID.generate(), tagged = ThingsID.generate(), untouched = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            areaItem(area), tagItem(tag), tagItem(other),
            taskItem(inArea, ["tt": "x", "tp": 1, "tr": true, "ar": .array([.string(area)])]),
            taskItem(tagged, ["tt": "y", "tp": 0, "tr": true, "tg": .array([.string(tag), .string(other)])]),
            taskItem(untouched, ["tt": "z", "tp": 0, "tg": .array([.string(other)])])])
        let client = cloud.client()
        try await client.deleteArea(id: area)
        var body = try cloud.commitBody(0)
        #expect(body.count == 2 && body[area]?["t"] == 2 && body[area]?["e"] == "Area3" && body[area]?["p"] == [:])
        #expect(body[inArea]?["t"] == 1 && body[inArea]?["p"]?["ar"] == [] && Set(body[inArea]?["p"]?.object?.keys.map { $0 } ?? []) == ["ar", "md"])

        try await client.deleteTag(id: tag)
        body = try cloud.commitBody(1)
        #expect(body.count == 2 && body[tag]?["t"] == 2 && body[tag]?["e"] == "Tag4")
        #expect(body[tagged]?["p"]?["tg"] == .array([.string(other)]))
    }

    /// Parity D4: this client writes no area update, so a tag an area still carries is not deleted.
    @Test func aTagAnAreaCarriesIsNotDeleted() async throws {
        let area = ThingsID.generate(), tag = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [tagItem(tag), areaItem(area, ["tg": .array([.string(tag)])])])
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) { try await client.deleteTag(id: tag) }
        #expect(cloud.commits.isEmpty)
    }

    /// M11: the template's reminder time is written as `ato` alone.
    @Test func templateMinutesWritesOnlyTheTime() async throws {
        let template = ThingsID.generate()
        let rr = try #require(ThingsRepeat.rr(for: monday, start: "2026-11-16"))
        let cloud = FakeThingsCloud(items: [taskItem(template, ["tt": "t", "tp": 0, "st": 2, "rr": rr, "tir": .number(day(2026, 11, 16))])])
        let client = cloud.client()
        try await client.updateTodo(id: template, patch: ThingsTodoPatch(templateMinutes: .some(600)))
        #expect(try lastPatch(cloud, template) == ["md": .number(1_794_186_000), "ato": 36000])
    }

    /// L6: a checklist change is a change of its to-do, so it syncs on the next poll.
    @Test func aChecklistChangeTouchesItsToDo() {
        var db = ThingsDatabase()
        let task = ThingsID.generate(), item = ThingsID.generate()
        db.apply([task: ThingsChange(t: 0, e: "Task6", p: ["tt": "t"])])
        let added = db.apply([item: ThingsChange(t: 0, e: "ChecklistItem3", p: ["tt": "i", "ss": 0, "ts": .array([.string(task)])])])
        #expect(added == [task])
        #expect(db.apply([item: ThingsChange(t: 1, e: "ChecklistItem3", p: ["ss": 3])]) == [task])
        #expect(db.apply([item: ThingsChange(t: 2, e: "ChecklistItem3", p: [:])]) == [task])
    }
}
