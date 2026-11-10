import Foundation

/// Deletions in one list that the safety limit held back, for the menu and the Lists tab.
public struct HeldDeletions: Sendable, Equatable, Identifiable {
    public static let maxTitles = 5

    /// The Reminders list id (the mapping id).
    public var mappingId: String
    public var listTitle: String
    /// Reminders waiting to be deleted (their Things to-dos are gone).
    public var remindersToDelete: Int
    /// Things to-dos waiting to move to the Trash (their reminders are gone).
    public var todosToTrash: Int
    /// Up to `maxTitles` titles of the items waiting, in pass order.
    public var titles: [String]

    public var id: String { mappingId }
    public var count: Int { remindersToDelete + todosToTrash }

    public init(mappingId: String, listTitle: String, remindersToDelete: Int, todosToTrash: Int, titles: [String]) {
        self.mappingId = mappingId; self.listTitle = listTitle
        self.remindersToDelete = remindersToDelete; self.todosToTrash = todosToTrash
        self.titles = Array(titles.prefix(Self.maxTitles))
    }

    /// "12 deletions waiting in Family"
    public var summary: String { "\(count) \(count == 1 ? "deletion" : "deletions") waiting in \(listTitle)" }

    /// "Delete 9 reminders and move 3 to-dos to the Trash"
    public var detail: String {
        var parts: [String] = []
        if remindersToDelete > 0 { parts.append("delete \(remindersToDelete) \(remindersToDelete == 1 ? "reminder" : "reminders")") }
        if todosToTrash > 0 { parts.append("move \(todosToTrash) \(todosToTrash == 1 ? "to-do" : "to-dos") to the Trash") }
        let text = parts.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The confirmation text: what will happen, then the titles, then how many more there are.
    public var confirmationMessage: String {
        var lines = ["\(detail) in \(listTitle). The safety limit held these back because so many went at once."]
        if !titles.isEmpty {
            lines.append("")
            lines += titles.map { "• \($0)" }
            if count > titles.count { lines.append("and \(count - titles.count) more") }
        }
        return lines.joined(separator: "\n")
    }

    /// The held lists after a pass. A list the pass held again takes its new entry; a list whose deletions were forced
    /// is cleared; a clean full pass clears everything (the deletions are no longer pending); otherwise entries stay.
    public static func merged(_ current: [HeldDeletions], report: SyncReport, forcedAll: Bool, forcedLists: Set<String>,
                              fullPass: Bool) -> [HeldDeletions] {
        let fresh = Set(report.heldDeletions.map(\.mappingId))
        let cleanFull = fullPass && report.failures == 0
        let kept = (forcedAll || cleanFull) ? [] : current.filter { !forcedLists.contains($0.mappingId) && !fresh.contains($0.mappingId) }
        return (kept + report.heldDeletions).sorted { ($0.listTitle, $0.mappingId) < ($1.listTitle, $1.mappingId) }
    }
}
