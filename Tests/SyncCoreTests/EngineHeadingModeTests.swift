import Foundation
import Testing
@testable import SyncCore

private func headingMapping(_ list: String, heading: String?, project: String? = "P1", title: String? = nil) -> ListMapping {
    ListMapping(id: list, listTitle: list, mode: .heading, targetId: heading, targetTitle: title ?? list, parentProjectId: project)
}

@Test func headingModeMirrorsOnlyTheToDosUnderThatHeading() async throws {
    var w = World(mappings: [headingMapping("L1", heading: "H1")])
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Groceries", project: "P1")
    await w.things.addHeading("H2", "Other", project: "P1")
    await w.things.add(todo("t1", "Under heading", heading: "H1"))
    await w.things.add(todo("t2", "Other heading", heading: "H2"))
    await w.things.add(todo("t3", "Loose in project", project: "P1"))
    await w.reminders.add(reminder("r1", "L1", "From reminders", section: "Ignored section"))
    let r = try await w.sync()
    #expect(r.createdInReminders == 1 && r.createdInThings == 1)
    #expect(await w.reminders.all(in: "L1").map(\.title).sorted() == ["From reminders", "Under heading"])
    let created = try #require(await w.things.all().first { $0.title == "From reminders" })
    #expect(created.headingId == "H1")                                   // placement .heading(target)
    #expect(await w.things.headingsCreated.isEmpty)                      // sections are ignored in heading mode
    #expect(await w.reminders.all(in: "L1").allSatisfy { $0.section == nil || $0.title == "From reminders" })
    #expect(try await w.sync().changeCount == 0)
}

@Test func headingIsCreatedInTheParentProject() async throws {
    var w = World(mappings: [headingMapping("L1", heading: nil, title: "Weekend")])
    await w.things.add(projectTask("P1"))
    await w.reminders.add(reminder("r1", "L1", "Mow the lawn"))
    let r = try await w.sync()
    #expect(await w.things.headingsCreated.map(\.title) == ["Weekend"])
    #expect(await w.things.headingsCreated.map(\.projectId) == ["P1"])
    let id = try #require(w.config.mappings[0].targetId)
    #expect(await w.things.task(id)?.kind == .heading)
    #expect(r.createdInThings == 1)
    #expect((try await w.things.all()[0]).headingId == id)
}

@Test func headingModeWithoutProjectIsSkippedWithAWarning() async throws {
    var w = World(mappings: [headingMapping("L1", heading: nil, project: nil)])
    await w.reminders.add(reminder("r1", "L1", "Stays put"))
    let r = try await w.sync()
    #expect(r.failures == 0 && r.createdInThings == 0)
    #expect(w.config.mappings[0].targetId == nil)
    #expect(await w.things.headingsCreated.isEmpty)
    #expect(r.log.contains { $0.level == .warning && $0.message.contains("no project") })
}

@Test func awaitingTargetHeadingCreatesNothing() async throws {
    var w = World(mappings: [headingMapping("L1", heading: nil)])
    w.config.mappings[0].awaitingTarget = true
    await w.things.add(projectTask("P1"))
    try await w.sync()
    #expect(await w.things.headingsCreated.isEmpty && w.config.mappings[0].targetId == nil)
}

@Test func missingOrTrashedHeadingPausesTheList() async throws {
    var w = World(mappings: [headingMapping("L1", heading: "H1")])
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Gone", project: "P1")
    await w.things.edit("H1") { $0.trashed = true }
    await w.reminders.add(reminder("r1", "L1", "Nothing happens"))
    let r = try await w.sync()
    #expect(r.createdInThings == 0 && r.log.contains { $0.message.contains("no longer exists") })
    // A project is not a heading.
    w.config.mappings[0].targetId = "P1"
    let again = try await w.sync()
    #expect(again.createdInThings == 0)
}

@Test func severalListsMapToDifferentHeadingsOfOneProject() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [headingMapping("L1", heading: "H1"), headingMapping("L2", heading: "H2")])
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "One", project: "P1")
    await w.things.addHeading("H2", "Two", project: "P1")
    await w.things.add(todo("a", "In one", heading: "H1"))
    await w.things.add(todo("b", "In two", heading: "H2"))
    await w.reminders.add(reminder("r1", "L2", "New in two"))
    try await w.sync()
    #expect(await w.reminders.all(in: "L1").map(\.title) == ["In one"])
    #expect(await w.reminders.all(in: "L2").map(\.title).sorted() == ["In two", "New in two"])
    #expect(try await w.things.all().first { $0.title == "New in two" }?.headingId == "H2")
    #expect(w.links.links.count == 3)
    #expect(try await w.sync().changeCount == 0)
}

@Test func headingMappingBeatsAProjectMappingOfTheSameProjectEvenListedLater() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj"),   // listed first
        headingMapping("L2", heading: "H1"),
    ])
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Groceries", project: "P1")
    await w.things.add(todo("a", "Under heading", heading: "H1"))
    await w.things.add(todo("b", "Directly in project", project: "P1"))
    let r = try await w.sync()
    #expect(r.createdInReminders == 2)
    #expect(await w.reminders.all(in: "L2").map(\.title) == ["Under heading"])
    #expect(await w.reminders.all(in: "L1").map(\.title) == ["Directly in project"])
    #expect(try await w.sync().changeCount == 0)
}

@Test func projectToHeadingRetargetMovesLinkedTodos() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Weekend", project: "P1")
    await w.things.add(todo("t1", "Pay rent", project: "P1"))
    await w.reminders.add(reminder("r2", "L1", "Book flights"))
    try await w.sync()
    #expect(w.links.links.count == 2)
    w.config.mappings[0] = headingMapping("L1", heading: "H1")
    let r = try await w.sync()
    #expect(r.unlinked == 0 && r.deletedInThings == 0 && r.deletedInReminders == 0)
    for t in try await w.things.all() { #expect(t.headingId == "H1") }
    #expect(w.links.links.count == 2 && w.links.detachedThingsIds.isEmpty)
    #expect(await w.things.all().count == 2)
    #expect(await w.reminders.all(in: "L1").count == 2)
    #expect(try await w.sync().changeCount == 0)
}

@Test func headingToProjectRetargetMovesLinkedTodosOut() async throws {
    var w = World(mappings: [headingMapping("L1", heading: "H1")])
    await w.things.add(projectTask("P1")); await w.things.add(projectTask("P2", "New home"))
    await w.things.addHeading("H1", "Weekend", project: "P1")
    await w.things.add(todo("t1", "Pay rent", heading: "H1"))
    await w.reminders.add(reminder("r2", "L1", "Book flights"))
    try await w.sync()
    #expect(w.links.links.count == 2)
    w.config.mappings[0] = ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P2", targetTitle: "New home")
    let r = try await w.sync()
    #expect(r.unlinked == 0)
    for t in try await w.things.all() { #expect(t.projectId == "P2" && t.headingId == nil) }
    #expect(await w.things.task("H1")?.trashed == false)               // old heading left in place
    #expect(try await w.sync().changeCount == 0)
}

@Test func headingToHeadingRetargetMoves() async throws {
    var w = World(mappings: [headingMapping("L1", heading: "H1")])
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Old", project: "P1"); await w.things.addHeading("H2", "New", project: "P1")
    await w.things.add(todo("t1", "Pay rent", heading: "H1"))
    try await w.sync()
    w.config.mappings[0].targetId = "H2"
    let r = try await w.sync()
    #expect(r.unlinked == 0 && r.deletedInReminders == 0)
    #expect(await w.things.task("t1")?.headingId == "H2" && (w.links.links.count == 1))
}

@Test func projectRetargetKeepsTodosUnderSameNamedHeadings() async throws {
    var w = World()
    await w.things.add(projectTask("P1")); await w.things.add(projectTask("P2", "Second"))
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.add(todo("t1", "Pay rent", project: "P1", heading: "H1"))
    await w.reminders.add(reminder("r1", "L1", "Pay rent", section: "Errands"))
    try await w.sync()
    w.config.mappings[0].targetId = "P2"
    let r = try await w.sync()
    #expect(r.unlinked == 0 && r.failures == 0)
    let t = try #require(await w.things.task("t1"))
    #expect(await w.things.task(try #require(t.headingId))?.projectId == "P2")
    #expect(await w.things.task(try #require(t.headingId))?.title == "Errands")
    #expect(await w.reminders.item("r1")?.section == "Errands")        // not stripped by the move
    #expect(try await w.sync().changeCount == 0)
}

@Test func mappingDecodingKeepsOldConfigsWorking() throws {
    let old = #"{"id":"L1","listTitle":"Family","enabled":true,"mode":"project","targetTitle":"Family"}"#
    let m = try JSONDecoder().decode(ListMapping.self, from: Data(old.utf8))
    #expect(m.syncSections == true && m.parentProjectId == nil)
    let h = headingMapping("L1", heading: "H1")
    #expect(try JSONDecoder().decode(ListMapping.self, from: JSONEncoder().encode(h)) == h)
    var off = m; off.syncSections = false
    #expect(try JSONDecoder().decode(ListMapping.self, from: JSONEncoder().encode(off)).syncSections == false)
}
