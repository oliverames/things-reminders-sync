import Foundation

/// What stopping a list (or removing its mapping) would remove, for the confirmation dialog.
public struct TeardownPreview: Sendable, Equatable {
    public var listTitle: String
    /// Things to-dos the app created from reminders; they would go to the Trash.
    public var thingsTodosToTrash = 0
    /// Reminders the app created from to-dos; they would go to Recently Deleted.
    public var remindersToDelete = 0
    /// App-created Things projects, areas, tags, and headings that would be removed once empty.
    public var thingsContainersToRemove = 0
    /// App-created Reminders sections that would be removed once empty.
    public var remindersSectionsToRemove = 0
    /// Linked pairs that existed on both sides before the app: always kept.
    public var originalsKept = 0
    public var copyCount: Int { thingsTodosToTrash + remindersToDelete }
    public var containerCount: Int { thingsContainersToRemove + remindersSectionsToRemove }
}

/// Copies made because "include completed on first link" brought completed items over.
public struct CompletedCopiesPreview: Sendable, Equatable {
    public var thingsTodosToTrash = 0
    public var remindersToDelete = 0
    public var count: Int { thingsTodosToTrash + remindersToDelete }
}

/// Outcome of an explicit teardown or completed-copy removal.
public struct TeardownReport: Sendable {
    public var config: SyncConfig
    public var links: LinkStore
    public var log: [SyncLogEntry] = []
    public var thingsTrashed = 0
    public var remindersDeleted = 0
    public var containersRemoved = 0
    public var sectionsRemoved = 0
    public var failures = 0
    public var firstFailure: String?
    public var snapshot = ThingsSnapshot()
    public var reminders: [ReminderItem] = []
    /// False when something could not be removed: links and mapping are kept so the action can be repeated.
    public var completed: Bool { failures == 0 }
}

/// Planning shared by the preview and the real thing. Pure.
enum Teardown {
    struct Copies {
        var things: [LinkRecord] = []
        var reminders: [LinkRecord] = []
        var kept = 0
    }

    static func findReminder(_ link: LinkRecord, _ items: [ReminderItem]) -> ReminderItem? {
        items.first { $0.id == link.reminderId } ?? link.reminderExternalId.flatMap { e in items.first { $0.externalId == e } }
    }

    /// The copies among `links` that still exist, by side. `onlyCompleted` limits it to completed copies.
    static func copies(of links: [LinkRecord], snapshot: ThingsSnapshot, reminders: [ReminderItem], onlyCompleted: Bool = false) -> Copies {
        var out = Copies()
        for link in links {
            if onlyCompleted && !link.copiedCompleted { continue }
            switch link.copySide {
            case .things:
                if let t = snapshot.tasks[link.thingsId], t.kind == .todo, !t.trashed { out.things.append(link) }
            case .reminders:
                if findReminder(link, reminders) != nil { out.reminders.append(link) }
            case nil:
                out.kept += 1
            }
        }
        return out
    }

    /// App-created containers of the mapping that would be empty once the given to-dos are gone.
    static func emptyContainers(listId: String, store: LinkStore, config: SyncConfig, snapshot: ThingsSnapshot,
                                goneThings: Set<String>) -> [OwnedThingsContainer] {
        let busy = config.targetIds(excluding: listId)
        let candidates = store.ownedThings.filter { $0.mappingId == listId && !busy.contains($0.id) && snapshot.exists($0.kind, id: $0.id) }
        let order: [OwnedThingsContainer.Kind: Int] = [.heading: 0, .project: 1, .area: 2, .tag: 3]
        return candidates.filter { snapshot.isEmpty($0.kind, id: $0.id, ignoring: goneThings) }
            .sorted { (order[$0.kind] ?? 9) < (order[$1.kind] ?? 9) }
    }

    static func emptySections(listId: String, store: LinkStore, reminders: [ReminderItem], goneReminders: Set<String>,
                              grocery: Bool) -> [OwnedReminderSection] {
        guard !grocery else { return [] }
        return store.ownedSections.filter { sec in
            sec.listId == listId && !reminders.contains {
                $0.listId == listId && !goneReminders.contains($0.id) && Fingerprint.groupKey($0.section) == Fingerprint.groupKey(sec.name)
            }
        }
    }

    static func preview(listId: String, config: SyncConfig, store: LinkStore, snapshot: ThingsSnapshot,
                        reminders: [ReminderItem], groceryLists: Set<String>) -> TeardownPreview {
        let title = config.mappings.first { $0.id == listId }?.listTitle ?? listId
        var p = TeardownPreview(listTitle: title)
        let c = copies(of: store.links.filter { $0.mappingId == listId }, snapshot: snapshot, reminders: reminders)
        p.thingsTodosToTrash = c.things.count
        p.remindersToDelete = c.reminders.count
        p.originalsKept = c.kept
        let goneThings = Set(c.things.map(\.thingsId))
        let goneReminders = Set(c.reminders.compactMap { findReminder($0, reminders)?.id })
        p.thingsContainersToRemove = emptyContainers(listId: listId, store: store, config: config, snapshot: snapshot, goneThings: goneThings).count
        p.remindersSectionsToRemove = emptySections(listId: listId, store: store, reminders: reminders, goneReminders: goneReminders,
                                                    grocery: groceryLists.contains(listId)).count
        return p
    }
}

extension SyncEngine {
    /// Stops syncing one list. With `removeCopies` the app's own copies go (Things to-dos to the Trash, reminders to
    /// Recently Deleted; originals stay) and then the app-created containers and sections that are left empty.
    /// Either way the mapping's links, parked links, first-link marker and detached marks are dropped, so turning the
    /// list on again links by title instead of duplicating. This explicit, user-confirmed action is not held back by
    /// the per-pass deletion safety limit; the caller serializes it with sync passes. Every removal is logged.
    /// If something fails, nothing is dropped, so the action can be repeated.
    public func teardown(config: SyncConfig, links: LinkStore, listId: String, removeCopies: Bool, removeMapping: Bool) async throws -> TeardownReport {
        var report = TeardownReport(config: config, links: links)
        var store = links
        let refreshed = try await things.refresh()
        var snapshot = refreshed.snapshot
        let lists = try await reminders.lists()
        var items = try await reminders.reminders(inLists: lists.map(\.id))
        let grocery = Set(lists.filter(\.isGroceries).map(\.id))
        guard let index = config.mappings.firstIndex(where: { $0.id == listId }) else {
            report.snapshot = snapshot; report.reminders = items
            return report
        }
        let mapping = config.mappings[index]
        func log(_ level: SyncLogEntry.Level, _ message: String) { report.log.append(SyncLogEntry(level: level, message: message)) }
        func fail(_ message: String) {
            report.failures += 1
            if report.firstFailure == nil { report.firstFailure = message }
            log(.error, message)
        }

        if removeCopies {
            let copies = Teardown.copies(of: store.links.filter { $0.mappingId == listId }, snapshot: snapshot, reminders: items)
            for link in copies.things {
                let title = snapshot.tasks[link.thingsId]?.title ?? link.fingerprint.title
                do {
                    try await things.updateTodo(id: link.thingsId, patch: ThingsTodoPatch(trashed: true))
                    snapshot.tasks[link.thingsId]?.trashed = true
                    report.thingsTrashed += 1
                    log(.change, "Moved Things to-do \"\(title)\" to the Trash (stopped syncing \"\(mapping.listTitle)\")")
                } catch { fail("Could not trash Things to-do \"\(title)\": \(error.localizedDescription)") }
            }
            for link in copies.reminders {
                guard let r = Teardown.findReminder(link, items) else { continue }
                do {
                    try await reminders.delete(id: r.id)
                    items.removeAll { $0.id == r.id }
                    report.remindersDeleted += 1
                    log(.change, "Deleted reminder \"\(r.title)\" (stopped syncing \"\(mapping.listTitle)\")")
                } catch { fail("Could not delete reminder \"\(r.title)\": \(error.localizedDescription)") }
            }
            if copies.kept > 0 { log(.info, "Kept \(copies.kept) item\(copies.kept == 1 ? "" : "s") in \"\(mapping.listTitle)\" that existed on both sides before syncing") }

            // Containers and sections this app made for the list, if they are empty now.
            for c in Teardown.emptyContainers(listId: listId, store: store, config: config, snapshot: snapshot, goneThings: []) {
                let name = snapshot.displayTitle(c.kind, id: c.id) ?? c.title
                do {
                    try await things.removeContainer(c)
                    snapshot.markRemoved(c.kind, id: c.id)
                    store.ownedThings.removeAll { $0.id == c.id }
                    report.containersRemoved += 1
                    log(.change, "Removed empty Things \(c.kind.rawValue) \"\(name)\" (created by this app; stopped syncing \"\(mapping.listTitle)\")")
                } catch { fail("Could not remove Things \(c.kind.rawValue) \"\(name)\": \(error.localizedDescription)") }
            }
            for sec in Teardown.emptySections(listId: listId, store: store, reminders: items, goneReminders: [], grocery: grocery.contains(listId)) {
                do {
                    try await reminders.deleteSection(name: sec.name, listId: listId)
                    store.ownedSections.removeAll { $0.matches(listId: listId, name: sec.name) }
                    report.sectionsRemoved += 1
                    log(.change, "Removed empty Reminders section \"\(sec.name)\" from \"\(mapping.listTitle)\" (created by this app)")
                } catch { fail("Could not remove Reminders section \"\(sec.name)\": \(error.localizedDescription)") }
            }
        }

        var newConfig = config
        newConfig.mappings[index].enabled = false
        if let target = mapping.targetId, !snapshot.exists(.init(mapping.mode), id: target) { newConfig.mappings[index].targetId = nil }
        if report.failures == 0 {
            // Detached marks of this list: its parked pairs, reminders still in the list, and to-dos in its target.
            let parked = store.parkedLinks.filter { $0.mappingId == listId }
            store.detachedThingsIds.subtract(parked.map(\.thingsId))
            store.detachedReminderIds.subtract(parked.map(\.reminderId))
            store.detachedReminderIds.subtract(items.filter { $0.listId == listId }.map(\.id))
            store.detachedThingsIds = store.detachedThingsIds.filter { id in
                !(snapshot.tasks[id].map { taskMatches($0, mapping, in: snapshot) } ?? false)
            }
            store.links.removeAll { $0.mappingId == listId }
            store.parkedLinks.removeAll { $0.mappingId == listId }
            store.linkedMappings[listId] = nil
            if removeMapping { newConfig.mappings.remove(at: index) }
            log(.info, removeMapping ? "Removed \"\(mapping.listTitle)\" from sync" : "Stopped syncing \"\(mapping.listTitle)\"")
        }
        report.config = newConfig
        report.links = store
        report.snapshot = snapshot
        report.reminders = items
        return report
    }

    /// Removes the app's copies made because "include completed on first link" brought completed items over.
    /// Same side rules as `teardown` (Things copies to the Trash, reminder copies to Recently Deleted, originals kept).
    public func removeCompletedCopies(config: SyncConfig, links: LinkStore) async throws -> TeardownReport {
        var report = TeardownReport(config: config, links: links)
        var store = links
        var snapshot = try await things.refresh().snapshot
        let lists = try await reminders.lists()
        var items = try await reminders.reminders(inLists: lists.map(\.id))
        let copies = Teardown.copies(of: store.links, snapshot: snapshot, reminders: items, onlyCompleted: true)
        func fail(_ message: String) {
            report.failures += 1
            if report.firstFailure == nil { report.firstFailure = message }
            report.log.append(SyncLogEntry(level: .error, message: message))
        }
        var done = Set<UUID>()
        for link in copies.things {
            let title = snapshot.tasks[link.thingsId]?.title ?? link.fingerprint.title
            do {
                try await things.updateTodo(id: link.thingsId, patch: ThingsTodoPatch(trashed: true))
                snapshot.tasks[link.thingsId]?.trashed = true
                store.detachedReminderIds.insert(link.reminderId)   // the original must not get a new copy
                done.insert(link.id)
                report.thingsTrashed += 1
                report.log.append(SyncLogEntry(level: .change, message: "Moved completed Things to-do \"\(title)\" to the Trash (completed copies turned off)"))
            } catch { fail("Could not trash Things to-do \"\(title)\": \(error.localizedDescription)") }
        }
        for link in copies.reminders {
            guard let r = Teardown.findReminder(link, items) else { continue }
            do {
                try await reminders.delete(id: r.id)
                items.removeAll { $0.id == r.id }
                store.detachedThingsIds.insert(link.thingsId)
                done.insert(link.id)
                report.remindersDeleted += 1
                report.log.append(SyncLogEntry(level: .change, message: "Deleted completed reminder \"\(r.title)\" (completed copies turned off)"))
            } catch { fail("Could not delete reminder \"\(r.title)\": \(error.localizedDescription)") }
        }
        store.links.removeAll { done.contains($0.id) }
        report.links = store
        report.snapshot = snapshot
        report.reminders = items
        return report
    }
}
