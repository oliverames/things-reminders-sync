import Foundation

// Assignee tags (docs/SPEC.md, "Assignee tags"): a linked to-do carrying a tag named in `ListMapping.assigneeTags`
// assigns its reminder to the mapped sharee. Things to Reminders only: RemCTL shows no assignment in any read.

extension SyncPass {
    /// The sharee the to-do's tags ask for: the first key of the map, in sorted key order, whose tag the to-do
    /// carries (tag titles match without case, as in tag sync). `several` is true when more than one key matched.
    func wantedAssignee(_ task: ThingsTask, _ m: ListMapping) -> (sharee: String?, several: Bool) {
        let carried = Set(task.tagIds.compactMap { snapshot.tags[$0]?.title }.map(TagEnvironment.key))
        let matches = m.assigneeTags.keys.sorted().filter { carried.contains(TagEnvironment.key(m.assigneeTags[$0] ?? "")) }
        return (matches.first, matches.count > 1)
    }

    /// Writes the assignment when it differs from the last one written, and carries the two fingerprint fields over.
    /// A failed write (the list is not shared, say) is logged once and tried again only when the to-do's tags or the
    /// wanted sharee change. Never writes in a list that is one-way from Reminders.
    func syncAssignee(base: Fingerprint, fingerprint fp: inout Fingerprint, reminderId: String, reminder: ReminderItem,
                      task: ThingsTask, mapping m: ListMapping?) async {
        fp.assignee = base.assignee
        fp.assigneeFailed = base.assigneeFailed
        guard let m, !m.assigneeTags.isEmpty, m.direction.source != .reminders,
              !reminder.completed, task.status == .open else { return }
        let (wanted, several) = wantedAssignee(task, m)
        if wanted == base.assignee { fp.assigneeFailed = nil; return }
        let attempt = task.tagIds.sorted().joined(separator: ",") + "\u{1F}" + (wanted ?? "")
        if base.assigneeFailed == attempt { return }
        if several, let wanted {
            log(.info, "\"\(task.title)\" carries more than one assignee tag; assigning to \(wanted), the first in key order")
        }
        do {
            _ = try await reminders.update(id: reminderId, patch: ReminderPatch(assignee: .some(wanted)))
            fp.assignee = wanted
            fp.assigneeFailed = nil
            report.updatedInReminders += 1
            log(.change, wanted.map { "Assigned reminder \"\(reminder.title)\" to \($0)" } ?? "Cleared the assignment of reminder \"\(reminder.title)\"")
        } catch {
            fp.assigneeFailed = attempt
            log(.warning, "Could not \(wanted == nil ? "clear" : "set") the assignment of \"\(reminder.title)\" (is the list shared?): \(error.localizedDescription)")
        }
    }
}
