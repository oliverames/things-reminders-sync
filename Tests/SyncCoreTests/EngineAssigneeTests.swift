import Foundation
import Testing
@testable import SyncCore

// `assigneeTags`: a mapped tag on the to-do assigns the reminder. Things to Reminders only (docs/SPEC.md).

private func world(_ map: [String: String] = ["ana@example.com": "Ana", "ben@example.com": "Ben"],
                   direction: SyncDirection = .twoWay) async throws -> World {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj",
                                         direction: direction, assigneeTags: map)])
    await w.things.add(projectTask("P1"))
    await w.things.addTag("GA", "Ana")
    await w.things.addTag("GB", "Ben")
    await w.things.add(todo("T1", "Call", project: "P1"))
    try await w.sync()
    #expect(w.links.links.count == 1)
    return w
}

@Suite("Assignee tags")
struct EngineAssigneeTests {
    @Test func theKeysAreOptionalAndOffByDefault() throws {
        let m = try JSONDecoder().decode(ListMapping.self, from: Data(#"{"id":"1","listTitle":"L"}"#.utf8))
        #expect(m.assigneeTags.isEmpty && !m.sectionsAsProjects)
        let on = try JSONDecoder().decode(ListMapping.self, from: Data(#"{"id":"1","listTitle":"L","assigneeTags":{"me":"Mine"},"sectionsAsProjects":true}"#.utf8))
        #expect(on.assigneeTags == ["me": "Mine"] && on.sectionsAsProjects)
    }

    @Test func aMappedTagAssignsOnceAndRemovingItUnassigns() async throws {
        var w = try await world()
        #expect(await w.reminders.assignAttempts == 0, "no mapped tag, nothing written")
        await w.things.edit("T1") { $0.tagIds = ["GA"]; $0.modificationDate = Date() }
        try await w.sync()
        var writes = await w.reminders.assignWrites
        #expect(writes.count == 1 && writes[0].sharee == "ana@example.com")
        #expect(w.links.links[0].fingerprint.assignee == "ana@example.com")
        try await w.sync()
        try await w.sync()
        #expect(await w.reminders.assignAttempts == 1, "the fingerprint keeps the value: nothing is rewritten")
        await w.things.edit("T1") { $0.tagIds = []; $0.modificationDate = Date() }
        try await w.sync()
        writes = await w.reminders.assignWrites
        #expect(writes.count == 2 && writes[1].sharee == nil)
        #expect(w.links.links[0].fingerprint.assignee == nil)
        try await w.sync()
        #expect(await w.reminders.assignAttempts == 2)
    }

    @Test func theAssigneeTagStaysAnOrdinaryTag() async throws {
        var w = try await world()
        await w.things.edit("T1") { $0.tagIds = ["GA"]; $0.modificationDate = Date() }
        try await w.sync()
        #expect(await w.reminders.item(w.links.links[0].reminderId)?.tags == ["Ana"])
    }

    @Test func twoMappedTagsUseTheFirstKeyInSortedOrder() async throws {
        var w = try await world()
        await w.things.edit("T1") { $0.tagIds = ["GB", "GA"]; $0.modificationDate = Date() }
        let report = try await w.sync()
        let writes = await w.reminders.assignWrites
        #expect(writes.count == 1 && writes[0].sharee == "ana@example.com")
        #expect(report.log.filter { $0.message.contains("more than one assignee tag") }.count == 1)
        let again = try await w.sync()
        #expect(!again.log.contains { $0.message.contains("more than one assignee tag") }, "logged once, not on every pass")
    }

    @Test func aFailedAssignWarnsAndIsRetriedOnlyWhenTheTagsChange() async throws {
        var w = try await world()
        await w.reminders.setAssignFails(true)
        await w.things.edit("T1") { $0.tagIds = ["GA"]; $0.modificationDate = Date() }
        let report = try await w.sync()
        #expect(report.log.contains { $0.level == .warning && $0.message.contains("assignment") })
        #expect(report.failures == 0, "a failed assignment does not fail the pair")
        #expect(w.links.links[0].fingerprint.assignee == nil)
        try await w.sync()
        try await w.sync()
        #expect(await w.reminders.assignAttempts == 1, "not retried while the tags are the same")
        await w.reminders.setAssignFails(false)
        await w.things.edit("T1") { $0.tagIds = ["GA", "GB"]; $0.modificationDate = Date() }
        try await w.sync()
        #expect(await w.reminders.assignAttempts == 2)
        #expect(w.links.links[0].fingerprint.assignee == "ana@example.com")
    }

    @Test func aListOneWayFromRemindersNeverAssigns() async throws {
        var w = World(mappings: [ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj",
                                             direction: .remindersToThings, assigneeTags: ["me": "Ana"])])
        await w.things.add(projectTask("P1"))
        await w.things.addTag("GA", "Ana")
        await w.reminders.add(reminder("r1", "L1", "Call"))
        try await w.sync()
        await w.things.edit(w.links.links[0].thingsId) { $0.tagIds = ["GA"]; $0.modificationDate = Date() }
        try await w.sync()
        #expect(await w.reminders.assignAttempts == 0)
    }
}
