import Foundation

// MARK: - Fingerprint

/// What both sides of a linked pair looked like the last time the engine wrote them.
/// Comparing each side's current fingerprint with this one tells which side changed (and the loop
/// guard falls out of it: after a write the stored fingerprint is the written one, so the echo is a no-op).
public struct Fingerprint: Codable, Hashable, Sendable {
    public var title: String
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

    public init(title: String, notes: String, due: DueDate?, completed: Bool, completionDay: String?,
                group: String? = nil, stuckSection: String? = nil) {
        self.title = title; self.notes = notes; self.due = due
        self.completed = completed; self.completionDay = completionDay
        self.group = group; self.stuckSection = stuckSection
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

    public init(id: UUID = UUID(), reminderId: String, reminderExternalId: String? = nil, thingsId: String,
                mappingId: String, fingerprint: Fingerprint, lastSynced: Date = Date()) {
        self.id = id; self.reminderId = reminderId; self.reminderExternalId = reminderExternalId
        self.thingsId = thingsId; self.mappingId = mappingId; self.fingerprint = fingerprint; self.lastSynced = lastSynced
    }
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
    }

    public func count(mappingId: String) -> Int { links.reduce(0) { $0 + ($1.mappingId == mappingId ? 1 : 0) } }
    public var countsByMapping: [String: Int] { Dictionary(grouping: links, by: \.mappingId).mapValues(\.count) }
}
