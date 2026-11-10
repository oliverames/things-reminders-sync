import Foundation
import Testing
@testable import SyncCore

/// The deadline (`dd`) and This Evening (`sb` 1) shapes, copied from the JavaScript client (`buildTaskCreate`,
/// `updateTask` and `schedulingFields("evening")` in things3-mcp-server/src/things-client.js).
@Suite struct ThingsCloudNativeFieldTests {
    // The fake's clock is 2026-11-09 01:00 UTC.
    let today = day(2026, 11, 9)

    @Test func createWritesDeadlineAndThisEvening() async throws {
        let cloud = FakeThingsCloud()
        let client = cloud.client()
        let a = try await client.createTodo(ThingsTodoDraft(title: "pay", deadline: "2026-11-20"))
        let pa = try #require(try cloud.commitBody(0)[a]?["p"]?.object)
        #expect(pa["dd"] == .number(day(2026, 11, 20)))
        #expect(pa["st"] == 0 && pa["sb"] == 0 && pa["sr"] == .null && pa["tir"] == .null)   // the When is untouched

        let b = try await client.createTodo(ThingsTodoDraft(title: "call", when: DueDate(day: "2026-11-09", minutes: 20 * 60), evening: true))
        let pb = try #require(try cloud.commitBody(1)[b]?["p"]?.object)
        #expect(pb["st"] == 1 && pb["sb"] == 1 && pb["sr"] == .number(today) && pb["tir"] == .number(today))
        #expect(pb["ato"] == 72000 && pb["dd"] == .null)

        // This Evening belongs to today: any other day is refused before anything is sent.
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "x", when: DueDate(day: "2026-11-10", minutes: 1200), evening: true))
        }
        await #expect(throws: ThingsCloudError.self) { _ = try await client.createTodo(ThingsTodoDraft(title: "x", evening: true)) }
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "x", when: DueDate(day: "2026-11-09"), recurrence: RepeatRule(frequency: .daily), deadline: "2026-11-20"))
        }
        #expect(cloud.commits.count == 2)
    }

    @Test func updateWritesOnlyTheDeadlineOrEveningKeys() async throws {
        let onToday = ThingsID.generate(), later = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(onToday, ["tt": "a", "tp": 0, "ss": 0, "st": 1, "sb": 0, "sr": .number(today), "tir": .number(today)]),
            taskItem(later, ["tt": "b", "tp": 0, "ss": 0, "st": 2, "sb": 0, "sr": .number(day(2026, 11, 12)), "tir": .number(day(2026, 11, 12))]),
        ])
        let client = cloud.client()
        func patch(_ id: String, _ p: ThingsTodoPatch) async throws -> [String: JSONValue] {
            try await client.updateTodo(id: id, patch: p)
            return try #require(try cloud.commitBody(cloud.commits.count - 1)[id]?["p"]?.object)
        }
        let set = try await patch(later, ThingsTodoPatch(deadline: .some("2026-11-20")))
        #expect(Set(set.keys) == ["dd", "md"] && set["dd"] == .number(day(2026, 11, 20)))
        let clear = try await patch(later, ThingsTodoPatch(deadline: .some(nil)))
        #expect(Set(clear.keys) == ["dd", "md"] && clear["dd"] == .null)

        let evening = try await patch(onToday, ThingsTodoPatch(evening: true))
        #expect(Set(evening.keys) == ["st", "sb", "sr", "tir", "md"])
        #expect(evening["st"] == 1 && evening["sb"] == 1 && evening["sr"] == .number(today) && evening["tir"] == .number(today))

        // A to-do moved to today in the same patch.
        let moved = try await patch(later, ThingsTodoPatch(when: .some(DueDate(day: "2026-11-09", minutes: 19 * 60)), evening: true))
        #expect(moved["st"] == 1 && moved["sb"] == 1 && moved["sr"] == .number(today) && moved["tir"] == .number(today) && moved["ato"] == 68400)

        let before = cloud.commits.count
        let other = ThingsID.generate()
        cloud.items.append(taskItem(other, ["tt": "c", "tp": 0, "ss": 0, "st": 2, "sr": .number(day(2026, 11, 12)), "tir": .number(day(2026, 11, 12))]))
        cloud.head = cloud.items.count + 10
        await #expect(throws: ThingsCloudError.self) { try await client.updateTodo(id: other, patch: ThingsTodoPatch(evening: true)) }
        await #expect(throws: ThingsCloudError.self) {
            try await client.updateTodo(id: other, patch: ThingsTodoPatch(when: .some(DueDate(day: "2026-11-10")), evening: true))
        }
        #expect(cloud.commits.count == before)
        // `evening: false` writes nothing of its own.
        let off = try await patch(onToday, ThingsTodoPatch(title: "t", evening: false))
        #expect(Set(off.keys) == ["tt", "md"])
    }
}
