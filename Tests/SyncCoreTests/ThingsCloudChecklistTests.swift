import Foundation
import Testing
@testable import SyncCore

@Suite("Things client checklists") struct ThingsCloudChecklistTests {
    private func item(_ id: String, task: String, _ title: String, ss: Int = 0, ix: Double, sp: Double? = nil, t: Int = 0) -> JSONValue {
        taskItem(id, ["tt": .string(title), "ss": .number(Double(ss)), "sp": sp.map { .number($0) } ?? .null, "ix": .number(ix),
                      "ts": .array([.string(task)]), "lt": false, "cd": 1_794_000_000, "md": 1_794_000_000,
                      "xx": ["_t": "oo", "sn": [:]]], entity: "ChecklistItem3", t: t)
    }

    @Test func readsChecklistItemsInIxOrderEvenWhenWritesAreOff() async throws {
        let task = ThingsID.generate(), a = ThingsID.generate(), b = ThingsID.generate(), c = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(task, ["tt": "Parent", "tp": 0]),
            item(c, task: task, "Gamma", ix: 0), item(a, task: task, "Alpha", ix: -518), item(b, task: task, "Beta", ss: 3, ix: -310, sp: 1_794_100_000),
        ])
        let snapshot = try await cloud.client().refresh().snapshot
        let list = try #require(snapshot.tasks[task]?.checklist)
        #expect(list.map(\.title) == ["Alpha", "Beta", "Gamma"])
        #expect(list.map(\.completed) == [false, true, false])
        // An item that is deleted later disappears; an update merges.
        cloud.items.append(item(b, task: task, "", ix: 0, t: 2))
        cloud.items.append(taskItem(a, ["tt": "Alpha 2", "ss": 3], entity: "ChecklistItem3", t: 1))
        cloud.head = cloud.items.count
        let again = try await cloud.client().refresh().snapshot.tasks[task]?.checklist
        #expect(again?.map(\.title) == ["Alpha 2", "Gamma"] && again?.first?.completed == true)
    }

    @Test func createWithChecklistWritesEveryItemInTheSameCommit() async throws {
        let cloud = FakeThingsCloud(head: 0)
        let id = try await cloud.client().createTodo(ThingsTodoDraft(title: "T", checklist: [
            ThingsChecklistDraft(title: "One"), ThingsChecklistDraft(title: "Two", completed: true)]))
        let body = try cloud.commitBody()
        #expect(body.count == 3)
        let items = body.filter { $0.value["e"] == "ChecklistItem3" }.values.compactMap { $0["p"]?.object }.sorted { ($0["ix"]?.double ?? 0) < ($1["ix"]?.double ?? 0) }
        #expect(items.count == 2)
        // The keys Things 3.24.2 writes, with the parent in `ts`.
        #expect(Set(items[0].keys) == ["tt", "ss", "sp", "ix", "ts", "lt", "cd", "md", "xx"])
        #expect(items[0]["tt"] == "One" && items[0]["ss"] == 0 && items[0]["sp"] == .null && items[0]["ts"] == .array([.string(id)]))
        #expect(items[1]["ss"] == 3 && items[1]["sp"] != .null && (items[1]["ix"]?.double ?? 0) > (items[0]["ix"]?.double ?? 0))
        #expect(body.values.allSatisfy { $0["t"] == 0 })
    }

    @Test func addRenameCompleteAndDeleteShapes() async throws {
        let task = ThingsID.generate(), a = ThingsID.generate(), b = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(task, ["tt": "Parent", "tp": 0]), item(a, task: task, "Alpha", ix: 0), item(b, task: task, "Beta", ix: 5),
        ])
        let client = cloud.client()
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(checklist: [
            .add(title: "Gamma", completed: false), .rename(id: a, title: "Alpha!"), .setCompleted(id: a, completed: true), .delete(id: b),
        ]))
        let body = try cloud.commitBody()
        #expect(body[task]?["t"] == 1 && body[task]?["e"] == "Task6" && body[task]?["p"]?["md"] != nil)
        // `a` is renamed and completed in one entry per id.
        let aEntry = try #require(body[a]?.object)
        #expect(aEntry["t"] == 1 && aEntry["e"] == "ChecklistItem3")
        let ap = try #require(aEntry["p"]?.object)
        #expect(ap["tt"] == "Alpha!" && ap["ss"] == 3 && ap["sp"] != .null && ap["md"] != nil)
        #expect(body[b]?["t"] == 2 && body[b]?["e"] == "ChecklistItem3")
        let created = body.filter { $0.value["t"] == 0 }.values
        #expect(created.count == 1 && created.first?["p"]?["tt"] == "Gamma" && created.first?["p"]?["ix"] == 6)
    }

    @Test func renameAndUncompleteAreIndividualEntries() async throws {
        let task = ThingsID.generate(), a = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(task, ["tt": "Parent", "tp": 0]), item(a, task: task, "Alpha", ss: 3, ix: 0, sp: 1_794_100_000)])
        let client = cloud.client()
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(checklist: [.rename(id: a, title: "Renamed")]))
        #expect(try cloud.commitBody(0)[a]?["p"]?["tt"] == "Renamed")
        try await client.updateTodo(id: task, patch: ThingsTodoPatch(checklist: [.setCompleted(id: a, completed: false)]))
        let p = try #require(try cloud.commitBody(1)[a]?["p"]?.object)
        #expect(p["ss"] == 0 && p["sp"] == .null)
        // And the local database reflects both.
        let item = try await client.refresh().snapshot.tasks[task]?.checklist.first
        #expect(item?.title == "Renamed" && item?.completed == false)
    }

    @Test func anUnknownItemIsRefusedBeforeAnythingIsSent() async throws {
        let task = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(task, ["tt": "Parent", "tp": 0])])
        await #expect(throws: ThingsCloudError.self) {
            try await cloud.client().updateTodo(id: task, patch: ThingsTodoPatch(checklist: [.delete(id: ThingsID.generate())]))
        }
        #expect(cloud.commits.isEmpty)
    }

    @Test func theValidatorChecksEveryNewChecklistKey() throws {
        let task = ThingsID.generate()
        let good = ThingsChanges.checklistCreate(taskId: task, title: "x", completed: false, index: 0, now: Date(timeIntervalSince1970: 1_794_000_000))
        try ThingsChangeValidator.validate([ThingsID.generate(): good])
        func rejects(_ edit: (inout ThingsChange) -> Void) {
            var bad = good
            edit(&bad)
            #expect(throws: ThingsCloudError.self) { try ThingsChangeValidator.validate([ThingsID.generate(): bad]) }
        }
        rejects { $0.p["ts"] = ["not-an-id"] }                              // parent id
        rejects { $0.p["ts"] = .array([.string(task), .string(task)]) }     // exactly one parent
        rejects { $0.p["ts"] = [] }
        rejects { $0.p["sp"] = .number(1e12) }                              // milliseconds
        rejects { $0.p["md"] = .number(-1) }
        rejects { $0.p["ss"] = 1 }                                          // not a Things status
        rejects { $0.p["ix"] = .string("0") }
        rejects { $0.p["tt"] = 5 }
    }
}
