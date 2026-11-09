import Foundation
import Testing
@testable import SyncCore

// Reminders sections <-> Things headings for a project-mode mapping.

private func heading(_ w: World, _ todoId: String) async -> String? {
    guard let t = await w.things.task(todoId), let h = t.headingId else { return nil }
    return await w.things.task(h)?.title
}

/// P1 with two linked pairs (t1/r1 "One", t2/r2 "Two") and neither side in a group yet.
private func linked(sections: Bool = true) async throws -> World {
    var w = World()
    w.config.mappings[0].syncSections = sections
    await w.things.add(projectTask("P1"))
    await w.things.add(todo("t1", "One", project: "P1"))
    await w.things.add(todo("t2", "Two", project: "P1"))
    await w.reminders.add(reminder("r1", "L1", "One"))
    await w.reminders.add(reminder("r2", "L1", "Two"))
    try await w.sync()
    #expect(w.links.links.count == 2)
    return w
}

@Test func reminderSectionMovesTodosUnderOneCreatedHeading() async throws {
    var w = try await linked()
    await w.reminders.edit("r1") { $0.section = "Errands" }
    await w.reminders.edit("r2") { $0.section = " errands " }   // same section, other spelling and padding
    let r = try await w.sync()
    #expect(r.updatedInThings == 2)
    let created = await w.things.headingsCreated
    #expect(created.count == 1 && created[0].title == "Errands" && created[0].projectId == "P1")
    for id in ["t1", "t2"] {
        let t = try #require(await w.things.task(id))
        #expect(t.headingId != nil && t.projectId == nil)
        #expect(await heading(w, id) == "Errands")
    }
    #expect(try await w.sync().changeCount == 0)   // echo is a no-op
    #expect(await w.things.headingsCreated.count == 1)
}

@Test func existingHeadingIsReusedCaseInsensitivelyOldestFirst() async throws {
    var w = try await linked()
    await w.things.addHeading("H-new", "ERRANDS", project: "P1", created: 200)
    await w.things.addHeading("H-old", "Errands", project: "P1", created: 100)
    await w.things.addHeading("H-other-project", "Errands", project: "P9", created: 1)
    await w.reminders.edit("r1") { $0.section = "errands" }
    try await w.sync()
    #expect(await w.things.task("t1")?.headingId == "H-old")
    #expect(await w.things.headingsCreated.isEmpty)
}

@Test func thingsHeadingChangeSetsTheReminderSection() async throws {
    var w = try await linked()
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.addHeading("H2", "Later", project: "P1")
    await w.reminders.setClearsSections(true)
    await w.things.edit("t1") { $0.headingId = "H1"; $0.modificationDate = Date() }
    try await w.sync()
    #expect(await w.reminders.item("r1")?.section == "Errands")
    #expect(try await w.sync().changeCount == 0)

    await w.things.edit("t1") { $0.headingId = "H2"; $0.modificationDate = Date() }
    try await w.sync()
    #expect(await w.reminders.item("r1")?.section == "Later")

    // A heading removed in Things clears the section when RemCTL can.
    await w.things.edit("t1") { $0.headingId = nil; $0.modificationDate = Date() }
    try await w.sync()
    #expect(await w.reminders.item("r1")?.section == nil)
    #expect(try await w.sync().changeCount == 0)
    #expect(await w.reminders.item("r2")?.section == nil)   // untouched neighbour
}

@Test func sectionRemovedInRemindersMovesTodoOutOfItsHeading() async throws {
    var w = try await linked()
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.edit("t1") { $0.headingId = "H1" }
    await w.reminders.edit("r1") { $0.section = "Errands" }
    try await w.sync()                                   // already in step: no change
    #expect(await w.things.task("t1")?.headingId == "H1")
    await w.reminders.edit("r1") { $0.section = nil }
    try await w.sync()
    let t = try #require(await w.things.task("t1"))
    #expect(t.headingId == nil && t.projectId == "P1")
    #expect(try await w.sync().changeCount == 0)
}

@Test func unclearableSectionIsLeftAloneAndDoesNotLoop() async throws {
    var w = try await linked()                           // FakeReminders cannot clear sections by default, like RemCTL 2.5.0
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.reminders.edit("r1") { $0.section = "Errands" }
    try await w.sync()                                   // to-do goes under the heading
    #expect(await w.things.task("t1")?.headingId == "H1")
    await w.things.edit("t1") { $0.headingId = nil; $0.projectId = "P1"; $0.modificationDate = Date() }   // dragged out of the heading
    let first = try await w.sync()
    #expect(await w.reminders.item("r1")?.section == "Errands")          // left where it is
    #expect(first.log.filter { $0.level == .info && $0.message.contains("cannot remove") }.count == 1)
    #expect(first.updatedInReminders == 0)
    // Later passes neither retry nor pull the to-do back under the heading.
    let again = try await w.sync()
    #expect(again.changeCount == 0 && again.log.allSatisfy { !$0.message.contains("section") })
    #expect(await w.things.task("t1")?.headingId == nil)
    #expect(w.links.links.first { $0.reminderId == "r1" }?.fingerprint.group == nil)
    // A real change on either side still flows afterwards.
    await w.reminders.edit("r1") { $0.section = "Other" }
    try await w.sync()
    #expect(await heading(w, "t1") == "Other")
}

@Test func firstLinkGroupRulesAreConservative() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.addHeading("H2", "Home", project: "P1")
    await w.things.addHeading("H3", "Things pick", project: "P1")
    await w.things.add(todo("a", "Reminder has section", project: "P1"))
    await w.things.add(todo("b", "Things has heading", project: "P1", heading: "H1"))
    await w.things.add(todo("c", "Both differ", project: "P1", heading: "H3"))
    await w.things.add(todo("d", "Both equal", project: "P1", heading: "H2"))
    await w.reminders.setClearsSections(true)
    await w.reminders.add(reminder("ra", "L1", "Reminder has section", section: "Errands"))
    await w.reminders.add(reminder("rb", "L1", "Things has heading"))
    await w.reminders.add(reminder("rc", "L1", "Both differ", section: "Reminders pick"))
    await w.reminders.add(reminder("rd", "L1", "Both equal", section: "home"))
    let r = try await w.sync()
    #expect(r.linked == 4)
    #expect(await heading(w, "a") == "Errands")                       // non-nil beats nil
    #expect(await w.reminders.item("rb")?.section == "Errands")        // and the other way round
    #expect(await heading(w, "c") == "Things pick")                    // both differ: Things wins
    #expect(await w.reminders.item("rc")?.section == "Things pick")
    #expect(await w.things.task("d")?.headingId == "H2")
    #expect(await w.reminders.item("rd")?.section == "home")   // equal: no write
    #expect(try await w.sync().changeCount == 0)
}

@Test func syncSectionsOffLeavesStructureAlone() async throws {
    var w = try await linked(sections: false)
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.edit("t1") { $0.headingId = "H1"; $0.modificationDate = Date() }
    await w.reminders.edit("r2") { $0.section = "Chores" }
    let r = try await w.sync()
    #expect(r.changeCount == 0)
    #expect(await w.things.task("t1")?.headingId == "H1")
    #expect(await w.reminders.item("r1")?.section == nil)
    #expect(await w.things.task("t2")?.headingId == nil)
    #expect(await w.things.headingsCreated.isEmpty)
    // New partners are created without groups too.
    await w.reminders.add(reminder("r3", "L1", "New", section: "Chores"))
    await w.things.add(todo("t3", "Fresh", project: "P1", heading: "H1"))
    try await w.sync()
    let newTodo = try #require(await w.things.all().first { $0.title == "New" })
    #expect(newTodo.headingId == nil && newTodo.projectId == "P1")
    #expect(await w.reminders.all(in: "L1").first { $0.title == "Fresh" }?.section == nil)
}

@Test func partnersAreCreatedInTheRightHeadingAndSection() async throws {
    var w = World()
    await w.things.add(projectTask("P1"))
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.reminders.add(reminder("r1", "L1", "From reminders", section: "Errands"))
    await w.reminders.add(reminder("r2", "L1", "Needs a new heading", section: "Fresh"))
    await w.reminders.add(reminder("r3", "L1", "No section"))
    await w.things.add(todo("t9", "From things", project: "P1", heading: "H1"))
    try await w.sync()                                   // first link pass
    let created = try await w.things.all()
    func find(_ title: String) throws -> ThingsTask { try #require(created.first { $0.title == title }) }
    #expect(try find("From reminders").headingId == "H1")
    #expect(await heading(w, try find("Needs a new heading").id) == "Fresh")
    #expect(try find("No section").headingId == nil && (try find("No section")).projectId == "P1")
    #expect(await w.reminders.all(in: "L1").first { $0.title == "From things" }?.section == "Errands")
    #expect(await w.things.headingsCreated.map(\.title) == ["Fresh"])
    #expect(try await w.sync().changeCount == 0)

    // Created after the first link, in a targeted-free full pass.
    await w.reminders.add(reminder("r4", "L1", "Later reminder", section: "Fresh"))
    await w.things.add(todo("t10", "Later todo", project: "P1", heading: "H1"))
    try await w.sync()
    #expect(await w.things.headingsCreated.count == 1)   // the heading made earlier is reused
    let later = try await w.things.all().first { $0.title == "Later reminder" }
    #expect(await heading(w, try #require(later).id) == "Fresh")
    #expect(await w.reminders.all(in: "L1").first { $0.title == "Later todo" }?.section == "Errands")
    #expect(try await w.sync().changeCount == 0)
}

@Test func trashedOrForeignHeadingCountsAsNoGroup() async throws {
    var w = try await linked()
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.addHeading("HX", "Elsewhere", project: "P9")
    await w.things.edit("H1") { $0.trashed = true }
    await w.things.edit("t1") { $0.headingId = "H1"; $0.modificationDate = Date() }
    await w.things.edit("t2") { $0.headingId = "HX"; $0.modificationDate = Date() }
    #expect(try await w.sync().changeCount == 0)
    #expect(await w.reminders.item("r1")?.section == nil)
    #expect(await w.reminders.item("r2")?.section == nil)
}

@Test func oldFingerprintsWithoutGroupDecodeAndMoveNothing() async throws {
    let json = #"{"title":"One","notes":"","completed":false}"#
    let fp = try JSONDecoder().decode(Fingerprint.self, from: Data(json.utf8))
    #expect(fp.group == nil && fp.stuckSection == nil)

    // A link store written before groups existed, with no groups on either side: nothing moves.
    var w = try await linked()
    var stripped = try JSONEncoder().encode(w.links)
    var object = try #require(try JSONSerialization.jsonObject(with: stripped) as? [String: Any])
    var links = try #require(object["links"] as? [[String: Any]])
    for i in links.indices {
        var f = try #require(links[i]["fingerprint"] as? [String: Any])
        f["group"] = nil; f["stuckSection"] = nil
        links[i]["fingerprint"] = f
    }
    object["links"] = links
    stripped = try JSONSerialization.data(withJSONObject: object)
    w.links = try JSONDecoder().decode(LinkStore.self, from: stripped)
    let r = try await w.sync()
    #expect(r.changeCount == 0 && r.failures == 0)
    await w.things.clearRecords()
    #expect(try await w.sync().changeCount == 0)
    #expect(await w.things.updates.isEmpty)
}

@Test func groceryListSectionsAreReadButNeverWritten() async throws {
    var w = try await linked()
    await w.reminders.setGrocery("L1")
    await w.reminders.setClearsSections(true)
    // Categories flow into headings.
    await w.reminders.edit("r1") { $0.section = "Dairy" }
    try await w.sync()
    #expect(await heading(w, "t1") == "Dairy")
    // A heading moved in Things is not written back.
    await w.things.addHeading("H2", "Produce", project: "P1")
    await w.things.edit("t1") { $0.headingId = "H2"; $0.modificationDate = Date() }
    let r = try await w.sync()
    #expect(r.updatedInReminders == 0)
    #expect(await w.reminders.item("r1")?.section == "Dairy")
    #expect(await w.reminders.sectionWrites.isEmpty)
    #expect(try await w.sync().changeCount == 0)
    // A new to-do in a heading becomes a reminder without a section (the list categorizes it).
    await w.things.add(todo("t5", "Eggs", project: "P1", heading: "H2"))
    try await w.sync()
    #expect(await w.reminders.all(in: "L1").first { $0.title == "Eggs" }?.section == nil)
    #expect(await w.reminders.sectionWrites.isEmpty)
    #expect(try await w.sync().changeCount == 0)
}

@Test func movingBetweenProjectListsCarriesTheGroup() async throws {
    var w = World(lists: ["L1", "L2"], mappings: [
        ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "A"),
        ListMapping(id: "L2", listTitle: "L2", mode: .project, targetId: "P2", targetTitle: "B"),
    ])
    await w.reminders.setClearsSections(true)
    await w.things.add(projectTask("P1", "A")); await w.things.add(projectTask("P2", "B"))
    await w.things.addHeading("H1", "Errands", project: "P1")
    await w.things.add(todo("t1", "One", project: "P1", heading: "H1"))
    await w.reminders.add(reminder("r1", "L1", "One", section: "Errands"))
    try await w.sync()
    // The reminder moves to L2 (its section is dropped by the move); the to-do follows without losing its meaning.
    await w.reminders.edit("r1") { $0.listId = "L2"; $0.section = "Errands"; $0.lastModified = Date() }
    try await w.sync()
    let t = try #require(await w.things.task("t1"))
    #expect(await heading(w, "t1") == "Errands" && t.headingId != "H1")
    #expect(await w.things.task(try #require(t.headingId))?.projectId == "P2")
    #expect(try await w.sync().changeCount == 0)
}
