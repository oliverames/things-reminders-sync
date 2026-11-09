import Foundation
import Testing
@testable import SyncCore

@Suite struct RemCTLRepeatBackendTests {
    private let due = DueDate(day: "2026-11-16")

    @Test func exportRowsCarryTheDecodedRuleAndIgnoreOtherKeys() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "Weekly", ["dueDate": "2026-11-10T00:00:00", "recurrence": ["frequency": "weekly", "interval": 2, "daysOfWeek": [2, 5]],
                                                     "parentID": .null, "tags": [], "flagged": false, "url": .null]))
        await fake.put(FakeRemCTL.row(2, "Odd", ["dueDate": "2026-11-10T00:00:00", "recurrence": ["frequency": "daily", "interval": 1, "setPositions": [1]]]))
        await fake.put(FakeRemCTL.row(3, "Plain"))
        let items = try await makeBackend(fake).reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(items[0].recurrence == RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4]))
        #expect(items[1].isRepeating && items[1].recurrence == nil)
        #expect(!items[2].isRepeating)
    }

    @Test func createSendsTheGrammarOrTheObject() async throws {
        let fake = FakeRemCTL()
        let b = makeBackend(fake)
        _ = try await b.create(title: "A", notes: "", due: due, completed: false, completionDate: nil, listId: "1", section: nil,
                               recurrence: RepeatRule(frequency: .monthly, interval: 2, nthWeekdays: [.init(ordinal: 4, weekday: 5)]))
        _ = try await b.create(title: "B", notes: "", due: due, completed: false, completionDate: nil, listId: "1", section: nil,
                               recurrence: RepeatRule(frequency: .monthly, monthDays: [-1]))
        let calls = await fake.calls("create_reminder")
        #expect(calls[0]["recurrence"] == "monthly x2 4th-fri")
        #expect(calls[1]["recurrence"] == .string(#"{"daysOfMonth":[-1],"frequency":"monthly","interval":1}"#))
    }

    @Test func createRefusesARuleRemCTLCannotWrite() async throws {
        let fake = FakeRemCTL()
        await #expect(throws: RemCTLError.self) {
            _ = try await makeBackend(fake).create(title: "A", notes: "", due: due, completed: false, completionDate: nil, listId: "1", section: nil,
                                                   recurrence: RepeatRule(frequency: .daily, interval: 2, afterCompletion: true))
        }
        #expect(await fake.calls("create_reminder").isEmpty)
    }

    @Test func updateSetsAndClearsTheRule() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(7, "R", ["dueDate": "2026-11-16T00:00:00", "recurrence": ["frequency": "daily", "interval": 1]]))
        let b = makeBackend(fake)
        _ = try await b.update(id: "7", patch: ReminderPatch(recurrence: .some(RepeatRule(frequency: .weekly, weekdays: [1, 4]))))
        _ = try await b.update(id: "7", patch: ReminderPatch(recurrence: .some(nil)))
        let updates = await fake.calls("update_reminder")
        #expect(updates[0]["recurrence"] == "weekly mon,thu")
        #expect(updates[1]["recurrence"] == "clear")
    }

    @Test func completingARepeatingReminderNeverSendsADate() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(6, "R", ["dueDate": "2026-11-16T00:00:00", "recurrence": ["frequency": "daily", "interval": 1]]))
        _ = try await makeBackend(fake).update(id: "6", patch: ReminderPatch(completed: true, completionDate: Date()))
        #expect(await fake.calls("set_completion").first?["completion_date"] == nil)
    }
}
