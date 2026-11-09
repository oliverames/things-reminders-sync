import Foundation
import Testing
@testable import SyncCore

// Regression: changing a list's target (another project, project to area, to a tag) used to drop
// every link as "moved out of scope", strand the reminders, and duplicate items in the new target.

private func linkedWorld() async throws -> World {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "Pay rent", project: "P1"))
    await w.things.add(todo("t2", "Call plumber", project: "P1"))
    await w.reminders.add(reminder("r3", "L1", "Book flights"))
    try await w.sync()
    #expect(w.links.links.count == 3)
    return w
}

@Test func projectToAreaMovesLinkedTodosAndKeepsLinks() async throws {
    var w = try await linkedWorld()
    await w.things.addArea("A1", "Home")
    await w.things.add(todo("t9", "Already in area", area: "A1"))
    let linksBefore = Set(w.links.links.map(\.reminderId))
    w.config.mappings[0].mode = .area
    w.config.mappings[0].targetId = "A1"
    let r = try await w.sync()
    #expect(r.unlinked == 0 && r.deletedInThings == 0 && r.deletedInReminders == 0)
    #expect(Set(w.links.links.map(\.reminderId)).isSuperset(of: linksBefore))   // every old link survives
    for t in try await w.things.all() where t.id != "t9" {
        #expect(t.areaId == "A1" && t.projectId == nil)
    }
    #expect(await w.things.all().count == 4)                       // nothing duplicated in Things
    #expect(await w.reminders.all(in: "L1").count == 4)            // only the area's own item was added
    #expect(w.links.detachedReminderIds.isEmpty && w.links.detachedThingsIds.isEmpty)
    #expect(await w.things.task("P1")?.trashed == false)           // old project left in place
    #expect(try await w.sync().changeCount == 0)
}

@Test func projectToTagAddsTagAndKeepsPlacement() async throws {
    var w = try await linkedWorld()
    await w.things.addTag("G1", "Errand")
    w.config.mappings[0].mode = .tag
    w.config.mappings[0].targetId = "G1"
    let r = try await w.sync()
    #expect(r.unlinked == 0)
    for t in await w.things.all() { #expect(t.tagIds.contains("G1") && t.projectId == "P1") }
    #expect(await w.reminders.all(in: "L1").count == 3)
}

@Test func tagToProjectRemovesOldTagAndPlaces() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .tag, targetId: "G1", targetTitle: "Errand")])
    await w.things.addTag("G1", "Errand")
    await w.things.add(projectTask("P2"))
    await w.things.add(todo("t1", "Buy stamps", tags: ["G1"]))
    try await w.sync()
    w.config.mappings[0].mode = .project
    w.config.mappings[0].targetId = "P2"
    #expect(try await w.sync().unlinked == 0)
    let t = try #require(await w.things.task("t1"))
    #expect(t.projectId == "P2" && !t.tagIds.contains("G1"))
    #expect(w.links.links.count == 1)
}

@Test func awaitingTargetPausesTheListAndCreatesNothing() async throws {
    var w = try await linkedWorld()
    w.config.mappings[0].mode = .area
    w.config.mappings[0].targetId = nil
    w.config.mappings[0].awaitingTarget = true
    await w.reminders.add(reminder("r4", "L1", "Added while choosing"))
    let r = try await w.sync()
    #expect(r.unlinked == 0 && r.createdInThings == 0 && r.createdInReminders == 0)
    #expect(await w.things.areas.isEmpty)
    #expect(w.links.links.count == 3)
    // Choosing the area resumes: links move, the new reminder is created there.
    await w.things.addArea("A1", "Home")
    w.config.mappings[0].targetId = "A1"
    w.config.mappings[0].awaitingTarget = false
    let r2 = try await w.sync()
    #expect(r2.unlinked == 0 && r2.createdInThings == 1)
    #expect(try await w.things.all().allSatisfy { $0.areaId == "A1" })
}

@Test func oldConfigWithoutAwaitingTargetDecodes() throws {
    let json = #"{"id":"L1","listTitle":"Family","enabled":true,"mode":"project","targetTitle":"Family"}"#
    let m = try JSONDecoder().decode(ListMapping.self, from: Data(json.utf8))
    #expect(m.awaitingTarget == false && m.targetId == nil)
}
