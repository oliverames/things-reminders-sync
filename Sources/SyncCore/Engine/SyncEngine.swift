import Foundation

public enum SyncScope: Sendable, Equatable {
    /// Re-read everything and reconcile every enabled mapping (also runs first-link pairing).
    case full
    /// Only the given Things items and/or whatever changed in Reminders.
    case targeted(thingsIds: Set<String>, remindersChanged: Bool)
}

public struct SyncReport: Sendable {
    /// The configuration with newly created target ids written back.
    public var config: SyncConfig
    public var links: LinkStore
    public var createdInThings = 0
    public var createdInReminders = 0
    public var updatedInThings = 0
    public var updatedInReminders = 0
    /// Things to-dos moved to the Trash.
    public var deletedInThings = 0
    public var deletedInReminders = 0
    /// Existing items paired by title on first link.
    public var linked = 0
    /// Links dropped (item moved out of scope, or an unpropagated deletion).
    public var unlinked = 0
    /// Per-item failures; the failed items are retried on the next pass.
    public var failures = 0
    public var firstFailure: String?
    /// True when the deletion safety limit held back deletions.
    public var deletionsHeld = false
    public var log: [SyncLogEntry] = []
    public var snapshot = ThingsSnapshot()
    public var reminderLists: [ReminderList] = []

    public var changeCount: Int {
        createdInThings + createdInReminders + updatedInThings + updatedInReminders
            + deletedInThings + deletedInReminders + linked + unlinked
    }
}

/// Pure sync logic against the two backends (docs/SPEC.md). All state lives in the arguments and the report.
public struct SyncEngine: Sendable {
    public static let maxDeletionsPerPass = 10
    public static let maxDeletionFraction = 0.25

    let things: any ThingsBackend
    let reminders: any RemindersBackend
    let timeZone: TimeZone

    public init(things: any ThingsBackend, reminders: any RemindersBackend, timeZone: TimeZone = .current) {
        self.things = things; self.reminders = reminders; self.timeZone = timeZone
    }

    /// Runs one pass. `forceDeletions` lifts the deletion safety limit (the user acknowledged it with Sync Now).
    public func sync(config: SyncConfig, links: LinkStore, scope: SyncScope, forceDeletions: Bool = false) async throws -> SyncReport {
        let pass = SyncPass(engine: self, config: config, store: links, scope: scope, force: forceDeletions)
        return try await pass.run()
    }
}

// MARK: - One pass

private enum PendingDelete {
    case trashThings(String)
    case deleteReminder(String)
}

private struct MergePlan {
    var reminderPatch = ReminderPatch()
    var thingsPatch = ThingsTodoPatch()
    var fingerprint: Fingerprint
    var conflicts: [String] = []
}

private final class SyncPass {
    let things: any ThingsBackend
    let reminders: any RemindersBackend
    let days: DayFormatter
    var config: SyncConfig
    var store: LinkStore
    let scope: SyncScope
    let force: Bool
    var report: SyncReport

    var snapshot = ThingsSnapshot()
    var remindersById: [String: ReminderItem] = [:]
    var remindersByExternal: [String: ReminderItem] = [:]
    var activeById: [String: ListMapping] = [:]
    var activeOrder: [ListMapping] = []
    var thingsScope: [String: String] = [:]
    var pendingDeletes: [String: [(linkId: UUID, action: PendingDelete, title: String)]] = [:]
    var removedLinks: Set<UUID> = []
    var failedMappings: Set<String> = []

    init(engine: SyncEngine, config: SyncConfig, store: LinkStore, scope: SyncScope, force: Bool) {
        things = engine.things; reminders = engine.reminders; days = DayFormatter(timeZone: engine.timeZone)
        self.config = config; self.store = store; self.scope = scope; self.force = force
        report = SyncReport(config: config, links: store)
    }

    var isFull: Bool { if case .full = scope { return true } else { return false } }
    var targetedIds: Set<String> { if case .targeted(let ids, _) = scope { return ids } else { return [] } }
    var remindersChanged: Bool { if case .targeted(_, let r) = scope { return r } else { return true } }

    func log(_ level: SyncLogEntry.Level, _ message: String) {
        report.log.append(SyncLogEntry(level: level, message: message))
    }

    func fail(_ message: String) {
        report.failures += 1
        if report.firstFailure == nil { report.firstFailure = message }
        log(.error, message)
    }

    // MARK: Run

    func run() async throws -> SyncReport {
        await ensureTargets()
        let refresh = try await things.refresh()
        snapshot = refresh.snapshot
        let lists = try await reminders.lists()
        let items = try await reminders.reminders(inLists: lists.map(\.id))
        for r in items {
            remindersById[r.id] = r
            if let e = r.externalId { remindersByExternal[e] = r }
        }
        buildActiveMappings(lists: lists)
        buildThingsScope()

        let linksAtStart = store.links
        let linkedThings = Set(linksAtStart.map(\.thingsId))
        let linkedReminders = Set(linksAtStart.map(\.reminderId))
        for link in linksAtStart { await processLink(link) }
        await processUnlinked(linkedThings: linkedThings, linkedReminders: linkedReminders)
        await runDeletions(linksAtStart: linksAtStart)

        store.links.removeAll { removedLinks.contains($0.id) }
        if isFull {
            store.detachedThingsIds = store.detachedThingsIds.filter { snapshot.tasks[$0].map { !$0.trashed } ?? false }
            store.detachedReminderIds = store.detachedReminderIds.filter { remindersById[$0] != nil }
        }
        report.links = store
        report.config = config
        report.snapshot = snapshot
        report.reminderLists = lists
        return report
    }

    // MARK: Targets and mappings

    func ensureTargets() async {
        for i in config.mappings.indices where config.mappings[i].enabled && config.mappings[i].targetId == nil {
            let m = config.mappings[i]
            do {
                let id: String
                switch m.mode {
                case .project: id = try await things.createProject(title: m.targetTitle, areaId: m.projectAreaId)
                case .area: id = try await things.createArea(title: m.targetTitle)
                case .tag: id = try await things.createTag(title: m.targetTitle, parentId: nil)
                }
                config.mappings[i].targetId = id
                log(.change, "Created Things \(m.mode.rawValue) \"\(m.targetTitle)\" for list \"\(m.listTitle)\"")
            } catch {
                fail("Could not create Things \(m.mode.rawValue) \"\(m.targetTitle)\": \(error.localizedDescription)")
            }
        }
    }

    func buildActiveMappings(lists: [ReminderList]) {
        let listsById = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
        for m in config.mappings where m.enabled {
            guard let list = listsById[m.id] else {
                log(.warning, "Reminders list \"\(m.listTitle)\" is not available; skipped")
                continue
            }
            guard list.allowsModifications else {
                log(.warning, "Reminders list \"\(list.title)\" is read-only; skipped")
                continue
            }
            guard let target = m.targetId, targetExists(m.mode, target) else {
                if m.targetId != nil { log(.warning, "Things \(m.mode.rawValue) for \"\(m.listTitle)\" no longer exists; skipped") }
                continue
            }
            activeById[m.id] = m
            activeOrder.append(m)
        }
    }

    func targetExists(_ mode: MappingMode, _ id: String) -> Bool {
        switch mode {
        case .project: if let t = snapshot.tasks[id] { return t.kind == .project && !t.trashed } else { return false }
        case .area: return snapshot.areas[id] != nil
        case .tag: return snapshot.tags[id] != nil
        }
    }

    func signature(_ m: ListMapping) -> String { "\(m.mode.rawValue):\(m.targetId ?? "")" }

    /// Maps each in-scope Things to-do to the first matching mapping (config order).
    func buildThingsScope() {
        for task in snapshot.tasks.values.sorted(by: { $0.id < $1.id }) {
            guard task.kind == .todo, !task.trashed, !task.isRepeating else { continue }
            for m in activeOrder where matches(task, m) {
                thingsScope[task.id] = m.id
                break
            }
        }
    }

    func matches(_ task: ThingsTask, _ m: ListMapping) -> Bool {
        guard let target = m.targetId else { return false }
        switch m.mode {
        case .project:
            if task.projectId == target { return true }
            if let h = task.headingId, let heading = snapshot.tasks[h], heading.projectId == target { return true }
            return false
        case .area:
            return task.areaId == target && task.projectId == nil && task.headingId == nil
        case .tag:
            return task.tagIds.contains(target)
        }
    }

    // MARK: Existing links

    func included(_ link: LinkRecord) -> Bool {
        isFull || remindersChanged || targetedIds.contains(link.thingsId)
    }

    func findReminder(_ link: LinkRecord) -> ReminderItem? {
        if let r = remindersById[link.reminderId] { return r }
        if let e = link.reminderExternalId { return remindersByExternal[e] }
        return nil
    }

    func unlink(_ link: LinkRecord, _ reason: String) {
        removedLinks.insert(link.id)
        store.detachedThingsIds.insert(link.thingsId)
        store.detachedReminderIds.insert(link.reminderId)
        report.unlinked += 1
        log(.info, "Unlinked \"\(link.fingerprint.title)\": \(reason)")
    }

    func processLink(_ link: LinkRecord) async {
        guard let mapping = activeById[link.mappingId], included(link) else { return }
        let reminder = findReminder(link)
        let task = snapshot.tasks[link.thingsId]
        let thingsGone = task == nil || task!.trashed
        let title = link.fingerprint.title

        switch (reminder, thingsGone) {
        case (nil, true):
            removedLinks.insert(link.id)
            log(.info, "Dropped link for \"\(title)\": gone on both sides")
            return
        case (nil, false):
            if config.propagateDeletes { queueDelete(mapping.id, link.id, .trashThings(link.thingsId), title) }
            else { unlink(link, "reminder deleted (deletes are not propagated)") }
            return
        case (_, true):
            if config.propagateDeletes, let r = reminder { queueDelete(mapping.id, link.id, .deleteReminder(r.id), title) }
            else { unlink(link, "Things to-do deleted (deletes are not propagated)") }
            return
        default: break
        }
        guard let reminder, let task else { return }

        if reminder.isRepeating || task.isRepeating { unlink(link, "repeating item"); return }
        let rm = activeById[reminder.listId]?.id
        let tm = thingsScope[task.id]
        guard let rm, let tm else { unlink(link, "moved out of scope"); return }

        var destination: ListMapping?
        var movedThings = false   // true: the Things side must follow the reminder
        var movedReminder = false
        if tm != rm {
            let thingsMoved = tm != link.mappingId
            let reminderMoved = rm != link.mappingId
            let follow: Side
            if thingsMoved && !reminderMoved { follow = .things }
            else if reminderMoved && !thingsMoved { follow = .reminders }
            else { follow = laterSide(reminder.lastModified, task.modificationDate) }
            if follow == .things { destination = activeById[tm]; movedReminder = true }
            else { destination = activeById[rm]; movedThings = true }
        }

        var plan = merge(base: link.fingerprint, reminder: reminder, task: task)
        if let destination {
            if movedReminder { plan.reminderPatch.listId = destination.id }
            if movedThings { applyPlacement(&plan.thingsPatch, task: task, old: activeById[tm], new: destination) }
        }
        let newMapping = destination?.id ?? tm
        do {
            var updated = link
            if !plan.reminderPatch.isEmpty {
                let r = try await reminders.update(id: reminder.id, patch: plan.reminderPatch)
                updated.reminderId = r.id; updated.reminderExternalId = r.externalId ?? updated.reminderExternalId
                report.updatedInReminders += 1
                log(.change, "Updated reminder \"\(r.title)\"" + (destination != nil && movedReminder ? " (moved to \"\(destination!.listTitle)\")" : ""))
            }
            if !plan.thingsPatch.isEmpty {
                try await things.updateTodo(id: task.id, patch: plan.thingsPatch)
                report.updatedInThings += 1
                log(.change, "Updated Things to-do \"\(task.title)\"" + (destination != nil && movedThings ? " (moved to \"\(destination!.listTitle)\")" : ""))
            }
            for field in plan.conflicts {
                log(.warning, "Conflict on \"\(plan.fingerprint.title)\" (\(field)); the newer edit won")
            }
            updated.fingerprint = plan.fingerprint
            updated.mappingId = newMapping
            updated.lastSynced = Date()
            replace(updated)
        } catch {
            fail("Could not sync \"\(title)\": \(error.localizedDescription)")
        }
    }

    func replace(_ link: LinkRecord) {
        if let i = store.links.firstIndex(where: { $0.id == link.id }) { store.links[i] = link }
    }

    func queueDelete(_ mappingId: String, _ linkId: UUID, _ action: PendingDelete, _ title: String) {
        pendingDeletes[mappingId, default: []].append((linkId, action, title))
    }

    func applyPlacement(_ patch: inout ThingsTodoPatch, task: ThingsTask, old: ListMapping?, new: ListMapping) {
        guard let target = new.targetId else { return }
        var remove: [String] = []
        if let old, old.mode == .tag, let oldTag = old.targetId, oldTag != target, task.tagIds.contains(oldTag) { remove.append(oldTag) }
        switch new.mode {
        case .project: patch.placement = .project(target)
        case .area: patch.placement = .area(target)
        case .tag:
            if !task.tagIds.contains(target) { patch.addTagIds = [target] }
            if let old, old.mode != .tag { patch.placement = .inbox }
        }
        if !remove.isEmpty { patch.removeTagIds = remove }
    }

    // MARK: Merge

    enum Side { case reminders, things }

    func laterSide(_ r: Date?, _ t: Date?) -> Side {
        if let r, let t { return r > t ? .reminders : .things }
        if r != nil { return .reminders }
        return .things
    }

    /// Per-field three-way merge. `base == nil` (first link) treats every differing field as a conflict.
    func merge(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask) -> MergePlan {
        let rf = Fingerprint(reminder: r, days: days)
        let tf = Fingerprint(things: t, days: days)
        var plan = MergePlan(fingerprint: rf)
        let later = laterSide(r.lastModified, t.modificationDate)

        func decide(_ field: String, equal: Bool, rChanged: Bool, tChanged: Bool, tiebreak: Side? = nil) -> Side? {
            if equal { return nil }
            if rChanged && !tChanged { return .reminders }
            if tChanged && !rChanged { return .things }
            if base != nil { plan.conflicts.append(field) }
            return tiebreak ?? later
        }

        // First link (no base) is conservative: modification times are not comparable yet (RemCTL
        // stamps every reminder "modified now" on its first poll), so an empty value never replaces
        // a filled one, Things keeps its title casing and its (Markdown) notes when both have text,
        // and completed beats open.
        let firstLink = base == nil
        // Title
        let titleSide = decide("title", equal: rf.title == tf.title,
                               rChanged: base.map { rf.title != $0.title } ?? true,
                               tChanged: base.map { tf.title != $0.title } ?? true,
                               tiebreak: firstLink ? .things : nil)
        switch titleSide {
        case .reminders: plan.thingsPatch.title = r.title; plan.fingerprint.title = rf.title
        case .things: plan.reminderPatch.title = t.title; plan.fingerprint.title = tf.title
        case nil: break
        }
        // Notes
        let notesSide = decide("notes", equal: rf.notes == tf.notes,
                               rChanged: base.map { rf.notes != $0.notes } ?? true,
                               tChanged: base.map { tf.notes != $0.notes } ?? true,
                               tiebreak: firstLink ? (tf.notes.isEmpty ? .reminders : .things) : nil)
        switch notesSide {
        case .reminders: plan.thingsPatch.notes = r.notes; plan.fingerprint.notes = rf.notes
        case .things: plan.reminderPatch.notes = t.notes; plan.fingerprint.notes = tf.notes
        case nil: break
        }
        // Due date. On first link a missing date never overrides a real one ("no due date" rule).
        var dueTiebreak: Side?
        if base == nil { if rf.due == nil { dueTiebreak = .things } else if tf.due == nil { dueTiebreak = .reminders } }
        let dueSide = decide("due date", equal: rf.due == tf.due,
                             rChanged: base.map { rf.due != $0.due } ?? true,
                             tChanged: base.map { tf.due != $0.due } ?? true, tiebreak: dueTiebreak)
        switch dueSide {
        case .reminders: plan.thingsPatch.when = .some(r.due); plan.fingerprint.due = rf.due
        case .things: plan.reminderPatch.due = .some(t.due); plan.fingerprint.due = tf.due
        case nil: break
        }
        // Completion
        let compSide = decide("completion", equal: !Fingerprint.completionDiffers(rf, tf),
                              rChanged: base.map { Fingerprint.completionDiffers(rf, $0) } ?? true,
                              tChanged: base.map { Fingerprint.completionDiffers(tf, $0) } ?? true,
                              tiebreak: firstLink ? (tf.completed || !rf.completed ? .things : .reminders) : nil)
        switch compSide {
        case .reminders:
            plan.thingsPatch.completed = r.completed
            if r.completed { plan.thingsPatch.completionDate = r.completionDate }
            plan.fingerprint.completed = rf.completed; plan.fingerprint.completionDay = rf.completionDay
        case .things:
            plan.reminderPatch.completed = tf.completed
            if tf.completed { plan.reminderPatch.completionDate = t.stopDate }
            plan.fingerprint.completed = tf.completed; plan.fingerprint.completionDay = tf.completionDay
        case nil:
            // Equal: keep whichever side knows the completion day.
            if plan.fingerprint.completionDay == nil { plan.fingerprint.completionDay = tf.completionDay }
        }
        return plan
    }

    // MARK: Unlinked items

    func processUnlinked(linkedThings: Set<String>, linkedReminders: Set<String>) async {
        for m in activeOrder {
            guard let target = m.targetId else { continue }
            let sig = signature(m)
            let isFirst = store.linkedMappings[m.id] != sig
            if isFirst && !isFull { continue }
            let allowCompleted = isFirst && config.includeCompletedOnFirstLink

            var taskCandidates: [ThingsTask] = []
            if isFull || !targetedIds.isEmpty {
                taskCandidates = thingsScope.compactMap { (id, mid) -> ThingsTask? in
                    guard mid == m.id, !linkedThings.contains(id), !store.detachedThingsIds.contains(id), isFull || targetedIds.contains(id) else { return nil }
                    return snapshot.tasks[id]
                }
                .filter { ($0.status == .open || allowCompleted) && !Fingerprint.normalize($0.title).isEmpty }
                .sorted { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
            }
            var reminderCandidates: [ReminderItem] = []
            if isFull || remindersChanged {
                reminderCandidates = remindersById.values
                    .filter { $0.listId == m.id && !$0.isRepeating && !linkedReminders.contains($0.id) && !store.detachedReminderIds.contains($0.id) }
                    .filter { (!$0.completed || allowCompleted) && !Fingerprint.normalize($0.title).isEmpty }
                    .sorted { ($0.lastModified ?? .distantPast, $0.id) < ($1.lastModified ?? .distantPast, $1.id) }
            }

            let failuresBefore = report.failures
            if isFirst {
                var byTitle: [String: [ReminderItem]] = [:]
                for r in reminderCandidates { byTitle[Fingerprint.normalize(r.title).lowercased(), default: []].append(r) }
                var pairedReminders: Set<String> = []
                var unmatchedTasks: [ThingsTask] = []
                for t in taskCandidates {
                    let key = Fingerprint.normalize(t.title).lowercased()
                    if var queue = byTitle[key], !queue.isEmpty {
                        let r = queue.removeFirst()
                        byTitle[key] = queue
                        pairedReminders.insert(r.id)
                        await pair(reminder: r, task: t, mapping: m)
                    } else { unmatchedTasks.append(t) }
                }
                taskCandidates = unmatchedTasks
                reminderCandidates.removeAll { pairedReminders.contains($0.id) }
            }
            for r in reminderCandidates { await createThings(from: r, mapping: m, target: target) }
            for t in taskCandidates { await createReminder(from: t, mapping: m) }

            if isFirst && report.failures == failuresBefore { store.linkedMappings[m.id] = sig }
        }
    }

    func pair(reminder r: ReminderItem, task t: ThingsTask, mapping m: ListMapping) async {
        let plan = merge(base: nil, reminder: r, task: t)
        do {
            var linkedReminder = r
            if !plan.reminderPatch.isEmpty { linkedReminder = try await reminders.update(id: r.id, patch: plan.reminderPatch) }
            if !plan.thingsPatch.isEmpty { try await things.updateTodo(id: t.id, patch: plan.thingsPatch) }
            store.links.append(LinkRecord(reminderId: linkedReminder.id, reminderExternalId: linkedReminder.externalId ?? r.externalId,
                                          thingsId: t.id, mappingId: m.id, fingerprint: plan.fingerprint))
            report.linked += 1
            log(.change, "Linked \"\(r.title)\" in \"\(m.listTitle)\" with its Things to-do")
        } catch {
            fail("Could not link \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    func createThings(from r: ReminderItem, mapping m: ListMapping, target: String) async {
        let placement: ThingsPlacement
        var tags: [String] = []
        switch m.mode {
        case .project: placement = .project(target)
        case .area: placement = .area(target)
        case .tag: placement = .inbox; tags = [target]
        }
        let draft = ThingsTodoDraft(title: r.title, notes: r.notes, when: r.due, completed: r.completed,
                                    completionDate: r.completionDate, placement: placement, tagIds: tags)
        do {
            let id = try await things.createTodo(draft)
            store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: id, mappingId: m.id,
                                          fingerprint: Fingerprint(reminder: r, days: days)))
            report.createdInThings += 1
            log(.change, "Created Things to-do \"\(r.title)\" from list \"\(m.listTitle)\"")
        } catch {
            fail("Could not create Things to-do \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    func createReminder(from t: ThingsTask, mapping m: ListMapping) async {
        let done = t.status != .open
        do {
            let r = try await reminders.create(title: t.title, notes: t.notes, due: t.due, completed: done,
                                               completionDate: done ? t.stopDate : nil, listId: m.id)
            store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: t.id, mappingId: m.id,
                                          fingerprint: Fingerprint(things: t, days: days)))
            report.createdInReminders += 1
            log(.change, "Created reminder \"\(t.title)\" in \"\(m.listTitle)\"")
        } catch {
            fail("Could not create reminder \"\(t.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: Deletions

    func runDeletions(linksAtStart: [LinkRecord]) async {
        for (mappingId, items) in pendingDeletes.sorted(by: { $0.key < $1.key }) {
            let total = linksAtStart.filter { $0.mappingId == mappingId }.count
            let n = items.count
            let tripped = !force && (n > SyncEngine.maxDeletionsPerPass
                || (n > 1 && Double(n) > SyncEngine.maxDeletionFraction * Double(total)))
            let listTitle = activeById[mappingId]?.listTitle ?? mappingId
            if tripped {
                report.deletionsHeld = true
                log(.error, "Held back \(n) deletions in \"\(listTitle)\" (\(total) linked items): over the safety limit. Run Sync Now to apply them.")
                continue
            }
            for item in items {
                do {
                    switch item.action {
                    case .trashThings(let id):
                        try await things.updateTodo(id: id, patch: ThingsTodoPatch(trashed: true))
                        report.deletedInThings += 1
                        log(.change, "Moved Things to-do \"\(item.title)\" to the Trash (reminder was deleted)")
                    case .deleteReminder(let id):
                        try await reminders.delete(id: id)
                        report.deletedInReminders += 1
                        log(.change, "Deleted reminder \"\(item.title)\" (Things to-do was deleted)")
                    }
                    removedLinks.insert(item.linkId)
                } catch {
                    fail("Could not delete \"\(item.title)\": \(error.localizedDescription)")
                }
            }
        }
    }
}
