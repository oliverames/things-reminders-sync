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
    /// Reminders read at the start of the pass (for previews; sections only for lists that mirror them).
    public var reminders: [ReminderItem] = []
    /// App-created containers and sections removed this pass (retargeted old targets, emptied headings and sections).
    public var removedContainers = 0

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
    /// `backfillLog` (newest first) lets a full pass infer the ownership ledger for data created before it existed
    /// (see `LedgerBackfill`); the coordinator passes it only until the one-time backfill has run.
    public func sync(config: SyncConfig, links: LinkStore, scope: SyncScope, forceDeletions: Bool = false,
                     backfillLog: [SyncLogEntry]? = nil) async throws -> SyncReport {
        let pass = SyncPass(engine: self, config: config, store: links, scope: scope, force: forceDeletions, backfillLog: backfillLog)
        return try await pass.run()
    }
}

// MARK: - One pass

enum PendingDelete {
    case trashThings(String)
    case deleteReminder(String)
}

struct MergePlan {
    var reminderPatch = ReminderPatch()
    var thingsPatch = ThingsTodoPatch()
    var fingerprint: Fingerprint
    var conflicts: [String] = []
    /// The group (heading) the Things to-do should move to: `.some(nil)` is directly in the project.
    /// Resolved to a placement (finding or creating the heading) just before the write.
    var thingsGroup: String??
    /// Repeating pairs: writes to occurrences (not the linked to-do): completing the occurrence for the old day,
    /// or moving an open occurrence.
    var occurrenceWrites: [(id: String, patch: ThingsTodoPatch)] = []
    /// Repeating pairs: the reminder's own due after this write is the pair's new due (it advanced itself).
    var reminderAdvances = false
    /// `.reminderRepeats` pairs: replace the plain to-do with a fresh one for the reminder's new due.
    var replaceThings = false
    /// The stored fingerprint this plan was made against (nil on a first link); a field whose write did not take falls back to it.
    var base: Fingerprint?
    /// Subtask completions and deletions (through the subtasks' own ids), run after the reminder update.
    var subtaskOps: [SubtaskOp] = []
    /// Checklist keys whose Reminders side was written, verified by a re-read.
    var checklistTouched: Set<String> = []
}

/// The two sides' groups for a pair whose mapping syncs sections.
struct GroupInput {
    var things: String?
    var reminders: String?
    /// Groceries lists categorize themselves: the engine reads their sections but never writes them.
    var remindersReadOnly: Bool
}

final class SyncPass {
    let things: any ThingsBackend
    let reminders: any RemindersBackend
    let days: DayFormatter
    var config: SyncConfig
    var store: LinkStore
    let scope: SyncScope
    let force: Bool
    let backfillLog: [SyncLogEntry]?
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
    var groceryLists: Set<String> = []
    var tagEnv = TagEnvironment()

    init(engine: SyncEngine, config: SyncConfig, store: LinkStore, scope: SyncScope, force: Bool, backfillLog: [SyncLogEntry]?) {
        things = engine.things; reminders = engine.reminders; days = DayFormatter(timeZone: engine.timeZone)
        self.config = config; self.store = store; self.scope = scope; self.force = force; self.backfillLog = backfillLog
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
        // Both sides are read before anything is created, and nothing below these three reads throws. A pass that
        // cannot read therefore ends here, having created nothing: creating a "New…" target first meant every failed
        // pass made the project, area, tag or heading again, and lost the id of the one before.
        let refresh = try await things.refresh()
        snapshot = refresh.snapshot
        let lists = try await reminders.lists()
        // A subtask is a part of its parent (it syncs as a checklist item), never a to-do of its own.
        let items = try await reminders.reminders(inLists: lists.map(\.id)).filter { $0.parentId == nil }
        await ensureTargets()
        for r in items {
            remindersById[r.id] = r
            if let e = r.externalId { remindersByExternal[e] = r }
        }
        groceryLists = Set(lists.filter(\.isGroceries).map(\.id))
        if isFull, !store.ledgerBackfilled, let backfillLog {
            let result = LedgerBackfill.infer(log: backfillLog, store: store, config: config, snapshot: snapshot, reminders: items)
            store = result.store
            if result.hasChanges { log(.info, "Worked out which items this app created: \(result.summary)") }
        }
        buildActiveMappings(lists: lists)
        await migrateRetargetedMappings()
        buildThingsScope()
        buildTagEnvironment()

        reattachParkedLinks()
        let linksAtStart = store.links
        for link in linksAtStart { await processLink(link) }
        // Taken after the links ran: a link can move to another Things item meanwhile (a to-do that became repeating
        // hands its link to the new template), and that item must not get a second partner.
        let linkedThings = Set(linksAtStart.map(\.thingsId)).union(store.links.map(\.thingsId))
        let linkedReminders = Set(linksAtStart.map(\.reminderId)).union(store.links.map(\.reminderId))
        await processUnlinked(linkedThings: linkedThings, linkedReminders: linkedReminders)
        await runDeletions(linksAtStart: linksAtStart)

        store.links.removeAll { removedLinks.contains($0.id) }
        await recordCreatedSections()
        if isFull {
            if backfillLog != nil { store.ledgerBackfilled = true }
            await cleanUpEmptyHeadingsAndSections(lists: lists)

            store.detachedThingsIds = store.detachedThingsIds.filter { snapshot.tasks[$0].map { !$0.trashed } ?? false }
            store.detachedReminderIds = store.detachedReminderIds.filter { remindersById[$0] != nil }
        }
        report.links = store
        report.config = config
        report.snapshot = snapshot
        report.reminderLists = lists
        report.reminders = items
        return report
    }

    // MARK: Targets and mappings

    func ensureTargets() async {
        for i in config.mappings.indices where config.mappings[i].enabled && config.mappings[i].targetId == nil && !config.mappings[i].awaitingTarget {
            let m = config.mappings[i]
            do {
                let id: String
                // The new container joins the snapshot read above (no second read that could fail), and the place it
                // goes into must still be there: a heading in a deleted project would point at nothing.
                switch m.mode {
                case .project:
                    if let area = m.projectAreaId, snapshot.areas[area] == nil {
                        log(.warning, "Cannot create the Things project \"\(m.targetTitle)\" for list \"\(m.listTitle)\": its area no longer exists; choose a target in Settings")
                        continue
                    }
                    id = try await things.createProject(title: m.targetTitle, areaId: m.projectAreaId)
                    snapshot.tasks[id] = ThingsTask(id: id, kind: .project, title: m.targetTitle, areaId: m.projectAreaId)
                case .area:
                    id = try await things.createArea(title: m.targetTitle)
                    snapshot.areas[id] = ThingsArea(id: id, title: m.targetTitle)
                case .tag:
                    id = try await things.createTag(title: m.targetTitle, parentId: nil)
                    snapshot.tags[id] = ThingsTag(id: id, title: m.targetTitle)
                case .heading:
                    guard let project = m.parentProjectId else {
                        log(.warning, "Cannot create the Things heading \"\(m.targetTitle)\" for list \"\(m.listTitle)\": no project is chosen; skipped")
                        continue
                    }
                    guard targetExists(.project, project) else {
                        log(.warning, "Cannot create the Things heading \"\(m.targetTitle)\" for list \"\(m.listTitle)\": its project no longer exists; choose a target in Settings")
                        continue
                    }
                    id = try await things.createHeading(title: m.targetTitle, projectId: project)
                    snapshot.tasks[id] = ThingsTask(id: id, kind: .heading, title: m.targetTitle, projectId: project)
                }
                config.mappings[i].targetId = id
                store.ownedThings.append(OwnedThingsContainer(id: id, kind: .init(m.mode), mappingId: m.id, title: m.targetTitle))
                log(.change, "Created Things \(m.mode.rawValue) \"\(m.targetTitle)\" for list \"\(m.listTitle)\"")
            } catch {
                fail("Could not create Things \(m.mode.rawValue) \"\(m.targetTitle)\": \(error.localizedDescription)")
            }
        }
    }

    func buildActiveMappings(lists: [ReminderList]) {
        let listsById = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
        for m in config.mappings where m.enabled {
            if m.awaitingTarget {
                log(.info, "\"\(m.listTitle)\" is paused until you choose a Things \(m.mode.rawValue) in Settings")
                continue
            }
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
        case .heading: if let t = snapshot.tasks[id] { return t.kind == .heading && !t.trashed } else { return false }
        }
    }

    func signature(_ m: ListMapping) -> String { "\(m.mode.rawValue):\(m.targetId ?? "")" }

    func targetName(_ mode: MappingMode, _ id: String?) -> String {
        guard let id else { return "?" }
        switch mode {
        case .project, .heading: return snapshot.tasks[id]?.title ?? "?"
        case .area: return snapshot.areas[id]?.title ?? "?"
        case .tag: return snapshot.tags[id]?.title ?? "?"
        }
    }

    /// A mapping whose target changed since it was linked (another project, project to area, to a
    /// tag, ...) keeps its links: each linked to-do still in the old target moves to the new one.
    /// Without this the links fell out of scope, the reminders were detached, and the new target got
    /// duplicates. The old project/area/tag is left in place, never deleted. Unlinked items already in
    /// the new target are paired by title afterwards (the changed signature makes it a first link).
    func migrateRetargetedMappings() async {
        for m in activeOrder {
            guard let target = m.targetId, let old = store.linkedMappings[m.id], old != signature(m),
                  let colon = old.firstIndex(of: ":"), let oldMode = MappingMode(rawValue: String(old[..<colon]))
            else { continue }
            let oldTargetId = String(old[old.index(after: colon)...])
            var oldMapping = m
            oldMapping.mode = oldMode
            oldMapping.targetId = oldTargetId.isEmpty ? nil : oldTargetId
            var moved = 0
            var failed = false
            for link in store.links where link.mappingId == m.id {
                guard var task = snapshot.tasks[link.thingsId], task.kind == .todo, !task.trashed,
                      oldMapping.targetId != nil, matches(task, oldMapping), !matches(task, m) else { continue }
                var patch = ThingsTodoPatch()
                var newHeading: String?
                do {
                    switch m.mode {
                    case .project:
                        // Keep the to-do under a same-named heading when both projects mirror sections.
                        if sectionsActive(m), let group = thingsGroup(task, oldMapping) {
                            newHeading = try await heading(titled: group, in: target, mappingId: m.id)
                            patch.placement = .heading(newHeading!)
                        } else {
                            patch.placement = .project(target)
                        }
                    case .area: patch.placement = .area(target)
                    case .tag: patch.addTagIds = [target]
                    case .heading: patch.placement = .heading(target)
                    }
                    if oldMode == .tag, let oldTag = oldMapping.targetId, oldTag != target, task.tagIds.contains(oldTag) {
                        patch.removeTagIds = [oldTag]
                    }
                    try await things.updateTodo(id: task.id, patch: patch)
                    switch m.mode {
                    case .project: task.projectId = target; task.areaId = nil; task.headingId = newHeading
                    case .heading: task.headingId = target; task.projectId = nil; task.areaId = nil
                    case .area: task.areaId = target; task.projectId = nil; task.headingId = nil
                    case .tag: if !task.tagIds.contains(target) { task.tagIds.append(target) }
                    }
                    if let removed = patch.removeTagIds { task.tagIds.removeAll { removed.contains($0) } }
                    snapshot.tasks[task.id] = task
                    moved += 1
                } catch {
                    fail("Could not move \"\(task.title)\" to the new Things \(m.mode.rawValue): \(error.localizedDescription)")
                    failed = true
                }
            }
            if moved > 0 {
                log(.change, "Moved \(moved) linked to-do\(moved == 1 ? "" : "s") for \"\(m.listTitle)\" from Things \(oldMode.rawValue) \"\(targetName(oldMode, oldMapping.targetId))\" to \(m.mode.rawValue) \"\(targetName(m.mode, target))\"; the old \(oldMode.rawValue) was kept unless this app created it and it is now empty")
            }
            if !failed, let oldId = oldMapping.targetId {
                await removeOwnedIfEmpty(.init(oldMode), id: oldId,
                                         why: "list \"\(m.listTitle)\" moved to \(m.mode.rawValue) \"\(targetName(m.mode, target))\"")
            }
            if failed {
                // Leave the old signature so the next pass retries; skip the mapping now so links whose
                // to-do did not move are not mistaken for items that left the list's scope.
                activeById[m.id] = nil
                activeOrder.removeAll { $0.id == m.id }
            }
        }
    }

    /// Maps each in-scope Things to-do to the first matching mapping (config order).
    func buildThingsScope() {
        // A heading mapping claims its to-dos before a project mapping of the same project does.
        let ordered = activeOrder.filter { $0.mode == .heading } + activeOrder.filter { $0.mode != .heading }
        for task in snapshot.tasks.values.sorted(by: { $0.id < $1.id }) {
            guard task.kind == .todo, !task.trashed, !task.isOccurrence else { continue }
            for m in ordered where matches(task, m) {
                thingsScope[task.id] = m.id
                break
            }
        }
        // An occurrence syncs on its own only when its template's rule cannot be copied to Reminders (the
        // template pair carries every other repeating item); the template must be in a synced place too.
        for task in snapshot.tasks.values.sorted(by: { $0.id < $1.id }) {
            guard task.kind == .todo, !task.trashed, let tid = task.templateId, let template = snapshot.tasks[tid],
                  template.isTemplate, !template.trashed, thingsScope[tid] != nil, !templateSyncs(template) else { continue }
            for m in ordered where matches(task, m) {
                thingsScope[task.id] = m.id
                break
            }
        }
    }

    func matches(_ task: ThingsTask, _ m: ListMapping) -> Bool { taskMatches(task, m, in: snapshot) }

    // MARK: Groups (Reminders sections <-> Things headings)

    func sectionsActive(_ m: ListMapping) -> Bool { m.mode == .project && m.syncSections }

    /// The title of the heading a to-do sits under in the mapping's project, or nil when it is directly in the
    /// project (or its heading is trashed or belongs to another project).
    func thingsGroup(_ task: ThingsTask, _ m: ListMapping) -> String? {
        guard sectionsActive(m), let target = m.targetId, let h = task.headingId, let heading = snapshot.tasks[h],
              heading.kind == .heading, !heading.trashed, heading.projectId == target else { return nil }
        return Fingerprint.cleanGroup(heading.title)
    }

    /// The existing heading titled `title` in the project (case-insensitive, oldest first when duplicated), or a new one.
    /// A heading created here joins the snapshot, so later items in the pass reuse it.
    func heading(titled title: String, in project: String, mappingId: String) async throws -> String {
        guard let clean = Fingerprint.cleanGroup(title) else { throw ThingsCloudError.invalidChange(["empty heading title"]) }
        let key = clean.lowercased()
        let hits = snapshot.tasks.values
            .filter { $0.kind == .heading && !$0.trashed && $0.projectId == project && Fingerprint.groupKey($0.title) == key }
            .sorted { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
        if let existing = hits.first { return existing.id }
        let id = try await things.createHeading(title: clean, projectId: project)
        snapshot.tasks[id] = ThingsTask(id: id, kind: .heading, title: clean, projectId: project)
        store.ownedThings.append(OwnedThingsContainer(id: id, kind: .heading, mappingId: mappingId, title: clean))
        log(.change, "Created Things heading \"\(clean)\" in \"\(snapshot.tasks[project]?.title ?? "project")\"")
        return id
    }

    func placement(forGroup group: String?, in m: ListMapping) async throws -> ThingsPlacement {
        guard let target = m.targetId else { throw ThingsCloudError.notFound("target of \(m.listTitle)") }
        guard let group else { return .project(target) }
        return .heading(try await heading(titled: group, in: target, mappingId: m.id))
    }

    /// After a reminder write that asked for `wanted` (nil: no section), checks what RemCTL reports.
    /// A section that cannot be removed is remembered (`stuckSection`), so the reminder still reading it is not
    /// mistaken for a change; a section that did not take is recorded as it is, so the next pass retries it.
    func reconcileSection(_ fp: inout Fingerprint, wanted: String?, actual: String?, title: String) {
        let got = Fingerprint.cleanGroup(actual)
        if Fingerprint.groupKey(got) == Fingerprint.groupKey(wanted) { fp.stuckSection = nil; return }
        if wanted == nil {
            fp.stuckSection = got
            log(.info, "\"\(title)\" stays in its Reminders section \"\(got ?? "")\": RemCTL cannot remove a reminder from a section")
        } else {
            fp.group = got
            fp.stuckSection = nil
            log(.warning, "Could not put \"\(title)\" in the Reminders section \"\(wanted ?? "")\"; it will be retried")
        }
    }

    // MARK: Existing links

    func included(_ link: LinkRecord) -> Bool {
        isFull || remindersChanged || targetedIds.contains(link.thingsId)
            || (link.repeatMode == .template && targetedIds.contains { snapshot.tasks[$0]?.templateId == link.thingsId })
    }

    func findReminder(_ link: LinkRecord) -> ReminderItem? {
        if let r = remindersById[link.reminderId] { return r }
        if let e = link.reminderExternalId { return remindersByExternal[e] }
        return nil
    }

    /// Restores parked links whose items are both back in a mapped place, and frees an item whose
    /// parked partner no longer exists. Runs before existing links are processed, so a restored link
    /// syncs whatever changed meanwhile against its old fingerprint (and follows a move to another list).
    func reattachParkedLinks() {
        var keep: [LinkRecord] = []
        for parked in store.parkedLinks {
            let task = snapshot.tasks[parked.thingsId].flatMap { $0.trashed ? nil : $0 }
            let reminder = findReminder(parked)
            switch (task, reminder) {
            case let (task?, reminder?):
                let tm = thingsScope[task.id], rm = activeById[reminder.listId]?.id
                guard tm != nil, rm != nil else { keep.append(parked); continue }   // still out of scope: stay parked
                var link = parked
                link.reminderId = reminder.id
                if activeById[link.mappingId] == nil { link.mappingId = tm! }
                store.links.append(link)
                store.detachedThingsIds.remove(task.id)
                store.detachedReminderIds.remove(parked.reminderId)
                store.detachedReminderIds.remove(reminder.id)
                report.linked += 1
                log(.info, "Relinked \"\(task.title)\": both items are back in synced places")
            case (nil, nil):
                store.detachedThingsIds.remove(parked.thingsId)
                store.detachedReminderIds.remove(parked.reminderId)
            case (let task?, nil):
                store.detachedThingsIds.remove(task.id)          // partner gone: sync as a new item
            case (nil, let reminder?):
                store.detachedReminderIds.remove(reminder.id)
                store.detachedReminderIds.remove(parked.reminderId)
            }
        }
        store.parkedLinks = keep
    }

    func unlink(_ link: LinkRecord, _ reason: String, park: Bool = false) {
        if park { store.parkedLinks.append(link) }
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
            // Things removes a to-do that was given a repeat with a first date in the future and keeps a new template:
            // the pair moves to the template instead of the reminder being deleted.
            if link.repeatMode == nil, let r = reminder, !r.completed,
               let template = successorTemplate(for: link, task: nil, mapping: mapping) {
                await convertToTemplatePair(link, reminder: r, template: template)
                return
            }
            if config.propagateDeletes, let r = reminder { queueDelete(mapping.id, link.id, .deleteReminder(r.id), title) }
            else { unlink(link, "Things to-do deleted (deletes are not propagated)") }
            return
        default: break
        }
        guard var reminder, let task else { return }
        var link = link

        switch link.repeatMode {
        case .template:
            if !task.isTemplate {
                // The template stopped repeating: the reminder stops too, and the pair carries on as a plain one.
                do {
                    reminder = try await reminders.update(id: reminder.id, patch: ReminderPatch(recurrence: .some(nil)))
                    link.repeatMode = nil; link.fingerprint.rule = nil
                    replace(link)
                    log(.change, "Removed the repeat from reminder \"\(reminder.title)\": the Things to-do no longer repeats")
                } catch { fail("Could not remove the repeat from \"\(title)\": \(error.localizedDescription)"); return }
            } else if !reminder.isRepeating {
                unlink(link, "the reminder no longer repeats"); return
            }
        case .reminderRepeats:
            if task.isRepeating { unlink(link, "the Things to-do became repeating"); return }
            if !reminder.isRepeating { link.repeatMode = nil; replace(link) }   // stopped repeating: a plain pair now
        case nil:
            // An item that was given a repeat after it was linked stays linked.
            if task.isOccurrence, !reminder.completed, let template = successorTemplate(for: link, task: task, mapping: mapping) {
                // Things moved the rule to a new template and made the linked to-do its first occurrence.
                await convertToTemplatePair(link, reminder: reminder, template: template)
                return
            }
            if task.isTemplate {
                if reminder.isRepeating { link.repeatMode = .template; replace(link) }
                else if templateSyncs(task) { await convertToTemplatePair(link, reminder: reminder, template: task); return }
                else { unlink(link, "the Things to-do repeats in a way Reminders cannot hold"); return }
            } else if reminder.isRepeating, !task.isOccurrence {
                // The reminder was given a repeat: the to-do stands for the current occurrence. When the reminder moves
                // on, the to-do is replaced (by a repeating to-do when Things can hold the rule).
                link.repeatMode = .reminderRepeats
                replace(link)
                log(.info, "\"\(reminder.title)\" now repeats in Reminders; its Things to-do stands for the current occurrence")
            } else if reminder.isRepeating {
                unlink(link, "repeating item"); return
            }
        }
        let rm = activeById[reminder.listId]?.id
        let tm = thingsScope[task.id]
        guard let rm, let tm else { unlink(link, "moved out of scope", park: true); return }
        if link.repeatMode == .reminderRepeats, link.awaitingReplacement, let m = activeById[rm] {
            await finishReplacement(link, reminder: reminder, task: task, mapping: m)
            return
        }

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

        var groupInput: GroupInput?
        if destination == nil, let m = activeById[tm], sectionsActive(m) {
            groupInput = GroupInput(things: thingsGroup(task, m), reminders: reminder.section,
                                    remindersReadOnly: groceryLists.contains(reminder.listId))
        }
        var plan: MergePlan
        switch link.repeatMode {
        case .template:
            // Title, notes and group merge as usual; due, completion and the rule are decided by the repeat logic.
            let (rEff, tEff) = neutralized(reminder: reminder, task: task, base: link.fingerprint)
            plan = merge(base: link.fingerprint, reminder: rEff, task: tEff, group: groupInput)
            plan.fingerprint.rule = link.fingerprint.rule
            templateExtras(link: link, reminder: reminder, task: task, plan: &plan)
        case .reminderRepeats:
            plan = reminderRepeatsPlan(link: link, reminder: reminder, task: task, group: groupInput)
        case nil:
            plan = merge(base: link.fingerprint, reminder: reminder, task: task, group: groupInput)
        }
        if let destination {
            if movedReminder { plan.reminderPatch.listId = destination.id }
            if movedThings { applyPlacement(&plan.thingsPatch, task: task, old: activeById[tm], new: destination) }
            followAcrossMove(&plan, destination: destination, thingsMoves: movedThings, reminder: reminder, task: task)
        }
        let newMapping = destination?.id ?? tm
        do {
            var updated = link
            var advancedReminder: ReminderItem?
            if case .some(let group) = plan.thingsGroup, let m = destination ?? activeById[tm] {
                plan.thingsPatch.placement = try await placement(forGroup: group, in: m)
            }
            var actualReminder: ReminderItem?
            if !plan.reminderPatch.isEmpty {
                let r = try await reminders.update(id: reminder.id, patch: plan.reminderPatch)
                actualReminder = r
                if plan.reminderAdvances || plan.replaceThings { advancedReminder = r }
                updated.reminderId = r.id; updated.reminderExternalId = r.externalId ?? updated.reminderExternalId
                var rest = plan.reminderPatch
                rest.section = nil
                if let wanted = plan.reminderPatch.section {
                    reconcileSection(&plan.fingerprint, wanted: wanted, actual: r.section, title: r.title)
                }
                if !rest.isEmpty {
                    report.updatedInReminders += 1
                    log(.change, "Updated reminder \"\(r.title)\"" + (destination != nil && movedReminder ? " (moved to \"\(destination!.listTitle)\")" : ""))
                } else if case .some(.some(let name)) = plan.reminderPatch.section {
                    report.updatedInReminders += 1
                    log(.change, "Moved reminder \"\(r.title)\" to the section \"\(name)\"")
                }
            }
            if plan.replaceThings {
                // The reminder is on its next occurrence from here on. Save that before the Things writes that can still
                // fail: with the old fingerprint the next pass would read the completed to-do as a new completion and
                // complete the reminder again, skipping an occurrence.
                var checkpoint = updated
                checkpoint.fingerprint.due = (advancedReminder ?? reminder).due
                checkpoint.awaitingReplacement = true
                replace(checkpoint)
            }
            let afterwards = try await runSubtaskWrites(plan, reminder: updated.reminderId, listId: actualReminder?.listId ?? reminder.listId)
            if plan.reminderPatch.isEmpty && !plan.subtaskOps.isEmpty { report.updatedInReminders += 1 }
            settle(&plan, actual: actualReminder, afterwards: afterwards, title: reminder.title)
            if !plan.thingsPatch.isEmpty {
                try await things.updateTodo(id: task.id, patch: plan.thingsPatch)
                report.updatedInThings += 1
                log(.change, "Updated Things to-do \"\(task.title)\"" + (destination != nil && movedThings ? " (moved to \"\(destination!.listTitle)\")" : ""))
            }
            for write in plan.occurrenceWrites {
                try await things.updateTodo(id: write.id, patch: write.patch)
                report.updatedInThings += 1
                log(.change, "Updated Things occurrence of \"\(task.title)\"" + (write.patch.completed == true ? " (completed)" : ""))
            }
            if let advanced = advancedReminder {
                plan.fingerprint.due = advanced.due
                if advanced.completed { plan.fingerprint.completed = true }
            }
            if plan.replaceThings, let fresh = try await replacePlainTodo(link: link, task: task, plan: plan, mapping: destination ?? activeById[tm],
                                                                          reminder: advancedReminder ?? reminder) {
                updated.thingsId = fresh.id
                updated.repeatMode = fresh.mode
                plan.fingerprint = fresh.fingerprint
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

    /// A pair that changes mapping carries its group across: the follower takes the leader's group in the new list.
    func followAcrossMove(_ plan: inout MergePlan, destination: ListMapping, thingsMoves: Bool, reminder: ReminderItem, task: ThingsTask) {
        plan.fingerprint.stuckSection = nil
        guard sectionsActive(destination) else { plan.fingerprint.group = nil; return }
        if thingsMoves {
            // The to-do follows the reminder: it lands under the heading named like the reminder's section.
            let group = Fingerprint.cleanGroup(reminder.section)
            plan.thingsGroup = .some(group)
            plan.fingerprint.group = group
        } else {
            // The reminder follows the to-do: it takes the section named like the to-do's heading.
            let group = thingsGroup(task, destination)
            if let group, !groceryLists.contains(destination.id) { plan.reminderPatch.section = .some(group) }
            plan.fingerprint.group = groceryLists.contains(destination.id) ? nil : group
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
        case .heading: patch.placement = .heading(target)
        case .tag:
            if !task.tagIds.contains(target) { patch.addTagIds = (patch.addTagIds ?? []) + [target] }
            if let old, old.mode != .tag { patch.placement = .inbox }
        }
        if !remove.isEmpty { patch.removeTagIds = (patch.removeTagIds ?? []) + remove }
    }

    // MARK: Merge

    func laterSide(_ r: Date?, _ t: Date?) -> Side {
        if let r, let t { return r > t ? .reminders : .things }
        if r != nil { return .reminders }
        return .things
    }

    /// Per-field three-way merge. `base == nil` (first link) treats every differing field as a conflict.
    func merge(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, group: GroupInput? = nil) -> MergePlan {
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
        // Group (section <-> heading). Without section syncing the stored group is left alone. On first link a
        // group beats none, and two different groups go to Things.
        plan.fingerprint.group = base?.group
        plan.fingerprint.stuckSection = base?.stuckSection
        if let g = group {
            let rg = Fingerprint.cleanGroup(g.reminders), tg = Fingerprint.cleanGroup(g.things)
            let rk = Fingerprint.groupKey(rg), tk = Fingerprint.groupKey(tg), bk = Fingerprint.groupKey(base?.group)
            if rk == tk {
                plan.fingerprint.group = tg ?? rg
                plan.fingerprint.stuckSection = nil
            } else {
                var rChanged = base == nil || rk != bk
                let tChanged = base == nil || tk != bk
                if let stuck = base?.stuckSection, Fingerprint.groupKey(stuck) == rk { rChanged = false }
                var side: Side?
                if g.remindersReadOnly {
                    // Sections there are read-only: only Reminders can move things, and a missing section on first link says nothing.
                    if rChanged && !(firstLink && rg == nil) { side = .reminders }
                    else if firstLink { plan.fingerprint.group = rg }
                } else if rChanged || tChanged {
                    side = decide("section", equal: false, rChanged: rChanged, tChanged: tChanged,
                                  tiebreak: firstLink ? (rg == nil ? .things : tg == nil ? .reminders : .things) : nil)
                }
                switch side {
                case .reminders:
                    plan.thingsGroup = .some(rg); plan.fingerprint.group = rg; plan.fingerprint.stuckSection = nil
                case .things:
                    plan.reminderPatch.section = .some(tg); plan.fingerprint.group = tg; plan.fingerprint.stuckSection = nil
                case nil: break
                }
            }
        }
        mergeFields(into: &plan, base: base, reminder: r, task: t, later: later)
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

            // Every unlinked item of the list on each side, whatever this pass was started for.
            let taskPool = thingsScope.compactMap { (id, mid) -> ThingsTask? in
                guard mid == m.id, !linkedThings.contains(id), !store.detachedThingsIds.contains(id) else { return nil }
                return snapshot.tasks[id]
            }
            .filter { ($0.status == .open || allowCompleted) && !Fingerprint.normalize($0.title).isEmpty }
            .sorted { ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id) }
            let reminderPool = remindersById.values
                .filter { $0.listId == m.id && !linkedReminders.contains($0.id) && !store.detachedReminderIds.contains($0.id) }
                .filter { (!$0.completed || allowCompleted) && !Fingerprint.normalize($0.title).isEmpty }
                .sorted { ($0.lastModified ?? .distantPast, $0.id) < ($1.lastModified ?? .distantPast, $1.id) }

            let failuresBefore = report.failures
            // Unlinked items with the same title on both sides are paired, never copied. On a first link that is how
            // turning a list on avoids duplicates. Later it catches a partner whose creation landed although the pass
            // lost track of it (a lost answer, a failed follow-up step, a quit mid-pass): without it the next pass
            // would copy both items again and leave two of each.
            var byTitle: [String: [ReminderItem]] = [:]
            // A repeating reminder only pairs with a template, a plain one only with a non-template.
            func key(_ title: String, repeating: Bool) -> String { Fingerprint.normalize(title).lowercased() + (repeating ? "\u{1F}rep" : "") }
            for r in reminderPool { byTitle[key(r.title, repeating: r.isRepeating), default: []].append(r) }
            var pairedTasks: Set<String> = [], pairedReminders: Set<String> = []
            for t in taskPool {
                let key = key(t.title, repeating: t.isTemplate)
                guard var queue = byTitle[key], !queue.isEmpty else { continue }
                let r = queue.removeFirst()
                byTitle[key] = queue
                pairedReminders.insert(r.id); pairedTasks.insert(t.id)
                if t.isTemplate { await pairTemplate(reminder: r, task: t, mapping: m) } else { await pair(reminder: r, task: t, mapping: m) }
            }
            // New partners are only made for what this pass covers.
            let taskCandidates = taskPool.filter { !pairedTasks.contains($0.id) && (isFull || targetedIds.contains($0.id)) }
            let reminderCandidates = isFull || remindersChanged ? reminderPool.filter { !pairedReminders.contains($0.id) } : []
            for r in reminderCandidates { await createThings(from: r, mapping: m, target: target) }
            for t in taskCandidates { await createReminder(from: t, mapping: m) }

            if isFirst && report.failures == failuresBefore { store.linkedMappings[m.id] = sig }
        }
    }

    func pair(reminder r: ReminderItem, task t: ThingsTask, mapping m: ListMapping) async {
        var groupInput: GroupInput?
        if sectionsActive(m) {
            groupInput = GroupInput(things: thingsGroup(t, m), reminders: r.section, remindersReadOnly: groceryLists.contains(r.listId))
        }
        var plan = merge(base: nil, reminder: r, task: t, group: groupInput)
        do {
            var linkedReminder = r
            var actual: ReminderItem?
            if case .some(let group) = plan.thingsGroup { plan.thingsPatch.placement = try await placement(forGroup: group, in: m) }
            if !plan.reminderPatch.isEmpty {
                linkedReminder = try await reminders.update(id: r.id, patch: plan.reminderPatch)
                actual = linkedReminder
                if let wanted = plan.reminderPatch.section {
                    reconcileSection(&plan.fingerprint, wanted: wanted, actual: linkedReminder.section, title: r.title)
                }
            }
            let afterwards = try await runSubtaskWrites(plan, reminder: linkedReminder.id, listId: linkedReminder.listId)
            settle(&plan, actual: actual, afterwards: afterwards, title: r.title)
            if !plan.thingsPatch.isEmpty { try await things.updateTodo(id: t.id, patch: plan.thingsPatch) }
            store.links.append(LinkRecord(reminderId: linkedReminder.id, reminderExternalId: linkedReminder.externalId ?? r.externalId,
                                          thingsId: t.id, mappingId: m.id, fingerprint: plan.fingerprint))
            report.linked += 1
            log(.change, "Linked \"\(r.title)\" in \"\(m.listTitle)\" with its Things to-do")
            if plan.reminderPatch.notes != nil, !Fingerprint.normalize(r.notes).isEmpty {
                log(.warning, "\"\(r.title)\" had different notes in Reminders and Things when it was linked; the Things notes were kept and replaced the Reminders notes")
            }
        } catch {
            fail("Could not link \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    func createThings(from r: ReminderItem, mapping m: ListMapping, target: String) async {
        if r.isRepeating { await createThingsForRepeating(from: r, mapping: m); return }
        var placement: ThingsPlacement
        var tags: [String] = []
        let group = sectionsActive(m) ? Fingerprint.cleanGroup(r.section) : nil
        switch m.mode {
        case .project: placement = .project(target)
        case .area: placement = .area(target)
        case .tag: placement = .inbox; tags = [target]
        case .heading: placement = .heading(target)
        }
        do {
            if let group { placement = try await self.placement(forGroup: group, in: m) }
            let fields = thingsFields(from: r)
            let draft = ThingsTodoDraft(title: r.title, notes: fields.notes, when: r.due, completed: r.completed,
                                        completionDate: r.completionDate, placement: placement,
                                        tagIds: tags + fields.tagIds.filter { !tags.contains($0) }, checklist: fields.checklist)
            let id = try await things.createTodo(draft)
            store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: id, mappingId: m.id,
                                          fingerprint: fingerprint(forNewThingsFrom: r, group: group, fields: fields),
                                          copySide: .things, copiedCompleted: r.completed))
            report.createdInThings += 1
            log(.change, "Created Things to-do \"\(r.title)\" from list \"\(m.listTitle)\"")
        } catch {
            fail("Could not create Things to-do \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    func createReminder(from t: ThingsTask, mapping m: ListMapping) async {
        if t.isTemplate { await createReminderForTemplate(from: t, mapping: m); return }
        if let tid = t.templateId, let template = snapshot.tasks[tid] {
            log(.info, "\"\(t.title)\" repeats in Things, but \(whyTemplateDoesNotSync(template)); Reminders gets a plain reminder for this occurrence")
        }
        let done = t.status != .open
        let active = sectionsActive(m)
        let group = active ? thingsGroup(t, m) : nil
        let wanted = groceryLists.contains(m.id) ? nil : group
        do {
            let (r, copied) = try await createReminderCopy(from: t, mapping: m, due: t.due, completed: done,
                                                           completionDate: done ? t.stopDate : nil, section: wanted)
            var fingerprint = copied
            fingerprint.group = Fingerprint.cleanGroup(group)
            if done, !r.completed {
                // The reminder exists but could not be completed: record it as open, so the next pass completes it.
                fingerprint.completed = false; fingerprint.completionDay = nil
            }
            if active {
                // Record the section the reminder really has: a section that did not take (or a grocery
                // category) must not look like a later change on the Reminders side.
                let actual = Fingerprint.cleanGroup(r.section)
                if Fingerprint.groupKey(actual) != Fingerprint.groupKey(group) { fingerprint.group = actual }
                if wanted != nil, Fingerprint.groupKey(actual) != Fingerprint.groupKey(wanted) {
                    log(.warning, "Could not put \"\(t.title)\" in the Reminders section \"\(wanted ?? "")\"; it will be retried")
                }
            }
            store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: t.id, mappingId: m.id,
                                          fingerprint: fingerprint, copySide: .reminders, copiedCompleted: done))
            report.createdInReminders += 1
            log(.change, "Created reminder \"\(t.title)\" in \"\(m.listTitle)\"")
        } catch {
            fail("Could not create reminder \"\(t.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: Ownership ledger cleanup

    /// Removes a container this app created once nothing is left in it: projects and headings go to the Trash,
    /// areas and tags are deleted. Containers the user made (not in the ledger) and containers a mapping still
    /// targets are never touched.
    @discardableResult
    func removeOwnedIfEmpty(_ kind: OwnedThingsContainer.Kind, id: String, why: String) async -> Bool {
        guard let entry = store.ownedThings.first(where: { $0.id == id && $0.kind == kind }) else { return false }
        guard snapshot.exists(kind, id: id) else {
            store.ownedThings.removeAll { $0.id == id }   // already gone: nothing left to track
            return false
        }
        guard !config.targetIds().contains(id), snapshot.isEmpty(kind, id: id) else { return false }
        let name = snapshot.displayTitle(kind, id: id) ?? entry.title
        do {
            try await things.removeContainer(entry)
            snapshot.markRemoved(kind, id: id)
            store.ownedThings.removeAll { $0.id == id }
            report.removedContainers += 1
            log(.change, "Removed empty Things \(kind.rawValue) \"\(name)\" (created by this app; \(why))")
            return true
        } catch {
            log(.warning, "Could not remove empty Things \(kind.rawValue) \"\(name)\": \(error.localizedDescription)")
            return false
        }
    }

    func recordCreatedSections() async {
        for c in await reminders.takeCreatedSections()
        where !store.ownedSections.contains(where: { $0.matches(listId: c.listId, name: c.name) }) {
            store.ownedSections.append(OwnedReminderSection(listId: c.listId, name: c.name))
        }
    }

    /// End of a full pass: trash app-created headings that hold no to-dos and delete app-created Reminders
    /// sections that hold no reminders. Both are re-read first, because this pass's own writes are not in the
    /// snapshots. Skipped after any failure, so a half-finished move never looks like an empty container.
    func cleanUpEmptyHeadingsAndSections(lists: [ReminderList]) async {
        guard report.failures == 0 else { return }
        // Every container this app created that no list targets any more (a list re-pointed elsewhere,
        // removed, or items moved out by hand) and that is empty goes too, so settings changes leave no
        // remnants. removeOwnedIfEmpty refuses targeted, non-empty, and user-created containers.
        if !store.ownedThings.isEmpty, let fresh = try? await things.refresh() {
            snapshot = fresh.snapshot
            for entry in store.ownedThings {
                await removeOwnedIfEmpty(entry.kind, id: entry.id,
                                         why: entry.kind == .heading ? "it held no to-dos" : "no list syncs to it and it is empty")
            }
        }
        let known = Set(lists.map(\.id))
        let candidates = store.ownedSections.filter { sec in
            known.contains(sec.listId) && !groceryLists.contains(sec.listId) && (activeById[sec.listId].map(sectionsActive) ?? false)
        }
        guard !candidates.isEmpty,
              let fresh = try? await reminders.reminders(inLists: Array(Set(candidates.map(\.listId)))) else { return }
        for sec in candidates {
            let occupied = fresh.contains { $0.listId == sec.listId && Fingerprint.groupKey($0.section) == Fingerprint.groupKey(sec.name) }
            guard !occupied else { continue }
            let listTitle = activeById[sec.listId]?.listTitle ?? sec.listId
            do {
                try await reminders.deleteSection(name: sec.name, listId: sec.listId)
                store.ownedSections.removeAll { $0.matches(listId: sec.listId, name: sec.name) }
                report.removedContainers += 1
                log(.change, "Removed empty Reminders section \"\(sec.name)\" from \"\(listTitle)\" (created by this app)")
            } catch {
                log(.warning, "Could not remove empty Reminders section \"\(sec.name)\": \(error.localizedDescription)")
            }
        }
    }

    // MARK: Deletions

    func runDeletions(linksAtStart: [LinkRecord]) async {
        // The count limit holds for the pass as a whole (three lists losing ten items each is thirty deletions) as well
        // as per list; the fraction is per list. A single deletion in a list is never held by the fraction.
        let overall = pendingDeletes.values.reduce(0) { $0 + $1.count }
        for (mappingId, items) in pendingDeletes.sorted(by: { $0.key < $1.key }) {
            let total = linksAtStart.filter { $0.mappingId == mappingId }.count
            let n = items.count
            let tripped = !force && (n > SyncEngine.maxDeletionsPerPass || overall > SyncEngine.maxDeletionsPerPass
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
                        try await trashTemplateOccurrences(of: id)
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
