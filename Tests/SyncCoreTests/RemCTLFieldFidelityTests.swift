import Foundation
import Testing
@testable import SyncCore

// RemCTL 2.5.0 field fidelity: the export carries url, tags, flagged and subtask rows; private metadata is written
// through update_reminder with `private: true`.

@Suite struct RemCTLFieldReadingTests {
    @Test func exportRowsCarryLinkTagsFlagAndSubtasks() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "Parent", ["url": "https://example.com/a", "tags": ["Home", "Solo"], "flagged": true, "subtaskCount": 2]))
        await fake.put(FakeRemCTL.row(2, "Child one", ["isSubtask": true, "parentID": 1]))
        await fake.put(FakeRemCTL.row(3, "Child two", ["isSubtask": true, "parentID": 1, "completed": true]))
        await fake.put(FakeRemCTL.row(4, "Plain"))
        let items = try await makeBackend(fake).reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        // Subtask rows are never reminders of their own.
        #expect(items.map(\.id) == ["1", "4"])
        #expect(items[0].url == "https://example.com/a" && items[0].tags == ["Home", "Solo"] && items[0].flagged)
        #expect(items[0].subtasks == [ReminderSubtask(id: "2", title: "Child one"), ReminderSubtask(id: "3", title: "Child two", completed: true)])
        #expect(items[1].url == nil && items[1].tags == [] && !items[1].flagged && items[1].subtasks == [] && items[1].parentId == nil)
    }

    @Test func aSubtaskRowWithoutAParentIsStillNotAnItem() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "Orphan", ["isSubtask": true]))
        #expect(try await makeBackend(fake).reminders(inLists: ["1"]).isEmpty)
    }

    @Test func editingTheLinkTagsOrFlagBumpsTheStampButSubtasksDoNotNeedTo() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        await fake.put(FakeRemCTL.row(2, "B"))
        let clock = Clock()
        let backend = makeBackend(fake, clock: clock)
        let first = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        clock.advance(60)
        await fake.edit(1, "url", "https://example.com/x")
        let second = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(second[0].lastModified == clock.now() && second[1].lastModified == first[1].lastModified)
        clock.advance(60)
        await fake.edit(1, "tags", ["T"])
        #expect(try await backend.reminders(inLists: ["1"]).first { $0.id == "1" }?.lastModified == clock.now())
        clock.advance(60)
        await fake.edit(1, "flagged", true)
        #expect(try await backend.reminders(inLists: ["1"]).first { $0.id == "1" }?.lastModified == clock.now())
    }
}

@Suite struct RemCTLFieldWritingTests {
    // Reminders stores "TRS Assign" as "TRSAssign": the tag goes out in that form, once, and the read-back agrees.
    @Test func aTagWithWhitespaceIsSentWithoutItAndOnlyOnce() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let patch = ReminderPatch(tags: ["TRS Assign", "TRSAssign", "#trs assign", "Home"])
        let item = try await makeBackend(fake).update(id: "5", patch: patch)
        #expect(try #require(await fake.calls("update_reminder").first)["set_tags"] == "TRSAssign,Home")
        #expect(item.tags == ["TRSAssign", "Home"])
        #expect(RemCTLReminders.privateFieldsLanded(ReminderPatch(tags: ["TRS Assign", "Home"]), in: item))
        #expect(!RemCTLReminders.privateFieldsLanded(ReminderPatch(tags: ["TRS Assign", "Work"]), in: item))
    }

    @Test func linkFlagTagsAndSubtasksAreSentPrivately() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let item = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(
            notes: "body", url: "https://example.com/a", flagged: true, tags: ["Home", "Work"], addSubtasks: ["One", "Two"]))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(args["private"] == true && args["url"] == "https://example.com/a" && args["flagged"] == true)
        #expect(args["set_tags"] == "Home,Work" && args["clear_tags"] == nil)
        #expect(args["subtasks"] == .array(["One", "Two"]) && args["notes"] == "body")
        #expect(item.url == "https://example.com/a" && item.tags == ["Home", "Work"] && item.flagged && item.notes == "body")
    }

    @Test func assignAndUnassignAreSentPrivately() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let backend = makeBackend(fake)
        _ = try await backend.update(id: "5", patch: ReminderPatch(assignee: .some("ana@example.com")))
        _ = try await backend.update(id: "5", patch: ReminderPatch(assignee: .some(nil)))
        let calls = await fake.calls("update_reminder")
        #expect(calls.count == 2)
        #expect(calls[0]["private"] == true && calls[0]["assign"] == "ana@example.com" && calls[0]["unassign"] == nil)
        #expect(calls[1]["private"] == true && calls[1]["unassign"] == true && calls[1]["assign"] == nil)
    }

    /// Live on 2026-11-09, 5 of 7 tag writes read back stale right after the call although all had landed.
    @Test func aStaleReadAfterAPrivateWriteIsReread() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        await fake.setStaleReads(2)
        let backend = makeBackend(fake)
        await backend.setPrivateReadBackDelays([.zero, .zero, .zero])
        let item = try await backend.update(id: "5", patch: ReminderPatch(flagged: true, tags: ["Post"]))
        #expect(item.tags == ["Post"] && item.flagged)
        #expect(await fake.calls("get_reminder").count == 3)
    }

    @Test func aPlainWriteIsReadOnce() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        await fake.setStaleReads(5)
        let backend = makeBackend(fake)
        await backend.setPrivateReadBackDelays([.zero, .zero, .zero])
        _ = try await backend.update(id: "5", patch: ReminderPatch(title: "Y"))
        #expect(await fake.calls("get_reminder").count == 1)
    }

    @Test func priorityIsReadFromTheExportAndWrittenAsAPlainField() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "High", ["priority": "high"]))
        await fake.put(FakeRemCTL.row(6, "Medium", ["priority": "medium"]))
        await fake.put(FakeRemCTL.row(7, "None", ["priority": "none"]))
        await fake.put(FakeRemCTL.row(8, "Missing"))
        let backend = makeBackend(fake)
        let items = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(items.map(\.priority) == [.high, .medium, .none, .none])
        let item = try await backend.update(id: "5", patch: ReminderPatch(priority: ReminderPriority.none))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(args["priority"] == "none" && args["private"] == nil)
        #expect(item.priority == .none)
        #expect(try await backend.update(id: "8", patch: ReminderPatch(priority: .high)).priority == .high)
        // A priority change is a change the poll notices.
        var a = items[0], b = items[0]
        a.priority = .high; b.priority = .none
        #expect(RemCTLReminders.contentHash(a) != RemCTLReminders.contentHash(b))
    }

    @Test func emptyTagsClearThemAndUnflagIsSent() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X", ["tags": ["A"], "flagged": true]))
        let item = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(flagged: false, tags: []))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(args["clear_tags"] == true && args["set_tags"] == nil && args["flagged"] == false && args["private"] == true)
        #expect(item.tags == [] && !item.flagged)
    }

    @Test func plainUpdatesNeverCarryPrivateMetadata() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        _ = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(title: "Y", notes: "n"))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(Set(args.keys) == ["reminder_id", "title", "notes"])   // no private, url, tags or flag: nothing else is touched
    }

    @Test func aTagWithACommaIsRefusedBeforeAnythingIsSent() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        await #expect(throws: RemCTLError.self) { _ = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(tags: ["a,b"])) }
        #expect(await fake.calls("update_reminder").isEmpty)
    }

    @Test func aSubtaskIsCompletedRenamedAndDeletedThroughItsOwnId() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "Parent"))
        await fake.put(FakeRemCTL.row(2, "Child", ["isSubtask": true, "parentID": 1]))
        let backend = makeBackend(fake)
        _ = try await backend.update(id: "2", patch: ReminderPatch(title: "Renamed", completed: true))
        let update = try #require(await fake.calls("update_reminder").first)
        #expect(update["reminder_id"] == 2 && update["title"] == "Renamed")
        #expect(await fake.calls("set_completion").first?["reminder_id"] == 2)
        try await backend.delete(id: "2")
        #expect(await fake.calls("delete_reminder").first?["reminder_id"] == 2)
        #expect(try await backend.reminders(inLists: ["1"]).first?.subtasks == [])
    }
}
