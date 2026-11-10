import Foundation

// MARK: - Fingerprint

/// What both sides of a linked pair looked like the last time the engine wrote them.
/// Comparing each side's current fingerprint with this one tells which side changed (and the loop
/// guard falls out of it: after a write the stored fingerprint is the written one, so the echo is a no-op).
public struct Fingerprint: Codable, Hashable, Sendable {
    public var title: String
    /// The notes of the Things to-do as last written or seen (trimmed). With `remindersNotes` and `url` below this is
    /// the notes triple: Things holds Markdown plus an optional trailing link line, Reminders holds plain notes plus a
    /// rich link, and the two are different renderings of one text (see `NoteFormatting` and docs/SPEC.md).
    public var notes: String
    public var due: DueDate?
    public var completed: Bool
    /// Local calendar day of completion (`YYYY-MM-DD`), when completed and known.
    public var completionDay: String?
    /// The group (Reminders section / Things heading title) both sides had when last written, in its
    /// original spelling; nil for none. Links saved before sections existed decode it as nil.
    public var group: String?
    /// A Reminders section the reminder could not be removed from (RemCTL cannot clear one) while the
    /// Things side sits at no heading. A reminder still reading this section is not a change.
    public var stuckSection: String?
    /// For a repeating pair: the rule both sides last agreed on (compared through `RepeatRule.key`). Nil for plain
    /// pairs, and for a repeating pair whose rule cannot be synced. Links saved before repeating sync decode it as nil.
    public var rule: RepeatRule?
    /// The reminder's notes (trimmed) as last written or seen. Nil on links saved before field fidelity: both sides'
    /// notes were then equal to `notes`, and `url` is unknown (see `SyncPass.decideNotes`).
    public var remindersNotes: String?
    /// The reminder's rich link as last written or seen; meaningful only when `remindersNotes` is set.
    public var url: String?
    /// Flagged state both sides agreed on (Things: carries the flagged tag). Nil: never synced, read as not flagged.
    public var flagged: Bool?
    /// Titles of the tags both sides agreed on (only tags that exist in Things). Nil: never synced, read as none.
    public var tags: [String]?
    /// Subtasks / checklist items both sides agreed on. Nil: never synced, read as none.
    public var checklist: [ChecklistEntry]?
    /// Set when the to-do was created in Today for a reminder with no due date (`ListMapping.undatedArriveAs`): the
    /// start day it was given. While the to-do still starts on that day with no time and the reminder has no due
    /// date, that day is not a due date and is not copied to Reminders. Cleared as soon as either side changes its date.
    public var undatedThingsDay: String? = nil

    public struct ChecklistEntry: Codable, Hashable, Sendable {
        public var title: String
        public var done: Bool
        public init(title: String, done: Bool) { self.title = title; self.done = done }
    }

    public init(title: String, notes: String, due: DueDate?, completed: Bool, completionDay: String?,
                group: String? = nil, stuckSection: String? = nil, rule: RepeatRule? = nil,
                remindersNotes: String? = nil, url: String? = nil, flagged: Bool? = nil, tags: [String]? = nil,
                checklist: [ChecklistEntry]? = nil) {
        self.title = title; self.notes = notes; self.due = due
        self.completed = completed; self.completionDay = completionDay
        self.group = group; self.stuckSection = stuckSection; self.rule = rule
        self.remindersNotes = remindersNotes; self.url = url; self.flagged = flagged; self.tags = tags; self.checklist = checklist
    }

    static func normalize(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A group name trimmed; blank is no group.
    static func cleanGroup(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = normalize(name)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Comparison key: trimmed and case-insensitive.
    static func groupKey(_ name: String?) -> String? { cleanGroup(name)?.lowercased() }

    init(reminder r: ReminderItem, days: DayFormatter, group: String? = nil) {
        self.init(title: Self.normalize(r.title), notes: Self.normalize(r.notes), due: r.due, completed: r.completed,
                  completionDay: r.completed ? r.completionDate.map(days.day) : nil, group: Self.cleanGroup(group))
    }

    init(things t: ThingsTask, days: DayFormatter, group: String? = nil) {
        let done = t.status != .open   // Things canceled counts as completed in Reminders.
        self.init(title: Self.normalize(t.title), notes: Self.normalize(t.notes), due: t.due, completed: done,
                  completionDay: done ? t.stopDate.map(days.day) : nil, group: Self.cleanGroup(group))
    }

    /// True when the completion state differs. The completion day only counts when both days are known.
    static func completionDiffers(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        if a.completed != b.completed { return true }
        guard a.completed, let x = a.completionDay, let y = b.completionDay else { return false }
        return x != y
    }
}

// MARK: - Mapping helpers (Things start date + reminder time <-> DueDate)

extension ThingsTask {
    /// Things "When" day plus reminder time, as a shared `DueDate`. Items without a start date have no due date.
    public var due: DueDate? {
        guard let day = startDate else { return nil }
        return DueDate(day: day, minutes: reminderSeconds.map { $0 / 60 })
    }
}

extension DueDate {
    /// Things `ato`: seconds after local midnight.
    public var reminderSeconds: Int? { minutes.map { $0 * 60 } }
}

struct DayFormatter: Sendable {
    var timeZone: TimeZone
    func day(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Link state

public struct LinkRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var reminderId: String
    public var reminderExternalId: String?
    public var thingsId: String
    /// `ListMapping.id` (the Reminders list id) this pair currently belongs to.
    public var mappingId: String
    public var fingerprint: Fingerprint
    public var lastSynced: Date
    /// Which side is the app's own copy: `.things` when the engine created the to-do from a reminder,
    /// `.reminders` when it created the reminder from a to-do, nil when both existed before (paired by title,
    /// or unknown). Only a copy is ever removed when the user stops syncing a list.
    public var copySide: Side?
    /// True when the copy was made because "include completed on first link" brought a completed item over.
    public var copiedCompleted: Bool
    /// How a repeating item is paired; nil for plain pairs (including a plain pair on one occurrence of a Things
    /// template whose rule Reminders cannot hold).
    public var repeatMode: RepeatLinkMode?
    /// `.reminderRepeats` pairs: the reminder has moved on to its next occurrence and the Things to-do for it is still
    /// to be created (the create failed, or the pass was cut short). Saved as soon as the reminder has moved, so the
    /// next pass creates the to-do instead of completing the reminder a second time.
    public var awaitingReplacement: Bool

    public init(id: UUID = UUID(), reminderId: String, reminderExternalId: String? = nil, thingsId: String,
                mappingId: String, fingerprint: Fingerprint, lastSynced: Date = Date(),
                copySide: Side? = nil, copiedCompleted: Bool = false, repeatMode: RepeatLinkMode? = nil,
                awaitingReplacement: Bool = false) {
        self.repeatMode = repeatMode; self.awaitingReplacement = awaitingReplacement
        self.id = id; self.reminderId = reminderId; self.reminderExternalId = reminderExternalId
        self.thingsId = thingsId; self.mappingId = mappingId; self.fingerprint = fingerprint; self.lastSynced = lastSynced
        self.copySide = copySide; self.copiedCompleted = copiedCompleted
    }

    /// Links saved before the ownership ledger decode with no copy side.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        reminderId = try c.decode(String.self, forKey: .reminderId)
        reminderExternalId = try c.decodeIfPresent(String.self, forKey: .reminderExternalId)
        thingsId = try c.decode(String.self, forKey: .thingsId)
        mappingId = try c.decode(String.self, forKey: .mappingId)
        fingerprint = try c.decode(Fingerprint.self, forKey: .fingerprint)
        lastSynced = try c.decode(Date.self, forKey: .lastSynced)
        copySide = try c.decodeIfPresent(Side.self, forKey: .copySide)
        copiedCompleted = try c.decodeIfPresent(Bool.self, forKey: .copiedCompleted) ?? false
        repeatMode = try c.decodeIfPresent(RepeatLinkMode.self, forKey: .repeatMode)
        awaitingReplacement = try c.decodeIfPresent(Bool.self, forKey: .awaitingReplacement) ?? false
    }
}

/// What a repeating pair links.
public enum RepeatLinkMode: String, Codable, Hashable, Sendable {
    /// A repeating reminder and the Things TEMPLATE; the rule syncs both ways.
    case template
    /// A repeating reminder and a plain Things to-do for its current occurrence (the Things side cannot hold the
    /// rule). Completing either advances the reminder and replaces the to-do.
    case reminderRepeats
}

public struct LinkStore: Codable, Hashable, Sendable {
    public var links: [LinkRecord]
    /// Mapping id -> signature (`mode:targetId`) of the target that was first-linked. A mapping whose
    /// signature is absent or different gets a first-link pass (title pairing) before anything is created.
    public var linkedMappings: [String: String]
    /// Items whose link was dropped on purpose (moved out of scope, deleted on the other side with
    /// deletes off, or repeating). They never get a partner created again, which would resurrect a
    /// deleted item or duplicate a moved one. Full passes prune ids that no longer exist.
    public var detachedThingsIds: Set<String>
    public var detachedReminderIds: Set<String>
    /// Links dropped because an item moved out of scope. When both items are back in scope the link is
    /// restored (and syncs from its old fingerprint); if one item disappears, the other is freed.
    public var parkedLinks: [LinkRecord] = []
    /// Things projects, areas, tags, and headings this app created (ownership ledger). Only these are ever removed.
    public var ownedThings: [OwnedThingsContainer] = []
    /// Reminders sections this app created.
    public var ownedSections: [OwnedReminderSection] = []
    /// Set once the one-time ledger inference for data created before the ledger existed has run.
    public var ledgerBackfilled = false
    /// Mapping ids seen paused. A list stays here until the first full pass without failures after it resumes; until
    /// then an item missing on one side of its pairs is never treated as a deletion (the pair is unlinked instead).
    public var pausedMappings: Set<String> = []

    public init(links: [LinkRecord] = [], linkedMappings: [String: String] = [:],
                detachedThingsIds: Set<String> = [], detachedReminderIds: Set<String> = []) {
        self.links = links; self.linkedMappings = linkedMappings
        self.detachedThingsIds = detachedThingsIds; self.detachedReminderIds = detachedReminderIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        links = try c.decodeIfPresent([LinkRecord].self, forKey: .links) ?? []
        linkedMappings = try c.decodeIfPresent([String: String].self, forKey: .linkedMappings) ?? [:]
        detachedThingsIds = try c.decodeIfPresent(Set<String>.self, forKey: .detachedThingsIds) ?? []
        detachedReminderIds = try c.decodeIfPresent(Set<String>.self, forKey: .detachedReminderIds) ?? []
        parkedLinks = try c.decodeIfPresent([LinkRecord].self, forKey: .parkedLinks) ?? []
        ownedThings = try c.decodeIfPresent([OwnedThingsContainer].self, forKey: .ownedThings) ?? []
        ownedSections = try c.decodeIfPresent([OwnedReminderSection].self, forKey: .ownedSections) ?? []
        ledgerBackfilled = try c.decodeIfPresent(Bool.self, forKey: .ledgerBackfilled) ?? false
        pausedMappings = try c.decodeIfPresent(Set<String>.self, forKey: .pausedMappings) ?? []
    }

    public func count(mappingId: String) -> Int { links.reduce(0) { $0 + ($1.mappingId == mappingId ? 1 : 0) } }
    public var countsByMapping: [String: Int] { Dictionary(grouping: links, by: \.mappingId).mapValues(\.count) }
}
