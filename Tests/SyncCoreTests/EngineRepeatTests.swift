import Foundation
import Testing
@testable import SyncCore

// Repeating sync: a repeating reminder pairs with a Things TEMPLATE (docs/RECURRENCE.md). 2026-11-16 is a Monday.

private let monday = RepeatRule(frequency: .weekly, weekdays: [1])

private func world() async -> World {
    let w = World()
    await w.things.add(projectTask("P1"))
    return w
}

private func template(_ id: String = "TPL", _ title: String = "Water plants", rule: RepeatRule? = monday, next: String? = "2026-11-16",
                      seconds: Int? = nil, created: Int = 0, project: String = "P1") -> ThingsTask {
    ThingsTask(id: id, title: title, start: .someday, reminderSeconds: seconds, projectId: project,
               modificationDate: Date(timeIntervalSince1970: 1_000), isRepeating: true, recurrence: rule,
               nextDay: next, instanceDay: next, instancesCreated: created)
}

private func occurrence(_ id: String, of template: String = "TPL", _ title: String = "Water plants", day: String,
                        status: ThingsStatus = .open, project: String = "P1") -> ThingsTask {
    ThingsTask(id: id, title: title, status: status, stopDate: status == .open ? nil : Date(), startDate: day,
               projectId: project, modificationDate: Date(timeIntervalSince1970: 1_000), isRepeating: true, templateId: template)
}

private func repeatingReminder(_ id: String, _ title: String = "Water plants", rule: RepeatRule? = monday, due: DueDate? = DueDate(day: "2026-11-16")) -> ReminderItem {
    ReminderItem(id: id, externalId: "x\(id)", listId: "L1", title: title, due: due, lastModified: Date(timeIntervalSince1970: 1_000),
                 isRepeating: true, recurrence: rule)
}

/// A world already synced with one template pair (Things template + open Monday occurrence, reminder made from it).
private func pairedWorld(rule: RepeatRule = monday) async throws -> World {
    var w = await world()
    await w.things.add(template(rule: rule, created: 1))
    await w.things.add(occurrence("OCC1", day: "2026-11-16"))
    try await w.sync()
    #expect(w.links.links.count == 1 && w.links.links[0].repeatMode == .template)
    await w.things.clearRecords()
    return w
}

@Suite("Repeating sync")
struct EngineRepeatTests {
    // MARK: Creation

    @Test func newTemplateBecomesARepeatingReminderDueOnTheOpenOccurrence() async throws {
        var w = await world()
        await w.things.add(template(seconds: 32400, created: 1))
        await w.things.add(occurrence("OCC1", day: "2026-11-16"))
        await w.things.add(occurrence("OLD", day: "2026-11-09", status: .completed))
        let r = try await w.sync()
        #expect(r.createdInReminders == 1)
        let all = await w.reminders.all(in: "L1")
        #expect(all.count == 1, "occurrences of a synced template are never synced individually")
        let made = await w.reminders.created
        #expect(made.count == 1 && made[0].rule == monday)
        #expect(all[0].isRepeating && all[0].recurrence == monday)
        #expect(all[0].due?.day == "2026-11-16" && all[0].due?.minutes == nil)   // the occurrence's own day (it has no ato)
        let link = try #require(w.links.links.first)
        #expect(link.copySide == .reminders && link.repeatMode == .template && link.thingsId == "TPL" && link.fingerprint.rule == monday)
        #expect(await w.things.created.isEmpty)
    }

    @Test func templateWithNoOccurrenceUsesItsNextDayAndTime() async throws {
        var w = await world()
        await w.things.add(template(seconds: 32400))
        try await w.sync()
        let r = try #require(await w.reminders.all(in: "L1").first)
        #expect(r.due == DueDate(day: "2026-11-16", minutes: 540) && r.recurrence == monday)
    }

    @Test func newRepeatingReminderBecomesATemplateNeverAnOccurrence() async throws {
        var w = await world()
        let rule = RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4])
        await w.reminders.add(repeatingReminder("r1", rule: rule, due: DueDate(day: "2026-11-16", minutes: 540)))
        let r = try await w.sync()
        #expect(r.createdInThings == 1)
        let created = try #require(await w.things.created.first)
        #expect(created.recurrence == rule && created.when == DueDate(day: "2026-11-16", minutes: 540))
        #expect(created.placement == .project("P1"))
        let tasks = await w.things.tasks.values.filter { $0.kind == .todo }
        #expect(tasks.count == 1 && tasks[0].isTemplate && tasks[0].templateId == nil, "no occurrence is created")
        let link = try #require(w.links.links.first)
        #expect(link.copySide == .things && link.repeatMode == .template)
        // Stable afterwards: nothing is written either way.
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func firstLinkPairsRepeatingReminderWithTemplateOnly() async throws {
        var w = await world()
        await w.things.add(template(created: 1))
        await w.things.add(occurrence("OCC1", day: "2026-11-16"))
        await w.things.add(todo("t9", "Water plants", project: "P1"))   // a plain to-do with the same title
        await w.reminders.add(repeatingReminder("r1"))
        let r = try await w.sync()
        let template = try #require(w.links.links.first { $0.repeatMode == .template })
        #expect(template.thingsId == "TPL" && template.reminderId == "r1")
        #expect(r.linked == 1)
        #expect(await w.things.created.isEmpty, "no duplicate template")
        #expect(await w.reminders.all(in: "L1").count == 2, "the plain to-do got its own reminder")
    }

    // MARK: Completion

    @Test func completingTheOccurrenceInThingsAdvancesTheReminderWithoutADate() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.things.edit("OCC1") { $0.status = .completed; $0.stopDate = Date() }
        let r = try await w.sync()
        let completions = await w.reminders.completions
        #expect(completions.count == 1 && completions[0].id == rid && completions[0].date == nil)
        let reminder = try #require(await w.reminders.item(rid))
        #expect(!reminder.completed && reminder.due?.day == "2026-11-23")
        #expect(w.links.links[0].fingerprint.due?.day == "2026-11-23")
        #expect(r.updatedInReminders == 1)
        // No echo, and the next occurrence Things generates is just the current one.
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
        await w.things.add(occurrence("OCC2", day: "2026-11-23"))
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.reminders.completions.count == 1)
    }

    @Test func completingInRemindersCompletesTheOpenOccurrenceForTheOldDay() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.due = DueDate(day: "2026-11-23") }   // Reminders advanced the same reminder
        let r = try await w.sync()
        let writes = await w.things.updates
        #expect(writes.count == 1 && writes[0].0 == "OCC1" && writes[0].1.completed == true)
        #expect(writes[0].1.when == nil, "an advance is a completion, not a reschedule")
        #expect(await w.things.task("TPL")?.nextDay == "2026-11-16", "the template is left alone")
        #expect(w.links.links[0].fingerprint.due?.day == "2026-11-23")
        #expect(r.updatedInThings == 1)
        await w.things.edit("OCC1") { $0.status = .completed }
        await w.things.add(occurrence("OCC2", day: "2026-11-23"))
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aDueChangeThatIsNotTheNextOccurrenceMovesTheOpenOccurrence() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.due = DueDate(day: "2026-11-18") }
        try await w.sync()
        let writes = await w.things.updates
        #expect(writes.count == 1 && writes[0].0 == "OCC1" && writes[0].1.completed == nil)
        #expect(writes[0].1.when == .some(DueDate(day: "2026-11-18")))
        #expect(await w.things.task("OCC1")?.startDate == "2026-11-18")
    }

    @Test func rescheduleWithNoOpenOccurrenceMovesTheTemplatesNextDay() async throws {
        var w = await world()
        await w.things.add(template(seconds: 32400))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.due = DueDate(day: "2026-11-18", minutes: 600) }
        try await w.sync()
        let tpl = try #require(await w.things.task("TPL"))
        #expect(tpl.nextDay == "2026-11-18" && tpl.reminderSeconds == 36000)
        let writes = await w.things.updates
        #expect(writes.count == 1 && writes[0].1.templateNext == DueDate(day: "2026-11-18", minutes: 600))
    }

    @Test func reschedulingTheOccurrenceInThingsMovesTheReminder() async throws {
        var w = try await pairedWorld()
        await w.things.edit("OCC1") { $0.startDate = "2026-11-18"; $0.modificationDate = Date() }
        try await w.sync()
        let rid = w.links.links[0].reminderId
        #expect(await w.reminders.item(rid)?.due?.day == "2026-11-18")
        #expect(await w.reminders.completions.isEmpty)
    }

    @Test func aFinishedReminderFinishesItsOpenOccurrence() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.completed = true; $0.completionDate = Date() }
        try await w.sync()
        #expect(await w.things.updates.map(\.0) == ["OCC1"])
        await w.things.edit("OCC1") { $0.status = .completed }
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    // MARK: Rule edits

    @Test func ruleEditInRemindersRewritesTheTemplate() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        let edited = RepeatRule(frequency: .weekly, weekdays: [1, 4])
        await w.reminders.edit(rid) { $0.recurrence = edited }
        try await w.sync()
        let writes = await w.things.updates
        #expect(writes.count == 1 && writes[0].0 == "TPL" && writes[0].1.recurrence == edited)
        #expect(writes[0].1.templateNext == nil && writes[0].1.when == nil)
        #expect(w.links.links[0].fingerprint.rule == edited)
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func ruleEditInThingsRewritesTheReminder() async throws {
        var w = try await pairedWorld()
        let edited = RepeatRule(frequency: .weekly, interval: 2, weekdays: [1])
        await w.things.edit("TPL") { $0.recurrence = edited; $0.modificationDate = Date() }
        try await w.sync()
        let rid = w.links.links[0].reminderId
        let writes = await w.reminders.recurrenceWrites
        #expect(writes.count == 1 && writes[0].id == rid && writes[0].rule == edited)
        #expect(await w.reminders.item(rid)?.recurrence == edited)
        #expect(await w.reminders.completions.isEmpty)
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aCountingDownEndIsNotARuleEdit() async throws {
        var w = try await pairedWorld(rule: RepeatRule(frequency: .weekly, weekdays: [1], end: .afterCount(5)))
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.recurrence = RepeatRule(frequency: .weekly, weekdays: [1], end: .afterCount(4)) }
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.things.updates.isEmpty)
    }

    @Test func titleAndNotesSyncTemplateToReminderAndBack() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.things.edit("TPL") { $0.title = "Water the plants"; $0.notes = "weekly"; $0.modificationDate = Date() }
        try await w.sync()
        let synced = await w.reminders.item(rid)
        #expect(synced?.title == "Water the plants" && synced?.notes == "weekly")
        await w.reminders.edit(rid) { $0.title = "Water everything"; $0.lastModified = Date().addingTimeInterval(5) }
        await w.things.clearRecords()
        try await w.sync()
        #expect(await w.things.task("TPL")?.title == "Water everything")
        #expect(await w.things.task("OCC1")?.title == "Water plants", "occurrences are not rewritten")
    }

    // MARK: Fallbacks

    @Test func afterCompletionTemplateSyncsItsOccurrenceAsAPlainReminder() async throws {
        var w = await world()
        let rule = RepeatRule(frequency: .daily, interval: 4, afterCompletion: true)
        await w.things.add(template(rule: rule, created: 1))
        await w.things.add(occurrence("OCC1", day: "2026-11-16"))
        let r = try await w.sync()
        let all = await w.reminders.all(in: "L1")
        #expect(all.count == 1 && !all[0].isRepeating && all[0].due?.day == "2026-11-16")
        #expect(await w.reminders.created.isEmpty)
        #expect(w.links.links.map(\.repeatMode) == [nil] && w.links.links[0].thingsId == "OCC1")
        #expect(r.log.filter { $0.level == .info && $0.message.contains("no repeat-after-completion") }.count == 1)
        // Completing the occurrence completes the plain reminder; the next occurrence gets a fresh reminder.
        await w.things.edit("OCC1") { $0.status = .completed; $0.stopDate = Date() }
        try await w.sync()
        #expect(await w.reminders.item(all[0].id)?.completed == true)
        await w.things.add(occurrence("OCC2", day: "2026-11-20"))
        try await w.sync()
        #expect(await w.reminders.all(in: "L1").filter { !$0.completed }.map { $0.due?.day } == ["2026-11-20"])
    }

    @Test func unrecognisedTemplateRuleFallsBackTheSameWay() async throws {
        var w = await world()
        await w.things.add(template(rule: nil, created: 1))
        await w.things.add(occurrence("OCC1", day: "2026-11-16"))
        let r = try await w.sync()
        #expect(await w.reminders.all(in: "L1").map(\.isRepeating) == [false])
        #expect(r.log.contains { $0.message.contains("not one this app recognises") })
    }

    @Test func lastDayOfMonthTemplateSyncsThroughTheObjectForm() async throws {
        // RemCTL's grammar cannot say "last day", but its recurrence object can (verified live), so this is a template pair.
        var w = await world()
        let last = RepeatRule(frequency: .monthly, monthDays: [-1])
        await w.things.add(template(rule: last, next: "2026-11-30"))
        try await w.sync()
        #expect(await w.reminders.all(in: "L1").first?.recurrence == last)
        #expect(w.links.links.first?.repeatMode == .template)
    }

    @Test func reminderRuleThingsCannotHoldGetsAPlainToDoThatIsReplacedOnCompletion() async throws {
        var w = await world()
        await w.reminders.add(repeatingReminder("r1", rule: nil, due: DueDate(day: "2026-11-16")))
        let r = try await w.sync()
        #expect(r.log.filter { $0.level == .info && $0.message.contains("Things cannot hold") }.count == 1)
        let first = try #require(w.links.links.first)
        #expect(first.repeatMode == .reminderRepeats)
        let plainId = first.thingsId
        let plain = await w.things.task(plainId)
        #expect(plain?.recurrence == nil && plain?.isRepeating == false)
        // Completing the plain to-do advances the reminder (no date) and a fresh to-do replaces it.
        await w.things.edit(plainId) { $0.status = .completed; $0.stopDate = Date() }
        try await w.sync()
        let completions = await w.reminders.completions
        #expect(completions.count == 1 && completions[0].id == "r1" && completions[0].date == nil)
        let link = try #require(w.links.links.first)
        #expect(link.thingsId != plainId && link.repeatMode == .reminderRepeats)
        let fresh = try #require(await w.things.task(link.thingsId))
        let advanced = await w.reminders.item("r1")
        #expect(fresh.status == .open && fresh.startDate == advanced?.due?.day && fresh.startDate != "2026-11-16")
        #expect(await w.things.task(plainId)?.status == .completed)
        await w.things.clearRecords()
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func advancingTheReminderCompletesAndReplacesThePlainToDo() async throws {
        var w = await world()
        let rule = RepeatRule(frequency: .weekly, weekdays: [1])
        await w.reminders.add(repeatingReminder("r1", rule: rule, due: DueDate(day: "2026-11-16")))
        // Make Things unable to hold it by forcing the fallback path: use an unrecognised-rule reminder first, then give it a rule.
        var link = LinkRecord(reminderId: "r1", thingsId: "PLAIN", mappingId: "L1",
                              fingerprint: Fingerprint(title: "Water plants", notes: "", due: DueDate(day: "2026-11-09"), completed: false, completionDay: nil),
                              repeatMode: .reminderRepeats)
        link.copySide = .things
        await w.things.add(todo("PLAIN", "Water plants", project: "P1", startDate: "2026-11-09"))
        w.links.links = [link]
        try await w.sync()
        #expect(await w.things.task("PLAIN")?.status == .completed)
        let current = try #require(w.links.links.first)
        #expect(current.thingsId != "PLAIN")
        #expect(await w.things.task(current.thingsId)?.startDate == "2026-11-16")
    }

    // MARK: Lifecycle

    @Test func deletingTheRepeatingReminderTrashesTheTemplateAndItsOpenOccurrence() async throws {
        var w = try await pairedWorld()
        await w.reminders.remove(w.links.links[0].reminderId)
        let r = try await w.sync()
        #expect(r.deletedInThings == 1)
        #expect(await w.things.trashedIds() == ["TPL", "OCC1"])
        #expect(await w.things.tasks["TPL"] != nil, "trashed, never permanently deleted")
        #expect(w.links.links.isEmpty)
    }

    @Test func trashingTheTemplateDeletesTheReminder() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.things.edit("TPL") { $0.trashed = true }
        let r = try await w.sync()
        let gone = await w.reminders.item(rid)
        #expect(r.deletedInReminders == 1 && gone == nil)
    }

    @Test func aTemplateThatStopsRepeatingClearsTheReminderRepeat() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.things.edit("TPL") { $0.isRepeating = false; $0.recurrence = nil }
        try await w.sync()
        let writes = await w.reminders.recurrenceWrites
        #expect(writes.count == 1 && writes[0].rule == nil)
        #expect(await w.reminders.item(rid)?.isRepeating == false)
        #expect(w.links.links.first?.repeatMode == nil)
    }

    @Test func aReminderThatStopsRepeatingIsUnlinkedAndLeftAlone() async throws {
        var w = try await pairedWorld()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.isRepeating = false; $0.recurrence = nil }
        let r = try await w.sync()
        #expect(r.unlinked == 1 && w.links.links.isEmpty)
        let trashed = await w.things.trashedIds(), writes = await w.things.updates
        #expect(trashed.isEmpty && writes.isEmpty)
        #expect(await w.reminders.item(rid) != nil)
    }

    @Test func movingTheTemplateToAnotherSyncedListMovesTheReminder() async throws {
        var w = World(lists: ["L1", "L2"], mappings: [
            ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "A"),
            ListMapping(id: "L2", listTitle: "L2", mode: .project, targetId: "P2", targetTitle: "B")])
        await w.things.add(projectTask("P1", "A")); await w.things.add(projectTask("P2", "B"))
        await w.things.add(template(created: 1)); await w.things.add(occurrence("OCC1", day: "2026-11-16"))
        try await w.sync()
        await w.things.edit("TPL") { $0.projectId = "P2"; $0.modificationDate = Date() }
        try await w.sync()
        let rid = w.links.links[0].reminderId
        #expect(await w.reminders.item(rid)?.listId == "L2" && w.links.links[0].mappingId == "L2")
    }

    @Test func templateCopiesCountInTheLedgerAndComeBackOutOnTeardown() async throws {
        var w = await world()
        await w.reminders.add(repeatingReminder("r1"))
        try await w.sync()
        #expect(w.links.links[0].copySide == .things)
        let tid = w.links.links[0].thingsId
        await w.things.add(occurrence("OCCX", of: tid, day: "2026-11-16"))   // Things generated it from our template
        let engine = SyncEngine(things: w.things, reminders: w.reminders)
        let report = try await engine.teardown(config: w.config, links: w.links, listId: "L1", removeCopies: true, removeMapping: false)
        #expect(report.failures == 0)
        #expect(await w.things.trashedIds() == [tid, "OCCX"])
    }

    // MARK: Old state

    @Test func oldStateFilesDecode() throws {
        let link = """
        {"links":[{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","reminderId":"1","thingsId":"T","mappingId":"L1",
        "fingerprint":{"title":"a","notes":"","completed":false},"lastSynced":0}],"linkedMappings":{},
        "detachedThingsIds":[],"detachedReminderIds":[]}
        """
        let store = try JSONDecoder().decode(LinkStore.self, from: Data(link.utf8))
        #expect(store.links[0].repeatMode == nil && store.links[0].fingerprint.rule == nil)
        let task = try JSONDecoder().decode(ThingsTask.self, from: Data(#"{"id":"T","kind":0,"title":"t","notes":"","status":0,"trashed":false,"start":1,"evening":false,"tagIds":[],"isRepeating":true}"#.utf8))
        #expect(task.recurrence == nil && task.templateId == nil && task.isTemplate)
        let item = try JSONDecoder().decode(ReminderItem.self, from: Data(#"{"id":"1","listId":"L","title":"t","notes":"","completed":false,"isRepeating":true}"#.utf8))
        #expect(item.recurrence == nil && item.isRepeating)
        // New state round-trips.
        var l = LinkRecord(reminderId: "1", thingsId: "T", mappingId: "L1",
                           fingerprint: Fingerprint(title: "a", notes: "", due: nil, completed: false, completionDay: nil, rule: monday), repeatMode: .template)
        l.copySide = .things
        let back = try JSONDecoder().decode(LinkRecord.self, from: try JSONEncoder().encode(l))
        #expect(back == l)
    }
}
