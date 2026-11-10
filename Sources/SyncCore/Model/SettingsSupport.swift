import Foundation

// Logic behind the Settings controls for the per-list preferences and the global tag options. It lives here, not in
// the views, so it is tested (SettingsSupportTests.swift).

/// A per-list override of a global on/off setting, as a three-way choice.
public enum OverrideChoice: String, CaseIterable, Sendable, Identifiable {
    case global, on, off

    public var id: String { rawValue }

    public init(_ value: Bool?) {
        switch value {
        case nil: self = .global
        case true?: self = .on
        case false?: self = .off
        }
    }

    /// The value stored in `ListMapping`: nil follows the global setting.
    public var value: Bool? {
        switch self {
        case .global: return nil
        case .on: return true
        case .off: return false
        }
    }
}

/// A per-list preference that some modes or directions ignore.
public enum ListPreference: Sendable, CaseIterable {
    case undatedArriveAs, alwaysTag, eveningFromHour, canceledBecomes, assigneeTags, sectionsAsProjects
}

extension ListMapping {
    /// The tag put on every to-do, or nil when unset or blank.
    public var effectiveAlwaysTag: String? {
        guard let tag = alwaysTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else { return nil }
        return tag
    }

    /// True when a preference in the list's Options sheet differs from its default, so the row can say so.
    /// `paused` and `syncSections` have their own controls on the row and do not count. `sectionsAsProjects` counts
    /// only in area mode, the one mode that reads it.
    public var hasCustomPreferences: Bool {
        direction != .twoWay || propagateDeletes != nil || undatedArriveAs != .anytime || effectiveAlwaysTag != nil
            || includeCompletedOnFirstLink != nil || syncChecklists != nil || dueMapsTo != .when
            || eveningFromMinutes != nil || canceledBecomes != .completed || !syncSomeday || !assigneeTags.isEmpty
            || sectionsAreProjects
    }

    /// Why the list ignores a preference as it is set up now, in one plain line, or nil when the preference applies.
    /// `deletesPropagate` is the global "propagate deletes" setting, used when the list has no override.
    public func reasonIgnored(_ preference: ListPreference, deletesPropagate: Bool) -> String? {
        switch preference {
        case .undatedArriveAs:
            return direction == .thingsToReminders
                ? "Not used: this list syncs from Things only, so the app creates no to-dos." : nil
        case .alwaysTag:
            return direction == .thingsToReminders
                ? "Not used: this list syncs from Things only, so the app writes nothing to Things." : nil
        case .eveningFromHour:
            if dueMapsTo == .deadline { return "Not used while due dates map to deadlines." }
            return direction == .thingsToReminders
                ? "Not used: this list syncs from Things only, so the app moves no to-dos." : nil
        case .canceledBecomes:
            if direction == .remindersToThings {
                return "Not used: this list syncs from Reminders only, so the app writes nothing to Reminders."
            }
            return (propagateDeletes ?? deletesPropagate)
                ? nil : "Deleting needs deletes to be passed on for this list. Until then the reminder is completed."
        case .assigneeTags:
            return direction == .remindersToThings
                ? "Not used: this list syncs from Reminders only, so the app writes nothing to Reminders." : nil
        case .sectionsAsProjects:
            return mode == .area ? nil : "Only for lists mirrored as a Things area."
        }
    }
}

extension SyncConfig {
    /// The flag tag title, or nil when blank (the flag is then not synced).
    public var effectiveFlaggedTag: String? {
        let title = flaggedTagTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// The priority tag title, or nil when unset or blank.
    public var effectivePriorityTag: String? {
        guard let title = priorityTag?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// True when the priority tag and the flag tag name the same tag. The engine then ignores the priority tag.
    public var priorityTagClashesWithFlag: Bool {
        guard let priority = effectivePriorityTag else { return false }
        return priority == effectiveFlaggedTag
    }
}

/// The choices of a tag picker: the titles of the existing Things tags, plus the saved title when no tag has it.
public struct TagMenu: Hashable, Sendable {
    /// Existing tag titles, alphabetical, each once.
    public var titles: [String]
    /// The saved title when Things has no tag of exactly that title. It stays selectable so the picker can show it.
    public var missing: String?

    public init(known: [String], current: String?) {
        var seen = Set<String>()
        titles = known.filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let wanted = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        missing = wanted.isEmpty || seen.contains(wanted) ? nil : wanted
    }
}

/// One row of the assignee editor: a person the list is shared with and the Things tag that stands for them.
public struct AssigneeTagRow: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// A Reminders sharee id, email address, objectUUID, or "me".
    public var sharee: String
    /// A Things tag title; empty until one is picked.
    public var tag: String

    public init(id: UUID = UUID(), sharee: String = "", tag: String = "") {
        self.id = id; self.sharee = sharee; self.tag = tag
    }

    /// True when the row has both a person and a tag and so can be saved.
    public var isComplete: Bool {
        !sharee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !tag.isEmpty
    }

    /// The rows for a saved `assigneeTags` value, in sorted key order: the order the engine uses when a to-do
    /// carries two mapped tags.
    public static func rows(from assigneeTags: [String: String]) -> [AssigneeTagRow] {
        assigneeTags.keys.sorted().map { AssigneeTagRow(sharee: $0, tag: assigneeTags[$0] ?? "") }
    }

    /// The `assigneeTags` value for the rows. Incomplete rows are left out, and when two rows name the same person
    /// the first one is kept.
    public static func assigneeTags(from rows: [AssigneeTagRow]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows where row.isComplete {
            let sharee = row.sharee.trimmingCharacters(in: .whitespacesAndNewlines)
            if result[sharee] == nil { result[sharee] = row.tag }
        }
        return result
    }
}
