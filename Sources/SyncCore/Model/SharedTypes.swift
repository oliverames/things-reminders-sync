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
    /// Repeating templates and their instances are never synced.
    public var isRepeating: Bool

    public init(id: String, kind: ThingsTaskKind = .todo, title: String, notes: String = "", status: ThingsStatus = .open,
                stopDate: Date? = nil, trashed: Bool = false, start: ThingsStart = .anytime, startDate: String? = nil,
                reminderSeconds: Int? = nil, evening: Bool = false, deadline: String? = nil, projectId: String? = nil,
                headingId: String? = nil, areaId: String? = nil, tagIds: [String] = [], creationDate: Date? = nil,
                modificationDate: Date? = nil, isRepeating: Bool = false) {
        self.id = id; self.kind = kind; self.title = title; self.notes = notes; self.status = status
        self.stopDate = stopDate; self.trashed = trashed; self.start = start; self.startDate = startDate
        self.reminderSeconds = reminderSeconds; self.evening = evening; self.deadline = deadline
        self.projectId = projectId; self.headingId = headingId; self.areaId = areaId; self.tagIds = tagIds
        self.creationDate = creationDate; self.modificationDate = modificationDate; self.isRepeating = isRepeating
    }
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

    public init(title: String? = nil, notes: String? = nil, when: DueDate?? = nil, completed: Bool? = nil,
                completionDate: Date? = nil, placement: ThingsPlacement? = nil, addTagIds: [String]? = nil,
                removeTagIds: [String]? = nil, trashed: Bool? = nil) {
        self.title = title; self.notes = notes; self.when = when; self.completed = completed
        self.completionDate = completionDate; self.placement = placement; self.addTagIds = addTagIds
        self.removeTagIds = removeTagIds; self.trashed = trashed
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && when == nil && completed == nil && placement == nil
            && addTagIds == nil && removeTagIds == nil && trashed == nil
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

    public init(title: String, notes: String = "", when: DueDate? = nil, completed: Bool = false,
                completionDate: Date? = nil, placement: ThingsPlacement = .inbox, tagIds: [String] = []) {
        self.title = title; self.notes = notes; self.when = when; self.completed = completed
        self.completionDate = completionDate; self.placement = placement; self.tagIds = tagIds
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
    func createArea(title: String) async throws -> String
    func createTag(title: String, parentId: String?) async throws -> String
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
    public init(id: String, title: String, colorHex: String? = nil, sourceTitle: String? = nil, allowsModifications: Bool = true) {
        self.id = id; self.title = title; self.colorHex = colorHex; self.sourceTitle = sourceTitle
        self.allowsModifications = allowsModifications
    }
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
    public init(id: String, externalId: String? = nil, listId: String, title: String, notes: String = "",
                due: DueDate? = nil, completed: Bool = false, completionDate: Date? = nil,
                lastModified: Date? = nil, isRepeating: Bool = false) {
        self.id = id; self.externalId = externalId; self.listId = listId; self.title = title; self.notes = notes
        self.due = due; self.completed = completed; self.completionDate = completionDate
        self.lastModified = lastModified; self.isRepeating = isRepeating
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
    public init(title: String? = nil, notes: String? = nil, due: DueDate?? = nil, completed: Bool? = nil,
                completionDate: Date? = nil, listId: String? = nil) {
        self.title = title; self.notes = notes; self.due = due; self.completed = completed
        self.completionDate = completionDate; self.listId = listId
    }
    public var isEmpty: Bool { title == nil && notes == nil && due == nil && completed == nil && listId == nil }
}

public enum RemindersAccess: String, Codable, Sendable { case notDetermined, granted, denied }

/// The Reminders side as the engine sees it. `RemCTLReminders` implements it; tests use a fake.
public protocol RemindersBackend: Sendable {
    func access() async -> RemindersAccess
    func requestAccess() async throws -> RemindersAccess
    func lists() async throws -> [ReminderList]
    /// All reminders (open and completed) in the given lists.
    func reminders(inLists listIds: [String]) async throws -> [ReminderItem]
    func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String) async throws -> ReminderItem
    func update(id: String, patch: ReminderPatch) async throws -> ReminderItem
    /// Removes the reminder. Missing ids are not an error.
    func delete(id: String) async throws
    /// Yields when the Reminders content the engine watches changed (RemCTL polls; there is no push).
    func changes() -> AsyncStream<Void>
}

// MARK: - Configuration

public enum MappingMode: String, Codable, CaseIterable, Sendable {
    /// The list mirrors one Things project.
    case project
    /// The list mirrors to-dos that sit directly in one Things area (not inside its projects).
    case area
    /// The list mirrors every to-do carrying one Things tag; new items land in the Things Inbox.
    case tag
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

    public init(id: String, listTitle: String, enabled: Bool = true, mode: MappingMode = .project,
                targetId: String? = nil, targetTitle: String, projectAreaId: String? = nil, awaitingTarget: Bool = false) {
        self.id = id; self.listTitle = listTitle; self.enabled = enabled; self.mode = mode
        self.targetId = targetId; self.targetTitle = targetTitle; self.projectAreaId = projectAreaId
        self.awaitingTarget = awaitingTarget
    }

    private enum CodingKeys: String, CodingKey { case id, listTitle, enabled, mode, targetId, targetTitle, projectAreaId, awaitingTarget }

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

    public init(mappings: [ListMapping] = [], pollSeconds: Int = 15, reconcileMinutes: Int = 10,
                includeCompletedOnFirstLink: Bool = false, propagateDeletes: Bool = true,
                remindersPollSeconds: Int = 10, remctlPath: String? = nil) {
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
