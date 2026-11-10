import Foundation

// Field fidelity (docs/SPEC.md "Field fidelity"): links, notes Markdown, flagged, tags and subtasks. Every field here is
// merged three-way against the stored fingerprint, patches carry only what changed, and a write that did not take keeps
// the old fingerprint so it is retried (and a delete is never mistaken for "never synced").

// MARK: - Notes and link rendering

enum NotesLink {
    static func clean(_ url: String?) -> String? {
        guard let t = url?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// How Reminders shows Things notes: the trailing link line becomes the rich link when the reminder has none (or
    /// the same one); a different link stays in the notes as text. Markdown is rendered as plain text.
    static func render(thingsNotes: String, existingURL: String?) -> (notes: String, url: String?) {
        let (body, trail) = NoteFormatting.splitTrailingURL(thingsNotes, known: existingURL)
        guard let trail else { return (NoteFormatting.plainText(fromMarkdown: thingsNotes), existingURL) }
        if existingURL == nil || existingURL == trail { return (NoteFormatting.plainText(fromMarkdown: body), trail) }
        return (NoteFormatting.plainText(fromMarkdown: thingsNotes), existingURL)
    }

    /// Things notes carrying the reminder's text and link.
    static func thingsNotes(notes: String, url: String?) -> String {
        guard let url else { return notes.trimmingCharacters(in: .whitespacesAndNewlines) }
        return NoteFormatting.appendingURL(url, to: notes)
    }

    /// Things notes with the link line `old` swapped for `new` (added when `old` is not the trailing line).
    static func replacingTrailingURL(in notes: String, old: String?, new: String?) -> String {
        var base = notes
        let (body, trail) = NoteFormatting.splitTrailingURL(notes, known: old)
        if let trail, let old, trail == old { base = body }
        guard let new else { return base }
        return NoteFormatting.appendingURL(new, to: base)
    }
}

/// What the notes triple (Things notes, Reminders notes, rich link) needs this pass.
struct NotesOutcome {
    var thingsNotes: String?
    var reminderNotes: String?
    var reminderURL: String?
    var fpNotes: String
    var fpRemindersNotes: String
    var fpURL: String?
    var conflict = false
}

struct FlagOutcome {
    var reminderFlag: Bool?
    var thingsTag: Bool?       // add (true) or remove (false) the flagged tag
    var fp: Bool?
}

struct TagOutcome {
    var reminderTags: [String]?
    var thingsAdd: [String] = []
    var thingsRemove: [String] = []
    var fp: [String]
}

enum SubtaskOp: Sendable, Equatable {
    case setCompleted(id: String, done: Bool)
    case delete(id: String)
}

struct ChecklistOutcome {
    var addSubtasks: [String] = []
    var subtaskOps: [SubtaskOp] = []
    var thingsChanges: [ThingsChecklistChange] = []
    var fp: [Fingerprint.ChecklistEntry]
    /// Keys the Reminders side was asked to change (verified by a re-read afterwards).
    var touched: Set<String> = []
}

/// Tags the engine may sync: titles that exist in Things, minus the flagged tag and every tag a tag-mode list owns.
struct TagEnvironment {
    var flaggedId: String?
    /// Mappable tag title, lowercased -> Things tag id (the oldest id when several share a title). Titles match
    /// without case because Reminders treats `#errands` and `#Errands` as one tag.
    var idByKey: [String: String] = [:]
    /// The same key -> the title as Things spells it.
    var titleByKey: [String: String] = [:]

    static func key(_ title: String) -> String { title.lowercased() }
}

func checklistKey(_ title: String) -> String { Fingerprint.normalize(title).lowercased() }

extension SyncPass {
    // MARK: Environment

    func buildTagEnvironment() {
        var env = TagEnvironment()
        let wanted = config.flaggedTagTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = snapshot.tags.values.sorted { $0.id < $1.id }
        if !wanted.isEmpty { env.flaggedId = sorted.first { $0.title == wanted }?.id }
        var excluded: Set<String> = Set(config.mappings.filter { $0.mode == .tag }.compactMap(\.targetId))
        if let f = env.flaggedId { excluded.insert(f) }
        // A list's `alwaysTag` is an existing tag (exact title first, then without case). It is never synced as a tag,
        // and a list that syncs one way from Things does not put it on anything (the app writes nothing to Things there).
        for m in config.mappings {
            guard let wanted = m.alwaysTag?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else { continue }
            guard let tag = sorted.first(where: { $0.title == wanted }) ?? sorted.first(where: { $0.title.lowercased() == wanted.lowercased() }) else {
                if isFull, activeById[m.id] != nil {
                    log(.info, "\"\(m.listTitle)\": no tag is added to its to-dos, because Things has no tag titled \"\(wanted)\" (this app never creates one)")
                }
                continue
            }
            excluded.insert(tag.id)
            if m.direction != .thingsToReminders { alwaysTagIds[m.id] = tag.id }
        }
        // RemCTL's `set_tags` takes one comma-separated string, so a title with a comma cannot be written to Reminders.
        for tag in sorted where !excluded.contains(tag.id) && !tag.title.isEmpty && !tag.title.contains(",") {
            let key = TagEnvironment.key(tag.title)
            if env.idByKey[key] == nil { env.idByKey[key] = tag.id; env.titleByKey[key] = tag.title }
        }
        tagEnv = env
        if isFull, env.flaggedId == nil {
            log(.info, "Flags are not synced: Things has no tag titled \"\(wanted)\" (this app never creates one; set the tag title in the config)")
        }
    }

    /// Keys of the to-do's tags that can sync.
    func thingsTagKeys(_ t: ThingsTask) -> Set<String> {
        Set(t.tagIds.compactMap { snapshot.tags[$0]?.title }.map(TagEnvironment.key).filter { tagEnv.idByKey[$0] != nil })
    }

    // MARK: Notes

    /// One-way notes: only the source's notes (or link) are copied, and nothing is written to the source. A change
    /// made only on the receiver is left alone, with the fingerprint unchanged, until the source's notes change.
    func decideNotesOneWay(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, source: Side) -> NotesOutcome {
        let tn = Fingerprint.normalize(t.notes), nn = Fingerprint.normalize(r.notes)
        let u = NotesLink.clean(r.url)
        // Reminders gets the rendering of the Things notes; a link line becomes the rich link when the reminder has none.
        func toReminders() -> NotesOutcome {
            let (rn, ru) = NotesLink.render(thingsNotes: t.notes, existingURL: u)
            var out = NotesOutcome(fpNotes: tn, fpRemindersNotes: Fingerprint.normalize(rn), fpURL: ru)
            if out.fpRemindersNotes != nn { out.reminderNotes = rn }
            if u == nil, let ru { out.reminderURL = ru }
            return out
        }
        func toThings(_ wanted: String) -> NotesOutcome {
            var out = NotesOutcome(fpNotes: Fingerprint.normalize(wanted), fpRemindersNotes: nn, fpURL: u)
            if out.fpNotes != tn { out.thingsNotes = wanted }
            return out
        }
        guard let base else {
            // First link: a source with no notes leaves the receiver's notes alone; a reminder with only a link adds its line.
            let asIs = NotesOutcome(fpNotes: tn, fpRemindersNotes: nn, fpURL: u)
            switch source {
            case .things: return tn.isEmpty ? asIs : toReminders()
            case .reminders:
                if nn.isEmpty { return u == nil ? asIs : toThings(NotesLink.thingsNotes(notes: t.notes, url: u)) }
                return toThings(NotesLink.thingsNotes(notes: r.notes, url: u))
            }
        }
        let legacy = base.remindersNotes == nil
        let t0 = base.notes
        let n0 = base.remindersNotes ?? base.notes
        let u0: String? = legacy ? (u.flatMap { NoteFormatting.containsLink($0, in: t.notes) ? $0 : nil }) : NotesLink.clean(base.url)
        let unchanged = NotesOutcome(fpNotes: t0, fpRemindersNotes: n0, fpURL: u0)
        switch source {
        case .things: return tn != t0 ? toReminders() : unchanged
        case .reminders:
            if nn != n0 { return toThings(NotesLink.thingsNotes(notes: r.notes, url: u)) }
            if u != u0 { return toThings(NotesLink.replacingTrailingURL(in: t.notes, old: u0, new: u)) }
            return unchanged
        }
    }

    func decideNotes(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, later: Side, source: Side? = nil) -> NotesOutcome {
        if let source { return decideNotesOneWay(base: base, reminder: r, task: t, source: source) }
        let tn = Fingerprint.normalize(t.notes), nn = Fingerprint.normalize(r.notes)
        let u = NotesLink.clean(r.url)

        // First link: Things is authoritative for text, an empty side never replaces a filled one, and the links are
        // united (a reminder's link that Things lacks is appended; a Things link line becomes the rich link).
        guard let base else {
            if tn.isEmpty {
                let wanted = NotesLink.thingsNotes(notes: r.notes, url: u)
                var out = NotesOutcome(fpNotes: Fingerprint.normalize(wanted), fpRemindersNotes: nn, fpURL: u)
                if out.fpNotes != tn { out.thingsNotes = wanted }
                return out
            }
            let wanted = NotesLink.thingsNotes(notes: t.notes, url: u)
            let (rn, ru) = NotesLink.render(thingsNotes: wanted, existingURL: u)
            var out = NotesOutcome(fpNotes: Fingerprint.normalize(wanted), fpRemindersNotes: Fingerprint.normalize(rn), fpURL: ru)
            if out.fpNotes != tn { out.thingsNotes = wanted }
            if out.fpRemindersNotes != nn { out.reminderNotes = rn }
            if u == nil, let ru { out.reminderURL = ru }
            return out
        }

        // Links saved before field fidelity stored one notes value that both sides shared and no link. A reminder link
        // that already appears in the Things notes is in sync; one that does not is a change on the Reminders side.
        let legacy = base.remindersNotes == nil
        let t0 = base.notes
        let n0 = base.remindersNotes ?? base.notes
        let u0: String? = legacy ? (u.flatMap { NoteFormatting.containsLink($0, in: t.notes) ? $0 : nil }) : NotesLink.clean(base.url)
        let tCh = tn != t0, textR = nn != n0, linkR = u != u0

        if !tCh && !textR && !linkR { return NotesOutcome(fpNotes: t0, fpRemindersNotes: n0, fpURL: u0) }

        // Both are renderings of the same text: accept without writing (no ping-pong, nothing synthesized over user text).
        let (rn, ru) = NotesLink.render(thingsNotes: t.notes, existingURL: u)
        if Fingerprint.normalize(rn) == nn, ru == u, u == nil || NoteFormatting.containsLink(u!, in: t.notes) || u == u0 {
            return NotesOutcome(fpNotes: tn, fpRemindersNotes: nn, fpURL: u)
        }

        if textR && (!tCh || later == .reminders) {
            // The reminder's text was edited (and wins any conflict): it replaces the Things notes as plain text.
            let wanted = NotesLink.thingsNotes(notes: r.notes, url: u)
            var out = NotesOutcome(fpNotes: Fingerprint.normalize(wanted), fpRemindersNotes: nn, fpURL: u)
            if out.fpNotes != tn { out.thingsNotes = wanted }
            out.conflict = tCh
            return out
        }
        if tCh {
            // Things edited the notes: Reminders gets the plain rendering (and the link line becomes the rich link). A link
            // change made in Reminders meanwhile is carried into the Things notes first.
            var wantedThings = t.notes
            if linkR { wantedThings = NotesLink.replacingTrailingURL(in: t.notes, old: u0, new: u) }
            let (rn2, ru2) = NotesLink.render(thingsNotes: wantedThings, existingURL: u)
            var out = NotesOutcome(fpNotes: Fingerprint.normalize(wantedThings), fpRemindersNotes: Fingerprint.normalize(rn2), fpURL: ru2)
            if linkR, out.fpNotes != tn { out.thingsNotes = wantedThings }
            if out.fpRemindersNotes != nn { out.reminderNotes = rn2 }
            if u == nil, let ru2 { out.reminderURL = ru2 }
            out.conflict = textR
            return out
        }
        // Only the reminder's link changed: swap the link line in the Things notes, leave its Markdown alone.
        let wanted = NotesLink.replacingTrailingURL(in: t.notes, old: u0, new: u)
        var out = NotesOutcome(fpNotes: Fingerprint.normalize(wanted), fpRemindersNotes: nn, fpURL: u)
        if out.fpNotes != tn { out.thingsNotes = wanted }
        return out
    }

    // MARK: Flagged

    func decideFlag(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, source: Side? = nil) -> FlagOutcome {
        guard let fid = tagEnv.flaggedId else { return FlagOutcome(fp: base?.flagged) }
        let rf = r.flagged, tf = t.tagIds.contains(fid), b = base?.flagged ?? false
        if rf == tf { return FlagOutcome(fp: rf) }
        if let source {
            // One way: the source's flag is copied when it changed; a flag only the receiver changed is ignored.
            let s = source == .reminders ? rf : tf
            if s == b { return FlagOutcome(fp: s) }
            return source == .reminders ? FlagOutcome(thingsTag: s, fp: s) : FlagOutcome(reminderFlag: s, fp: s)
        }
        if rf != b { return FlagOutcome(thingsTag: rf, fp: rf) }
        return FlagOutcome(reminderFlag: tf, fp: tf)
    }

    // MARK: Tags

    func decideTags(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, source: Side? = nil) -> TagOutcome {
        // Everything compares by lowercased title: a reminder's `#errands` and the Things tag "Errands" are the same tag.
        let key = TagEnvironment.key
        let mappable = Set(tagEnv.idByKey.keys)
        let rset = Set(r.tags.map(key)).intersection(mappable)
        let tset = thingsTagKeys(t)
        let b = Set((base?.tags ?? []).map(key)).intersection(mappable)
        if let source {
            // One way: a tag added to or removed from the source is added to or removed from the receiver. Tags only
            // the receiver gained or lost are ignored, and the agreed set is the source's.
            let sset = source == .reminders ? rset : tset, vset = source == .reminders ? tset : rset
            let adds = sset.subtracting(b).subtracting(vset), removes = b.subtracting(sset).intersection(vset)
            var out = TagOutcome(fp: sset.compactMap { tagEnv.titleByKey[$0] }.sorted())
            if source == .reminders {
                out.thingsAdd = adds.sorted().compactMap { tagEnv.idByKey[$0] }
                out.thingsRemove = t.tagIds.filter { id in snapshot.tags[id].map { removes.contains(key($0.title)) } ?? false }
            } else if !adds.isEmpty || !removes.isEmpty {
                out.reminderTags = r.tags.filter { !removes.contains(key($0)) } + adds.sorted().compactMap { tagEnv.titleByKey[$0] }
            }
            return out
        }
        let final = b.subtracting(b.subtracting(rset)).subtracting(b.subtracting(tset)).union(rset.subtracting(b)).union(tset.subtracting(b))
        var out = TagOutcome(fp: final.compactMap { tagEnv.titleByKey[$0] }.sorted())
        // Things: carry the tags with those titles; removal covers every tag of the to-do with a removed title.
        out.thingsAdd = final.subtracting(tset).sorted().compactMap { tagEnv.idByKey[$0] }
        let removeKeys = tset.subtracting(final)
        out.thingsRemove = t.tagIds.filter { id in snapshot.tags[id].map { removeKeys.contains(key($0.title)) } ?? false }
        // Reminders: every tag without a Things counterpart is kept as it is, and a tag it already has keeps its spelling.
        let kept = r.tags.filter { !mappable.contains(key($0)) || final.contains(key($0)) }
        let added = final.subtracting(rset).sorted().compactMap { tagEnv.titleByKey[$0] }
        if !added.isEmpty || kept.count != r.tags.count { out.reminderTags = kept + added }
        return out
    }

    // MARK: Checklist

    func decideChecklist(base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, mapping: ListMapping? = nil) -> ChecklistOutcome {
        // Checklist writes to Things use the shapes sampled from the Things app (docs/SPEC.md); `syncChecklists` (the
        // list's own setting, else the global one) turns them off.
        let write = writesChecklists(mapping)
        let source = mapping?.direction.source
        func unique<T>(_ items: [T], title: (T) -> String) -> [(key: String, item: T)] {
            var seen = Set<String>(), out: [(String, T)] = []
            for i in items {
                let k = checklistKey(title(i))
                if !k.isEmpty, seen.insert(k).inserted { out.append((k, i)) }
            }
            return out
        }
        let rItems = unique(r.subtasks, title: \.title)
        let tItems = unique(t.checklist.sorted { ($0.index, $0.id) < ($1.index, $1.id) }, title: \.title)
        let rMap = Dictionary(uniqueKeysWithValues: rItems.map { ($0.key, $0.item) })
        let tMap = Dictionary(uniqueKeysWithValues: tItems.map { ($0.key, $0.item) })
        var bMap: [String: Fingerprint.ChecklistEntry] = [:]
        for e in base?.checklist ?? [] { let k = checklistKey(e.title); if bMap[k] == nil { bMap[k] = e } }

        var keys: [String] = []
        for k in rItems.map(\.key) + tItems.map(\.key) + (base?.checklist ?? []).map({ checklistKey($0.title) }) where !keys.contains(k) { keys.append(k) }

        var out = ChecklistOutcome(fp: [])
        for key in keys {
            let rs = rMap[key], ts = tMap[key], b = bMap[key]
            func keep(_ title: String, _ done: Bool) { out.fp.append(.init(title: title, done: done)) }
            func keepBase() { if let b { out.fp.append(b) } }
            if let source {
                // One way: an item added, removed, completed or reopened on the source is copied to the receiver. What
                // only the receiver changed is ignored, and the agreed entry stays the source's. Things is only
                // written when checklist writes are on; Reminders always is.
                let s: (title: String, done: Bool)? = source == .reminders ? rs.map { ($0.title, $0.completed) } : ts.map { ($0.title, $0.completed) }
                let receiverDone: Bool? = source == .reminders ? ts?.completed : rs?.completed
                let canWrite = source == .things || write
                switch (s, receiverDone) {
                case let (s?, v?):
                    if s.done == v { keep(ts?.title ?? s.title, s.done); break }
                    guard b.map({ s.done != $0.done }) ?? s.done else {   // only the receiver differs (first sight: an open source item)
                        if b != nil { keepBase() } else { keep(s.title, s.done) }
                        break
                    }
                    guard canWrite else { keepBase(); break }
                    if source == .reminders, let ts { out.thingsChanges.append(.setCompleted(id: ts.id, completed: s.done)) }
                    if source == .things, let rs { out.subtaskOps.append(.setCompleted(id: rs.id, done: s.done)); out.touched.insert(key) }
                    keep(s.title, s.done)
                case let (s?, nil):
                    guard b == nil else { keepBase(); break }   // the receiver removed it: ignored
                    guard canWrite else { break }
                    if source == .reminders { out.thingsChanges.append(.add(title: s.title, completed: s.done)) }
                    else { out.addSubtasks.append(s.title); out.touched.insert(key) }
                    keep(s.title, s.done)
                case (nil, _?):
                    guard b != nil else { break }               // added on the receiver: ignored
                    guard canWrite else { keepBase(); break }
                    if source == .reminders, let ts { out.thingsChanges.append(.delete(id: ts.id)) }
                    if source == .things, let rs { out.subtaskOps.append(.delete(id: rs.id)); out.touched.insert(key) }
                case (nil, nil): break
                }
                continue
            }
            switch (rs, ts) {
            case let (rs?, ts?):
                var final = rs.completed
                if rs.completed != ts.completed {
                    if b == nil { final = true }                       // first sight: completed beats open
                    else if rs.completed != b!.done { final = rs.completed }
                    else { final = ts.completed }
                }
                var applied = true
                if final != rs.completed { out.subtaskOps.append(.setCompleted(id: rs.id, done: final)); out.touched.insert(key) }
                if final != ts.completed {
                    if write { out.thingsChanges.append(.setCompleted(id: ts.id, completed: final)) } else { applied = false }
                }
                if applied { keep(ts.title, final) } else { keepBase() }
            case let (rs?, nil):
                if b == nil {
                    // Added in Reminders.
                    if write { out.thingsChanges.append(.add(title: rs.title, completed: rs.completed)); keep(rs.title, rs.completed) }
                } else {
                    // Agreed before, gone from Things: remove the subtask.
                    out.subtaskOps.append(.delete(id: rs.id)); out.touched.insert(key)
                }
            case let (nil, ts?):
                if b == nil {
                    // Added in Things (a completed one is completed on the next pass, once the subtask has an id).
                    out.addSubtasks.append(ts.title); out.touched.insert(key); keep(ts.title, ts.completed)
                } else if write {
                    out.thingsChanges.append(.delete(id: ts.id))
                } else {
                    keepBase()   // removed in Reminders; the Things item is only removed once checklist writes are on
                }
            case (nil, nil):
                break
            }
        }
        return out
    }

    // MARK: Merge hook

    /// Adds the notes, flag, tag and checklist decisions to a plan. Notes edited on both sides go to the side whose
    /// notes changed later; the flag, tags and checklist merge by their own rules and use no times.
    func mergeFields(into plan: inout MergePlan, base: Fingerprint?, reminder r: ReminderItem, task t: ThingsTask, mapping: ListMapping? = nil) {
        let source = mapping?.direction.source
        let n = decideNotes(base: base, reminder: r, task: t, later: laterSide(.notes, r, t), source: source)
        plan.reminderPatch.notes = n.reminderNotes
        plan.reminderPatch.url = n.reminderURL
        plan.thingsPatch.notes = n.thingsNotes
        if n.thingsNotes != nil { plan.thingsPatch.notesBase = t.notes }   // refused if Things edits the notes meanwhile
        if n.conflict { plan.conflicts.append("notes") }
        plan.fingerprint.notes = n.fpNotes; plan.fingerprint.remindersNotes = n.fpRemindersNotes; plan.fingerprint.url = n.fpURL

        let f = decideFlag(base: base, reminder: r, task: t, source: source)
        if let tag = f.thingsTag, let id = tagEnv.flaggedId {
            if tag { plan.thingsPatch.addTagIds = (plan.thingsPatch.addTagIds ?? []) + [id] }
            else { plan.thingsPatch.removeTagIds = (plan.thingsPatch.removeTagIds ?? []) + [id] }
        }
        plan.reminderPatch.flagged = f.reminderFlag
        plan.fingerprint.flagged = f.fp

        let g = decideTags(base: base, reminder: r, task: t, source: source)
        if !g.thingsAdd.isEmpty { plan.thingsPatch.addTagIds = (plan.thingsPatch.addTagIds ?? []) + g.thingsAdd }
        if !g.thingsRemove.isEmpty { plan.thingsPatch.removeTagIds = (plan.thingsPatch.removeTagIds ?? []) + g.thingsRemove }
        plan.reminderPatch.tags = g.reminderTags
        plan.fingerprint.tags = g.fp

        let c = decideChecklist(base: base, reminder: r, task: t, mapping: mapping)
        if !c.addSubtasks.isEmpty { plan.reminderPatch.addSubtasks = c.addSubtasks }
        if !c.thingsChanges.isEmpty { plan.thingsPatch.checklist = c.thingsChanges }
        plan.subtaskOps = c.subtaskOps
        plan.checklistTouched = c.touched
        plan.fingerprint.checklist = c.fp
        plan.base = base
    }

    // MARK: Settling after the Reminders write

    /// Compares what RemCTL reports after a write with what the plan expected, and keeps the OLD fingerprint value for
    /// every field that did not take (the next pass retries it). On a first link there is no old value, so the actual
    /// state is recorded. `actual` is the item the update returned (nil when nothing was sent); `afterwards` is a re-read
    /// of the reminder used for its subtasks.
    func settle(_ plan: inout MergePlan, actual: ReminderItem?, afterwards: ReminderItem?, title: String) {
        let base = plan.base
        if let actual {
            if plan.reminderPatch.notes != nil || plan.reminderPatch.url != nil {
                let gotNotes = Fingerprint.normalize(actual.notes), gotURL = NotesLink.clean(actual.url)
                if gotNotes != plan.fingerprint.remindersNotes || gotURL != plan.fingerprint.url {
                    if let base {
                        plan.fingerprint.notes = base.notes; plan.fingerprint.remindersNotes = base.remindersNotes; plan.fingerprint.url = base.url
                    } else {
                        plan.fingerprint.remindersNotes = gotNotes; plan.fingerprint.url = gotURL
                    }
                    log(.warning, "\"\(title)\": Reminders did not take the notes or link; it will be retried")
                }
            }
            if let wanted = plan.reminderPatch.flagged, actual.flagged != wanted {
                plan.fingerprint.flagged = base != nil ? base!.flagged : actual.flagged
                log(.warning, "\"\(title)\": Reminders did not take the flag; it will be retried")
            }
            if let wanted = plan.reminderPatch.tags, RemCTLReminders.tagKeys(actual.tags) != RemCTLReminders.tagKeys(wanted) {
                let got = RemCTLReminders.tagKeys(actual.tags)
                plan.fingerprint.tags = base != nil ? base!.tags
                    : (plan.fingerprint.tags ?? []).filter { got.contains(TagEnvironment.key($0)) }
                log(.warning, "\"\(title)\": Reminders did not take the tags; they will be retried")
            }
        }
        if !plan.checklistTouched.isEmpty, let afterwards {
            var actualMap: [String: Bool] = [:]
            for s in afterwards.subtasks where actualMap[checklistKey(s.title)] == nil { actualMap[checklistKey(s.title)] = s.completed }
            var fpMap: [String: Fingerprint.ChecklistEntry] = [:]
            for e in plan.fingerprint.checklist ?? [] { fpMap[checklistKey(e.title)] = e }
            var baseMap: [String: Fingerprint.ChecklistEntry] = [:]
            for e in base?.checklist ?? [] { baseMap[checklistKey(e.title)] = e }
            var changed = false
            for key in plan.checklistTouched where actualMap[key] != fpMap[key]?.done {
                fpMap[key] = baseMap[key]
                changed = true
            }
            if changed {
                var order: [String] = []
                for e in (plan.fingerprint.checklist ?? []) + (base?.checklist ?? []) { let k = checklistKey(e.title); if !order.contains(k) { order.append(k) } }
                plan.fingerprint.checklist = order.compactMap { fpMap[$0] }
                log(.warning, "\"\(title)\": Reminders did not take every subtask change; it will be retried")
            }
        }
    }

    /// Runs the subtask completions and deletions of a plan (each through the subtask's own id) and re-reads the
    /// reminder when its subtasks were touched. Returns the re-read item (nil when none was needed).
    func runSubtaskWrites(_ plan: MergePlan, reminder id: String, listId: String) async throws -> ReminderItem? {
        for op in plan.subtaskOps {
            switch op {
            case let .setCompleted(sid, done): _ = try await reminders.update(id: sid, patch: ReminderPatch(completed: done))
            case let .delete(sid): try await reminders.delete(id: sid)
            }
        }
        guard !plan.checklistTouched.isEmpty else { return nil }
        return try await reminders.reminders(inLists: [listId]).first { $0.id == id }
    }

    // MARK: New partners

    /// What a Things to-do made from a reminder carries, and the matching fingerprint fields.
    struct ThingsFields {
        var notes: String
        var tagIds: [String]
        var checklist: [ThingsChecklistDraft]
        var flagged: Bool?
        var tags: [String]
        var entries: [Fingerprint.ChecklistEntry]
    }

    func thingsFields(from r: ReminderItem, mapping: ListMapping? = nil) -> ThingsFields {
        let writeChecklist = writesChecklists(mapping)
        let u = NotesLink.clean(r.url)
        var tagIds: [String] = []
        var titles: [String] = []
        for name in r.tags {
            let key = TagEnvironment.key(name)
            if let id = tagEnv.idByKey[key], !tagIds.contains(id) { tagIds.append(id); titles.append(tagEnv.titleByKey[key] ?? name) }
        }
        var flagged: Bool?
        if let fid = tagEnv.flaggedId { flagged = r.flagged; if r.flagged, !tagIds.contains(fid) { tagIds.append(fid) } }
        var seen = Set<String>(), items: [Fingerprint.ChecklistEntry] = []
        for s in r.subtasks where seen.insert(checklistKey(s.title)).inserted && !checklistKey(s.title).isEmpty {
            items.append(.init(title: s.title, done: s.completed))
        }
        let entries = writeChecklist ? items : []
        return ThingsFields(notes: NotesLink.thingsNotes(notes: r.notes, url: u), tagIds: tagIds,
                            checklist: writeChecklist ? items.map { ThingsChecklistDraft(title: $0.title, completed: $0.done) } : [],
                            flagged: flagged, tags: titles.sorted(), entries: entries)
    }

    /// The fingerprint of a reminder that was just copied to Things.
    func fingerprint(forNewThingsFrom r: ReminderItem, group: String?, fields f: ThingsFields) -> Fingerprint {
        var fp = Fingerprint(reminder: r, days: days, group: group)
        fp.notes = Fingerprint.normalize(f.notes)
        fp.remindersNotes = Fingerprint.normalize(r.notes)
        fp.url = NotesLink.clean(r.url)
        fp.flagged = f.flagged
        fp.tags = f.tags
        fp.checklist = f.entries
        return fp
    }

    /// Creates the reminder for a Things to-do: notes and the link line split, then flag, tags, link and subtasks in a
    /// second call (RemCTL needs `private` for them). If that call fails the reminder still exists, so the link is kept
    /// and the notes fingerprint is left stale, which makes the next pass retry the rest.
    func createReminderCopy(from t: ThingsTask, mapping m: ListMapping, due: DueDate?, completed: Bool, completionDate: Date?,
                            section: String?, recurrence: RepeatRule? = nil) async throws -> (reminder: ReminderItem, fingerprint: Fingerprint) {
        let (notes, url) = NotesLink.render(thingsNotes: t.notes, existingURL: nil)
        let created = try await reminders.create(title: t.title, notes: notes, due: due, completed: completed, completionDate: completionDate,
                                                 listId: m.id, section: section, recurrence: recurrence)
        var fp = Fingerprint(things: t, days: days)
        fp.remindersNotes = Fingerprint.normalize(created.notes); fp.url = NotesLink.clean(created.url)
        var plan = MergePlan(fingerprint: fp)
        var empty = created
        empty.url = nil; empty.tags = []; empty.flagged = false; empty.subtasks = []
        // The same decisions as for an existing pair, from a reminder that has nothing yet.
        let tagsOnly = decideTags(base: nil, reminder: empty, task: t)
        let flag = decideFlag(base: nil, reminder: empty, task: t)
        let list = decideChecklist(base: nil, reminder: empty, task: t)
        var patch = ReminderPatch()
        patch.url = url
        patch.flagged = flag.reminderFlag
        patch.tags = tagsOnly.reminderTags
        patch.addSubtasks = list.addSubtasks.isEmpty ? nil : list.addSubtasks
        plan.reminderPatch = patch
        plan.subtaskOps = []
        plan.checklistTouched = list.touched
        plan.fingerprint.notes = Fingerprint.normalize(t.notes)
        plan.fingerprint.remindersNotes = Fingerprint.normalize(created.notes)
        plan.fingerprint.url = url ?? NotesLink.clean(created.url)
        plan.fingerprint.flagged = flag.fp
        plan.fingerprint.tags = tagsOnly.fp
        plan.fingerprint.checklist = list.fp
        plan.base = nil
        guard !patch.isEmpty else { return (created, plan.fingerprint) }
        do {
            let updated = try await reminders.update(id: created.id, patch: patch)
            let after = plan.checklistTouched.isEmpty ? nil : try await reminders.reminders(inLists: [m.id]).first { $0.id == created.id }
            settle(&plan, actual: updated, afterwards: after, title: t.title)
            return (updated, plan.fingerprint)
        } catch {
            log(.warning, "Created reminder \"\(t.title)\" but could not add its link, flag, tags or subtasks: \(error.localizedDescription); it will be retried")
            var stale = plan.fingerprint
            if url != nil { stale.notes = "" }   // Things notes read as changed, so the link is written on the next pass
            stale.flagged = nil; stale.tags = nil; stale.checklist = nil
            return (created, stale)
        }
    }
}
