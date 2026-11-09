import Foundation

/// One-time inference of the ownership ledger for data created before the ledger existed (docs/SPEC.md,
/// "Ownership ledger"). Pure: it reads the activity log, the current links and config, the Things snapshot,
/// and the reminders, and returns an updated `LinkStore`. When the evidence is ambiguous it records nothing:
/// a link keeps `copySide == nil` (treated as an original, never deleted) and a container stays unrecorded
/// (never removed).
public enum LedgerBackfill {
    public struct Result: Sendable {
        public var store: LinkStore
        public var containersRecorded = 0
        public var copiesInThings = 0
        public var copiesInReminders = 0
        public var completedCopies = 0
        /// Links the log shows were paired by title (both items existed before the app).
        public var pairedOriginals = 0
        public var hasChanges: Bool { containersRecorded + copiesInThings + copiesInReminders > 0 }
        public var summary: String {
            "\(containersRecorded) container(s), \(copiesInThings) copy/copies in Things, \(copiesInReminders) in Reminders (\(completedCopies) completed)"
        }
    }

    /// How far a log entry's time may sit from the item's own creation time and still be the same event.
    static let tolerance: TimeInterval = 600

    private enum EventKind { case createdTodo, createdReminder, linked }
    private struct Event { var kind: EventKind; var title: String; var list: String; var date: Date }
    private struct ContainerEvent {
        var kind: OwnedThingsContainer.Kind
        var title: String
        /// The list title (`for list`) or, for a section heading, the project title (`in`).
        var scope: String
        var inProject: Bool
        var date: Date
    }

    private static func norm(_ s: String) -> String { Fingerprint.normalize(s).lowercased() }

    public static func infer(log: [SyncLogEntry], store: LinkStore, config: SyncConfig, snapshot: ThingsSnapshot,
                             reminders: [ReminderItem]) -> Result {
        var result = Result(store: store)
        var events: [Event] = []
        var containerEvents: [ContainerEvent] = []
        for entry in log {
            let m = entry.message
            if let r = m.wholeMatch(of: #/Created Things to-do "(.+)" from list "(.+)"/#) {
                events.append(Event(kind: .createdTodo, title: norm(String(r.1)), list: norm(String(r.2)), date: entry.date))
            } else if let r = m.wholeMatch(of: #/Created reminder "(.+)" in "(.+)"/#) {
                events.append(Event(kind: .createdReminder, title: norm(String(r.1)), list: norm(String(r.2)), date: entry.date))
            } else if let r = m.wholeMatch(of: #/Linked "(.+)" in "(.+)" with its Things to-do/#) {
                events.append(Event(kind: .linked, title: norm(String(r.1)), list: norm(String(r.2)), date: entry.date))
            } else if let r = m.wholeMatch(of: #/Created Things (project|area|tag|heading) "(.+)" for list "(.+)"/#),
                      let kind = OwnedThingsContainer.Kind(rawValue: String(r.1)) {
                containerEvents.append(ContainerEvent(kind: kind, title: norm(String(r.2)), scope: norm(String(r.3)), inProject: false, date: entry.date))
            } else if let r = m.wholeMatch(of: #/Created Things heading "(.+)" in "(.+)"/#) {
                containerEvents.append(ContainerEvent(kind: .heading, title: norm(String(r.1)), scope: norm(String(r.2)), inProject: true, date: entry.date))
            }
        }

        inferCopies(events: events, config: config, snapshot: snapshot, reminders: reminders, result: &result)
        inferContainers(containerEvents, config: config, snapshot: snapshot, result: &result)
        return result
    }

    // MARK: Copies

    private static func inferCopies(events: [Event], config: SyncConfig, snapshot: ThingsSnapshot, reminders: [ReminderItem],
                                    result: inout Result) {
        let listTitle = Dictionary(config.mappings.map { ($0.id, norm($0.listTitle)) }, uniquingKeysWith: { a, _ in a })
        func key(_ l: LinkRecord) -> String? {
            guard let list = listTitle[l.mappingId] else { return nil }
            return "\(list)\u{1}\(norm(l.fingerprint.title))"
        }
        var byKey: [String: [Event]] = [:]
        for e in events { byKey["\(e.list)\u{1}\(e.title)", default: []].append(e) }
        let reminderById = Dictionary(reminders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let reminderByExternal = Dictionary(reminders.compactMap { r in r.externalId.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        // Links and parked links are inferred together; `slot` says where to write back.
        enum Slot { case live(Int), parked(Int) }
        var groups: [String: [(slot: Slot, link: LinkRecord)]] = [:]
        for (i, l) in result.store.links.enumerated() where l.copySide == nil && !l.copiedCompleted {
            if let k = key(l), byKey[k] != nil { groups[k, default: []].append((.live(i), l)) }
        }
        for (i, l) in result.store.parkedLinks.enumerated() where l.copySide == nil && !l.copiedCompleted {
            if let k = key(l), byKey[k] != nil { groups[k, default: []].append((.parked(i), l)) }
        }

        func side(of kind: EventKind) -> Side? {
            switch kind { case .createdTodo: .things; case .createdReminder: .reminders; case .linked: nil }
        }
        /// A Things to-do the app created appears right after its log entry; the to-do behind a created reminder
        /// existed before it. An unknown creation date proves nothing against the log.
        func consistent(_ e: Event, _ link: LinkRecord) -> Bool {
            guard let created = snapshot.tasks[link.thingsId]?.creationDate else { return true }
            switch e.kind {
            case .createdTodo: return abs(created.timeIntervalSince(e.date)) <= tolerance
            case .createdReminder: return created <= e.date.addingTimeInterval(tolerance)
            case .linked: return created <= e.date.addingTimeInterval(tolerance)
            }
        }

        for (k, members) in groups {
            let evs = byKey[k] ?? []
            let kinds = Set(evs.map(\.kind))
            let decided: EventKind?
            if kinds.count == 1, let only = kinds.first {
                let ok = evs.count >= members.count && members.allSatisfy { m in evs.contains { consistent($0, m.link) } }
                decided = ok ? only : nil
            } else if members.count == 1 {
                let good = Set(evs.filter { consistent($0, members[0].link) }.map(\.kind))
                decided = good.count == 1 ? good.first : nil
            } else {
                decided = nil
            }
            guard let decided else { continue }
            let side = side(of: decided)
            if side == nil { result.pairedOriginals += members.count; continue }
            let earliest = evs.filter { $0.kind == decided }.map(\.date).min()!
            for member in members {
                var link = member.link
                link.copySide = side
                let completed = copyWasCompleted(link, side: side!, at: earliest, snapshot: snapshot,
                                                 reminder: reminderByExternal[link.reminderExternalId ?? ""] ?? reminderById[link.reminderId])
                link.copiedCompleted = completed
                switch member.slot {
                case .live(let i): result.store.links[i] = link
                case .parked(let i): result.store.parkedLinks[i] = link
                }
                if side == .things { result.copiesInThings += 1 } else { result.copiesInReminders += 1 }
                if completed { result.completedCopies += 1 }
            }
        }
    }

    /// The copy was completed before the app made it (so "include completed on first link" brought it over) when
    /// its own completion time precedes the creation entry. Without a completion time this is false.
    private static func copyWasCompleted(_ link: LinkRecord, side: Side, at created: Date, snapshot: ThingsSnapshot,
                                         reminder: ReminderItem?) -> Bool {
        let stop: Date?
        switch side {
        case .things:
            guard let t = snapshot.tasks[link.thingsId], t.status != .open else { return false }
            stop = t.stopDate
        case .reminders:
            guard let r = reminder, r.completed else { return false }
            stop = r.completionDate
        }
        guard let stop else { return false }
        return stop < created.addingTimeInterval(-60)
    }

    // MARK: Containers

    private static func inferContainers(_ events: [ContainerEvent], config: SyncConfig, snapshot: ThingsSnapshot, result: inout Result) {
        let known = Set(result.store.ownedThings.map(\.id))
        var recorded = Set<String>()
        for e in events {
            var candidates: [(id: String, created: Date?)] = []
            var mapping: ListMapping?
            if e.inProject {
                let projects = Set(snapshot.projects.filter { norm($0.title) == e.scope }.map(\.id))
                let owners = config.mappings.filter { $0.mode == .project && $0.targetId.map(projects.contains) == true }
                guard owners.count == 1 else { continue }
                mapping = owners[0]
                candidates = snapshot.headings.filter { norm($0.title) == e.title && $0.projectId == owners[0].targetId }.map { ($0.id, $0.creationDate) }
            } else {
                let owners = config.mappings.filter { norm($0.listTitle) == e.scope }
                guard owners.count == 1 else { continue }
                mapping = owners[0]
                switch e.kind {
                case .project: candidates = snapshot.projects.filter { norm($0.title) == e.title }.map { ($0.id, $0.creationDate) }
                case .heading: candidates = snapshot.headings.filter { norm($0.title) == e.title }.map { ($0.id, $0.creationDate) }
                case .area: candidates = snapshot.areas.values.filter { norm($0.title) == e.title }.map { ($0.id, nil) }
                case .tag: candidates = snapshot.tags.values.filter { norm($0.title) == e.title }.map { ($0.id, nil) }
                }
            }
            guard let mapping else { continue }
            // Same title can belong to a container the user made: keep what fits the log entry's time, then what the
            // config references, then the only empty one; anything else is not recorded.
            var fits = candidates.filter { c in c.created.map { abs($0.timeIntervalSince(e.date)) <= tolerance } ?? true }
            fits.removeAll { known.contains($0.id) || recorded.contains($0.id) }
            var pick: String?
            if fits.count == 1 { pick = fits[0].id }
            else if fits.count > 1 {
                let referenced = fits.filter { $0.id == mapping.targetId }
                let empty = fits.filter { snapshot.isEmpty(e.kind, id: $0.id) }
                if referenced.count == 1 { pick = referenced[0].id }
                else if empty.count == 1 { pick = empty[0].id }
            }
            guard let pick else { continue }
            recorded.insert(pick)
            let title = snapshot.displayTitle(e.kind, id: pick) ?? e.title
            result.store.ownedThings.append(OwnedThingsContainer(id: pick, kind: e.kind, mappingId: mapping.id, title: title, created: e.date))
            result.containersRecorded += 1
        }
    }
}
