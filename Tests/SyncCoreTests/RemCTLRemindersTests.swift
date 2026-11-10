import Foundation
import Testing
@testable import SyncCore

// MARK: - Fakes

/// In-memory stand-in for RemCTL. Rows are what `get_reminder` and the export return.
actor FakeRemCTL: RemCTLTransport {
    var lists: [JSONValue] = [FakeRemCTL.list(1, "Work"), FakeRemCTL.list(2, "Home")]
    var rows: [Int: JSONValue] = [:]
    private(set) var calls: [(tool: String, args: [String: JSONValue])] = []
    private(set) var exportCount = 0
    var failLists: RemCTLError?
    private var nextId = 100
    /// Sections per list id, as `get_list` reports them.
    var listSections: [Int: [String]] = [:]
    private(set) var cliCalls: [[String]] = []
    var failShow = false
    /// How many `get_reminder` calls after an `update_reminder` still return the row as it was before the update
    /// (private ReminderKit writes land a moment after the call returns).
    var staleReads = 0
    private var beforeUpdate: [Int: JSONValue] = [:]
    func setStaleReads(_ n: Int) { staleReads = n }

    static func list(_ id: Int, _ title: String, group: Bool = false, groceries: Bool = false) -> JSONValue {
        ["id": .number(Double(id)), "title": .string(title), "isGroup": .bool(group), "isGroceries": .bool(groceries),
         "color": ["hex": "#FF9500"]]
    }

    func setSections(_ list: Int, _ names: [String]) { listSections[list] = names }
    func setFailShow(_ v: Bool) { failShow = v }

    /// Applies the section arguments of `create_reminder` / `update_reminder` to a row.
    private func applySection(_ id: Int, _ arguments: [String: JSONValue], list: Int?) {
        let listId = list ?? lists.first { $0["title"]?.string == rows[id]?["list"]?.string }?["id"]?.int ?? 0
        if let name = arguments["new_section"]?.string {
            listSections[listId, default: []].append(name)
            edit(id, "section", .string(name))
        } else if let name = arguments["section"]?.string {
            edit(id, "section", .string(name))
        } else if let sectionId = arguments["section_id"]?.string {
            edit(id, "section", .string(sectionId))
        }
    }

    static func row(_ id: Int, _ title: String, list: String = "Work", _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .number(Double(id)), "title": .string(title), "list": .string(list),
                                      "completed": false, "isSubtask": false, "allDay": true,
                                      "deepLink": .string("x-apple-reminderkit://\(id)")]
        o.merge(extra) { $1 }
        return .object(o)
    }

    func put(_ row: JSONValue) { rows[row["id"]!.int!] = row }
    /// The list id of rows whose list title is shared by several lists (a real row only carries the title).
    private var rowLists: [Int: Int] = [:]
    func put(_ row: JSONValue, listId: Int) { put(row); rowLists[row["id"]!.int!] = listId }
    private func listId(ofRow id: Int) -> Int? {
        rowLists[id] ?? lists.first { $0["title"]?.string == rows[id]?["list"]?.string }?["id"]?.int
    }
    /// Scripted lost answers: the next call of the tool throws `.uncertain`, after doing the write when `lands`.
    private var uncertain: [String: Bool] = [:]
    func loseAnswer(of tool: String, lands: Bool) { uncertain[tool] = lands }
    var failGetReminder = false
    func setFailGetReminder(_ v: Bool) { failGetReminder = v }
    func setLists(_ l: [JSONValue]) { lists = l }
    func removeRow(_ id: Int) { rows[id] = nil }
    func setFailLists(_ e: RemCTLError?) { failLists = e }
    func calls(_ tool: String) -> [[String: JSONValue]] { calls.filter { $0.tool == tool }.map(\.args) }
    func edit(_ id: Int, _ key: String, _ value: JSONValue) {
        guard case .object(var o) = rows[id] else { return }
        o[key] = value; rows[id] = .object(o)
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((name, arguments))
        if let lands = uncertain.removeValue(forKey: name) {
            if lands { _ = try await perform(name, arguments) }
            throw RemCTLError.uncertain("RemCTL did not confirm \(name)")
        }
        return try await perform(name, arguments)
    }

    private func perform(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "lists":
            if let failLists { throw failLists }
            return ["items": .array(lists), "count": .number(Double(lists.count))]
        case "create_reminder":
            nextId += 1
            let listTitle = lists.first { $0["id"]?.int == arguments["list_id"]?.int }?["title"]?.string ?? "Work"
            var extra: [String: JSONValue] = [:]
            if let n = arguments["notes"] { extra["notes"] = n }
            put(Self.row(nextId, arguments["title"]?.string ?? "", list: listTitle, extra))
            applySection(nextId, arguments, list: arguments["list_id"]?.int)
            return ["status": "created", "id": .number(Double(nextId))]
        case "update_reminder":
            let id = arguments["reminder_id"]!.int!
            beforeUpdate[id] = rows[id]
            if let t = arguments["title"] { edit(id, "title", t) }
            if let n = arguments["notes"] { edit(id, "notes", n) }
            if let p = arguments["priority"] { edit(id, "priority", p) }
            // Private metadata: only honoured with `private: true`, like RemCTL (without it a url would land in the notes).
            if arguments["private"] == true {
                if let u = arguments["url"] { edit(id, "url", u) }
                if let f = arguments["flagged"] { edit(id, "flagged", f) }
                if let tags = arguments["set_tags"]?.string { edit(id, "tags", .array(tags.split(separator: ",").map { .string(String($0)) })) }
                if arguments["clear_tags"] == true { edit(id, "tags", []) }
                for title in arguments["subtasks"]?.array?.compactMap(\.string) ?? [] {
                    nextId += 1
                    put(Self.row(nextId, title, list: rows[id]?["list"]?.string ?? "Work", ["isSubtask": true, "parentID": .number(Double(id))]))
                }
            }
            if let l = arguments["list_id"]?.int, let title = lists.first(where: { $0["id"]?.int == l })?["title"] {
                edit(id, "list", title)
                if rowLists[id] != nil { rowLists[id] = l }
            }
            applySection(id, arguments, list: nil)
            return ["status": "updated", "id": .number(Double(id))]
        case "set_completion":
            let id = arguments["reminder_id"]!.int!
            edit(id, "completed", arguments["completed"] ?? false)
            return ["status": "completed", "id": .number(Double(id))]
        case "get_list":
            let id = arguments["list_id"]?.int ?? 0
            let sections = (listSections[id] ?? []).map { JSONValue.object(["id": .string("S-\($0)"), "name": .string($0)]) }
            return ["id": .number(Double(id)), "sections": .array(sections)]
        case "get_reminder":
            if failGetReminder { throw RemCTLError.tool("get_reminder failed") }
            if staleReads > 0, let old = beforeUpdate[arguments["reminder_id"]?.int ?? 0] { staleReads -= 1; return old }
            guard let row = rows[arguments["reminder_id"]?.int ?? 0] else { throw RemCTLError.tool("Error: #\(arguments["reminder_id"]?.int ?? 0) not found") }
            return row
        case "delete_reminder":
            guard let id = arguments["reminder_id"]?.int, rows[id] != nil else { throw RemCTLError.tool("Error: not found") }
            rows[id] = nil
            return ["status": "deleted"]
        default:
            throw RemCTLError.tool("unexpected tool \(name)")
        }
    }

    func runCLI(_ arguments: [String]) async throws -> JSONValue {
        cliCalls.append(arguments)
        if arguments.first == "show" {
            // ["show", "--list-id", id, "--completed", "--json"]: rows of one list, with their sections.
            if failShow { throw RemCTLError.tool("show failed") }
            guard arguments.count == 5, let id = Int(arguments[2]),
                  lists.contains(where: { $0["id"]?.int == id }) else { throw RemCTLError.tool("unexpected cli \(arguments)") }
            return .array(rows.keys.sorted().filter { listId(ofRow: $0) == id }.compactMap { rows[$0] })
        }
        if arguments.first == "section-delete" {
            // ["section-delete", NAME, "--list-id", id, "--force", "--private", "--json"]
            guard arguments.count == 7, let id = Int(arguments[3]), arguments[4...] == ["--force", "--private", "--json"] else {
                throw RemCTLError.tool("unexpected cli \(arguments)")
            }
            guard listSections[id]?.contains(arguments[1]) == true else { throw RemCTLError.tool("Error: section not found") }
            listSections[id]?.removeAll { $0 == arguments[1] }
            return ["status": "deleted"]
        }
        if arguments == ["sections", "--json"] {
            // Like the real command: list title -> section names (strings), only for lists that have sections.
            var byList: [String: [JSONValue]] = [:]
            for row in rows.values {
                if let list = row["list"]?.string, let name = row["section"]?.string, !name.isEmpty {
                    byList[list, default: []].append(.string(name))
                }
            }
            return .object(byList.mapValues { .array($0) })
        }
        // ["export", "--list-id", id, "--json"]: the rows of one list, which is how a shared list title is told apart.
        var only: Int?
        if arguments.count == 4, arguments[0] == "export", arguments[1] == "--list-id", arguments[3] == "--json", let id = Int(arguments[2]) {
            if failListExport { throw RemCTLError.tool("export failed") }
            only = id
        } else {
            guard arguments == ["export", "--json"] else { throw RemCTLError.tool("unexpected cli \(arguments)") }
            exportCount += 1
        }
        // Like the real export, rows carry no `section`.
        return .array(rows.keys.sorted().filter { only == nil || listId(ofRow: $0) == only }.map { key in
            guard case .object(var o) = rows[key]! else { return rows[key]! }
            o["section"] = nil
            return .object(o)
        })
    }

    var failListExport = false
    func setFailListExport(_ v: Bool) { failListExport = v }

    func serverVersion() async -> String? { "2.5.0" }
    func setExecutablePath(_ path: String?) async {}
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var t = 1_000.0
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: t) }
    func advance(_ s: Double) { lock.lock(); t += s; lock.unlock() }
}

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("remctl-tests-\(UUID().uuidString)", isDirectory: true)
}

func makeBackend(_ fake: FakeRemCTL, dir: URL = tempDir(), clock: Clock = Clock(), poll: Double = 10) -> RemCTLReminders {
    RemCTLReminders(transport: fake, pollSeconds: poll, stateDirectory: dir, clock: { clock.now() })
}

// MARK: - Reading

@Suite struct RemCTLReadingTests {
    @Test func parsesExportRows() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "All day", ["dueDate": "2026-11-09T00:00:00", "allDay": true]))
        await fake.put(FakeRemCTL.row(2, "Timed", ["dueDate": "2026-11-09T09:30:00", "allDay": false, "notes": "n"]))
        await fake.put(FakeRemCTL.row(3, "Done", ["completed": true, "completionDate": "2026-10-15T15:58:16.078038"]))
        await fake.put(FakeRemCTL.row(4, "Repeats", ["dueDate": "2026-11-09T08:00:00", "allDay": false, "recurrence": ["frequency": "daily", "interval": 1]]))
        await fake.put(FakeRemCTL.row(5, "Child", ["isSubtask": true]))
        await fake.put(FakeRemCTL.row(6, "Other list", list: "Home"))
        await fake.put(FakeRemCTL.row(7, "Unknown list", list: "Nowhere"))
        let backend = makeBackend(fake)

        let items = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(items.map(\.id) == ["1", "2", "3", "4"])
        #expect(items[0].due == DueDate(day: "2026-11-09", minutes: nil))
        #expect(items[1].due == DueDate(day: "2026-11-09", minutes: 9 * 60 + 30))
        #expect(items[1].notes == "n")
        #expect(items[2].completed)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try #require(items[2].completionDate))
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 10, 15, 15, 58, 16])
        #expect(items[3].isRepeating && !items[0].isRepeating)
        #expect(items.allSatisfy { $0.listId == "1" && $0.lastModified != nil })
        #expect(items[0].externalId == "x-apple-reminderkit://1")
        // One export call serves any number of lists.
        #expect(try await backend.reminders(inLists: ["1", "2"]).count == 5)
    }

    @Test func listsSkipGroupsAndKeepColor() async throws {
        let fake = FakeRemCTL()
        await fake.setLists([FakeRemCTL.list(1, "Work"), FakeRemCTL.list(9, "Group", group: true)])
        let lists = try await makeBackend(fake).lists()
        #expect(lists == [ReminderList(id: "1", title: "Work", colorHex: "#FF9500", allowsModifications: true)])
    }

    /// H2: a second list with the same title used to make every reminder of both lists vanish from the read, which
    /// the engine then took for deletions. Rows are placed by list id instead.
    @Test func listsSharingATitleAreReadByListId() async throws {
        let fake = FakeRemCTL()
        await fake.setLists([FakeRemCTL.list(1, "Same"), FakeRemCTL.list(2, "Same"), FakeRemCTL.list(3, "Solo")])
        await fake.put(FakeRemCTL.row(1, "Mine", list: "Same"), listId: 1)
        await fake.put(FakeRemCTL.row(4, "Theirs", list: "Same"), listId: 2)
        await fake.put(FakeRemCTL.row(2, "Fine", list: "Solo"))
        let backend = makeBackend(fake)
        let items = try await backend.reminders(inLists: ["1", "2", "3"]).sorted { $0.id < $1.id }
        #expect(items.map(\.title) == ["Mine", "Fine", "Theirs"])
        #expect(items.map(\.listId) == ["1", "3", "2"])
        #expect(try await backend.reminders(inLists: ["1"]).map(\.title) == ["Mine"])
        // A write on a reminder in such a list still knows its list afterwards.
        let renamed = try await backend.update(id: "1", patch: ReminderPatch(title: "Mine too"))
        #expect(renamed.listId == "1" && renamed.title == "Mine too")
    }

    /// H2: when the rows of a shared title cannot be placed, the read fails. It never returns the list as empty.
    @Test func aSharedTitleThatCannotBeResolvedFailsTheRead() async throws {
        let fake = FakeRemCTL()
        await fake.setLists([FakeRemCTL.list(1, "Same"), FakeRemCTL.list(2, "Same")])
        await fake.put(FakeRemCTL.row(1, "Mine", list: "Same"), listId: 1)
        await fake.setFailListExport(true)
        let backend = makeBackend(fake)
        await #expect(throws: RemCTLError.self) { try await backend.reminders(inLists: ["1"]) }
    }

    /// M3: an all-day due with an alert that day shows as "Nov 12, 9:00 AM" in Reminders (RemCTL `displayDate`).
    @Test func displayDateOnTheDueDayIsReadAsTheTime() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "Alert that day", ["dueDate": "2026-11-12T00:00:00", "allDay": true, "displayDate": "2026-11-12T09:00:00"]))
        await fake.put(FakeRemCTL.row(2, "Alert the day before", ["dueDate": "2026-11-12T00:00:00", "allDay": true, "displayDate": "2026-11-11T18:00:00"]))
        await fake.put(FakeRemCTL.row(3, "Timed", ["dueDate": "2026-11-12T10:00:00", "allDay": false, "displayDate": "2026-11-12T09:45:00"]))
        let items = try await makeBackend(fake).reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(items[0].due == DueDate(day: "2026-11-12", minutes: 9 * 60))
        #expect(items[1].due == DueDate(day: "2026-11-12"))
        #expect(items[2].due == DueDate(day: "2026-11-12", minutes: 10 * 60))
    }

    /// M7: reading one list must not re-stamp the sectioned reminders of another section-mirroring list.
    @Test func readingOneListLeavesOtherSectionedListsStampsAlone() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "In A", list: "Work", ["section": "Alpha"]))
        await fake.put(FakeRemCTL.row(2, "In B", list: "Home", ["section": "Beta"]))
        let clock = Clock()
        let backend = makeBackend(fake, clock: clock)
        await backend.setSectionLists(["1", "2"])
        let first = try await backend.reminders(inLists: ["1", "2"]).first { $0.id == "2" }
        clock.advance(500)
        _ = try await backend.reminders(inLists: ["1"])   // a verification re-read of list 1 only
        clock.advance(500)
        let again = try await backend.reminders(inLists: ["1", "2"]).first { $0.id == "2" }
        #expect(first?.lastModified != nil && again?.lastModified == first?.lastModified)
    }

    @Test func accessReportsVersionOrError() async throws {
        let fake = FakeRemCTL()
        let backend = makeBackend(fake)
        #expect(await backend.access() == .granted)
        #expect(await backend.statusDetail() == "Ready via RemCTL 2.5.0")
        await fake.setFailLists(.tool("Capability Host unavailable"))
        #expect(await backend.access() == .denied)
        #expect(await backend.statusDetail() == "Capability Host unavailable")
        await fake.setFailLists(.notInstalled)
        #expect(try await backend.requestAccess() == .denied)
        #expect(await backend.statusDetail().contains("RemCTL not found"))
    }
}

// MARK: - Synthesized modification time

@Suite struct RemCTLModificationTests {
    @Test func stampIsStableThenBumpsOnChange() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        await fake.put(FakeRemCTL.row(2, "B"))
        let clock = Clock()
        let backend = makeBackend(fake, clock: clock)

        let first = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        clock.advance(60)
        let second = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(first.map(\.lastModified) == second.map(\.lastModified))

        clock.advance(60)
        await fake.edit(1, "title", "A2")
        let third = try await backend.reminders(inLists: ["1"]).sorted { $0.id < $1.id }
        #expect(third[0].lastModified == clock.now())
        #expect(third[1].lastModified == first[1].lastModified)
    }

    @Test func stampsSurviveRestart() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        let dir = tempDir(), clock = Clock()
        let first = try await makeBackend(fake, dir: dir, clock: clock).reminders(inLists: ["1"])
        clock.advance(500)
        let again = try await makeBackend(fake, dir: dir, clock: clock).reminders(inLists: ["1"])
        #expect(first[0].lastModified == again[0].lastModified)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("remctl-observed.json").path))
    }
}

// MARK: - Writing

@Suite struct RemCTLWritingTests {
    @Test func timedDueSetsAlarm() async throws {
        let fake = FakeRemCTL()
        let backend = makeBackend(fake)
        let item = try await backend.create(title: "T", notes: "", due: DueDate(day: "2026-11-10", minutes: 9 * 60), completed: false, completionDate: nil, listId: "2", section: nil)
        let args = try #require(await fake.calls("create_reminder").first)
        #expect(args["due"] == "2026-11-10 09:00" && args["alarm"] == "2026-11-10T09:00:00")
        #expect(args["list_id"] == 2 && args["notes"] == nil)
        #expect(item.listId == "2" && item.title == "T" && item.id.hasPrefix("10"))
    }

    @Test func allDayDueHasNoAlarmAndNotesAreSent() async throws {
        let fake = FakeRemCTL()
        _ = try await makeBackend(fake).create(title: "T", notes: "body", due: DueDate(day: "2026-11-10"), completed: false, completionDate: nil, listId: "1", section: nil)
        let args = try #require(await fake.calls("create_reminder").first)
        #expect(args["due"] == "2026-11-10" && args["alarm"] == nil && args["notes"] == "body")
    }

    @Test func createCompletedPassesCompletionDate() async throws {
        let fake = FakeRemCTL()
        let date = try #require(RemCTLReminders.parseLocal("2026-11-09T10:30:00"))
        let item = try await makeBackend(fake).create(title: "T", notes: "", due: nil, completed: true, completionDate: date, listId: "1", section: nil)
        let done = try #require(await fake.calls("set_completion").first)
        #expect(done["completed"] == true && done["completion_date"] == "2026-11-09T10:30:00")
        #expect(item.completed)
    }

    @Test func clearingDueClearsAlarm() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        _ = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(due: .some(nil)))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(args["due"] == "clear" && args["alarm"] == nil)   // RemCTL clears an alarm at the old due time itself
    }

    /// M4: a due write never names the alarms of a reminder that has some, so a custom alert survives it.
    @Test func dueWritesLeaveExistingAlarmsAlone() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X", ["dueDate": "2026-11-13T00:00:00", "allDay": true,
                                               "alarms": [["id": 1, "type": "absolute", "date": "2026-11-12T18:00:00"]]]))
        let backend = makeBackend(fake)
        _ = try await backend.update(id: "5", patch: ReminderPatch(due: .some(DueDate(day: "2026-11-14"))))
        _ = try await backend.update(id: "5", patch: ReminderPatch(due: .some(DueDate(day: "2026-11-14", minutes: 600))))
        _ = try await backend.update(id: "5", patch: ReminderPatch(due: .some(nil)))
        let calls = await fake.calls("update_reminder")
        #expect(calls.map { $0["due"] } == ["2026-11-14", "2026-11-14 10:00", "clear"])
        #expect(calls.allSatisfy { $0["alarm"] == nil })
    }

    /// H4: once `create_reminder` returned an id, a failing follow-up step must still hand the reminder back.
    @Test func aCreateWhoseReadBackFailsStillReturnsTheReminder() async throws {
        let fake = FakeRemCTL()
        let backend = makeBackend(fake)
        await fake.setFailGetReminder(true)
        let item = try await backend.create(title: "Call plumber", notes: "n", due: DueDate(day: "2026-11-10"), completed: false,
                                            completionDate: nil, listId: "2", section: nil)
        #expect(item.id == "101" && item.listId == "2" && item.title == "Call plumber" && item.due == DueDate(day: "2026-11-10"))
        #expect(await fake.calls("create_reminder").count == 1)
    }

    /// H3: a create whose answer is lost is looked up, not sent again.
    @Test func aCreateWithALostAnswerIsFoundNotRepeated() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(7, "Call plumber", list: "Home"))   // an older reminder with the same title
        let backend = makeBackend(fake)
        _ = try await backend.reminders(inLists: ["1", "2"])
        await fake.loseAnswer(of: "create_reminder", lands: true)
        let item = try await backend.create(title: "Call plumber", notes: "", due: nil, completed: false, completionDate: nil, listId: "2", section: nil)
        #expect(item.id == "101")
        #expect(await fake.calls("create_reminder").count == 1)

        await fake.loseAnswer(of: "create_reminder", lands: false)
        await #expect(throws: RemCTLError.self) {
            try await backend.create(title: "Other", notes: "", due: nil, completed: false, completionDate: nil, listId: "2", section: nil)
        }
        #expect(await fake.calls("create_reminder").count == 2)   // still not sent a second time
    }

    /// H3: an unconfirmed completion is checked by re-reading and never sent twice (a repeating reminder would skip an occurrence).
    @Test func aCompletionWithALostAnswerIsCheckedNotRepeated() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let backend = makeBackend(fake)
        await fake.loseAnswer(of: "set_completion", lands: true)
        let done = try await backend.update(id: "5", patch: ReminderPatch(completed: true))
        #expect(done.completed)
        await fake.loseAnswer(of: "set_completion", lands: false)
        await #expect(throws: RemCTLError.self) { try await backend.update(id: "5", patch: ReminderPatch(completed: false)) }
        #expect(await fake.calls("set_completion").count == 2)
    }

    /// H3: an unconfirmed update is accepted when the re-read shows it, and is an error (retried next pass) when not.
    @Test func anUpdateWithALostAnswerIsCheckedNotRepeated() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let backend = makeBackend(fake)
        await fake.loseAnswer(of: "update_reminder", lands: true)
        #expect(try await backend.update(id: "5", patch: ReminderPatch(title: "Y")).title == "Y")
        await fake.loseAnswer(of: "update_reminder", lands: false)
        await #expect(throws: RemCTLError.self) { try await backend.update(id: "5", patch: ReminderPatch(title: "Z")) }
        // Subtasks would be added twice by a resend, so that write is never assumed either way.
        await fake.loseAnswer(of: "update_reminder", lands: true)
        await #expect(throws: RemCTLError.self) { try await backend.update(id: "5", patch: ReminderPatch(addSubtasks: ["a"])) }
        #expect(await fake.calls("update_reminder").count == 3)
    }

    @Test func changingDueKeepsAlarmInStep() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let backend = makeBackend(fake)
        _ = try await backend.update(id: "5", patch: ReminderPatch(due: .some(DueDate(day: "2026-11-11", minutes: 8 * 60 + 5))))
        _ = try await backend.update(id: "5", patch: ReminderPatch(due: .some(DueDate(day: "2026-11-12"))))
        let calls = await fake.calls("update_reminder")
        #expect(calls[0]["due"] == "2026-11-11 08:05" && calls[0]["alarm"] == "2026-11-11T08:05:00")
        #expect(calls[1]["due"] == "2026-11-12" && calls[1]["alarm"] == nil)
    }

    @Test func moveToListAndRename() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X", list: "Work"))
        let item = try await makeBackend(fake).update(id: "5", patch: ReminderPatch(title: "Y", listId: "2"))
        let args = try #require(await fake.calls("update_reminder").first)
        #expect(args["list_id"] == 2 && args["title"] == "Y" && args["reminder_id"] == 5)
        #expect(item.listId == "2" && item.title == "Y")
    }

    @Test func completionSendsDateUnlessRepeating() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "Plain"))
        await fake.put(FakeRemCTL.row(6, "Repeats", ["recurrence": ["frequency": "daily", "interval": 1]]))
        let backend = makeBackend(fake)
        let date = try #require(RemCTLReminders.parseLocal("2026-11-09T10:30:00"))
        _ = try await backend.update(id: "5", patch: ReminderPatch(completed: true, completionDate: date))
        _ = try await backend.update(id: "6", patch: ReminderPatch(completed: true, completionDate: date))
        _ = try await backend.update(id: "5", patch: ReminderPatch(completed: false))
        let calls = await fake.calls("set_completion")
        #expect(calls[0]["completion_date"] == "2026-11-09T10:30:00" && calls[0]["completed"] == true)
        #expect(calls[1]["completion_date"] == nil && calls[1]["completed"] == true)
        #expect(calls[2]["completed"] == false && calls[2]["completion_date"] == nil)
        #expect(await fake.calls("update_reminder").isEmpty)   // completion alone is not an update_reminder call
    }

    @Test func deleteIgnoresMissing() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(5, "X"))
        let backend = makeBackend(fake)
        try await backend.delete(id: "5")
        try await backend.delete(id: "5")
        #expect(await fake.rows.isEmpty)
    }
}

// MARK: - Change polling

@Suite struct RemCTLChangesTests {
    /// Waits until the fake has served `count` more exports than it had.
    private func polls(_ fake: FakeRemCTL, _ count: Int) async {
        let target = await fake.exportCount + count
        for _ in 0..<500 where await fake.exportCount < target { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private actor Counter { var n = 0; func bump() { n += 1 }; var value: Int { n } }

    @Test func yieldsOnlyForWatchedListChanges() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "Watched", list: "Work"))
        await fake.put(FakeRemCTL.row(2, "Ignored", list: "Home"))
        let backend = makeBackend(fake, poll: 0.02)
        await backend.setWatchedLists(["1"])
        let counter = Counter()
        let stream = backend.changes()
        let consumer = Task { for await _ in stream { await counter.bump() } }
        defer { consumer.cancel() }

        await polls(fake, 3)
        #expect(await counter.value == 0)   // the first poll is a baseline
        await fake.edit(2, "title", "Ignored, edited")
        await polls(fake, 3)
        #expect(await counter.value == 0)
        await fake.edit(1, "title", "Watched, edited")
        await polls(fake, 3)
        #expect(await counter.value == 1)
        await polls(fake, 3)
        #expect(await counter.value == 1)   // no further yields while nothing changes
    }

    @Test func pollStopsWhenStreamEnds() async throws {
        let fake = FakeRemCTL()
        await fake.put(FakeRemCTL.row(1, "A"))
        let backend = makeBackend(fake, poll: 0.02)
        let consumer = Task { for await _ in backend.changes() {} }
        await polls(fake, 2)
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(100))
        let settled = await fake.exportCount
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.exportCount == settled)
    }
}

// MARK: - MCP transport

final class FakeLink: RemCTLLink, @unchecked Sendable {
    enum Behavior { case normal, eofOnToolCall, silentOnToolCall }
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let behavior: Behavior

    init(_ behavior: Behavior) {
        self.behavior = behavior
        (lines, continuation) = AsyncStream<String>.makeStream()
    }

    func write(_ line: String) throws {
        guard let message = try? JSONValue.parse(Data(line.utf8)), let method = message["method"]?.string else { return }
        guard let id = message["id"] else { return }   // notifications get no reply
        switch method {
        case "initialize":
            reply(id, ["serverInfo": ["name": "remctl", "version": "9.9"]])
        case "tools/call":
            switch behavior {
            case .normal:
                reply(id, ["structuredContent": ["items": [], "tool": message["params"]?["name"] ?? .null], "isError": false])
            case .eofOnToolCall: continuation.finish()
            case .silentOnToolCall: break
            }
        default: break
        }
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) {
        continuation.yield(JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).serialized())
    }

    func close() { continuation.finish() }
}

final class LinkFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var behaviors: [FakeLink.Behavior]
    private(set) var made = 0
    init(_ behaviors: [FakeLink.Behavior]) { self.behaviors = behaviors }
    func next() -> FakeLink {
        lock.lock(); defer { lock.unlock() }
        made += 1
        return FakeLink(behaviors.isEmpty ? .normal : behaviors.removeFirst())
    }
}

@Suite struct MCPTransportTests {
    @Test func handshakeThenToolCall() async throws {
        let factory = LinkFactory([.normal])
        let transport = MCPTransport { factory.next() }
        let result = try await transport.callTool("lists", arguments: [:])
        #expect(result["tool"] == "lists")
        _ = try await transport.callTool("lists", arguments: [:])
        #expect(factory.made == 1)   // one process, initialized once
        #expect(await transport.serverVersion == "9.9")
    }

    @Test func restartsAfterEOF() async throws {
        let factory = LinkFactory([.eofOnToolCall, .normal])
        let transport = MCPTransport { factory.next() }
        let result = try await transport.callTool("lists", arguments: [:])
        #expect(result["tool"] == "lists")
        #expect(factory.made == 2)
    }

    @Test func restartsOnTimeoutButOnlyOnce() async throws {
        let once = LinkFactory([.silentOnToolCall, .normal])
        let recovered = MCPTransport(timeout: .milliseconds(100)) { once.next() }
        #expect(try await recovered.callTool("lists", arguments: [:])["tool"] == "lists")
        #expect(once.made == 2)

        let hopeless = LinkFactory([.silentOnToolCall, .silentOnToolCall, .normal])
        let failing = MCPTransport(timeout: .milliseconds(100)) { hopeless.next() }
        await #expect(throws: RemCTLError.self) { try await failing.callTool("lists", arguments: [:]) }
        #expect(hopeless.made == 2)
    }

    /// H3: a write that was sent and got no answer is not sent again; it surfaces as `.uncertain`.
    @Test func aWriteThatGotNoAnswerIsNotSentAgain() async throws {
        let silent = LinkFactory([.silentOnToolCall, .normal])
        let transport = MCPTransport(timeout: .milliseconds(100)) { silent.next() }
        do {
            _ = try await transport.callTool("create_reminder", arguments: ["title": "x"])
            Issue.record("the lost write must throw")
        } catch let error as RemCTLError {
            #expect(error.kind == .uncertain)
        }
        #expect(silent.made == 1)   // no second process was started to repeat the call

        let dying = LinkFactory([.eofOnToolCall, .normal])
        let second = MCPTransport { dying.next() }
        await #expect(throws: RemCTLError.self) { try await second.callTool("set_completion", arguments: [:]) }
        #expect(dying.made == 1)
        // The session recovers for the next call.
        #expect(try await second.callTool("lists", arguments: [:])["tool"] == "lists")
    }

    @Test func payloadUnwrapping() throws {
        let structured: JSONValue = ["structuredContent": ["id": 7], "content": [["text": "{\"id\":8}"]]]
        #expect(try MCPTransport.payload(of: structured)["id"]?.int == 7)
        let textOnly: JSONValue = ["content": [["type": "text", "text": "{\"id\":8}"]]]
        #expect(try MCPTransport.payload(of: textOnly)["id"]?.int == 8)
        let failed: JSONValue = ["isError": true, "structuredContent": ["error": ["message": "Error: #1 not found"]]]
        #expect(throws: RemCTLError.tool("Error: #1 not found")) { try MCPTransport.payload(of: failed) }
        let truncated: JSONValue = ["structuredContent": ["items": [], "truncated": true]]
        #expect(throws: RemCTLError.self) { try MCPTransport.payload(of: truncated) }
    }
}

// MARK: - Config

@Suite struct SyncConfigCompatibilityTests {
    @Test func oldConfigDecodesWithDefaults() throws {
        let old = #"{"mappings":[],"pollSeconds":20,"reconcileMinutes":7,"includeCompletedOnFirstLink":true,"propagateDeletes":false}"#
        let config = try JSONDecoder().decode(SyncConfig.self, from: Data(old.utf8))
        #expect(config.pollSeconds == 20 && config.reconcileMinutes == 7 && config.includeCompletedOnFirstLink && !config.propagateDeletes)
        #expect(config.remindersPollSeconds == 10 && config.remctlPath == nil)
        var custom = config
        custom.remctlPath = "/x/remctl"; custom.remindersPollSeconds = 30
        let round = try JSONDecoder().decode(SyncConfig.self, from: JSONEncoder().encode(custom))
        #expect(round == custom)
    }
}
