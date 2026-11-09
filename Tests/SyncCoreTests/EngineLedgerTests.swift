import Foundation
import Testing
@testable import SyncCore

// Ownership ledger: what the app creates is recorded, and only that is ever cleaned up.

private func appWorld(mode: MappingMode = .project, sections: Bool = true) -> World {
    var m = ListMapping(id: "L1", listTitle: "Alpha", mode: mode, targetId: nil, targetTitle: "Alpha")
    m.syncSections = sections
    return World(mappings: [m])
}

@Test func ledgerRecordsEveryCreationPath() async throws {
    var w = appWorld()
    await w.reminders.add(reminder("r1", "L1", "From reminder", section: "Errands"))   // -> Things copy under a new heading
    await w.reminders.add(reminder("r2", "L1", "Paired"))
    await w.reminders.add(reminder("r3", "L1", "Old and done", done: true))
    w.config.includeCompletedOnFirstLink = true
    try await w.sync()
    let projectId = try #require(w.config.mappings[0].targetId)
    let project = try #require(w.links.ownedThings.first { $0.kind == .project })
    #expect(project.id == projectId && project.mappingId == "L1" && project.title == "Alpha")
    let heading = try #require(w.links.ownedThings.first { $0.kind == .heading })
    #expect(heading.mappingId == "L1" && heading.title == "Errands")
    #expect(w.links.ownedSections.isEmpty)   // "Errands" already existed in Reminders: the user's, not recorded
    for l in w.links.links { #expect(l.copySide == .things) }
    #expect(w.links.links.first { $0.fingerprint.title == "Old and done" }?.copiedCompleted == true)
    #expect(w.links.links.first { $0.fingerprint.title == "From reminder" }?.copiedCompleted == false)

    // A to-do made in Things becomes a reminder copy; a to-do with a user heading creates the Reminders section.
    await w.things.addHeading("HU", "Plans", project: projectId)
    await w.things.add(todo("t9", "From Things", heading: "HU"))
    try await w.sync()
    let fromThings = try #require(w.links.links.first { $0.fingerprint.title == "From Things" })
    #expect(fromThings.copySide == .reminders && fromThings.copiedCompleted == false)
    #expect(w.links.ownedSections.map(\.name).contains("Plans"))
    #expect(!w.links.ownedThings.contains { $0.id == "HU" })   // the user's heading is not recorded
}

@Test func titlePairedItemsAreOriginalsOnBothSides() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Both", project: "P1"))
    await w.reminders.add(reminder("r1", "L1", "Both"))
    try await w.sync()
    #expect(w.links.links.count == 1 && w.links.links[0].copySide == nil && !w.links.links[0].copiedCompleted)
    #expect(w.links.ownedThings.isEmpty)
}

@Test func ledgerRecordsAreaTagAndHeadingTargets() async throws {
    for mode in [MappingMode.area, .tag] {
        var w = appWorld(mode: mode)
        try await w.sync()
        let owned = try #require(w.links.ownedThings.first)
        #expect(owned.kind == (mode == .area ? .area : .tag) && owned.id == w.config.mappings[0].targetId)
    }
    var w = appWorld(mode: .heading)
    await w.things.add(projectTask("PU", "Mine"))
    w.config.mappings[0].parentProjectId = "PU"
    try await w.sync()
    #expect(w.links.ownedThings.first?.kind == .heading)
    // The heading is the mapping's target: it stays although it is empty.
    try await w.sync()
    #expect(await w.things.trashCalls().isEmpty)
}

@Test func completedCopyFromThingsIsMarked() async throws {
    var w2 = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    w2.config.includeCompletedOnFirstLink = true
    await w2.things.add(projectTask("PX"))
    await w2.things.add(todo("t1", "Finished", project: "PX", status: .completed))
    try await w2.sync()
    #expect(w2.links.links.first?.copySide == .reminders && w2.links.links.first?.copiedCompleted == true)
}

// MARK: Retarget cleanup

@Test func retargetTrashesTheEmptiedAppCreatedProject() async throws {
    var w = appWorld()
    await w.reminders.add(reminder("r1", "L1", "Buy"))
    try await w.sync()
    let old = try #require(w.config.mappings[0].targetId)
    await w.things.add(projectTask("PU", "Mine"))
    w.config.mappings[0].targetId = "PU"
    let r = try await w.sync()
    #expect(await w.things.task(old)?.trashed == true)                          // trashed, not deleted
    #expect(await w.things.trashCalls() == [old])
    #expect(try await w.things.all().allSatisfy { $0.projectId == "PU" })
    #expect(w.links.ownedThings.isEmpty)
    #expect(r.log.contains { $0.level == .change && $0.message.contains("Removed empty Things project \"Alpha\"") })
    #expect(try await w.sync().changeCount == 0)
}

@Test func retargetKeepsUserCreatedAndNonEmptyProjects() async throws {
    // User-created old project: never touched.
    var a = World()
    await a.things.add(projectTask("P1")); await a.things.add(projectTask("P2", "Other"))
    await a.reminders.add(reminder("r1", "L1", "Buy"))
    try await a.sync()
    a.config.mappings[0].targetId = "P2"
    try await a.sync()
    #expect(await a.things.trashCalls().isEmpty)

    // App-created old project that still holds an unlinked to-do: kept.
    var b = appWorld()
    await b.reminders.add(reminder("r1", "L1", "Buy"))
    try await b.sync()
    let old = try #require(b.config.mappings[0].targetId)
    await b.things.add(todo("tx", "User's own", project: old, status: .completed))   // done to-dos count too
    await b.things.add(projectTask("PU", "Mine"))
    b.config.mappings[0].targetId = "PU"
    try await b.sync()
    #expect(await b.things.trashCalls().isEmpty)
    #expect(b.links.ownedThings.contains { $0.id == old })

    // Another mapping still targets it: kept.
    var c = appWorld()
    await c.reminders.add(reminder("r1", "L1", "Buy"))
    try await c.sync()
    let shared = try #require(c.config.mappings[0].targetId)
    await c.things.add(projectTask("PU", "Mine"))
    c.config.mappings.append(ListMapping(id: "L2", listTitle: "L2", enabled: false, mode: .project, targetId: shared, targetTitle: "x"))
    c.config.mappings[0].targetId = "PU"
    try await c.sync()
    #expect(await c.things.trashCalls().isEmpty)
}

@Test func retargetRemovesAppCreatedAreaAndTag() async throws {
    var w = appWorld(mode: .area)
    await w.reminders.add(reminder("r1", "L1", "Buy"))
    try await w.sync()
    let area = try #require(w.config.mappings[0].targetId)
    await w.things.addArea("AU", "Mine")
    w.config.mappings[0].targetId = "AU"
    try await w.sync()
    #expect(await w.things.deletedAreas == [area])
    #expect(await w.things.areas.keys.contains("AU"))

    var t = appWorld(mode: .tag)
    await t.reminders.add(reminder("r1", "L1", "Buy"))
    try await t.sync()
    let tag = try #require(t.config.mappings[0].targetId)
    await t.things.addTag("GU", "Mine")
    t.config.mappings[0].targetId = "GU"
    try await t.sync()
    #expect(await t.things.deletedTags == [tag])
}

// MARK: Headings and sections

@Test func emptiedAppHeadingIsTrashedUserHeadingIsNot() async throws {
    var w = appWorld()
    await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
    try await w.sync()
    let project = try #require(w.config.mappings[0].targetId)
    let heading = try #require(w.links.ownedThings.first { $0.kind == .heading }?.id)
    await w.things.addHeading("HU", "Mine", project: project)           // empty, but the user's
    try await w.sync()
    #expect(await w.things.trashCalls().isEmpty)                         // still holds a to-do
    let link = try #require(w.links.links.first)
    await w.things.edit(link.thingsId) { $0.headingId = nil; $0.projectId = project; $0.modificationDate = Date() }
    let r = try await w.sync()
    #expect(await w.things.task(heading)?.trashed == true)
    #expect(await w.things.task("HU")?.trashed == false)
    #expect(await w.things.trashCalls() == [heading])
    #expect(!w.links.ownedThings.contains { $0.id == heading })
    #expect(r.removedContainers == 1)
}

@Test func emptyAppSectionIsDeletedUserSectionIsNot() async throws {
    var w = appWorld()
    try await w.sync()
    let project = try #require(w.config.mappings[0].targetId)
    await w.things.addHeading("HU", "Plans", project: project)
    await w.things.add(todo("t1", "From Things", heading: "HU"))
    await w.reminders.addSection("L1", "Mine")                           // the user's own, empty
    try await w.sync()
    #expect(w.links.ownedSections.map(\.name) == ["Plans"])
    try await w.sync()
    #expect(await w.reminders.sectionDeletes.isEmpty)                    // still holds a reminder
    let reminderId = try #require(w.links.links.first?.reminderId)
    await w.reminders.remove(reminderId)                                 // deleted in Reminders: the to-do is trashed
    try await w.sync()
    #expect(await w.reminders.sectionDeletes == ["L1:Plans"])
    #expect(w.links.ownedSections.isEmpty)
}

@Test func sectionsOfGroceryListsAreNeverTouched() async throws {
    var w = appWorld()
    try await w.sync()
    w.links.ownedSections = [OwnedReminderSection(listId: "L1", name: "Produce")]
    await w.reminders.setGrocery("L1")
    try await w.sync()
    #expect(await w.reminders.sectionDeletes.isEmpty)
}

// MARK: State files

@Test func oldStateFilesDecode() throws {
    let link = #"{"id":"B4EC795B-3FEA-4A3E-A292-2751756BC613","reminderId":"1","thingsId":"t","mappingId":"L","lastSynced":"2026-01-01T00:00:00Z","fingerprint":{"title":"A","notes":"","completed":false}}"#
    let store = #"{"links":[\#(link)],"linkedMappings":{"L":"project:P"},"detachedThingsIds":[],"detachedReminderIds":[],"parkedLinks":[\#(link)]}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(LinkStore.self, from: Data(store.utf8))
    #expect(decoded.links[0].copySide == nil && decoded.links[0].copiedCompleted == false)
    #expect(decoded.parkedLinks[0].copySide == nil)
    #expect(decoded.ownedThings.isEmpty && decoded.ownedSections.isEmpty && decoded.ledgerBackfilled == false)
    // The new fields survive a round trip, including on parked links.
    var l = decoded.links[0]; l.copySide = .reminders; l.copiedCompleted = true
    var s = decoded; s.parkedLinks = [l]; s.ownedThings = [OwnedThingsContainer(id: "P", kind: .project, mappingId: "L", title: "T")]
    s.ledgerBackfilled = true
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let back = try decoder.decode(LinkStore.self, from: try encoder.encode(s))
    #expect(back.parkedLinks[0].copySide == .reminders && back.parkedLinks[0].copiedCompleted && back.ledgerBackfilled)
    #expect(back.ownedThings.count == 1)
}

// Regression: an app-created project abandoned before cleanup existed (or emptied by hand) stayed
// forever. The end-of-pass sweep removes owned, untargeted, empty containers, and nothing else.
@Test func sweepRemovesAbandonedOwnedContainersOnly() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))                                   // targeted by L1
    await w.things.add(projectTask("OLD", "Abandoned app project"))           // owned, untargeted, empty
    await w.things.add(projectTask("FULL", "Owned but not empty"))
    await w.things.add(todo("t9", "Still here", project: "FULL"))
    await w.things.add(projectTask("MINE", "User project"))                  // not owned
    w.links.ownedThings = [
        OwnedThingsContainer(id: "OLD", kind: .project, mappingId: "L1", title: "Abandoned app project"),
        OwnedThingsContainer(id: "FULL", kind: .project, mappingId: "L1", title: "Owned but not empty"),
        OwnedThingsContainer(id: "P1", kind: .project, mappingId: "L1", title: "Proj"),
    ]
    let r = try await w.sync()
    #expect(r.removedContainers == 1)
    #expect(await w.things.task("OLD")?.trashed == true)
    #expect(await w.things.task("FULL")?.trashed == false)
    #expect(await w.things.task("P1")?.trashed == false)
    #expect(await w.things.task("MINE")?.trashed == false)
    #expect(!w.links.ownedThings.contains { $0.id == "OLD" })
}
