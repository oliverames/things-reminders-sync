import Foundation
import Testing
@testable import SyncCore

// `sectionsAsProjects`: Reminders sections <-> Things projects inside the area of an area-mode mapping.

private func areaWorld(on: Bool = true) async -> World {
    let w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .area, targetId: "A1", targetTitle: "Area",
                                         sectionsAsProjects: on)])
    await w.things.addArea("A1", "Area")
    return w
}

private func areaProject(_ id: String, _ title: String, area: String = "A1") -> ThingsTask {
    ThingsTask(id: id, kind: .project, title: title, areaId: area)
}

private func projectTitle(_ w: World, of todoId: String) async -> String? {
    guard let t = await w.things.task(todoId), let p = t.projectId else { return nil }
    return await w.things.task(p)?.title
}

private func thingsId(_ w: World, _ reminderId: String) -> String { w.links.links.first { $0.reminderId == reminderId }!.thingsId }

@Suite("Sections as projects")
struct EngineSectionProjectsTests {
    @Test func aSectionBecomesAnOwnedProjectAndNoSectionStaysLoose() async throws {
        var w = await areaWorld()
        await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
        await w.reminders.add(reminder("r2", "L1", "Two", section: " errands "))
        await w.reminders.add(reminder("r3", "L1", "Three"))
        try await w.sync()
        #expect(w.links.links.count == 3)
        #expect(await w.things.projectsCreated == 1)
        #expect(await projectTitle(w, of: thingsId(w, "r1")) == "Errands")
        #expect(await w.things.task(thingsId(w, "r1"))?.projectId == w.things.task(thingsId(w, "r2"))?.projectId)
        let loose = try #require(await w.things.task(thingsId(w, "r3")))
        #expect(loose.areaId == "A1" && loose.projectId == nil)
        let project = try #require(await w.things.task(thingsId(w, "r1"))?.projectId)
        #expect(await w.things.task(project)?.areaId == "A1")
        #expect(w.links.ownedThings.contains { $0.id == project && $0.kind == .project && $0.mappingId == "L1" })
        #expect(try await w.sync().changeCount == 0)
        #expect(await w.things.projectsCreated == 1)
    }

    @Test func anExistingProjectIsReusedAndNeverOwned() async throws {
        var w = await areaWorld()
        await w.things.add(areaProject("PX", "ERRANDS"))
        await w.things.add(areaProject("PZ", "Errands", area: "A9"))   // same name in another area
        await w.reminders.add(reminder("r1", "L1", "One", section: "errands"))
        try await w.sync()
        #expect(await w.things.task(thingsId(w, "r1"))?.projectId == "PX")
        #expect(await w.things.projectsCreated == 0 && w.links.ownedThings.isEmpty)
    }

    @Test func movingTheReminderBetweenSectionsMovesTheTodoAndRemovesTheEmptiedOwnedProject() async throws {
        var w = await areaWorld()
        await w.things.add(areaProject("PX", "Home"))
        await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
        try await w.sync()
        let created = try #require(await w.things.task(thingsId(w, "r1"))?.projectId)
        await w.reminders.edit("r1") { $0.section = "Home"; $0.lastModified = Date() }
        try await w.sync()
        #expect(await w.things.task(thingsId(w, "r1"))?.projectId == "PX")
        #expect(await w.things.task(created)?.trashed == true, "the app-created project is removed once empty")
        #expect(!w.links.ownedThings.contains { $0.id == created })
        // Back out of the user's own project: that one is never removed.
        await w.reminders.edit("r1") { $0.section = "Errands"; $0.lastModified = Date() }
        try await w.sync()
        #expect(await projectTitle(w, of: thingsId(w, "r1")) == "Errands")
        #expect(await w.things.task("PX")?.trashed == false)
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func movingTheTodoIntoAnotherProjectOfTheAreaSetsTheSectionCreatingIt() async throws {
        var w = await areaWorld()
        await w.things.add(areaProject("PX", "Home"))
        await w.things.add(todo("tOther", "Not synced", project: "PX"))
        await w.reminders.add(reminder("r1", "L1", "One"))
        try await w.sync()
        #expect(w.links.links.count == 1, "a project with no matching section is left alone")
        let t = thingsId(w, "r1")
        await w.things.edit(t) { $0.projectId = "PX"; $0.areaId = nil; $0.modificationDate = Date() }
        try await w.sync()
        #expect(await w.reminders.item("r1")?.section == "Home")
        #expect(w.links.links.first { $0.reminderId == "r1" }?.fingerprint.group == "Home")
        #expect(await w.things.task(t)?.projectId == "PX")
    }

    @Test func aTodoMovedOutOfEveryProjectKeepsItsStuckSection() async throws {
        var w = await areaWorld()
        await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
        try await w.sync()
        let t = thingsId(w, "r1")
        await w.things.edit(t) { $0.projectId = nil; $0.areaId = "A1"; $0.modificationDate = Date() }
        try await w.sync()
        let fp = try #require(w.links.links.first?.fingerprint)
        #expect(fp.group == nil && fp.stuckSection == "Errands", "RemCTL cannot clear a section")
        #expect(await w.reminders.item("r1")?.section == "Errands")
        let after = try #require(await w.things.task(t))
        #expect(after.areaId == "A1" && after.projectId == nil, "the to-do stays loose in the area")
        try await w.sync()
        #expect(await w.things.task(t)?.projectId == nil)
    }

    @Test func aProjectWithNoMatchingSectionIsLeftAloneAndItsTodosAreNotSynced() async throws {
        var w = await areaWorld()
        await w.things.add(areaProject("PX", "Renovation"))
        await w.things.add(todo("t1", "Paint", project: "PX"))
        await w.things.add(todo("t2", "Loose", area: "A1"))
        try await w.sync()
        #expect(w.links.links.map(\.thingsId) == ["t2"])
        #expect(await w.things.task("PX")?.trashed == false && w.links.ownedThings.isEmpty)
    }

    @Test func aNewTodoInAMirroredProjectGetsAReminderInTheSection() async throws {
        var w = await areaWorld()
        await w.things.add(areaProject("PX", "Home"))
        await w.reminders.add(reminder("r1", "L1", "One", section: "Home"))
        try await w.sync()
        await w.things.add(todo("t2", "Two", project: "PX"))
        try await w.sync()
        let link = try #require(w.links.links.first { $0.thingsId == "t2" })
        #expect(await w.reminders.item(link.reminderId)?.section == "Home")
    }

    @Test func offByDefaultTodosInProjectsOfTheAreaAreNotSynced() async throws {
        var w = await areaWorld(on: false)
        await w.things.add(areaProject("PX", "Home"))
        await w.things.add(todo("t1", "In project", project: "PX"))
        await w.reminders.add(reminder("r1", "L1", "One", section: "Home"))
        try await w.sync()
        #expect(w.links.links.map(\.reminderId) == ["r1"])
        let t = try #require(await w.things.task(thingsId(w, "r1")))
        #expect(t.areaId == "A1" && t.projectId == nil)
        #expect(await w.things.projectsCreated == 0)
    }

    @Test func aProjectAnotherListTargetsIsNeverASectionProject() async throws {
        var w = World(lists: ["L1", "L2"], mappings: [
            ListMapping(id: "L1", listTitle: "L1", mode: .area, targetId: "A1", targetTitle: "Area", sectionsAsProjects: true),
            ListMapping(id: "L2", listTitle: "L2", mode: .project, targetId: "PX", targetTitle: "Home")])
        await w.things.addArea("A1", "Area")
        await w.things.add(areaProject("PX", "Home"))
        await w.things.add(todo("t1", "Theirs", project: "PX"))
        await w.reminders.add(reminder("r1", "L1", "One", section: "Home"))
        try await w.sync()
        #expect(w.links.links.first { $0.thingsId == "t1" }?.mappingId == "L2")
        let mine = try #require(await w.things.task(thingsId(w, "r1"))?.projectId)
        #expect(mine != "PX", "a second project is made instead of using the other list's target")
    }
}
