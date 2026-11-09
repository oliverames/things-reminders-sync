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
}

actor FakeReminders: RemindersBackend {
    var listsById: [String: ReminderList] = [:]
    var items: [String: ReminderItem] = [:]
    private var counter = 0
    private(set) var deletes: [String] = []
    /// Like RemCTL 2.5.0, a section cannot be removed: `.some(nil)` is a no-op.
    var clearsSections = false
    var groceryLists: Set<String> = []
    private(set) var sectionWrites: [(id: String, section: String)] = []

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
                section: String?) async throws -> ReminderItem {
        counter += 1
        if section != nil { sectionWrites.append(("new", section!)) }
        let r = ReminderItem(id: "R\(counter)", externalId: "X\(counter)", listId: listId, title: title, notes: notes, due: due,
                             completed: completed, completionDate: completed ? (completionDate ?? Date()) : nil, lastModified: Date(),
                             section: groceryLists.contains(listId) ? nil : section)
        items[r.id] = r
        return r
    }

    func update(id: String, patch p: ReminderPatch) async throws -> ReminderItem {
        guard var r = items[id] else { throw NSError(domain: "fake", code: 1) }
        if let v = p.title { r.title = v }
        if let v = p.notes { r.notes = v }
        if let d = p.due { r.due = d }
        if let c = p.completed { r.completed = c; r.completionDate = c ? (p.completionDate ?? Date()) : nil }
        if let l = p.listId { r.listId = l; r.section = nil }   // sections belong to a list
        if let sec = p.section, !groceryLists.contains(r.listId) {
            if let name = sec { r.section = name; sectionWrites.append((id, name)) }
            else if clearsSections { r.section = nil; sectionWrites.append((id, "")) }
        }
        r.lastModified = Date()
        items[id] = r
        return r
    }

    func delete(id: String) async throws { deletes.append(id); items[id] = nil }
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
