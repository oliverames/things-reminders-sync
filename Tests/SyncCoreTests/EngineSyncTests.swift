import Foundation
import Testing
@testable import SyncCore

private let early = Date(timeIntervalSince1970: 1_000)
private let late = Date(timeIntervalSince1970: 9_000_000_000)

private func projectWorld() async -> World {
    let w = World()
    await w.things.add(projectTask("P1"))
    return w
}

@Test func firstLinkPairsByTitleAndCreatesTheRestWithoutDuplicates() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Buy milk", project: "P1"))
    await w.things.add(todo("t2", "Only in Things", project: "P1"))
    await w.reminders.add(reminder("r1", "L1", "  buy MILK "))
    await w.reminders.add(reminder("r2", "L1", "Only in Reminders"))
    let r = try await w.sync()
    #expect(r.linked == 1 && r.createdInThings == 1 && r.createdInReminders == 1)
    #expect(await w.things.all().count == 3)
    #expect(await w.reminders.all(in: "L1").count == 3)
    #expect(w.links.links.count == 3)
    let again = try await w.sync()
    #expect(again.changeCount == 0)
    #expect(await w.things.all().count == 3)
}

@Test func oneSideEditPropagatesAndEchoIsNoOp() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Task", project: "P1"))
    try await w.sync()
    let rid = w.links.links[0].reminderId
    await w.reminders.edit(rid) { $0.title = "Renamed"; $0.notes = "n"; $0.lastModified = late }
    let r = try await w.sync()
    #expect(r.updatedInThings == 1)
    let t = try #require(await w.things.task("t1"))
    #expect(t.title == "Renamed" && t.notes == "n")
    #expect(try await w.sync().changeCount == 0)
    // Things edit comes back the other way.
    await w.things.edit("t1") { $0.title = "From Things"; $0.modificationDate = late }
    #expect(try await w.sync().updatedInReminders == 1)
    #expect(await w.reminders.item(rid)?.title == "From Things")
    #expect(try await w.sync().changeCount == 0)
}

@Test func trueConflictResolvesPerFieldByModificationDate() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Task", project: "P1", notes: "a"))
    try await w.sync()
    let rid = w.links.links[0].reminderId
    // Reminders is newer: title conflict goes to Reminders. Things changed only the due date, Reminders only notes.
    await w.reminders.edit(rid) { $0.title = "R title"; $0.notes = "R notes"; $0.lastModified = late }
    await w.things.edit("t1") { $0.title = "T title"; $0.startDate = day(3); $0.modificationDate = early }
    let r = try await w.sync()
    #expect(r.log.contains { $0.level == .warning })
    let t = try #require(await w.things.task("t1"))
    let rem = try #require(await w.reminders.item(rid))
    #expect(t.title == "R title" && rem.title == "R title")
    #expect(t.notes == "R notes")
    #expect(rem.due == DueDate(day: day(3)))
    // Now Things is newer and wins a title conflict.
    await w.reminders.edit(rid) { $0.title = "R2"; $0.lastModified = early }
    await w.things.edit("t1") { $0.title = "T2"; $0.modificationDate = late }
    try await w.sync()
    #expect(await w.reminders.item(rid)?.title == "T2")
}

@Test func completionBothDirectionsIncludingCanceled() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "A", project: "P1"))
    await w.things.add(todo("t2", "B", project: "P1"))
    try await w.sync()
    let rA = try #require(w.links.links.first { $0.thingsId == "t1" }).reminderId
    let rB = try #require(w.links.links.first { $0.thingsId == "t2" }).reminderId
    await w.reminders.edit(rA) { $0.completed = true; $0.completionDate = Date(); $0.lastModified = late }
    await w.things.edit("t2") { $0.status = .canceled; $0.stopDate = Date(); $0.modificationDate = late }
    try await w.sync()
    #expect(await w.things.task("t1")?.status == .completed)
    #expect(await w.reminders.item(rB)?.completed == true)
    #expect(try await w.sync().changeCount == 0)
    // Reopen in Reminders reopens Things.
    await w.reminders.edit(rA) { $0.completed = false; $0.completionDate = nil; $0.lastModified = late }
    try await w.sync()
    #expect(await w.things.task("t1")?.status == .open)
}

@Test func dueDateRoundTripAndNoDueDateRule() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Timed", project: "P1", startDate: day(1), seconds: 9 * 3600 + 1800))
    await w.things.add(todo("t2", "Someday", project: "P1"))
    await w.things.edit("t2") { $0.start = .someday }
    await w.things.add(todo("t3", "Today", project: "P1", startDate: day(0)))
    try await w.sync()
    let link1 = try #require(w.links.links.first { $0.thingsId == "t1" })
    let link3 = try #require(w.links.links.first { $0.thingsId == "t3" })
    #expect(await w.reminders.item(link1.reminderId)?.due == DueDate(day: day(1), minutes: 570))
    #expect(await w.reminders.item(link3.reminderId)?.due == DueDate(day: day(0)))
    // Someday stays Someday: nothing pulls it to Anytime.
    #expect(await w.things.task("t2")?.start == .someday)
    #expect(try await w.sync().changeCount == 0)
    #expect(await w.things.task("t2")?.start == .someday)
    // Reminders adds a time, then removes the date entirely.
    await w.reminders.edit(link1.reminderId) { $0.due = DueDate(day: day(2), minutes: 600); $0.lastModified = late }
    try await w.sync()
    let t1 = try #require(await w.things.task("t1"))
    #expect(t1.startDate == day(2) && t1.reminderSeconds == 36_000)
    await w.reminders.edit(link3.reminderId) { $0.due = nil; $0.lastModified = late }
    try await w.sync()
    #expect(await w.things.task("t3")?.startDate == nil)
    // Things reschedules: the reminder follows.
    await w.things.edit("t1") { $0.startDate = day(5); $0.reminderSeconds = nil; $0.modificationDate = late }
    try await w.sync()
    #expect(await w.reminders.item(link1.reminderId)?.due == DueDate(day: day(5)))
}

@Test func firstLinkNeverClearsThingsDateBecauseReminderHasNone() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Same", project: "P1", startDate: day(0)))
    await w.reminders.add(reminder("r1", "L1", "Same", modified: late))
    try await w.sync()
    #expect(await w.things.task("t1")?.startDate == day(0))
    #expect(await w.reminders.item("r1")?.due == DueDate(day: day(0)))
}

@Test func moveBetweenTwoMappedLists() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "One"),
        ListMapping(id: "L2", listTitle: "L2", mode: .project, targetId: "P2", targetTitle: "Two"),
    ])
    await w.things.add(projectTask("P1")); await w.things.add(projectTask("P2"))
    await w.things.add(todo("t1", "Mover", project: "P1"))
    await w.things.add(todo("t2", "Mover2", project: "P1"))
    try await w.sync()
    let l1 = try #require(w.links.links.first { $0.thingsId == "t1" })
    let l2 = try #require(w.links.links.first { $0.thingsId == "t2" })
    // Reminder moves L1 -> L2: Things item follows.
    await w.reminders.edit(l1.reminderId) { $0.listId = "L2"; $0.lastModified = late }
    // Things item moves P1 -> P2: reminder follows.
    await w.things.edit("t2") { $0.projectId = "P2"; $0.modificationDate = late }
    try await w.sync()
    #expect(await w.things.task("t1")?.projectId == "P2")
    #expect(await w.reminders.item(l2.reminderId)?.listId == "L2")
    #expect(w.links.links.allSatisfy { $0.mappingId == "L2" })
    #expect(try await w.sync().changeCount == 0)
    #expect(await w.things.all().count == 2)
}

@Test func moveOutOfScopeUnlinksOnly() async throws {
    var w = World(lists: ["L1", "L9"])
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "A", project: "P1"))
    await w.things.add(todo("t2", "B", project: "P1"))
    try await w.sync()
    let a = try #require(w.links.links.first { $0.thingsId == "t1" })
    // Reminder moves to an unmapped list; Things item leaves the project.
    await w.reminders.edit(a.reminderId) { $0.listId = "L9" }
    await w.things.edit("t2") { $0.projectId = nil }
    let r = try await w.sync()
    #expect(r.unlinked == 2 && r.deletedInThings == 0 && r.deletedInReminders == 0)
    #expect(w.links.links.isEmpty)
    #expect(await w.things.task("t1")?.trashed == false)
    #expect(await w.reminders.item(a.reminderId) != nil)
    #expect(await w.reminders.all(in: "L1").count == 1)   // B's reminder stays; no new items appear
    #expect(await w.things.all().count == 2)
}

@Test func deletionBothDirectionsNeverPermanent() async throws {
    var w = await projectWorld()
    for i in 1...5 { await w.things.add(todo("t\(i)", "Item \(i)", project: "P1")) }
    try await w.sync()
    let l1 = try #require(w.links.links.first { $0.thingsId == "t1" })
    // 1 of 5 = 20%: under the limit. Reminder deleted -> Things trashed. Things trashed -> reminder deleted.
    await w.reminders.remove(l1.reminderId)
    let r = try await w.sync()
    #expect(r.deletedInThings == 1)
    #expect(await w.things.task("t1")?.trashed == true)
    let l2 = try #require(w.links.links.first { $0.thingsId == "t2" })
    await w.things.edit("t2") { $0.trashed = true }
    let r2 = try await w.sync()
    #expect(r2.deletedInReminders == 1)
    #expect(await w.reminders.item(l2.reminderId) == nil)
    #expect(w.links.links.count == 3)
    #expect(try await w.sync().changeCount == 0)
}

@Test func deletionSafetyLimitTripsAndForceApplies() async throws {
    var w = await projectWorld()
    for i in 1...4 { await w.things.add(todo("t\(i)", "Item \(i)", project: "P1")) }
    try await w.sync()
    for id in ["t1", "t2", "t3"] { await w.things.edit(id) { $0.trashed = true } }
    let r = try await w.sync()
    #expect(r.deletionsHeld && r.deletedInReminders == 0)
    #expect(r.log.contains { $0.level == .error })
    #expect(await w.reminders.all(in: "L1").count == 4)
    #expect(w.links.links.count == 4)
    let forced = try await w.sync(force: true)
    #expect(forced.deletedInReminders == 3 && !forced.deletionsHeld)
    #expect(await w.reminders.all(in: "L1").count == 1)
}

@Test func moreThanTenDeletionsTrips() async throws {
    var w = await projectWorld()
    for i in 1...60 { await w.things.add(todo("t\(i)", "Item \(i)", project: "P1")) }
    try await w.sync()
    for i in 1...11 { await w.things.edit("t\(i)") { $0.trashed = true } }   // 18%, but 11 > 10
    #expect(try await w.sync().deletionsHeld)
}

/// Updated for repeating sync: headings and projects are still never synced; a template whose rule is not a known
/// shape gets no reminder (nothing to copy), and a repeating reminder whose rule is not a known shape gets a PLAIN to-do.
@Test func headingsProjectsAndUnrecognisedRulesAreNotCopiedAsRepeating() async throws {
    var w = await projectWorld()
    var rep = todo("t1", "Repeats", project: "P1"); rep.isRepeating = true   // a template with an unrecognised rule
    await w.things.add(rep)
    var heading = ThingsTask(id: "H1", kind: .heading, title: "Heading"); heading.projectId = "P1"
    await w.things.add(heading)
    await w.things.add(ThingsTask(id: "P2", kind: .project, title: "Sub", areaId: nil))
    var repReminder = reminder("r1", "L1", "Repeating reminder", due: DueDate(day: "2026-11-10")); repReminder.isRepeating = true
    await w.reminders.add(repReminder)
    let r = try await w.sync()
    #expect(await w.reminders.all(in: "L1").map(\.title) == ["Repeating reminder"])   // no reminder for the template
    #expect(r.createdInThings == 1)
    let plain = try #require(await w.things.all().first { $0.title == "Repeating reminder" })
    #expect(!plain.isRepeating && plain.recurrence == nil && plain.startDate == "2026-11-10")
    #expect(w.links.links.map(\.repeatMode) == [.reminderRepeats])
    #expect(r.log.contains { $0.level == .info && $0.message.contains("Things cannot hold") })
}

@Test func tagModeCreatesInboxTodoWithTag() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .tag, targetId: "G1", targetTitle: "sync")])
    await w.things.addTag("G1", "sync")
    await w.things.add(todo("t1", "Tagged elsewhere", project: "PX", tags: ["G1"]))
    await w.reminders.add(reminder("r1", "L1", "From reminders"))
    try await w.sync()
    let created = try #require(await w.things.all().first { $0.title == "From reminders" })
    #expect(created.start == .inbox && created.tagIds == ["G1"] && created.projectId == nil)
    #expect(await w.reminders.all(in: "L1").map(\.title).sorted() == ["From reminders", "Tagged elsewhere"])
}

@Test func areaModeUsesDirectItemsOnly() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .area, targetId: "A1", targetTitle: "Home")])
    await w.things.addArea("A1", "Home")
    await w.things.add(todo("t1", "Direct", area: "A1"))
    await w.things.add(todo("t2", "In project", project: "PX"))
    await w.things.edit("t2") { $0.areaId = "A1" }
    await w.reminders.add(reminder("r1", "L1", "New one"))
    try await w.sync()
    #expect(await w.reminders.all(in: "L1").map(\.title).sorted() == ["Direct", "New one"])
    #expect(try await w.things.all().first { $0.title == "New one" }?.areaId == "A1")
}

@Test func projectModeIncludesItemsViaHeading() async throws {
    var w = await projectWorld()
    var heading = ThingsTask(id: "H1", kind: .heading, title: "H"); heading.projectId = "P1"
    await w.things.add(heading)
    var t = todo("t1", "Under heading"); t.headingId = "H1"
    await w.things.add(t)
    try await w.sync()
    #expect(await w.reminders.all(in: "L1").map(\.title) == ["Under heading"])
}

@Test func targetAutoCreationWritesIdBack() async throws {
    var w = World(lists: ["L1", "L2", "L3"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetTitle: "New Project"),
        ListMapping(id: "L2", listTitle: "L2", mode: .area, targetTitle: "New Area"),
        ListMapping(id: "L3", listTitle: "L3", mode: .tag, targetTitle: "new-tag"),
    ])
    let r = try await w.sync()
    #expect(r.config.mappings.allSatisfy { $0.targetId != nil })
    let pid = try #require(w.config.mappings[0].targetId)
    #expect(await w.things.task(pid)?.title == "New Project")
    #expect(await w.things.areas.count == 1)
    #expect(await w.things.tags.count == 1)
    // Second pass reuses the ids.
    try await w.sync()
    #expect(await w.things.areas.count == 1)
    await w.reminders.add(reminder("r1", "L1", "Goes to new project"))
    try await w.sync()
    #expect(try await w.things.all().first?.projectId == pid)
}

@Test func multiMappingPrecedenceFirstMappingWins() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "P"),
        ListMapping(id: "L2", listTitle: "L2", mode: .tag, targetId: "G1", targetTitle: "tag"),
    ])
    await w.things.add(projectTask("P1"))
    await w.things.addTag("G1", "tag")
    await w.things.add(todo("t1", "Both", project: "P1", tags: ["G1"]))
    await w.things.add(todo("t2", "Tag only", tags: ["G1"]))
    try await w.sync()
    #expect(await w.reminders.all(in: "L1").map(\.title) == ["Both"])
    #expect(await w.reminders.all(in: "L2").map(\.title) == ["Tag only"])
}

@Test func targetedScopeOnlyTouchesChangedThingsItems() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "One", project: "P1"))
    await w.things.add(todo("t2", "Two", project: "P1"))
    try await w.sync()
    await w.things.edit("t1") { $0.title = "One!"; $0.modificationDate = late }
    await w.things.edit("t2") { $0.title = "Two!"; $0.modificationDate = late }
    let r = try await w.sync(.targeted(thingsIds: ["t1"], remindersChanged: false))
    #expect(r.updatedInReminders == 1)
    let titles = await w.reminders.all(in: "L1").map(\.title).sorted()
    #expect(titles == ["One!", "Two"])
}

@Test func completedUnlinkedItemsOnlyLinkWhenFirstLinkAsksFor() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Done already", project: "P1", status: .completed))
    try await w.sync()
    #expect(w.links.links.isEmpty)
    #expect(await w.reminders.items.isEmpty)
    var w2 = await projectWorld()
    w2.config.includeCompletedOnFirstLink = true
    await w2.things.add(todo("t1", "Done already", project: "P1", status: .completed))
    try await w2.sync()
    #expect(await w2.reminders.all(in: "L1").first?.completed == true)
    // After the first link, a newly completed unlinked item is ignored.
    await w2.things.add(todo("t2", "Late done", project: "P1", status: .completed))
    try await w2.sync()
    #expect(await w2.reminders.all(in: "L1").count == 1)
}

// Regression: an unlinked item must not get a new partner on the next pass, or a moved item is
// duplicated and a deleted one comes back.
@Test func detachedItemsNeverGetARecreatedPartner() async throws {
    var w = World(lists: ["L1", "L9"])
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Moves away", project: "P1"))
    await w.things.add(todo("t2", "Deleted with deletes off", project: "P1"))
    try await w.sync()
    w.config.propagateDeletes = false
    let moved = try #require(w.links.links.first { $0.thingsId == "t1" })
    let deleted = try #require(w.links.links.first { $0.thingsId == "t2" })
    await w.reminders.edit(moved.reminderId) { $0.listId = "L9" }
    await w.reminders.remove(deleted.reminderId)
    #expect(try await w.sync().unlinked == 2)
    for _ in 0..<2 {
        let r = try await w.sync()
        #expect(r.createdInReminders == 0 && r.createdInThings == 0)
    }
    #expect(await w.reminders.all(in: "L1").isEmpty)
    #expect(await w.things.task("t2")?.trashed == false)
}

// Regression: on first link the reminder looks "modified now" (RemCTL has no modification date),
// which must not let an empty reminder note wipe a Things note or retitle the Things item.
@Test func firstLinkNeverOverwritesRicherThingsFields() async throws {
    var w = await projectWorld()
    await w.things.add(todo("t1", "Call Dr. Lee", project: "P1", notes: "**Bring** the referral", modified: early))
    await w.things.add(todo("t2", "Pay rent", project: "P1", notes: "", modified: early))
    await w.reminders.add(reminder("r1", "L1", "call dr. lee", notes: "", modified: late))
    await w.reminders.add(reminder("r2", "L1", "Pay rent", notes: "Portal login in 1Password", modified: late))
    try await w.sync()
    #expect(await w.things.task("t1")?.notes == "**Bring** the referral")
    #expect(await w.things.task("t1")?.title == "Call Dr. Lee")
    #expect(await w.reminders.item("r1")?.notes == "**Bring** the referral")
    #expect(await w.reminders.item("r1")?.title == "Call Dr. Lee")
    #expect(await w.things.task("t2")?.notes == "Portal login in 1Password")
}
