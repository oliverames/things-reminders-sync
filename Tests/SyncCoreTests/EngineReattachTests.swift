import Foundation
import Testing
@testable import SyncCore

// Regression: an unlinked pair stayed detached forever, so a to-do moved out of a mapped project
// and back (or a reminder moved to an unmapped list and back) never synced again.

@Test func thingsTodoMovedOutAndBackRelinksWithItsReminder() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Pay rent", project: "P1"))
    try await w.sync()
    let rid = try #require(w.links.links.first?.reminderId)
    await w.things.edit("t1") { $0.projectId = nil }               // to the Inbox
    #expect(try await w.sync().unlinked == 1)
    await w.things.edit("t1") { $0.projectId = "P1" }              // and back
    let r = try await w.sync()
    #expect(r.createdInReminders == 0 && r.createdInThings == 0)
    #expect(w.links.links.map(\.reminderId) == [rid] && w.links.links.map(\.thingsId) == ["t1"])
    #expect(w.links.detachedThingsIds.isEmpty && w.links.detachedReminderIds.isEmpty)
    // And it syncs again.
    await w.things.edit("t1") { $0.title = "Pay rent (Nov)"; $0.modificationDate = Date(timeIntervalSince1970: 9_000_000_000) }
    #expect(try await w.sync().updatedInReminders == 1)
    #expect(await w.reminders.item(rid)?.title == "Pay rent (Nov)")
}

@Test func reminderMovedToUnmappedListAndBackRelinks() async throws {
    var w = World(lists: ["L1", "L9"])
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Call plumber", project: "P1"))
    try await w.sync()
    let rid = try #require(w.links.links.first?.reminderId)
    await w.reminders.edit(rid) { $0.listId = "L9" }
    #expect(try await w.sync().unlinked == 1)
    await w.reminders.edit(rid) { $0.listId = "L1" }
    let r = try await w.sync()
    #expect(r.createdInReminders == 0 && r.createdInThings == 0)
    #expect(w.links.links.count == 1 && w.links.links[0].reminderId == rid)
}

@Test func detachedItemWhosePartnerIsGoneSyncsAsNew() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Water plants", project: "P1"))
    try await w.sync()
    let rid = try #require(w.links.links.first?.reminderId)
    await w.things.edit("t1") { $0.projectId = nil }
    try await w.sync()
    await w.reminders.remove(rid)                                  // old partner deleted meanwhile
    await w.things.edit("t1") { $0.projectId = "P1" }
    let r = try await w.sync()
    #expect(r.createdInReminders == 1)                             // gets a fresh reminder
    #expect(w.links.links.count == 1)
}

@Test func detachedPartnerStillDoesNotResurrect() async throws {
    // The original guard must hold: the item that stayed in scope gets no new partner.
    var w = World(lists: ["L1", "L9"])
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Stays in project", project: "P1"))
    try await w.sync()
    let rid = try #require(w.links.links.first?.reminderId)
    await w.reminders.edit(rid) { $0.listId = "L9" }
    try await w.sync()
    for _ in 0..<2 { #expect(try await w.sync().createdInReminders == 0) }
}

@Test func outThenIntoAnotherMappedProjectMovesTheReminderAlong() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "One"),
        ListMapping(id: "L2", listTitle: "L2", mode: .project, targetId: "P2", targetTitle: "Two"),
    ])
    await w.things.add(projectTask("P1"))
    await w.things.add(projectTask("P2"))
    await w.things.add(todo("t1", "Renew passport", project: "P1"))
    try await w.sync()
    let rid = try #require(w.links.links.first?.reminderId)
    await w.things.edit("t1") { $0.projectId = nil }               // Inbox first...
    try await w.sync()
    await w.things.edit("t1") { $0.projectId = "P2"; $0.modificationDate = Date(timeIntervalSince1970: 9_000_000_000) }
    let r = try await w.sync()                                     // ...then into the other synced project
    #expect(r.createdInReminders == 0 && r.createdInThings == 0)
    #expect(await w.reminders.item(rid)?.listId == "L2")
    #expect(w.links.links.count == 1 && w.links.links[0].mappingId == "L2")
}
