import Foundation
import Testing
@testable import SyncCore

// Field fidelity, part 1: rich links and Markdown notes (docs/SPEC.md "Field fidelity").

private let early = Date(timeIntervalSince1970: 1_000)
private let late = Date(timeIntervalSince1970: 9_000_000_000)
private let link = "https://example.com/a"

private func world() async -> World {
    let w = World()
    await w.things.add(projectTask("P1"))
    return w
}

/// A linked pair made from a Things to-do, so the stored fingerprint is what the engine wrote and read back.
private func pairFromThings(_ w: inout World, notes: String) async throws -> (thingsId: String, reminderId: String) {
    await w.things.add(todo("t1", "Task", project: "P1", notes: notes))
    try await w.sync()
    return ("t1", w.links.links[0].reminderId)
}

@Suite struct LinkTests {
    @Test func reminderLinkIsAppendedToTheThingsNotes() async throws {
        var w = await world()
        var r = reminder("r1", "L1", "Read this", notes: "Worth a look")
        r.url = link
        await w.reminders.add(r)
        try await w.sync()
        let t = try #require(await w.things.all().first)
        #expect(t.notes == "Worth a look\n\n\(link)")
        let fp = try #require(w.links.links.first).fingerprint
        #expect(fp.url == link && fp.remindersNotes == "Worth a look" && fp.notes == "Worth a look\n\n\(link)")
        // The echo is a no-op in both directions.
        #expect(try await w.sync().changeCount == 0)
        #expect(try await w.sync(.targeted(thingsIds: ["T1"], remindersChanged: true)).changeCount == 0)
    }

    @Test func linkOnlyReminderBecomesTheLinkLine() async throws {
        var w = await world()
        var r = reminder("r1", "L1", "Bookmark")
        r.url = link
        await w.reminders.add(r)
        try await w.sync()
        #expect(await w.things.all().first?.notes == link)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func linkAddedLaterToALinkedReminderReachesThings() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body")
        await w.reminders.edit(rid) { $0.url = link; $0.lastModified = late }
        let r = try await w.sync()
        #expect(r.updatedInThings == 1 && r.updatedInReminders == 0)
        #expect(await w.things.task(tid)?.notes == "Body\n\n\(link)")
        #expect(await w.reminders.item(rid)?.notes == "Body")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func thingsLinkLineBecomesTheRichLinkOnANewReminder() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body\n\n\(link)")
        let item = try #require(await w.reminders.item(rid))
        #expect(item.url == link)
        #expect(item.notes == "Body")   // the link line is not left in the Reminders notes
        #expect(await w.things.task(tid)?.notes == "Body\n\n\(link)")   // Things keeps its notes
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func thingsLinkAddedLaterBecomesTheRichLink() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body")
        await w.things.edit(tid) { $0.notes = "Body\n\n\(link)"; $0.modificationDate = late }
        try await w.sync()
        let item = try #require(await w.reminders.item(rid))
        #expect(item.url == link && item.notes == "Body")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aDifferentExistingLinkIsNeverReplacedAndTheLineStaysAsText() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body")
        await w.reminders.edit(rid) { $0.url = "https://example.com/mine"; $0.lastModified = late }
        try await w.sync()
        await w.reminders.clearPatches()
        await w.things.edit(tid) { $0.notes = "Body\n\n\(link)"; $0.modificationDate = late }
        try await w.sync()
        let item = try #require(await w.reminders.item(rid))
        #expect(item.url == "https://example.com/mine")
        #expect(item.notes == "Body\n\n\(link)")
        let patches = await w.reminders.patches
        #expect(patches.allSatisfy { $0.patch.url == nil })
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aLinkChangedInRemindersSwapsTheLineInThings() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body\n\n\(link)")
        await w.reminders.edit(rid) { $0.url = "https://example.com/b"; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.notes == "Body\n\nhttps://example.com/b")
        #expect(try await w.sync().changeCount == 0)
    }

    // Links saved before field fidelity stored no link at all.
    private func legacyWorld(thingsNotes: String, reminderNotes: String, url: String?) async throws -> World {
        var w = await world()
        await w.things.add(todo("t1", "Task", project: "P1", notes: thingsNotes))
        var r = reminder("r1", "L1", "Task", notes: reminderNotes)
        r.url = url
        await w.reminders.add(r)
        let fp = Fingerprint(title: "Task", notes: Fingerprint.normalize(thingsNotes), due: nil, completed: false, completionDay: nil)
        w.links.links = [LinkRecord(reminderId: "r1", reminderExternalId: "xr1", thingsId: "t1", mappingId: "L1", fingerprint: fp)]
        w.links.linkedMappings["L1"] = "project:P1"
        return w
    }

    @Test func upgradeLeavesAReminderWhoseLinkIsAlreadyInThingsAlone() async throws {
        var w = try await legacyWorld(thingsNotes: "Body\n\n\(link)", reminderNotes: "Body", url: link)
        let r = try await w.sync()
        #expect(r.changeCount == 0)
        #expect(await w.things.updates.isEmpty)
        #expect(await w.reminders.patches.isEmpty)
        #expect(w.links.links[0].fingerprint.url == link)   // upgraded in place
    }

    @Test func upgradeAppendsAMissingLinkToThingsOnce() async throws {
        var w = try await legacyWorld(thingsNotes: "Body", reminderNotes: "Body", url: link)
        let first = try await w.sync()
        #expect(first.updatedInThings == 1)
        #expect(await w.things.task("t1")?.notes == "Body\n\n\(link)")
        #expect(await w.reminders.patches.isEmpty)
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.things.updates.count == 1)
    }

    @Test func upgradeDoesNotRewriteExistingMarkdownOrPlainNotes() async throws {
        // Legacy links copied Things Markdown verbatim into Reminders: nothing changed since, so nothing is rewritten.
        var w = try await legacyWorld(thingsNotes: "**Bring** the referral", reminderNotes: "**Bring** the referral", url: nil)
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.reminders.item("r1")?.notes == "**Bring** the referral")
        #expect(await w.things.updates.isEmpty)
    }

    @Test func aLinkWriteThatDidNotTakeKeepsTheOldFingerprintAndIsRetried() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Body")
        let before = w.links.links[0].fingerprint
        await w.reminders.setIgnores(url: true)
        await w.things.edit(tid) { $0.notes = "Body\n\n\(link)"; $0.modificationDate = late }
        await w.reminders.clearPatches()
        let r1 = try await w.sync()
        #expect(r1.log.contains { $0.level == .warning && $0.message.contains("did not take") })
        #expect(w.links.links[0].fingerprint.notes == before.notes && w.links.links[0].fingerprint.url == nil)
        // Retried on the next pass, and settled once RemCTL takes it.
        try await w.sync()
        let retried = await w.reminders.patches
        #expect(retried.count == 2 && retried.allSatisfy { $0.patch.url == link })
        await w.reminders.setIgnores()
        try await w.sync()
        #expect(await w.reminders.item(rid)?.url == link)
        #expect(try await w.sync().changeCount == 0)
        #expect(w.links.links[0].fingerprint.url == link)
    }

    @Test func firstLinkUnitesTheLinkAndKeepsThingsText() async throws {
        var w = await world()
        await w.things.add(todo("t1", "Task", project: "P1", notes: "Things **text**"))
        var r = reminder("r1", "L1", "Task", notes: "", modified: late)
        r.url = link
        await w.reminders.add(r)
        try await w.sync()
        #expect(await w.things.task("t1")?.notes == "Things **text**\n\n\(link)")
        let item = try #require(await w.reminders.item("r1"))
        #expect(item.notes == "Things text" && item.url == link)
        #expect(try await w.sync().changeCount == 0)
    }
}

@Suite struct NotesMarkdownTests {
    @Test func remindersGetsThePlainRenderingAndItIsStable() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "# Plan\n**Bring** the [form](https://example.com/f)")
        #expect(await w.reminders.item(rid)?.notes == "Plan\nBring the form (https://example.com/f)")
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.things.updates.isEmpty)
        #expect(await w.things.task(tid)?.notes == "# Plan\n**Bring** the [form](https://example.com/f)")
    }

    @Test func aThingsEditIsRenderedAndAMarkdownOnlyEditIsNotWrittenAtAll() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "Buy milk")
        await w.things.edit(tid) { $0.notes = "Buy *oat* milk"; $0.modificationDate = late }
        try await w.sync()
        #expect(await w.reminders.item(rid)?.notes == "Buy oat milk")
        await w.reminders.clearPatches()
        // Only the Markdown markers change: the plain text is the same, so Reminders is not touched.
        await w.things.edit(tid) { $0.notes = "Buy **oat** milk"; $0.modificationDate = late }
        let r = try await w.sync()
        #expect(r.updatedInReminders == 0)
        #expect(await w.reminders.patches.isEmpty)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aRemindersEditReplacesTheThingsMarkdownWithPlainText() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "**Bold** start")
        await w.reminders.edit(rid) { $0.notes = "Bold start, edited"; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.notes == "Bold start, edited")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func userTextIsNeverRewrittenWithASynthesizedRendering() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "plain")
        await w.reminders.clearPatches()
        // The user types Markdown-looking characters in Reminders: Things gets them verbatim, and Reminders is not
        // "corrected" to the rendering of what it just sent.
        await w.reminders.edit(rid) { $0.notes = "*literal* asterisks"; $0.lastModified = late }
        try await w.sync()
        #expect(await w.things.task(tid)?.notes == "*literal* asterisks")
        #expect(await w.reminders.item(rid)?.notes == "*literal* asterisks")
        #expect(await w.reminders.patches.isEmpty)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func bothEditedTheNewerEditWinsAndIsLogged() async throws {
        var w = await world()
        let (tid, rid) = try await pairFromThings(&w, notes: "start")
        await w.reminders.edit(rid) { $0.notes = "from reminders"; $0.lastModified = late }
        await w.things.edit(tid) { $0.notes = "from **things**"; $0.modificationDate = early }
        let r = try await w.sync()
        #expect(r.log.contains { $0.level == .warning && $0.message.contains("notes") })
        #expect(await w.things.task(tid)?.notes == "from reminders")
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aRemindersCopyOfThingsMarkdownIsStillRecognisedAfterARelink() async throws {
        // No stored fingerprint triple (first link by title) and the two notes are renderings of each other: nothing is written.
        var w = await world()
        await w.things.add(todo("t1", "Task", project: "P1", notes: "**Bold** text"))
        await w.reminders.add(reminder("r1", "L1", "Task", notes: "Bold text"))
        try await w.sync()
        #expect(await w.things.updates.isEmpty)
        #expect(await w.reminders.patches.isEmpty)
        #expect(try await w.sync().changeCount == 0)
    }
}

@Suite struct PatchMinimalityTests {
    @Test func anUpdateNeverSendsFieldsThatDidNotChange() async throws {
        var w = await world()
        var r = reminder("r1", "L1", "Title", notes: "Body", due: DueDate(day: day(3), minutes: 540))
        r.url = link; r.tags = ["Home"]; r.flagged = true
        await w.reminders.add(r)
        try await w.sync()
        let rid = w.links.links[0].reminderId, tid = w.links.links[0].thingsId
        await w.reminders.clearPatches(); await w.things.clearRecords()
        // Reminders retitles: only the title travels to Things, and nothing at all goes back to Reminders.
        await w.reminders.edit(rid) { $0.title = "New"; $0.lastModified = late }
        try await w.sync()
        let toThings = await w.things.updates
        #expect(toThings.count == 1 && toThings[0].0 == tid)
        #expect(toThings[0].1 == ThingsTodoPatch(title: "New"))
        #expect(await w.reminders.patches.isEmpty)
        // Things reschedules: only the date travels to Reminders.
        await w.things.clearRecords()
        await w.things.edit(tid) { $0.startDate = day(5); $0.modificationDate = late }
        try await w.sync()
        let toReminders = await w.reminders.patches
        #expect(toReminders.count == 1)
        #expect(toReminders[0].patch == ReminderPatch(due: .some(DueDate(day: day(5), minutes: 540))))
        #expect(await w.things.updates.isEmpty)
    }

    @Test func remindersOnlyFieldsSurviveEveryRoundTrip() async throws {
        // Priority, alarms and the like have no Things counterpart: the engine never reads or writes them, so a
        // title-only change leaves the reminder byte-for-byte as it was.
        var w = await world()
        var r = reminder("r1", "L1", "Title")
        r.url = link
        await w.reminders.add(r)
        try await w.sync()
        let rid = w.links.links[0].reminderId
        let before = try #require(await w.reminders.item(rid))
        await w.things.edit(w.links.links[0].thingsId) { $0.title = "Renamed"; $0.modificationDate = late }
        try await w.sync()
        var after = try #require(await w.reminders.item(rid))
        after.title = before.title; after.lastModified = before.lastModified
        #expect(after == before)
    }
}
