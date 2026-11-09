import Foundation
import Testing
@testable import SyncCore

@Suite struct RemCTLSectionsTests {
    /// A backend that reads sections for list 1 ("Work"), like the coordinator sets it up.
    private func backend(_ fake: FakeRemCTL) async -> RemCTLReminders {
        let b = makeBackend(fake)
        await b.setSectionLists(["1"])
        return b
    }

    @Test func sectionsComeFromShowBecauseTheExportHasNone() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "In section", ["section": "Errands"]))
        await fake.put(FakeRemCTL.row(2, "Loose"))
        await fake.put(FakeRemCTL.row(3, "Other list", list: "Home", ["section": "Hidden"]))
        let items = try await backend(fake).reminders(inLists: ["1", "2"]).sorted { $0.id < $1.id }
        #expect(items.map(\.section) == ["Errands", nil, nil])   // Home is not a section list: no section read
        #expect(await fake.cliCalls.filter { $0.first == "show" } == [["show", "--list-id", "1", "--completed", "--json"]])
    }

    @Test func noSectionListsMeansNoShowCalls() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A", ["section": "Errands"]))
        let items = try await makeBackend(fake).reminders(inLists: ["1"])
        #expect(items[0].section == nil)
        #expect(await fake.cliCalls.allSatisfy { $0 == ["export", "--json"] })
    }

    @Test func failedShowFailsTheReadInsteadOfReportingNoSections() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A", ["section": "Errands"]))
        await fake.setFailShow(true)
        await #expect(throws: RemCTLError.self) { try await backend(fake).reminders(inLists: ["1"]) }
    }

    @Test func sectionChangeBumpsTheStamp() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        let clock = Clock()
        let b = makeBackend(fake, clock: clock)
        await b.setSectionLists(["1"])
        let first = try await b.reminders(inLists: ["1"])
        clock.advance(60)
        await fake.edit(1, "section", "Errands")
        let second = try await b.reminders(inLists: ["1"])
        #expect(second[0].section == "Errands" && second[0].lastModified == clock.now() && first[0].lastModified != clock.now())
    }

    @Test func existingSectionUsesSectionNewOneUsesNewSection() async throws {
        let fake = FakeRemCTL()
        await fake.setSections(1, ["Errands"])
        let b = await backend(fake)
        _ = try await b.create(title: "A", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: " errands ")
        _ = try await b.create(title: "B", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: "Later")
        let calls = await fake.calls("create_reminder")
        #expect(calls[0]["section"] == "Errands" && calls[0]["new_section"] == nil && calls[0]["private"] == true)
        #expect(calls[1]["new_section"] == "Later" && calls[1]["section"] == nil && calls[1]["private"] == true)
        // The section created for B is reused, not created twice, by the next reminder.
        _ = try await b.create(title: "C", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: "later")
        let third = try #require(await fake.calls("create_reminder").last)
        #expect(third["section"] == "Later" && third["new_section"] == nil)
        // No section: no private flag.
        _ = try await b.create(title: "D", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: nil)
        #expect(try #require(await fake.calls("create_reminder").last)["private"] == nil)
    }

    @Test func updateAssignsSectionAfterTheMove() async throws {
        let fake = FakeRemCTL()
        await fake.setSections(2, ["Chores"])
        await fake.put(FakeRemCTL.row(5, "X", list: "Work", ["section": "Old"]))
        let item = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(listId: "2", section: .some("Chores")))
        let calls = await fake.calls("update_reminder")
        #expect(calls.count == 2)
        #expect(calls[0]["list_id"] == 2 && calls[0]["section"] == nil)
        #expect(calls[1]["section"] == "Chores" && calls[1]["private"] == true && calls[1]["list_id"] == nil)
        #expect(item.listId == "2")
    }

    @Test func removingASectionSendsNothingAndReturnsTheItemUnchanged() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X", ["section": "Errands"]))
        let b = await backend(fake)
        let item = try await b.update(id: "5", patch: ReminderPatch(section: .some(nil)))
        #expect(await fake.calls("update_reminder").isEmpty)
        #expect(item.section == "Errands")   // how the engine notices that RemCTL cannot clear a section
    }

    @Test func groceryListsAreNeverWritten() async throws {
        let fake = FakeRemCTL()
        await fake.setLists([FakeRemCTL.list(1, "Work"), FakeRemCTL.list(3, "Groceries", groceries: true)])
        await fake.put(FakeRemCTL.row(7, "Milk", list: "Groceries", ["section": "Dairy"]))
        let b = makeBackend(fake)
        await b.setSectionLists(["3"])
        let lists = try await b.lists()
        #expect(lists.first { $0.id == "3" }?.isGroceries == true && lists.first { $0.id == "1" }?.isGroceries == false)
        // Still read, so headings can mirror the categories.
        #expect(try await b.reminders(inLists: ["3"])[0].section == "Dairy")
        _ = try await b.create(title: "Eggs", notes: "", due: nil, completed: false, completionDate: nil, listId: "3", section: "Dairy")
        _ = try await b.update(id: "7", patch: ReminderPatch(section: .some("Produce")))
        let writes = await fake.calls("create_reminder") + (await fake.calls("update_reminder"))
        #expect(writes.allSatisfy { $0["section"] == nil && $0["new_section"] == nil && $0["section_id"] == nil && $0["private"] == nil })
        #expect(await fake.calls("get_list").isEmpty)
    }

    @Test func copiedReminderCarriesTheNewId() async throws {
        // RemCTL copies a reminder moved into a shared list and answers with the new id; later calls must use it.
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X", list: "Work"))
        await fake.put(FakeRemCTL.row(55, "X", list: "Home"))
        let rerouting = Rerouting(base: fake, from: 5, to: 55)
        let b = RemCTLReminders(transport: rerouting, pollSeconds: 10, stateDirectory: tempDir())
        let item = try await b.update(id: "5", patch: ReminderPatch(title: "Y", listId: "2"))
        #expect(item.id == "55")
    }
}

/// Answers `update_reminder` for one id as RemCTL does for a copying move: new id plus `oldId`.
private struct Rerouting: RemCTLTransport {
    let base: FakeRemCTL, from: Int, to: Int
    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        if name == "update_reminder", arguments["reminder_id"]?.int == from {
            _ = try await base.callTool(name, arguments: arguments)
            return ["status": "updated", "id": .number(Double(to)), "oldId": .number(Double(from))]
        }
        return try await base.callTool(name, arguments: arguments)
    }
    func runCLI(_ arguments: [String]) async throws -> JSONValue { try await base.runCLI(arguments) }
    func serverVersion() async -> String? { nil }
    func setExecutablePath(_ path: String?) async {}
}

// Regression: with sections on, every 10 s poll ran `show` (~1.8 s) for every section list, which
// for ten lists never finished before the next poll. Polls are export-only; passes read sections
// only for lists that actually have some.
@Suite struct RemCTLSectionCostTests {
    @Test func aSectionListWithNoSectionsNeedsNoShow() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        let backend = makeBackend(fake)
        await backend.setSectionLists(["1"])
        let items = try await backend.reminders(inLists: ["1"])
        #expect(items[0].section == nil)
        #expect(await fake.cliCalls.contains(["sections", "--json"]))
        #expect(await !fake.cliCalls.contains { $0.first == "show" })
    }

    @Test func pollsNeverReadSectionsOrRestampItems() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "In section", ["section": "Errands"]))
        let clock = Clock()
        let backend = makeBackend(fake, clock: clock, poll: 0.02)
        await backend.setSectionLists(["1"])
        await backend.setWatchedLists(["1"])
        let before = try #require(try await backend.reminders(inLists: ["1"]).first)
        let showsAfterRead = await fake.cliCalls.filter { $0.first == "show" }.count
        let consumer = Task { for await _ in backend.changes() {} }
        let target = await fake.exportCount + 4
        for _ in 0..<500 where await fake.exportCount < target { try? await Task.sleep(for: .milliseconds(10)) }
        consumer.cancel()
        _ = await consumer.value
        #expect(await fake.cliCalls.filter { $0.first == "show" }.count == showsAfterRead)
        let after = try #require(try await backend.reminders(inLists: ["1"]).first)
        #expect(after.section == "Errands" && after.lastModified == before.lastModified)
    }
}
