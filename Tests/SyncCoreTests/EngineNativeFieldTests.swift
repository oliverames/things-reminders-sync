import Foundation
import Testing
@testable import SyncCore

// Native field mappings (docs/SPEC.md "Native field mappings"): dueMapsTo, priorityTag, eveningFromHour,
// canceledBecomes, syncSomeday, createMissingTags.

private func world(_ change: (inout ListMapping) -> Void = { _ in }) async -> World {
    var m = ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj")
    change(&m)
    let w = World(lists: ["L1"], mappings: [m])
    await w.things.add(projectTask("P1"))
    for (id, title) in [("TG1", "Important"), ("TG2", "Home"), ("TG5", "Urgent")] { await w.things.addTag(id, title) }
    return w
}

private func writes(_ w: World) async -> Int {
    let a = await w.things.updates.count, b = await w.things.created.count
    let c = await w.reminders.patches.count, d = await w.reminders.deletes.count
    return a + b + c + d
}

private func clear(_ w: World) async { await w.reminders.clearPatches(); await w.things.clearRecords() }

/// A second and third pass write nothing.
private func expectQuiet(_ w: inout World, _ comment: Comment? = nil) async throws {
    await clear(w)
    let before = await writes(w)   // deletions made earlier stay recorded in the fake
    for _ in 0..<2 {
        #expect(try await w.sync().changeCount == 0, comment)
        #expect(await writes(w) == before, comment)
    }
}

@Suite("Native fields: config")
struct NativeFieldConfigTests {
    @Test func theNewKeysRoundTripUnderTheirJSONNames() throws {
        let json = #"{"id":"7","listTitle":"Home","targetTitle":"Home","dueMapsTo":"deadline","eveningFromHour":18,"canceledBecomes":"deleted","syncSomeday":false}"#
        let m = try JSONDecoder().decode(ListMapping.self, from: Data(json.utf8))
        #expect(m.dueMapsTo == .deadline && m.eveningFromHour == 18 && m.canceledBecomes == .deleted && !m.syncSomeday)
        #expect(try JSONDecoder().decode(ListMapping.self, from: JSONEncoder().encode(m)) == m)
        #expect(DueTarget.allCases.map(\.rawValue) == ["when", "deadline"])
        #expect(CanceledOutcome.allCases.map(\.rawValue) == ["completed", "deleted"])
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(#"{"priorityTag":"Urgent","createMissingTags":true}"#.utf8))
        #expect(config.priorityTag == "Urgent" && config.createMissingTags)
        #expect(try JSONDecoder().decode(SyncConfig.self, from: JSONEncoder().encode(config)) == config)
        var odd = m
        odd.eveningFromHour = 24
        #expect(odd.eveningFromMinutes == nil && m.eveningFromMinutes == 18 * 60, "an hour outside 0 to 23 is ignored")
    }
}

@Suite("Native fields: dueMapsTo")
struct DueMapsToTests {
    @Test func aDueDateBecomesTheDeadlineAndTheWhenIsLeftAlone() async throws {
        var w = await world { $0.dueMapsTo = .deadline }
        await w.reminders.add(reminder("r1", "L1", "Pay", due: DueDate(day: "2026-12-01", minutes: 14 * 60)))
        await w.reminders.add(reminder("r2", "L1", "Undated"))
        try await w.sync()
        let created = await w.things.created
        let pay = try #require(created.first { $0.title == "Pay" })
        #expect(pay.deadline == "2026-12-01" && pay.when == nil && !pay.someday && !pay.evening)
        #expect(created.first { $0.title == "Undated" }?.deadline == nil)
        let link = try #require(w.links.links.first { $0.reminderId == "r1" })
        #expect(link.fingerprint.due == DueDate(day: "2026-12-01") && link.fingerprint.dueIsDeadline == true)
        try await expectQuiet(&w)
        // The due time stays in Reminders only.
        #expect(await w.reminders.item("r1")?.due == DueDate(day: "2026-12-01", minutes: 14 * 60))
        #expect(await w.things.task(link.thingsId)?.startDate == nil)
    }

    @Test func aNewToDoStartsWhereAnUndatedReminderWould() async throws {
        var w = await world { $0.dueMapsTo = .deadline; $0.undatedArriveAs = .someday }
        await w.reminders.add(reminder("r1", "L1", "Pay", due: DueDate(day: "2026-12-01")))
        try await w.sync()
        let draft = try #require(await w.things.created.first)
        #expect(draft.deadline == "2026-12-01" && draft.when == nil && draft.someday)
        try await expectQuiet(&w)
    }

    @Test func aThingsDeadlineBecomesTheDueDate() async throws {
        var w = await world { $0.dueMapsTo = .deadline }
        var t = todo("X1", "File", project: "P1", startDate: "2026-11-20")
        t.deadline = "2026-12-05"
        await w.things.add(t)
        await w.things.add(todo("X2", "Scheduled only", project: "P1", startDate: "2026-11-21"))
        try await w.sync()
        let r = try #require(await w.reminders.all(in: "L1").first { $0.title == "File" })
        #expect(r.due == DueDate(day: "2026-12-05"), "the deadline, not the start day")
        #expect(await w.reminders.all(in: "L1").first { $0.title == "Scheduled only" }?.due == nil)
        try await expectQuiet(&w)
        #expect(await w.things.task("X1")?.startDate == "2026-11-20")
    }

    @Test func changesAndClearsGoBothWays() async throws {
        var w = await world { $0.dueMapsTo = .deadline }
        await w.reminders.add(reminder("r1", "L1", "Pay", due: DueDate(day: "2026-12-01", minutes: 9 * 60)))
        try await w.sync()
        let tid = w.links.links[0].thingsId

        // Things moves the deadline: the reminder moves to that day and keeps its time.
        await w.things.edit(tid) { $0.deadline = "2026-12-03" }
        await clear(w)
        try await w.sync()
        #expect(await w.reminders.item("r1")?.due == DueDate(day: "2026-12-03", minutes: 9 * 60))
        #expect(await w.things.updates.isEmpty)
        try await expectQuiet(&w)

        // Reminders moves the due date: only the deadline is written.
        await w.reminders.edit("r1") { $0.due = DueDate(day: "2026-12-10", minutes: 9 * 60) }
        try await w.sync()
        let patch = try #require(await w.things.updates.first?.1)
        #expect(patch.deadline == .some("2026-12-10") && patch.when == nil && patch.evening == nil)
        #expect(await w.things.task(tid)?.deadline == "2026-12-10")
        try await expectQuiet(&w)

        // A change of the When in Things, or of the time in Reminders, is not a due date change.
        await w.things.edit(tid) { $0.startDate = "2026-12-08" }
        await w.reminders.edit("r1") { $0.due = DueDate(day: "2026-12-10", minutes: 17 * 60) }
        try await expectQuiet(&w)

        // Clearing one clears the other.
        await w.things.edit(tid) { $0.deadline = nil }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.due == nil)
        try await expectQuiet(&w)
        await w.reminders.edit("r1") { $0.due = DueDate(day: "2026-12-20") }
        try await w.sync()
        #expect(await w.things.task(tid)?.deadline == "2026-12-20")
        await w.reminders.edit("r1") { $0.due = nil }
        await clear(w)
        try await w.sync()
        #expect(await w.things.updates.first?.1.deadline == .some(nil))
        #expect(await w.things.task(tid)?.deadline == nil && w.links.links[0].fingerprint.due == nil)
        #expect(await w.things.task(tid)?.startDate == "2026-12-08", "the When was never touched")
        try await expectQuiet(&w)
    }

    @Test func theDefaultStillMapsTheDueDateToTheWhen() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "Pay", due: DueDate(day: "2026-12-01")))
        var t = todo("X1", "File", project: "P1", startDate: "2026-11-20")
        t.deadline = "2026-12-05"
        await w.things.add(t)
        try await w.sync()
        let draft = try #require(await w.things.created.first)
        #expect(draft.when == DueDate(day: "2026-12-01") && draft.deadline == nil)
        #expect(await w.reminders.all(in: "L1").first { $0.title == "File" }?.due == DueDate(day: "2026-11-20"))
        #expect(w.links.links.allSatisfy { $0.fingerprint.dueIsDeadline == nil })
        await w.things.edit("X1") { $0.deadline = "2026-12-06" }
        try await expectQuiet(&w, "a deadline is preserved and not synced")
        #expect(await w.things.updates.allSatisfy { $0.1.deadline == nil })
    }

    @Test func aRepeatingPairKeepsTheWhen() async throws {
        var w = await world { $0.dueMapsTo = .deadline }
        var r = reminder("r1", "L1", "Water", due: DueDate(day: "2026-11-30"))   // a Monday
        r.isRepeating = true; r.recurrence = RepeatRule(frequency: .weekly, weekdays: [1])
        await w.reminders.add(r)
        try await w.sync()
        let draft = try #require(await w.things.created.first)
        #expect(draft.recurrence != nil && draft.when == DueDate(day: "2026-11-30") && draft.deadline == nil)
        #expect(w.links.links[0].fingerprint.dueIsDeadline == nil)
        try await expectQuiet(&w)
    }

    @Test func switchingAListToDeadlineNeverLetsAMissingDateClearARealOne() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "Pay", due: DueDate(day: "2026-12-01")))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        w.config.mappings[0].dueMapsTo = .deadline
        await clear(w)
        let report = try await w.sync()
        #expect(await w.reminders.item("r1")?.due == DueDate(day: "2026-12-01"))
        #expect(await w.things.task(tid)?.deadline == "2026-12-01" && w.links.links[0].fingerprint.dueIsDeadline == true)
        #expect(await w.things.task(tid)?.startDate == "2026-12-01", "the When it already had stays")
        #expect(!report.log.contains { $0.level == .warning })
        try await expectQuiet(&w)
    }

    @Test func aOneWayListCopiesTheDeadlineOnlyFromItsSource() async throws {
        var w = await world { $0.dueMapsTo = .deadline; $0.direction = .thingsToReminders }
        var t = todo("X1", "File", project: "P1")
        t.deadline = "2026-12-05"
        await w.things.add(t)
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.due = DueDate(day: "2026-12-09") }
        try await expectQuiet(&w)
        #expect(await w.things.task("X1")?.deadline == "2026-12-05")
    }
}

@Suite("Native fields: eveningFromHour")
struct EveningFromHourTests {
    @Test func aReminderDueThisEveningArrivesInThisEvening() async throws {
        var w = await world { $0.eveningFromHour = 18 }
        let today = day(0)
        await w.reminders.add(reminder("r1", "L1", "Late", due: DueDate(day: today, minutes: 20 * 60)))
        await w.reminders.add(reminder("r2", "L1", "At six", due: DueDate(day: today, minutes: 18 * 60)))
        await w.reminders.add(reminder("r3", "L1", "Morning", due: DueDate(day: today, minutes: 10 * 60)))
        await w.reminders.add(reminder("r4", "L1", "Tomorrow night", due: DueDate(day: day(1), minutes: 20 * 60)))
        await w.reminders.add(reminder("r5", "L1", "All day", due: DueDate(day: today)))
        try await w.sync()
        let created = await w.things.created
        #expect(Set(created.filter(\.evening).map(\.title)) == ["Late", "At six"])
        #expect(created.first { $0.title == "Late" }?.when == DueDate(day: today, minutes: 20 * 60))
        try await expectQuiet(&w)
    }

    @Test func withoutTheOptionNothingGoesToThisEvening() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "Late", due: DueDate(day: day(0), minutes: 20 * 60)))
        try await w.sync()
        #expect(await w.things.created.allSatisfy { !$0.evening })
        await w.reminders.edit("r1") { $0.due = DueDate(day: day(0), minutes: 21 * 60) }
        try await w.sync()
        #expect(await w.things.updates.allSatisfy { $0.1.evening == nil })
    }

    @Test func aLinkedToDoMovesOncePerDueDateAndIsNotPutBack() async throws {
        var w = await world { $0.eveningFromHour = 18 }
        let today = day(0)
        await w.reminders.add(reminder("r1", "L1", "Call", due: DueDate(day: day(1), minutes: 9 * 60)))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        #expect(await w.things.task(tid)?.evening == false)

        await w.reminders.edit("r1") { $0.due = DueDate(day: today, minutes: 19 * 60) }
        await clear(w)
        try await w.sync()
        let patch = try #require(await w.things.updates.first?.1)
        #expect(patch.evening == true && patch.when == .some(DueDate(day: today, minutes: 19 * 60)))
        #expect(await w.things.task(tid)?.evening == true)
        try await expectQuiet(&w)

        // Moved back to Today by hand in Things: it stays there.
        await w.things.edit(tid) { $0.evening = false }
        try await expectQuiet(&w, "no echo")
        #expect(await w.things.task(tid)?.evening == false)

        // A due time before the hour, then one after it again: the rule runs for the new due date.
        await w.reminders.edit("r1") { $0.due = DueDate(day: today, minutes: 12 * 60) }
        try await w.sync()
        #expect(await w.things.updates.allSatisfy { $0.1.evening == nil })
        await w.reminders.edit("r1") { $0.due = DueDate(day: today, minutes: 21 * 60) }
        try await w.sync()
        #expect(await w.things.task(tid)?.evening == true)
        try await expectQuiet(&w)
    }

    @Test func anExistingPairDueThisEveningMovesWhenTheOptionIsTurnedOn() async throws {
        var w = await world()
        let today = day(0)
        await w.reminders.add(reminder("r1", "L1", "Call", due: DueDate(day: today, minutes: 19 * 60)))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        w.config.mappings[0].eveningFromHour = 18
        await clear(w)
        try await w.sync()
        let updates = await w.things.updates
        #expect(updates.count == 1 && updates[0].1 == ThingsTodoPatch(evening: true))
        #expect(await w.things.task(tid)?.evening == true)
        try await expectQuiet(&w)
    }

    @Test func aDateChosenInThingsIsLeftWhereItIs() async throws {
        var w = await world { $0.eveningFromHour = 18 }
        let today = day(0)
        // A to-do made in Things for tonight, in Today.
        await w.things.add(todo("X1", "Made in Things", project: "P1", startDate: today, seconds: 20 * 3600))
        // A linked pair whose date Things then moves to tonight.
        await w.reminders.add(reminder("r1", "L1", "Linked", due: DueDate(day: day(2))))
        try await w.sync()
        let tid = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        await w.things.edit(tid) { $0.startDate = today; $0.reminderSeconds = 21 * 3600 }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.due == DueDate(day: today, minutes: 21 * 60))
        try await expectQuiet(&w)
        #expect(await w.things.task("X1")?.evening == false)
        #expect(await w.things.task(tid)?.evening == false)
        #expect(await w.things.updates.allSatisfy { $0.1.evening == nil })
    }

    @Test func aListThatMapsTheDueDateToTheDeadlineNeverUsesThisEvening() async throws {
        var w = await world { $0.eveningFromHour = 18; $0.dueMapsTo = .deadline }
        await w.reminders.add(reminder("r1", "L1", "Late", due: DueDate(day: day(0), minutes: 20 * 60)))
        try await w.sync()
        #expect(await w.things.created.first?.evening == false)
        try await expectQuiet(&w)
    }
}

@Suite("Native fields: priorityTag")
struct PriorityTagTests {
    private func high(_ id: String, _ title: String, _ priority: ReminderPriority = .high) -> ReminderItem {
        var r = reminder(id, "L1", title)
        r.priority = priority
        return r
    }

    @Test func priorityIsNotSyncedByDefault() async throws {
        var w = await world()
        await w.reminders.add(high("r1", "Big"))
        await w.things.add(todo("X1", "Tagged", project: "P1", tags: ["TG5"]))
        try await w.sync()
        #expect(await w.things.created.first?.tagIds == [])
        #expect(await w.reminders.all(in: "L1").allSatisfy { $0.title == "Big" || $0.priority == .none })
        #expect(w.links.links.allSatisfy { $0.fingerprint.priorityHigh == nil })
        // Without the option "Urgent" is an ordinary tag.
        #expect(await w.reminders.all(in: "L1").first { $0.title == "Tagged" }?.tags == ["Urgent"])
        try await expectQuiet(&w)
    }

    @Test func highPriorityAndTheTagMapBothWaysOnCreate() async throws {
        var w = await world()
        w.config.priorityTag = "Urgent"
        await w.reminders.add(high("r1", "Big"))
        await w.reminders.add(high("r2", "Middling", .medium))
        await w.things.add(todo("X1", "Tagged", project: "P1", tags: ["TG5"]))
        try await w.sync()
        let created = await w.things.created
        #expect(created.first { $0.title == "Big" }?.tagIds == ["TG5"])
        #expect(created.first { $0.title == "Middling" }?.tagIds == [])
        let copy = try #require(await w.reminders.all(in: "L1").first { $0.title == "Tagged" })
        #expect(copy.priority == .high && copy.tags == [], "the priority tag is never synced as a tag")
        #expect(w.links.links.first { $0.reminderId == "r1" }?.fingerprint.priorityHigh == true)
        try await expectQuiet(&w)
        #expect(await w.reminders.item("r2")?.priority == .medium)
    }

    @Test func changesGoBothWaysAndOtherPrioritiesAreLeftAlone() async throws {
        var w = await world()
        w.config.priorityTag = "Urgent"
        await w.reminders.add(reminder("r1", "L1", "A"))
        await w.reminders.add(high("r2", "B", .low))
        try await w.sync()
        let a = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        let b = try #require(w.links.links.first { $0.reminderId == "r2" }).thingsId

        // Reminders: high adds the tag.
        await w.reminders.edit("r1") { $0.priority = .high }
        try await w.sync()
        #expect(await w.things.task(a)?.tagIds == ["TG5"])
        try await expectQuiet(&w)
        // Reminders: high to medium removes the tag and keeps medium.
        await w.reminders.edit("r1") { $0.priority = .medium }
        try await w.sync()
        #expect(await w.things.task(a)?.tagIds == [])
        #expect(await w.reminders.item("r1")?.priority == .medium)
        try await expectQuiet(&w)
        // A change among the other priorities writes nothing.
        await w.reminders.edit("r2") { $0.priority = .medium }
        try await expectQuiet(&w)

        // Things: the tag sets high; taking it off sets none.
        await w.things.edit(a) { $0.tagIds = ["TG5"] }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.priority == .high)
        try await expectQuiet(&w)
        await w.things.edit(a) { $0.tagIds = [] }
        await clear(w)
        try await w.sync()
        #expect(await w.reminders.patches.map(\.patch) == [ReminderPatch(priority: ReminderPriority.none)])
        #expect(await w.reminders.item("r1")?.priority == ReminderPriority.none)
        try await expectQuiet(&w)
        #expect(await w.things.task(b)?.tagIds == [] && w.links.links.first { $0.reminderId == "r2" }?.fingerprint.priorityHigh == false)
    }

    @Test func theOptionIsIgnoredWhenItNamesTheFlagTagOrAMissingTag() async throws {
        var w = await world()
        w.config.priorityTag = "Important"   // the default `flaggedTagTitle`
        await w.reminders.add(high("r1", "Big"))
        let report = try await w.sync()
        #expect(report.log.filter { $0.message.hasPrefix("Priority is not synced") }.count == 1)
        #expect(await w.things.created.first?.tagIds == [])
        #expect(w.links.links[0].fingerprint.priorityHigh == nil)
        try await expectQuiet(&w)

        w.config.priorityTag = "Nope"
        let second = try await w.sync()
        #expect(second.log.contains { $0.message.contains("no tag titled \"Nope\"") })
        #expect(await w.things.tags.count == 3, "the tag is never created")
        #expect(await w.things.updates.isEmpty)
    }

    @Test func aOneWayListCopiesPriorityOnlyFromItsSource() async throws {
        var w = await world { $0.direction = .remindersToThings }
        w.config.priorityTag = "Urgent"
        await w.reminders.add(high("r1", "Big"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        await w.things.edit(tid) { $0.tagIds = [] }
        try await expectQuiet(&w)
        #expect(await w.reminders.item("r1")?.priority == .high)
    }
}

@Suite("Native fields: canceledBecomes")
struct CanceledBecomesTests {
    private func cancel(_ w: World, _ id: String) async {
        await w.things.edit(id) { $0.status = .canceled; $0.stopDate = Date() }
    }

    @Test func aCanceledToDoCompletesItsReminderByDefault() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        await cancel(w, w.links.links[0].thingsId)
        try await w.sync()
        #expect(await w.reminders.item("r1")?.completed == true)
        #expect(await w.reminders.deletes.isEmpty && w.links.links.count == 1)
        try await expectQuiet(&w)
    }

    @Test func aCanceledToDoDeletesItsReminderWhenTheListSaysSo() async throws {
        var w = await world { $0.canceledBecomes = .deleted }
        await w.reminders.add(reminder("r1", "L1", "A"))
        await w.reminders.add(reminder("r2", "L1", "B"))
        try await w.sync()
        let a = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        let b = try #require(w.links.links.first { $0.reminderId == "r2" }).thingsId
        await cancel(w, a)
        let report = try await w.sync()
        #expect(await w.reminders.deletes == ["r1"] && report.deletedInReminders == 1)
        #expect(report.log.contains { $0.message.contains("its Things to-do was canceled") })
        #expect(w.links.links.map(\.reminderId) == ["r2"])
        #expect(await w.things.task(a)?.trashed == false, "the canceled to-do is kept")
        try await expectQuiet(&w, "the canceled to-do gets no new reminder")
        // Completing in Things is not canceling.
        await w.things.edit(b) { $0.status = .completed; $0.stopDate = Date() }
        try await w.sync()
        #expect(await w.reminders.item("r2")?.completed == true && w.links.links.count == 1)
    }

    @Test func theDeletionsGoThroughTheSafetyLimit() async throws {
        var w = await world { $0.canceledBecomes = .deleted }
        for i in 1...5 { await w.reminders.add(reminder("r\(i)", "L1", "Item \(i)")) }
        try await w.sync()
        for link in w.links.links.prefix(4) { await cancel(w, link.thingsId) }   // 4 of 5: over 3 and over a quarter
        let held = try await w.sync()
        #expect(held.deletionsHeld && held.deletedInReminders == 0)
        #expect(await w.reminders.deletes.isEmpty && w.links.links.count == 5)
        #expect(await w.reminders.all(in: "L1").allSatisfy { !$0.completed }, "held, not completed instead")
        let forced = try await w.sync(.full, force: true)
        #expect(forced.deletedInReminders == 4 && w.links.links.count == 1)
    }

    @Test func withoutPropagatedDeletesOrOneWayFromRemindersTheReminderIsNotDeleted() async throws {
        var w = await world { $0.canceledBecomes = .deleted; $0.propagateDeletes = false }
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        await cancel(w, w.links.links[0].thingsId)
        try await w.sync()
        #expect(await w.reminders.deletes.isEmpty)
        #expect(await w.reminders.item("r1")?.completed == true, "completed, as a list that deletes nothing does")

        var one = await world { $0.canceledBecomes = .deleted; $0.direction = .remindersToThings }
        await one.reminders.add(reminder("r1", "L1", "A"))
        try await one.sync()
        await cancel(one, one.links.links[0].thingsId)
        try await expectQuiet(&one)
        #expect(await one.reminders.item("r1")?.completed == false)
    }

    @Test func aToDoCanceledBeforeTheOptionWasSetKeepsItsCompletedReminder() async throws {
        var w = await world()
        await w.reminders.add(reminder("r1", "L1", "A"))
        try await w.sync()
        await cancel(w, w.links.links[0].thingsId)
        try await w.sync()
        w.config.mappings[0].canceledBecomes = .deleted
        try await expectQuiet(&w)
        #expect(await w.reminders.item("r1")?.completed == true)
    }
}

@Suite("Native fields: syncSomeday")
struct SyncSomedayTests {
    @Test func somedayToDosSyncByDefault() async throws {
        var w = await world()
        var t = todo("X1", "Maybe", project: "P1")
        t.start = .someday
        await w.things.add(t)
        await w.reminders.add(reminder("r1", "L1", "Linked"))
        try await w.sync()
        #expect(await w.reminders.all(in: "L1").map(\.title).sorted() == ["Linked", "Maybe"])
        let tid = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        await w.things.edit(tid) { $0.start = .someday }
        try await expectQuiet(&w)
        #expect(await w.reminders.item("r1") != nil)
    }

    @Test func aSomedayToDoIsNotCopiedAndIsCopiedOnceItLeavesSomeday() async throws {
        var w = await world { $0.syncSomeday = false }
        var t = todo("X1", "Maybe", project: "P1")
        t.start = .someday
        await w.things.add(t)
        await w.things.add(todo("X2", "Now", project: "P1"))
        try await w.sync()
        #expect(await w.reminders.all(in: "L1").map(\.title) == ["Now"])
        try await expectQuiet(&w)
        await w.things.edit("X1") { $0.start = .anytime }
        try await w.sync()
        #expect(await w.reminders.all(in: "L1").map(\.title).sorted() == ["Maybe", "Now"])
        try await expectQuiet(&w)
    }

    @Test func aLinkedToDoMovedToSomedayLosesItsReminderAndGetsItBack() async throws {
        var w = await world { $0.syncSomeday = false }
        await w.reminders.add(reminder("r1", "L1", "Trip", notes: "pack"))
        await w.reminders.add(reminder("r2", "L1", "Other"))
        try await w.sync()
        let tid = try #require(w.links.links.first { $0.reminderId == "r1" }).thingsId
        #expect(w.links.links.first { $0.thingsId == tid }?.fingerprint.thingsSomeday == false)

        await w.things.edit(tid) { $0.start = .someday }
        let report = try await w.sync()
        #expect(await w.reminders.deletes == ["r1"] && report.deletedInReminders == 1)
        #expect(report.log.contains { $0.message.contains("moved to Someday") })
        #expect(w.links.links.map(\.reminderId) == ["r2"])
        #expect(w.links.parkedLinks.map(\.thingsId) == [tid], "the pair is parked")
        #expect(await w.things.task(tid)?.trashed == false)
        try await expectQuiet(&w, "parked while the to-do is in Someday")
        #expect(w.links.parkedLinks.count == 1)

        // Out of Someday again: the reminder is made again and linked.
        await w.things.edit(tid) { $0.start = .anytime }
        try await w.sync()
        let back = try #require(await w.reminders.all(in: "L1").first { $0.title == "Trip" })
        #expect(back.notes == "pack")
        #expect(w.links.links.contains { $0.thingsId == tid && $0.reminderId == back.id } && w.links.parkedLinks.isEmpty)
        try await expectQuiet(&w)
    }

    @Test func remindersToThingsIsUnchanged() async throws {
        // An undated reminder that arrives in Someday keeps its reminder: nothing moved there after it was linked.
        var w = await world { $0.syncSomeday = false; $0.undatedArriveAs = .someday }
        await w.reminders.add(reminder("r1", "L1", "Idea"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        #expect(await w.things.task(tid)?.start == .someday && w.links.links[0].fingerprint.thingsSomeday == true)
        try await expectQuiet(&w)
        // Edits still sync both ways for a pair that stays linked.
        await w.reminders.edit("r1") { $0.title = "Better idea" }
        try await w.sync()
        #expect(await w.things.task(tid)?.title == "Better idea")
        #expect(await w.reminders.deletes.isEmpty && w.links.links.count == 1)
    }

    @Test func withoutPropagatedDeletesTheReminderStays() async throws {
        var w = await world { $0.syncSomeday = false; $0.propagateDeletes = false }
        await w.reminders.add(reminder("r1", "L1", "Trip"))
        try await w.sync()
        await w.things.edit(w.links.links[0].thingsId) { $0.start = .someday }
        try await expectQuiet(&w)
        #expect(await w.reminders.item("r1") != nil && w.links.links.count == 1)
    }
}

@Suite("Native fields: createMissingTags")
struct CreateMissingTagsTests {
    private func tagged(_ id: String, _ title: String, _ tags: [String]) -> ReminderItem {
        var r = reminder(id, "L1", title)
        r.tags = tags
        return r
    }

    @Test func aMissingTagIsNotCreatedByDefault() async throws {
        var w = await world()
        await w.reminders.add(tagged("r1", "Shop", ["Errands", "home"]))
        try await w.sync()
        #expect(await w.things.tags.count == 3)
        #expect(await w.things.created.first?.tagIds == ["TG2"])
        #expect(w.links.ownedThings.isEmpty)
        try await expectQuiet(&w)
    }

    @Test func aMissingTagIsCreatedRecordedAndApplied() async throws {
        var w = await world()
        w.config.createMissingTags = true
        await w.reminders.add(tagged("r1", "Shop", ["Errands", "home"]))
        let report = try await w.sync()
        let tags = await w.things.tags
        let made = try #require(tags.values.first { $0.title == "Errands" })
        #expect(tags.count == 4, "\"home\" is the existing tag \"Home\" in another case")
        #expect(Set(await w.things.created.first?.tagIds ?? []) == [made.id, "TG2"])
        #expect(w.links.ownedThings.map(\.id) == [made.id] && w.links.ownedThings[0].kind == .tag && w.links.ownedThings[0].title == "Errands")
        #expect(report.log.contains { $0.message.contains("Created the Things tag \"Errands\"") })
        #expect(w.links.links[0].fingerprint.tags == ["Errands", "Home"])
        try await expectQuiet(&w)
        #expect(await w.things.tags.count == 4)
        #expect(await w.things.deletedTags.isEmpty, "the cleanup keeps a tag that is in use")
        #expect(await w.reminders.item("r1")?.tags == ["Errands", "home"])
    }

    @Test func aLinkedReminderThatGainsANewTagGetsItInThings() async throws {
        var w = await world()
        w.config.createMissingTags = true
        await w.reminders.add(reminder("r1", "L1", "Shop"))
        try await w.sync()
        let tid = w.links.links[0].thingsId
        await w.reminders.edit("r1") { $0.tags = ["Later"] }
        try await w.sync()
        let made = try #require(await w.things.tags.values.first { $0.title == "Later" })
        #expect(await w.things.task(tid)?.tagIds == [made.id])
        try await expectQuiet(&w)
    }

    @Test func theTagsNamedBySettingsAreNeverCreated() async throws {
        let w0 = World(lists: ["L1"], mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj", alwaysTag: "Synced")])
        var w = w0
        await w.things.add(projectTask("P1"))
        w.config.createMissingTags = true
        w.config.flaggedTagTitle = "Flag"
        w.config.priorityTag = "Prio"
        var r = tagged("r1", "Shop", ["flag", "Prio", "synced", "a,b"])
        r.flagged = true; r.priority = .high
        await w.reminders.add(r)
        try await w.sync()
        #expect(await w.things.tags.isEmpty)
        #expect(await w.things.created.first?.tagIds == [] && w.links.ownedThings.isEmpty)
        try await expectQuiet(&w)
    }

    @Test func aListThatSyncsOneWayFromThingsCreatesNoTags() async throws {
        var w = await world { $0.direction = .thingsToReminders }
        w.config.createMissingTags = true
        await w.things.add(todo("X1", "Shop", project: "P1"))
        try await w.sync()
        let rid = w.links.links[0].reminderId
        await w.reminders.edit(rid) { $0.tags = ["Errands"] }
        try await expectQuiet(&w)
        #expect(await w.things.tags.count == 3)
    }
}
