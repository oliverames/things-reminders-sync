import Foundation

// Contracts shared by the Things Cloud client, the Reminders layer, the sync engine, and the UI.
// Change these only together with every module that uses them (see docs/SPEC.md).

// MARK: - Calendar date shared by both sides

/// A due/start day plus an optional time of day, in the user's local time zone.
/// Things stores the day as `sr` (midnight UTC) and the time as `ato` (seconds after local midnight).
/// Reminders stores it as `dueDateComponents` (all-day when there is no hour/minute).
public struct DueDate: Codable, Hashable, Sendable {
    /// Calendar day, `YYYY-MM-DD`.
    public var day: String
    /// Minutes after local midnight, or nil for an all-day date.
    public var minutes: Int?

    public init(day: String, minutes: Int? = nil) {
        self.day = day
        self.minutes = minutes
    }
}

// MARK: - Things

public enum ThingsTaskKind: Int, Codable, Sendable { case todo = 0, project = 1, heading = 2 }
public enum ThingsStatus: Int, Codable, Sendable { case open = 0, canceled = 2, completed = 3 }
/// Things `st`: 0 Inbox, 1 Anytime (or Today/scheduled when a start date is set), 2 Someday (or Upcoming with a future date).
public enum ThingsStart: Int, Codable, Sendable { case inbox = 0, anytime = 1, someday = 2 }

/// One Things checklist item (`ChecklistItem3`), read from history. Items sort by `index` (`ix`) ascending.
public struct ThingsChecklistItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// `ss` 3 (completed) or 2 (canceled, which counts as done like it does for a to-do).
    public var completed: Bool
    public var index: Double
    public init(id: String, title: String, completed: Bool = false, index: Double = 0) {
        self.id = id; self.title = title; self.completed = completed; self.index = index
    }
}

/// A checklist item to create with a to-do.
public struct ThingsChecklistDraft: Codable, Hashable, Sendable {
    public var title: String
    public var completed: Bool
    public init(title: String, completed: Bool = false) { self.title = title; self.completed = completed }
}

/// One change to a to-do's checklist (the engine only sends these when `SyncConfig.syncChecklists` is on).
public enum ThingsChecklistChange: Codable, Hashable, Sendable {
    case add(title: String, completed: Bool)
    case rename(id: String, title: String)
    case setCompleted(id: String, completed: Bool)
    case delete(id: String)
}

public struct ThingsTask: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ThingsTaskKind
    public var title: String
    public var notes: String
    public var status: ThingsStatus
    /// Completion or cancel time (`sp`).
    public var stopDate: Date?
    public var trashed: Bool
    public var start: ThingsStart
    /// Start ("When") day, `YYYY-MM-DD` (`sr`), if any.
    public var startDate: String?
    /// Reminder time as seconds after local midnight (`ato`), if any.
    public var reminderSeconds: Int?
    /// `true` when the item is in This Evening (`sb == 1`).
    public var evening: Bool
    public var deadline: String?
    public var projectId: String?
    public var headingId: String?
    public var areaId: String?
    public var tagIds: [String]
    public var creationDate: Date?
    public var modificationDate: Date?
    /// True for a repeating template (it holds `rr`) and for each occurrence generated from one (`rt`).
    public var isRepeating: Bool
    /// The template's repeat rule (`rr`), when it is one of the shapes in docs/RECURRENCE.md; nil for
    /// non-templates and for rules this app does not recognise.
    public var recurrence: RepeatRule?
    /// On an occurrence: the id of the template it came from (`rt`).
    public var templateId: String?
    /// On a template: next occurrence day (`tir`), next instance-creation day (`icsd`), instances created (`icc`).
    public var nextDay: String?
    public var instanceDay: String?
    public var instancesCreated: Int?
    /// Checklist items, ordered by `ix`. Read from history whatever the config says.
    /// (Stored optional so state saved before checklists existed still decodes.)
    public var checklist: [ThingsChecklistItem] {
        get { storedChecklist ?? [] }
        set { storedChecklist = newValue.isEmpty ? nil : newValue }
    }
    private var storedChecklist: [ThingsChecklistItem]?

    public init(id: String, kind: ThingsTaskKind = .todo, title: String, notes: String = "", status: ThingsStatus = .open,
                stopDate: Date? = nil, trashed: Bool = false, start: ThingsStart = .anytime, startDate: String? = nil,
                reminderSeconds: Int? = nil, evening: Bool = false, deadline: String? = nil, projectId: String? = nil,
                headingId: String? = nil, areaId: String? = nil, tagIds: [String] = [], creationDate: Date? = nil,
                modificationDate: Date? = nil, isRepeating: Bool = false, recurrence: RepeatRule? = nil,
                templateId: String? = nil, nextDay: String? = nil, instanceDay: String? = nil, instancesCreated: Int? = nil,
                checklist: [ThingsChecklistItem] = []) {
        self.storedChecklist = checklist.isEmpty ? nil : checklist
        self.id = id; self.kind = kind; self.title = title; self.notes = notes; self.status = status
        self.stopDate = stopDate; self.trashed = trashed; self.start = start; self.startDate = startDate
        self.reminderSeconds = reminderSeconds; self.evening = evening; self.deadline = deadline
        self.projectId = projectId; self.headingId = headingId; self.areaId = areaId; self.tagIds = tagIds
        self.creationDate = creationDate; self.modificationDate = modificationDate; self.isRepeating = isRepeating
        self.recurrence = recurrence; self.templateId = templateId; self.nextDay = nextDay
        self.instanceDay = instanceDay; self.instancesCreated = instancesCreated
    }

    /// A repeating template: it repeats and is not itself an occurrence.
    public var isTemplate: Bool { isRepeating && templateId == nil }
    /// An occurrence generated from a template.
    public var isOccurrence: Bool { templateId != nil }
}

public struct ThingsArea: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct ThingsTag: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var parentId: String?
    public init(id: String, title: String, parentId: String? = nil) { self.id = id; self.title = title; self.parentId = parentId }
}

/// Where a new or moved to-do should live in Things.
public enum ThingsPlacement: Codable, Hashable, Sendable {
    case inbox
    case project(String)
    case area(String)
    /// Inside a heading. The project is derived through the heading (`pr` stays empty).
    case heading(String)
}

/// Field changes for a Things to-do. `nil` leaves a field alone.
public struct ThingsTodoPatch: Codable, Hashable, Sendable {
    public var title: String?
    public var notes: String?
    /// `.some(nil)` clears the start date (moves to Anytime); `.some(date)` schedules it,
    /// setting the reminder time from `minutes` (nil minutes clears the reminder).
    public var when: DueDate??
    public var completed: Bool?
    /// Used with `completed == true`; defaults to now.
    public var completionDate: Date?
    public var placement: ThingsPlacement?
    public var addTagIds: [String]?
    public var removeTagIds: [String]?
    public var trashed: Bool?
    /// Templates only: replaces the repeat rule (`rr`), keeping the template's existing anchors.
    public var recurrence: RepeatRule?
    /// Templates only: moves the next occurrence (`tir`, `icsd`) and sets the reminder time (`ato`).
    public var templateNext: DueDate?
    /// Checklist changes, written as `ChecklistItem3` entities in the same commit as the to-do.
    public var checklist: [ThingsChecklistChange]?

    public init(title: String? = nil, notes: String? = nil, when: DueDate?? = nil, completed: Bool? = nil,
                completionDate: Date? = nil, placement: ThingsPlacement? = nil, addTagIds: [String]? = nil,
                removeTagIds: [String]? = nil, trashed: Bool? = nil, recurrence: RepeatRule? = nil,
                templateNext: DueDate? = nil, checklist: [ThingsChecklistChange]? = nil) {
        self.checklist = checklist
        self.title = title; self.notes = notes; self.when = when; self.completed = completed
        self.completionDate = completionDate; self.placement = placement; self.addTagIds = addTagIds
        self.removeTagIds = removeTagIds; self.trashed = trashed; self.recurrence = recurrence
        self.templateNext = templateNext
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && when == nil && completed == nil && placement == nil
            && addTagIds == nil && removeTagIds == nil && trashed == nil && recurrence == nil && templateNext == nil
            && (checklist?.isEmpty ?? true)
    }
}

public struct ThingsTodoDraft: Codable, Hashable, Sendable {
    public var title: String
    public var notes: String
    public var when: DueDate?
    public var completed: Bool
    public var completionDate: Date?
    public var placement: ThingsPlacement
    public var tagIds: [String]
    /// When set, a repeating TEMPLATE is created (never an occurrence): `when` is the first occurrence.
    public var recurrence: RepeatRule?
    /// Checklist items to create with the to-do (empty unless `SyncConfig.syncChecklists` is on).
    public var checklist: [ThingsChecklistDraft]

    public init(title: String, notes: String = "", when: DueDate? = nil, completed: Bool = false,
                completionDate: Date? = nil, placement: ThingsPlacement = .inbox, tagIds: [String] = [],
                recurrence: RepeatRule? = nil, checklist: [ThingsChecklistDraft] = []) {
        self.checklist = checklist
        self.title = title; self.notes = notes; self.when = when; self.completed = completed
        self.completionDate = completionDate; self.placement = placement; self.tagIds = tagIds
        self.recurrence = recurrence
    }
}

/// Snapshot of the Things database the engine works from.
public struct ThingsSnapshot: Sendable {
    public var tasks: [String: ThingsTask]
    public var areas: [String: ThingsArea]
    public var tags: [String: ThingsTag]
    public init(tasks: [String: ThingsTask] = [:], areas: [String: ThingsArea] = [:], tags: [String: ThingsTag] = [:]) {
        self.tasks = tasks; self.areas = areas; self.tags = tags
    }
    public var projects: [ThingsTask] { tasks.values.filter { $0.kind == .project && !$0.trashed } }
    public var headings: [ThingsTask] { tasks.values.filter { $0.kind == .heading && !$0.trashed } }
}

public struct ThingsRefreshResult: Sendable {
    public var snapshot: ThingsSnapshot
    /// Task ids touched by history items pulled in this refresh (empty when nothing changed).
    public var changedTaskIds: Set<String>
    /// True when this refresh rebuilt the database from scratch (first load or history reset).
    public var fullReload: Bool
    public init(snapshot: ThingsSnapshot, changedTaskIds: Set<String>, fullReload: Bool) {
        self.snapshot = snapshot; self.changedTaskIds = changedTaskIds; self.fullReload = fullReload
    }
}

/// The Things side as the engine sees it. `ThingsCloudClient` implements it; tests use a fake.
public protocol ThingsBackend: Sendable {
    /// Checks the server head (one cheap request) and pulls only new history items.
    func refresh() async throws -> ThingsRefreshResult
    /// Creates a to-do and returns its new id. Validated before anything is sent.
    func createTodo(_ draft: ThingsTodoDraft) async throws -> String
    func updateTodo(id: String, patch: ThingsTodoPatch) async throws
    func createProject(title: String, areaId: String?) async throws -> String
    /// Creates a heading inside a project (Anytime) and returns its id.
    func createHeading(title: String, projectId: String) async throws -> String
    func createArea(title: String) async throws -> String
    func createTag(title: String, parentId: String?) async throws -> String
    /// Permanently deletes an area. Only used to remove an area this app created once it holds nothing.
    func deleteArea(id: String) async throws
    /// Permanently deletes a tag. Only used to remove a tag this app created once nothing carries it.
    func deleteTag(id: String) async throws
}

// MARK: - Reminders

public struct ReminderList: Codable, Hashable, Sendable, Identifiable {
    /// RemCTL's numeric list id, as a string.
    public var id: String
    public var title: String
    /// `#RRGGBB`.
    public var colorHex: String?
    public var sourceTitle: String?
    public var allowsModifications: Bool
    /// Grocery-type lists auto-categorize reminders into sections; the engine never writes sections there.
    public var isGroceries: Bool
    public init(id: String, title: String, colorHex: String? = nil, sourceTitle: String? = nil, allowsModifications: Bool = true,
                isGroceries: Bool = false) {
        self.id = id; self.title = title; self.colorHex = colorHex; self.sourceTitle = sourceTitle
        self.allowsModifications = allowsModifications; self.isGroceries = isGroceries
    }
}

/// A Reminders subtask (a reminder of its own with a parent), as listed on its parent.
public struct ReminderSubtask: Codable, Hashable, Sendable, Identifiable {
    /// The subtask's own RemCTL id; complete, rename or delete it through this id.
    public var id: String
    public var title: String
    public var completed: Bool
    public init(id: String, title: String, completed: Bool = false) { self.id = id; self.title = title; self.completed = completed }
}

public struct ReminderItem: Codable, Hashable, Sendable, Identifiable {
    /// RemCTL's numeric reminder id, as a string (stable).
    public var id: String
    /// RemCTL `deepLink`, kept to re-find an item if the local id changes.
    public var externalId: String?
    public var listId: String
    public var title: String
    public var notes: String
    public var due: DueDate?
    public var completed: Bool
    public var completionDate: Date?
    public var lastModified: Date?
    public var isRepeating: Bool
    /// The repeat rule when RemCTL's export object is one this app can represent; nil for other rules
    /// (then `isRepeating` is still true).
    public var recurrence: RepeatRule?
    /// The Reminders section the item sits in, if any.
    public var section: String?
    /// The rich link (RemCTL `url`); the notes never contain it.
    public var url: String?
    /// Tag names.
    public var tags: [String] {
        get { storedTags ?? [] }
        set { storedTags = newValue.isEmpty ? nil : newValue }
    }
    public var flagged: Bool {
        get { storedFlagged ?? false }
        set { storedFlagged = newValue ? true : nil }
    }
    /// The item's subtasks, in Reminders order. Subtask rows are never items of their own.
    public var subtasks: [ReminderSubtask] {
        get { storedSubtasks ?? [] }
        set { storedSubtasks = newValue.isEmpty ? nil : newValue }
    }
    // Stored optional so reminders saved before field fidelity still decode.
    private var storedTags: [String]?
    private var storedFlagged: Bool?
    private var storedSubtasks: [ReminderSubtask]?
    /// Set only on a subtask row; the engine never links such a row as a to-do.
    public var parentId: String?
    public init(id: String, externalId: String? = nil, listId: String, title: String, notes: String = "",
                due: DueDate? = nil, completed: Bool = false, completionDate: Date? = nil,
                lastModified: Date? = nil, isRepeating: Bool = false, section: String? = nil,
                recurrence: RepeatRule? = nil, url: String? = nil, tags: [String] = [], flagged: Bool = false,
                subtasks: [ReminderSubtask] = [], parentId: String? = nil) {
        self.url = url; self.parentId = parentId
        self.storedTags = tags.isEmpty ? nil : tags; self.storedFlagged = flagged ? true : nil
        self.storedSubtasks = subtasks.isEmpty ? nil : subtasks
        self.recurrence = recurrence
        self.id = id; self.externalId = externalId; self.listId = listId; self.title = title; self.notes = notes
        self.due = due; self.completed = completed; self.completionDate = completionDate
        self.lastModified = lastModified; self.isRepeating = isRepeating; self.section = section
    }
}

public struct ReminderPatch: Codable, Hashable, Sendable {
    public var title: String?
    public var notes: String?
    /// `.some(nil)` clears the due date.
    public var due: DueDate??
    public var completed: Bool?
    public var completionDate: Date?
    public var listId: String?
    /// `.some(name)` assigns the section (creating it when missing); `.some(nil)` asks to remove the
    /// reminder from its section (RemCTL 2.5.0 cannot; see docs/SPEC.md). Applied after any list move.
    public var section: String??
    /// `.some(rule)` sets the repeat rule; `.some(nil)` removes the repeat (`remctl edit --recurrence clear`).
    public var recurrence: RepeatRule??
    /// Adds a rich link (`--private --url`). RemCTL can never replace or clear one (viticci/remctl#79), so the engine
    /// only sets this on a reminder that has no link.
    public var url: String?
    public var flagged: Bool?
    /// Replaces ALL tags of the reminder (`--private --set-tags`; empty clears them).
    public var tags: [String]?
    /// Adds subtasks with these titles to the reminder (`--private --subtasks`).
    public var addSubtasks: [String]?
    public init(title: String? = nil, notes: String? = nil, due: DueDate?? = nil, completed: Bool? = nil,
                completionDate: Date? = nil, listId: String? = nil, section: String?? = nil, recurrence: RepeatRule?? = nil,
                url: String? = nil, flagged: Bool? = nil, tags: [String]? = nil, addSubtasks: [String]? = nil) {
        self.url = url; self.flagged = flagged; self.tags = tags; self.addSubtasks = addSubtasks
        self.title = title; self.notes = notes; self.due = due; self.completed = completed
        self.completionDate = completionDate; self.listId = listId; self.section = section; self.recurrence = recurrence
    }
    public var isEmpty: Bool {
        title == nil && notes == nil && due == nil && completed == nil && listId == nil && section == nil && recurrence == nil
            && url == nil && flagged == nil && tags == nil && (addSubtasks?.isEmpty ?? true)
    }
}

public enum RemindersAccess: String, Codable, Sendable { case notDetermined, granted, denied }

/// The Reminders side as the engine sees it. `RemCTLReminders` implements it; tests use a fake.
public protocol RemindersBackend: Sendable {
    func access() async -> RemindersAccess
    func requestAccess() async throws -> RemindersAccess
    func lists() async throws -> [ReminderList]
    /// All reminders (open and completed) in the given lists.
    func reminders(inLists listIds: [String]) async throws -> [ReminderItem]
    func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                section: String?, recurrence: RepeatRule?) async throws -> ReminderItem
    func update(id: String, patch: ReminderPatch) async throws -> ReminderItem
    /// Removes the reminder. Missing ids are not an error.
    func delete(id: String) async throws
    /// Yields when the Reminders content the engine watches changed (RemCTL polls; there is no push).
    func changes() -> AsyncStream<Void>
    /// Sections the backend itself created (a write with a section name the list did not have) since the last call.
    /// The engine records them as app-created so it may remove them again once they are empty.
    func takeCreatedSections() async -> [CreatedReminderSection]
    /// Deletes a section of a list (the reminders in it must already be gone). A missing section is not an error.
    func deleteSection(name: String, listId: String) async throws
}

/// A Reminders section the backend created while writing a reminder.
public struct CreatedReminderSection: Hashable, Sendable {
    public var listId: String
    public var name: String
    public init(listId: String, name: String) { self.listId = listId; self.name = name }
}

extension RemindersBackend {
    public func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String,
                       section: String?) async throws -> ReminderItem {
        try await create(title: title, notes: notes, due: due, completed: completed, completionDate: completionDate,
                         listId: listId, section: section, recurrence: nil)
    }
    public func takeCreatedSections() async -> [CreatedReminderSection] { [] }
    public func deleteSection(name: String, listId: String) async throws {}
}

// MARK: - Configuration

public enum MappingMode: String, Codable, CaseIterable, Sendable {
    /// The list mirrors one Things project.
    case project
    /// The list mirrors to-dos that sit directly in one Things area (not inside its projects).
    case area
    /// The list mirrors every to-do carrying one Things tag; new items land in the Things Inbox.
    case tag
    /// The list mirrors the to-dos under ONE heading of a project (`targetId` is the heading id).
    case heading
}

public struct ListMapping: Codable, Hashable, Sendable, Identifiable {
    /// Reminders list id (RemCTL numeric list id).
    public var id: String
    /// Last known list title, for display when the list is unavailable.
    public var listTitle: String
    public var enabled: Bool
    public var mode: MappingMode
    /// Existing Things project, area, or tag id. When nil the engine creates one named `targetTitle`.
    public var targetId: String?
    public var targetTitle: String
    /// For `.project` mode when the engine creates the project: the area to create it in.
    public var projectAreaId: String?
    /// True while the user is choosing a target after changing the mode. The engine neither syncs
    /// this mapping nor creates a target for it until the user picks one (or confirms "New…").
    public var awaitingTarget: Bool
    /// For `.heading` mode: the project the heading lives in (needed to create the heading).
    public var parentProjectId: String?
    /// For `.project` mode: mirror the reminder's section as the to-do's heading. Ignored in other modes.
    public var syncSections: Bool

    public init(id: String, listTitle: String, enabled: Bool = true, mode: MappingMode = .project,
                targetId: String? = nil, targetTitle: String, projectAreaId: String? = nil, awaitingTarget: Bool = false,
                parentProjectId: String? = nil, syncSections: Bool = true) {
        self.id = id; self.listTitle = listTitle; self.enabled = enabled; self.mode = mode
        self.targetId = targetId; self.targetTitle = targetTitle; self.projectAreaId = projectAreaId
        self.awaitingTarget = awaitingTarget; self.parentProjectId = parentProjectId; self.syncSections = syncSections
    }

    private enum CodingKeys: String, CodingKey {
        case id, listTitle, enabled, mode, targetId, targetTitle, projectAreaId, awaitingTarget, parentProjectId, syncSections
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        listTitle = try c.decode(String.self, forKey: .listTitle)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try c.decodeIfPresent(MappingMode.self, forKey: .mode) ?? .project
        targetId = try c.decodeIfPresent(String.self, forKey: .targetId)
        targetTitle = try c.decodeIfPresent(String.self, forKey: .targetTitle) ?? listTitle
        projectAreaId = try c.decodeIfPresent(String.self, forKey: .projectAreaId)
        awaitingTarget = try c.decodeIfPresent(Bool.self, forKey: .awaitingTarget) ?? false
        parentProjectId = try c.decodeIfPresent(String.self, forKey: .parentProjectId)
        syncSections = try c.decodeIfPresent(Bool.self, forKey: .syncSections) ?? true
    }
}

public struct SyncConfig: Codable, Hashable, Sendable {
    public var mappings: [ListMapping]
    /// Seconds between Things Cloud head checks.
    public var pollSeconds: Int
    /// Full two-way reconcile interval, catching anything a notification missed.
    public var reconcileMinutes: Int
    /// When a list is first linked, also link items already completed on either side.
    public var includeCompletedOnFirstLink: Bool
    /// Deleting on one side deletes (Reminders) or trashes (Things) on the other.
    public var propagateDeletes: Bool
    /// Seconds between RemCTL exports that detect Reminders changes.
    public var remindersPollSeconds: Int
    /// Explicit path to the `remctl` executable; nil searches `~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
    public var remctlPath: String?
    /// Title of the existing Things tag a flagged reminder carries (two-way). When no tag has this title the flag is
    /// not synced (nothing is created).
    public var flaggedTagTitle: String
    /// Writes Reminders subtasks to Things checklists (create, complete, delete). Off until the completion and
    /// deletion shapes of `ChecklistItem3` have been sampled from the Things app (docs/SPEC.md); Things checklists still
    /// sync to Reminders subtasks.
    public var syncChecklists: Bool

    public init(mappings: [ListMapping] = [], pollSeconds: Int = 15, reconcileMinutes: Int = 10,
                includeCompletedOnFirstLink: Bool = false, propagateDeletes: Bool = true,
                remindersPollSeconds: Int = 10, remctlPath: String? = nil,
                flaggedTagTitle: String = "Important", syncChecklists: Bool = false) {
        self.flaggedTagTitle = flaggedTagTitle; self.syncChecklists = syncChecklists
        self.mappings = mappings; self.pollSeconds = pollSeconds; self.reconcileMinutes = reconcileMinutes
        self.includeCompletedOnFirstLink = includeCompletedOnFirstLink; self.propagateDeletes = propagateDeletes
        self.remindersPollSeconds = remindersPollSeconds; self.remctlPath = remctlPath
    }

    /// Older config files lack the RemCTL fields; they decode with the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mappings = try c.decodeIfPresent([ListMapping].self, forKey: .mappings) ?? []
        pollSeconds = try c.decodeIfPresent(Int.self, forKey: .pollSeconds) ?? 15
        reconcileMinutes = try c.decodeIfPresent(Int.self, forKey: .reconcileMinutes) ?? 10
        includeCompletedOnFirstLink = try c.decodeIfPresent(Bool.self, forKey: .includeCompletedOnFirstLink) ?? false
        propagateDeletes = try c.decodeIfPresent(Bool.self, forKey: .propagateDeletes) ?? true
        remindersPollSeconds = try c.decodeIfPresent(Int.self, forKey: .remindersPollSeconds) ?? 10
        remctlPath = try c.decodeIfPresent(String.self, forKey: .remctlPath)
        flaggedTagTitle = try c.decodeIfPresent(String.self, forKey: .flaggedTagTitle) ?? "Important"
        syncChecklists = try c.decodeIfPresent(Bool.self, forKey: .syncChecklists) ?? false
    }
}

// MARK: - Activity log

public struct SyncLogEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable { case info, change, warning, error }
    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String
    public init(id: UUID = UUID(), date: Date = Date(), level: Level, message: String) {
        self.id = id; self.date = date; self.level = level; self.message = message
    }
}
