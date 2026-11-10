import Foundation
import Testing
@testable import SyncCore

/// Audit finding M8: a field both sides changed goes to the side that changed THAT field later.
@Suite("Per-field conflict resolution") struct PerFieldConflictTests {
    /// Minutes after 10:00 on some day.
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_794_000_000 + minutes * 60) }

    private func linkedPair() async throws -> (World, String) {
        var w = World()
        await w.things.add(projectTask("P1"))
        await w.things.add(todo("t1", "Task", project: "P1", notes: "a", startDate: day(1)))
        try await w.sync()
        return (w, w.links.links[0].reminderId)
    }

    @Test func crossEditsResolveEachFieldToItsOwnLaterEdit() async throws {
        var (w, rid) = try await linkedPair()
        // Reminders: title and notes at 10:00, due at 10:06. Things: due at 10:01, title at 10:05.
        // One time per item would give Reminders (10:06) the title as well, although Things renamed it later.
        await w.reminders.edit(rid) {
            $0.title = "R title"; $0.notes = "R notes"; $0.due = DueDate(day: day(5))
            $0.lastModified = at(6)
            $0.fieldModified = [SyncField.title.rawValue: at(0), SyncField.notes.rawValue: at(0), SyncField.due.rawValue: at(6)]
        }
        await w.things.edit("t1") {
            $0.title = "T title"; $0.startDate = day(3)
            $0.modificationDate = at(5)
            $0.fieldModified = [SyncField.due.rawValue: at(1), SyncField.title.rawValue: at(5), SyncField.notes.rawValue: at(-60)]
        }
        let report = try await w.sync()
        let t = try #require(await w.things.task("t1"))
        let r = try #require(await w.reminders.item(rid))
        #expect(t.title == "T title" && r.title == "T title")                       // Things renamed later
        #expect(t.startDate == day(5) && r.due == DueDate(day: day(5)))             // Reminders rescheduled later
        #expect(t.notes == "R notes" && r.notes == "R notes")                       // only Reminders touched the notes
        #expect(report.log.filter { $0.level == .warning }.count == 2)             // title and due date were conflicts
        #expect(try await w.sync().changeCount == 0)
    }

    @Test func aFieldChangedOnOneSideStillGoesAcrossWhateverTheTimesSay() async throws {
        var (w, rid) = try await linkedPair()
        // Things moved the date long ago; the reminder was renamed just now. Neither field is a conflict.
        await w.things.edit("t1") {
            $0.startDate = day(4); $0.modificationDate = at(0)
            $0.fieldModified = [SyncField.due.rawValue: at(0)]
        }
        await w.reminders.edit(rid) {
            $0.title = "Renamed"; $0.lastModified = at(30)
            $0.fieldModified = [SyncField.title.rawValue: at(30), SyncField.due.rawValue: at(20)]
        }
        let report = try await w.sync()
        #expect(await w.reminders.item(rid)?.due == DueDate(day: day(4)))
        #expect(await w.things.task("t1")?.title == "Renamed")
        #expect(!report.log.contains { $0.level == .warning })
    }

    @Test func withoutFieldTimesTheItemTimeDecides() {
        let r = ReminderItem(id: "1", listId: "L", title: "x", lastModified: at(3))
        let t = ThingsTask(id: "t", title: "x", creationDate: at(1), modificationDate: at(2))
        #expect(r.modified(.title) == at(3) && t.modified(.due) == at(2))
        #expect(ThingsTask(id: "t", title: "x", creationDate: at(1)).modified(.notes) == at(1))
        // Things keeps the flag as a tag and the link in the notes.
        var tagged = t
        tagged.fieldModified = [SyncField.tags.rawValue: at(7), SyncField.notes.rawValue: at(8)]
        #expect(tagged.modified(.flagged) == at(7) && tagged.modified(.url) == at(8))
    }

    // MARK: Things: times from history

    @Test func thingsFieldKeepsItsOlderTimeWhenLaterItemsLeaveItAlone() async throws {
        let id = ThingsID.generate(), check = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(id, ["tt": "Task", "tp": 0, "nt": ["_t": "tx", "t": 1, "v": "notes"], "cd": 100, "md": 100]),
            taskItem(id, ["tt": "Renamed", "md": 200], t: 1),
            taskItem(id, ["sr": .number(day(2026, 11, 12)), "md": 300], t: 1),
            // A key repeated with the value the to-do already has is not an edit of that field.
            taskItem(id, ["tt": "Renamed", "ss": 3, "sp": 400, "md": 400], t: 1),
        ])
        var task = try #require(try await cloud.client().refresh().snapshot.tasks[id])
        #expect(task.modificationDate == Date(timeIntervalSince1970: 400))
        #expect(task.modified(.title) == Date(timeIntervalSince1970: 200))
        #expect(task.modified(.notes) == Date(timeIntervalSince1970: 100))
        #expect(task.modified(.due) == Date(timeIntervalSince1970: 300))
        #expect(task.modified(.completion) == Date(timeIntervalSince1970: 400))
        #expect(task.modified(.tags) == Date(timeIntervalSince1970: 100))
        // A checklist item's own `md` is the checklist's time and moves no other field.
        cloud.items.append(taskItem(check, ["tt": "Step", "ss": 0, "ix": 0, "ts": .array([.string(id)]), "cd": 500, "md": 500],
                                    entity: "ChecklistItem3"))
        cloud.head = cloud.items.count
        task = try #require(try await cloud.client().refresh().snapshot.tasks[id])
        #expect(task.modified(.checklist) == Date(timeIntervalSince1970: 500))
        #expect(task.modified(.title) == Date(timeIntervalSince1970: 200))
    }

    // MARK: Reminders: times from observation

    @Test func remindersStampsOnlyTheFieldThatChanged() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A", ["notes": "n"]))
        let clock = Clock()
        let backend = makeBackend(fake, clock: clock)
        let t0 = clock.now()
        _ = try await backend.reminders(inLists: ["1"])
        clock.advance(60)
        await fake.edit(1, "notes", "n2")
        _ = try await backend.reminders(inLists: ["1"])
        let t1 = clock.now()
        clock.advance(60)
        await fake.edit(1, "dueDate", "2026-11-12T00:00:00")
        let item = try #require(try await backend.reminders(inLists: ["1"]).first)
        #expect(item.modified(.title) == t0)
        #expect(item.modified(.notes) == t1)
        #expect(item.modified(.due) == clock.now())
        #expect(item.lastModified == clock.now())
    }

    @Test func observedFileFromBeforePerFieldStampsStillDecodes() async throws {
        // The old shape itself: one hash and one stamp per reminder.
        let old = try JSONDecoder().decode([String: RemCTLReminders.Observed].self, from: Data(#"{"1":{"hash":"abc","stamp":500}}"#.utf8))
        #expect(old["1"]?.fields == nil && old["1"]?.hash == "abc")

        // A real file with the per-field part removed is what an upgrade finds on disk.
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A", ["notes": "n"]))
        let dir = tempDir(), clock = Clock()
        let seeded = clock.now()
        _ = try await makeBackend(fake, dir: dir, clock: clock).reminders(inLists: ["1"])
        let url = dir.appendingPathComponent("remctl-observed.json")
        var file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
        #expect(file["1"]?["fields"] != nil)
        file["1"]?["fields"] = nil
        try JSONSerialization.data(withJSONObject: file).write(to: url)

        // Every field starts from the reminder's one stamp, not from "now".
        clock.advance(500)
        let upgraded = try #require(try await makeBackend(fake, dir: dir, clock: clock).reminders(inLists: ["1"]).first)
        #expect(upgraded.lastModified == seeded)
        #expect(SyncField.allCases.allSatisfy { upgraded.modified($0) == seeded })

        // From there on a change stamps its own field only.
        clock.advance(500)
        await fake.edit(1, "title", "A2")
        let edited = try #require(try await makeBackend(fake, dir: dir, clock: clock).reminders(inLists: ["1"]).first)
        #expect(edited.modified(.title) == clock.now() && edited.modified(.notes) == seeded)
    }
}
