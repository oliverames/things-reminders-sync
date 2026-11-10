import Foundation

/// One side of a linked pair.
public enum Side: String, Codable, Hashable, Sendable { case reminders, things }

/// A Things container the app created itself (ownership ledger). Containers the user made are never recorded,
/// so they are never removed.
public struct OwnedThingsContainer: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case project, area, tag, heading }
    public var id: String
    public var kind: Kind
    /// `ListMapping.id` (Reminders list id) the container was created for.
    public var mappingId: String
    public var title: String
    public var created: Date
    public init(id: String, kind: Kind, mappingId: String, title: String, created: Date = Date()) {
        self.id = id; self.kind = kind; self.mappingId = mappingId; self.title = title; self.created = created
    }
}

/// A Reminders section the app created (a section name the list did not have when a reminder was written to it).
public struct OwnedReminderSection: Codable, Hashable, Sendable {
    public var listId: String
    public var name: String
    public var created: Date
    public init(listId: String, name: String, created: Date = Date()) {
        self.listId = listId; self.name = name; self.created = created
    }
    func matches(listId: String, name other: String) -> Bool {
        listId == self.listId && Fingerprint.groupKey(name) == Fingerprint.groupKey(other)
    }
}

extension OwnedThingsContainer.Kind {
    init(_ mode: MappingMode) {
        switch mode {
        case .project: self = .project
        case .area: self = .area
        case .tag: self = .tag
        case .heading: self = .heading
        }
    }
}

/// Whether a Things task sits in the mapping's target (the rule the engine uses to scope a list).
func taskMatches(_ task: ThingsTask, _ m: ListMapping, in snapshot: ThingsSnapshot) -> Bool {
    guard let target = m.targetId else { return false }
    switch m.mode {
    case .project:
        if task.projectId == target { return true }
        if let h = task.headingId, let heading = snapshot.tasks[h], heading.projectId == target { return true }
        return false
    case .area: return task.areaId == target && task.projectId == nil && task.headingId == nil
    case .tag: return task.tagIds.contains(target)
    case .heading: return task.headingId == target
    }
}

extension ThingsSnapshot {
    /// True when nothing is left in the container. `ignoring` lists to-do ids to treat as already gone.
    /// Projects and headings go to the Trash, so only non-trashed to-dos count: for a project, to-dos (open or done)
    /// directly in it or under a heading; for a heading, to-dos under it.
    /// Areas and tags are deleted for good, so what sits in the Things Trash counts too (a project restored later
    /// would find no area): an area is empty when no to-do or project names it, a tag when no task or area carries
    /// it and no tag nests under it.
    func isEmpty(_ kind: OwnedThingsContainer.Kind, id: String, ignoring gone: Set<String> = []) -> Bool {
        let live = tasks.values.filter { !$0.trashed && !gone.contains($0.id) }
        switch kind {
        case .project:
            return !live.contains { t in
                guard t.kind == .todo else { return false }
                if t.projectId == id { return true }
                if let h = t.headingId, tasks[h]?.projectId == id { return true }
                return false
            }
        case .area:
            return !tasks.values.contains { !gone.contains($0.id) && ($0.kind == .todo || $0.kind == .project) && $0.areaId == id }
        case .tag:
            return !tasks.values.contains { !gone.contains($0.id) && $0.tagIds.contains(id) }
                && !tags.values.contains { $0.parentId == id } && !areas.values.contains { $0.tagIds.contains(id) }
        case .heading:
            return !live.contains { $0.kind == .todo && $0.headingId == id }
        }
    }

    func exists(_ kind: OwnedThingsContainer.Kind, id: String) -> Bool {
        switch kind {
        case .project: return tasks[id].map { $0.kind == .project && !$0.trashed } ?? false
        case .heading: return tasks[id].map { $0.kind == .heading && !$0.trashed } ?? false
        case .area: return areas[id] != nil
        case .tag: return tags[id] != nil
        }
    }
}

extension SyncConfig {
    /// Lists whose Reminders changes start a pass: enabled and not paused.
    var watchedListIds: [String] { mappings.filter { $0.enabled && !$0.paused }.map(\.id) }
    /// Lists whose sections are read: live project-mode lists that mirror sections as headings.
    var sectionListIds: [String] { mappings.filter { $0.isLive && $0.mode == .project && $0.syncSections }.map(\.id) }
    var pausedListIds: Set<String> { Set(mappings.filter(\.paused).map(\.id)) }

    /// Ids a mapping currently needs: its target, and a heading mapping's project.
    func targetIds(excluding mappingId: String? = nil) -> Set<String> {
        var ids = Set<String>()
        for m in mappings where m.id != mappingId {
            if let t = m.targetId { ids.insert(t) }
            if let p = m.parentProjectId { ids.insert(p) }
        }
        return ids
    }
}

extension ThingsSnapshot {
    func displayTitle(_ kind: OwnedThingsContainer.Kind, id: String) -> String? {
        switch kind {
        case .project, .heading: return tasks[id]?.title
        case .area: return areas[id]?.title
        case .tag: return tags[id]?.title
        }
    }

    mutating func markRemoved(_ kind: OwnedThingsContainer.Kind, id: String) {
        switch kind {
        case .project, .heading: tasks[id]?.trashed = true
        case .area: areas[id] = nil
        case .tag: tags[id] = nil
        }
    }
}

extension ThingsBackend {
    /// Projects and headings go to the Trash (never permanently deleted); areas and tags have no Trash and are deleted
    /// (the backend first takes the area or tag off every task that still names it).
    func removeContainer(_ c: OwnedThingsContainer) async throws {
        switch c.kind {
        case .project, .heading: try await updateTodo(id: c.id, patch: ThingsTodoPatch(trashed: true))
        case .area: try await deleteArea(id: c.id)
        case .tag: try await deleteTag(id: c.id)
        }
    }
}
