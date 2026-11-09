import Foundation
import Testing
@testable import SyncCore

@Suite("ThingsCloud templates")
struct ThingsCloudTemplateTests {
    private let rule = RepeatRule(frequency: .weekly, weekdays: [1])

    @Test func templateCreateWritesTheObservedKeysAndNoOccurrence() async throws {
        let project = ThingsID.generate()
        let cloud = FakeThingsCloud(head: 10)
        let client = cloud.client()
        // A plain create gives the reference key set (every key the app writes for a to-do).
        let plainId = try await client.createTodo(ThingsTodoDraft(title: "plain", placement: .project(project)))
        let plainKeys = Set(try #require(try cloud.commitBody(0)[plainId]?["p"]?.object).keys)

        let id = try await client.createTodo(ThingsTodoDraft(title: "Water plants", notes: "n", when: DueDate(day: "2026-11-16", minutes: 540),
                                                              placement: .project(project), recurrence: rule))
        let body = try cloud.commitBody(1)
        #expect(body.count == 1, "exactly one entity: the template, never an occurrence")
        let change = try #require(body[id]?.object)
        #expect(change["t"] == 0 && change["e"] == "Task6")
        let p = try #require(change["p"]?.object)
        #expect(Set(p.keys) == plainKeys)
        let monday = 1_794_787_200.0   // 2026-11-16
        #expect(p["rr"] == ThingsRepeat.rr(for: rule, start: "2026-11-16"))
        #expect(p["st"] == 2 && p["sr"] == .null && p["sb"] == 0)
        #expect(p["tir"] == .number(monday) && p["icsd"] == .number(monday))
        #expect(p["icc"] == 0)
        #expect(p["ato"] == 32400)
        #expect(p["tp"] == 0 && p["ss"] == 0 && p["rt"] == [])
        #expect(p["pr"] == [.string(project)])
        #expect(p["tt"] == "Water plants")
    }

    @Test func allDayTemplateHasNoReminderTime() async throws {
        let cloud = FakeThingsCloud()
        let id = try await cloud.client().createTodo(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-16"), recurrence: rule))
        #expect(try cloud.commitBody()[id]?["p"]?["ato"] == .null)
    }

    @Test func aRuleWithoutAVerifiedShapeOrDayIsRefusedBeforeAnythingIsSent() async throws {
        let cloud = FakeThingsCloud()
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-16"), recurrence: RepeatRule(frequency: .yearly, monthDays: [1])))
        }
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "t", recurrence: RepeatRule(frequency: .daily)))
        }
        #expect(cloud.commits.isEmpty)
    }

    @Test func ruleRewriteKeepsAnchorsAndTouchesNothingElse() async throws {
        let tpl = ThingsID.generate()
        let old = JSONValue.object(["fu": 256, "fa": 2, "of": [["wd": 1]], "tp": 0, "ia": .number(1_794_182_400), "sr": .number(1_794_182_400),
                                    "rc": 0, "ts": 0, "rrv": 4, "ed": .number(ThingsRepeat.farFuture)])
        let item = taskItem(tpl, ["tt": "t", "tp": 0, "ss": 0, "tr": false, "rr": old, "tir": .number(1_794_787_200), "icsd": .number(1_794_787_200), "icc": 0])
        let cloud = FakeThingsCloud(items: [item])
        let client = cloud.client()
        _ = try await client.refresh()
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4])))
        let p = try #require(try cloud.commitBody()[tpl]?["p"]?.object)
        let rr = try #require(p["rr"]?.object)
        #expect(rr["ia"] == .number(1_794_182_400) && rr["sr"] == .number(1_794_182_400))   // anchors preserved
        #expect(rr["of"] == [["wd": 1], ["wd": 4]])
        #expect(Set(p.keys) == ["md", "rr"])   // tir/icsd untouched
    }

    @Test func templateNextMovesOnlyTheNextDayKeys() async throws {
        let tpl = ThingsID.generate()
        let rr = try #require(ThingsRepeat.rr(for: rule, start: "2026-11-09"))
        let cloud = FakeThingsCloud(items: [taskItem(tpl, ["tt": "t", "tp": 0, "ss": 0, "tr": false, "rr": rr])])
        let client = cloud.client()
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(templateNext: DueDate(day: "2026-11-23", minutes: 60)))
        let p = try #require(try cloud.commitBody()[tpl]?["p"]?.object)
        #expect(Set(p.keys) == ["md", "tir", "icsd", "ato"])
        #expect(p["tir"] == .number(1_795_392_000) && p["icsd"] == .number(1_795_392_000) && p["ato"] == 3600)
    }

    @Test func rulePatchOnAPlainTodoIsRefused() async throws {
        let id = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(id, ["tt": "t", "tp": 0, "ss": 0, "tr": false])])
        await #expect(throws: ThingsCloudError.self) {
            try await cloud.client().updateTodo(id: id, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .daily)))
        }
        #expect(cloud.commits.isEmpty)
    }

    @Test func databaseDecodesTemplatesAndOccurrences() throws {
        let tpl = ThingsID.generate(), occ = ThingsID.generate()
        var db = ThingsDatabase()
        db.apply([
            tpl: ThingsChange(t: 0, e: "Task7", p: ["tt": "T", "rr": try #require(ThingsRepeat.rr(for: rule, start: "2026-11-09")), "st": 2,
                                                     "tir": .number(1_794_787_200), "icsd": .number(1_794_787_200), "icc": 3, "ato": 32400]),
            occ: ThingsChange(t: 0, e: "Task7", p: ["tt": "T", "rt": [.string(tpl)], "sr": .number(1_794_182_400)]),
        ])
        let t = try #require(db.snapshot.tasks[tpl]), o = try #require(db.snapshot.tasks[occ])
        #expect(t.isTemplate && !t.isOccurrence && t.recurrence == rule)
        #expect(t.nextDay == "2026-11-16" && t.instanceDay == "2026-11-16" && t.instancesCreated == 3 && t.reminderSeconds == 32400)
        #expect(o.isOccurrence && !o.isTemplate && o.templateId == tpl && o.recurrence == nil)
    }
}
