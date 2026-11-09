import Foundation
import Testing
@testable import SyncCore

actor FakeThings: ThingsBackend {
    var tasks: [String: ThingsTask] = [:]
    var areas: [String: ThingsArea] = [:]
    var tags: [String: ThingsTag] = [:]
    private var counter = 0
    private(set) var updates: [(String, ThingsTodoPatch)] = []
    private(set) var created: [ThingsTodoDraft] = []

    private func nextId(_ p: String) -> String { counter += 1; return "\(p)\(counter)" }

    func add(_ t: ThingsTask) { tasks[t.id] = t }
    func addArea(_ id: String, _ title: String) { areas[id] = ThingsArea(id: id, title: title) }
    func addTag(_ id: String, _ title: String) { tags[id] = ThingsTag(id: id, title: title) }
    func edit(_ id: String, _ change: (inout ThingsTask) -> Void) { change(&tasks[id]!) }
    func task(_ id: String) -> ThingsTask? { tasks[id] }
    func all() -> [ThingsTask] { tasks.values.filter { $0.kind == .todo }.sorted { $0.id < $1.id } }
    func clearRecords() { updates = []; created = [] }

    func refresh() async throws -> ThingsRefreshResult {
        ThingsRefreshResult(snapshot: ThingsSnapshot(tasks: tasks, areas: areas, tags: tags), changedTaskIds: [], fullReload: false)
    }

    func createTodo(_ d: ThingsTodoDraft) async throws -> String {
        created.append(d)
        let id = nextId("T")
        var t = ThingsTask(id: id, title: d.title, notes: d.notes, tagIds: d.tagIds, modificationDate: Date())
        t.checklist = d.checklist.enumerated().map { ThingsChecklistItem(id: nextId("CI"), title: $1.title, completed: $1.completed, index: Double($0)) }
        if let rule = d.recurrence {
            // A template: never an occurrence. `tir` and `icsd` are the first occurrence day.
            t.isRepeating = true; t.recurrence = rule; t.start = .someday
            t.nextDay = d.when?.day; t.instanceDay = d.when?.day; t.instancesCreated = 0
            t.reminderSeconds = d.when?.reminderSeconds
            switch d.placement {
            case .inbox: break
            case .project(let p): t.projectId = p
            case .area(let a): t.areaId = a
            case .heading(let h): t.headingId = h
            }
            tasks[id] = t
            return id
        }
        switch d.placement {
        case .inbox: t.start = .inbox
        case .project(let p): t.projectId = p
        case .area(let a): t.areaId = a
        case .heading(let h): t.headingId = h
        }
        if let w = d.when { t.startDate = w.day; t.reminderSeconds = w.reminderSeconds }
        if d.completed { t.status = .completed; t.stopDate = d.completionDate ?? Date() }
        tasks[id] = t
        return id
    }

    func updateTodo(id: String, patch p: ThingsTodoPatch) async throws {
        updates.append((id, p))
        guard var t = tasks[id] else { return }
        if let v = p.title { t.title = v }
        if let v = p.notes { t.notes = v }
        if let w = p.when {
            t.startDate = w?.day; t.reminderSeconds = w?.reminderSeconds
            if w == nil { t.start = .anytime }
        }
        if let c = p.completed { t.status = c ? .completed : .open; t.stopDate = c ? (p.completionDate ?? Date()) : nil }
        if let pl = p.placement {
            t.projectId = nil; t.areaId = nil; t.headingId = nil
            switch pl {
            case .inbox: t.start = .inbox
            case .project(let x): t.projectId = x
            case .area(let x): t.areaId = x
            case .heading(let x): t.headingId = x   // like Things: the project is derived through the heading
            }
        }
        if let add = p.addTagIds { t.tagIds += add }
        if let rem = p.removeTagIds { t.tagIds.removeAll { rem.contains($0) } }
        if let tr = p.trashed { t.trashed = tr }
        for change in p.checklist ?? [] {
            switch change {
            case let .add(title, done):
                t.checklist.append(ThingsChecklistItem(id: nextId("CI"), title: title, completed: done, index: Double(t.checklist.count)))
            case let .rename(id, title): if let i = t.checklist.firstIndex(where: { $0.id == id }) { t.checklist[i].title = title }
            case let .setCompleted(id, done): if let i = t.checklist.firstIndex(where: { $0.id == id }) { t.checklist[i].completed = done }
            case let .delete(id): t.checklist.removeAll { $0.id == id }
            }
        }
        if let rule = p.recurrence { t.recurrence = rule }
        if let next = p.templateNext { t.nextDay = next.day; t.instanceDay = next.day; t.reminderSeconds = next.reminderSeconds }
        t.modificationDate = Date()
        tasks[id] = t
    }

    func createProject(title: String, areaId: String?) async throws -> String {
        let id = nextId("P")
        tasks[id] = ThingsTask(id: id, kind: .project, title: title, areaId: areaId)
        return id
    }
    private(set) var headingsCreated: [(title: String, projectId: String)] = []
    func createHeading(title: String, projectId: String) async throws -> String {
        headingsCreated.append((title, projectId))
        let id = nextId("HD")
        tasks[id] = ThingsTask(id: id, kind: .heading, title: title, projectId: projectId, creationDate: Date())
        return id
    }
    func addHeading(_ id: String, _ title: String, project: String, created: Double = 0) {
        tasks[id] = ThingsTask(id: id, kind: .heading, title: title, projectId: project, creationDate: Date(timeIntervalSince1970: created))
    }
    func createArea(title: String) async throws -> String { let id = nextId("A"); areas[id] = ThingsArea(id: id, title: title); return id }
    func createTag(title: String, parentId: String?) async throws -> String { let id = nextId("G"); tags[id] = ThingsTag(id: id, title: title); return id }
    private(set) var deletedAreas: [String] = []
    private(set) var deletedTags: [String] = []
    func deleteArea(id: String) async throws { deletedAreas.append(id); areas[id] = nil }
    func deleteTag(id: String) async throws { deletedTags.append(id); tags[id] = nil }
    func trashedIds() -> Set<String> { Set(tasks.values.filter(\.trashed).map(\.id)) }
    /// Every id passed to `updateTodo` with `trashed == true`.
    func trashCalls() -> [String] { updates.filter { $0.1.trashed == true }.map(\.0) }
}

actor FakeReminders: RemindersBackend {
    var listsById: [String: ReminderList] = [:]
    var items: [String: ReminderItem] = [:]
    private var counter = 0
    private(set) var deletes: [String] = []
    private(set) var created: [(title: String, due: DueDate?, rule: RepeatRule)] = []
    /// Every `update` call, in order, so tests can check that a write carries only the fields that changed.
    private(set) var patches: [(id: String, patch: ReminderPatch)] = []
    /// Simulates RemCTL not taking a rich link / flag / subtask write.
    var ignoresURL = false, ignoresFlag = false, ignoresSubtasks = false
    func setIgnores(url: Bool = false, flag: Bool = false, subtasks: Bool = false) { ignoresURL = url; ignoresFlag = flag; ignoresSubtasks = subtasks }
    func clearPatches() { patches = [] }
    private var subtaskCounter = 0
    private(set) var recurrenceWrites: [(id: String, rule: RepeatRule?)] = []
    /// Every completion request on a repeating reminder: the id and the completion date it was (wrongly) given.
    private(set) var completions: [(id: String, date: Date?)] = []
    /// Like RemCTL 2.5.0, a section cannot be removed: `.some(nil)` is a no-op.
    var clearsSections = false
    var groceryLists: Set<String> = []
    private(set) var sectionWrites: [(id: String, section: String)] = []
    /// Sections that exist per list, so a write with an unknown name creates one (and reports it) like RemCTL.
    var sectionNames: [String: Set<String>] = [:]
    private var createdSections: [CreatedReminderSection] = []
    private(set) var sectionDeletes: [String] = []
    func addSection(_ list: String, _ name: String) { sectionNames[list, default: []].insert(name.lowercased()) }
    private func noteSection(_ list: String, _ name: String) {
        if sectionNames[list, default: []].insert(name.lowercased()).inserted { createdSections.append(CreatedReminderSection(listId: list, name: name)) }
    }
    func takeCreatedSections() async -> [CreatedReminderSection] { defer { createdSections = [] }; return createdSections }
    func deleteSection(name: String, listId: String) async throws {
        sectionDeletes.append("\(listId):\(name)")
        sectionNames[listId]?.remove(name.lowercased())
    }

    init(lists: [String]) { for l in lists { listsById[l] = ReminderList(id: l, title: l) } }
    func setGrocery(_ id: String) { listsById[id]?.isGroceries = true; groceryLists.insert(id) }
    func setClearsSections(_ v: Bool) { clearsSections = v }

    func add(_ r: ReminderItem) { items[r.id] = r }
    func edit(_ id: String, _ change: (inout ReminderItem) -> Void) { change(&items[id]!) }
    func item(_ id: String) -> ReminderItem? { items[id] }
    func all(in list: String) -> [ReminderItem] { items.values.filter { $0.listId == list }.sorted { $0.id < $1.id } }
    func remove(_ id: String) { items[id] = nil }

    func access() async -> RemindersAccess { .granted }
    func requestAccess() async throws -> RemindersAccess { .granted }
    func lists() async throws -> [ReminderList] { listsById.values.sorted { $0.id < $1.id } }
    func reminders(inLists ids: [String]) async throws -> [ReminderItem] { items.values.filter { ids.contains($0.listId) } }

    func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                section: String?, recurrence: RepeatRule?) async throws -> ReminderItem {
        counter += 1
        if section != nil { sectionWrites.append(("new", section!)) }
        if let section, !groceryLists.contains(listId) { noteSection(listId, section) }
        let r = ReminderItem(id: "R\(counter)", externalId: "X\(counter)", listId: listId, title: title, notes: notes, due: due,
                             completed: completed, completionDate: completed ? (completionDate ?? Date()) : nil, lastModified: Date(),
                             isRepeating: recurrence != nil, section: groceryLists.contains(listId) ? nil : section, recurrence: recurrence)
        if let recurrence { created.append((title, due, recurrence)) }
        items[r.id] = r
        return r
    }

    func update(id: String, patch p: ReminderPatch) async throws -> ReminderItem {
        patches.append((id, p))
        // A subtask is a reminder of its own: it is renamed and completed through its own id.
        for (parentId, parent) in items {
            if let i = parent.subtasks.firstIndex(where: { $0.id == id }) {
                var updated = parent
                if let v = p.title { updated.subtasks[i].title = v }
                if let c = p.completed { updated.subtasks[i].completed = c }
                items[parentId] = updated
                return updated
            }
        }
        guard var r = items[id] else { throw NSError(domain: "fake", code: 1) }
        if let u = p.url, !ignoresURL { r.url = u }
        if let f = p.flagged, !ignoresFlag { r.flagged = f }
        if let t = p.tags { r.tags = t }
        if let titles = p.addSubtasks, !ignoresSubtasks {
            for title in titles { subtaskCounter += 1; r.subtasks.append(ReminderSubtask(id: "S\(subtaskCounter)", title: title)) }
        }
        if let v = p.title { r.title = v }
        if let v = p.notes { r.notes = v }
        if let d = p.due { r.due = d }
        if let rec = p.recurrence { r.recurrence = rec; r.isRepeating = rec != nil; recurrenceWrites.append((id, rec)) }
        if let c = p.completed {
            if c, r.isRepeating {
                // Like RemCTL: a repeating reminder advances to its next occurrence (same id) instead of completing.
                completions.append((id, p.completionDate))
                if let day = r.due?.day, let next = r.recurrence?.nextOccurrence(after: day) { r.due = DueDate(day: next, minutes: r.due?.minutes) }
                else if r.recurrence == nil, let day = r.due?.day, let d = RepeatCalendar.date(day) {
                    // An unrecognised rule still advances (a week, here).
                    r.due = DueDate(day: RepeatCalendar.string(RepeatCalendar.add(days: 7, to: d)), minutes: r.due?.minutes)
                } else { r.completed = true; r.completionDate = Date() }
                if let n = r.recurrence, case .afterCount(let k) = n.end { r.recurrence?.end = .afterCount(max(k - 1, 1)) }
            } else { r.completed = c; r.completionDate = c ? (p.completionDate ?? Date()) : nil }
        }
        if let l = p.listId { r.listId = l; r.section = nil }   // sections belong to a list
        if let sec = p.section, !groceryLists.contains(r.listId) {
            if let name = sec { r.section = name; sectionWrites.append((id, name)); noteSection(r.listId, name) }
            else if clearsSections { r.section = nil; sectionWrites.append((id, "")) }
        }
        r.lastModified = Date()
        items[id] = r
        return r
    }

    func delete(id: String) async throws {
        deletes.append(id)
        for (parentId, parent) in items where parent.subtasks.contains(where: { $0.id == id }) {
            items[parentId]?.subtasks.removeAll { $0.id == id }
            return
        }
        items[id] = nil
    }
    nonisolated func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

func day(_ offset: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
    return DayFormatter(timeZone: .current).day(d)
}

func reminder(_ id: String, _ list: String, _ title: String, notes: String = "", due: DueDate? = nil, done: Bool = false,
               modified: Date = Date(timeIntervalSince1970: 1_000), section: String? = nil) -> ReminderItem {
    ReminderItem(id: id, externalId: "x\(id)", listId: list, title: title, notes: notes, due: due, completed: done,
                 completionDate: done ? Date(timeIntervalSince1970: 5_000) : nil, lastModified: modified, section: section)
}

func todo(_ id: String, _ title: String, project: String? = nil, area: String? = nil, tags: [String] = [], notes: String = "",
          status: ThingsStatus = .open, startDate: String? = nil, seconds: Int? = nil,
          modified: Date = Date(timeIntervalSince1970: 1_000), heading: String? = nil) -> ThingsTask {
    ThingsTask(id: id, title: title, notes: notes, status: status,
               stopDate: status == .open ? nil : Date(timeIntervalSince1970: 5_000), startDate: startDate, reminderSeconds: seconds,
               projectId: project, headingId: heading, areaId: area, tagIds: tags, modificationDate: modified)
}

func projectTask(_ id: String, _ title: String = "Proj") -> ThingsTask { ThingsTask(id: id, kind: .project, title: title) }

struct World {
    let things = FakeThings()
    let reminders: FakeReminders
    var config: SyncConfig
    var links = LinkStore()

    init(lists: [String] = ["L1"], mappings: [ListMapping]? = nil) {
        reminders = FakeReminders(lists: lists)
        config = SyncConfig(mappings: mappings ?? [ListMapping(id: "L1", listTitle: "L1", mode: .project, targetId: "P1", targetTitle: "Proj")])
    }

    @discardableResult
    mutating func sync(_ scope: SyncScope = .full, force: Bool = false) async throws -> SyncReport {
        let engine = SyncEngine(things: things, reminders: reminders)
        let report = try await engine.sync(config: config, links: links, scope: scope, forceDeletions: force)
        config = report.config; links = report.links
        return report
    }
}
