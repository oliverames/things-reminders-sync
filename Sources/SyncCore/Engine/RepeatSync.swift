import Foundation

// Repeating items (docs/RECURRENCE.md, docs/SPEC.md "Repeating items"). A repeating reminder pairs with a Things
// TEMPLATE; the rule syncs both ways and the app never creates an occurrence (Things generates them from `icsd`).

extension SyncPass {
    // MARK: Things side of a template

    /// Open (not done, not trashed) occurrences of a template, earliest day first.
    func openOccurrences(of templateId: String) -> [ThingsTask] {
        snapshot.tasks.values
            .filter { $0.templateId == templateId && $0.kind == .todo && !$0.trashed && $0.status == .open }
            .sorted { ($0.startDate ?? "9999", $0.id) < ($1.startDate ?? "9999", $1.id) }
    }

    func completedOccurrence(of templateId: String, on day: String) -> ThingsTask? {
        snapshot.tasks.values.first { $0.templateId == templateId && $0.kind == .todo && !$0.trashed && $0.status != .open && $0.startDate == day }
    }

    /// The due day a reminder made from this template gets: the open occurrence's day, else the template's next day.
    func templateDue(_ t: ThingsTask) -> DueDate? {
        if let o = openOccurrences(of: t.id).first, o.due != nil { return o.due }
        guard let day = t.nextDay else { return nil }
        return DueDate(day: day, minutes: t.reminderSeconds.map { $0 / 60 })
    }

    /// What Things currently says the pair's due is. Nil when Things has no signal: every occurrence so far is done and
    /// the next one has not been generated yet (Things generates it when its day arrives).
    func observedThingsDue(_ t: ThingsTask) -> DueDate? {
        if let o = openOccurrences(of: t.id).first, let due = o.due { return due }
        if (t.instancesCreated ?? 0) == 0, let day = t.nextDay { return DueDate(day: day, minutes: t.reminderSeconds.map { $0 / 60 }) }
        return nil
    }

    /// True when the template's rule can be written to Reminders exactly (so the pair is a template pair).
    func templateSyncs(_ t: ThingsTask) -> Bool {
        guard let rule = t.recurrence, !rule.afterCompletion, let due = templateDue(t) else { return false }
        return RemCTLRecurrence.spec(for: rule, due: due) != nil
    }

    func whyTemplateDoesNotSync(_ t: ThingsTask) -> String {
        guard let rule = t.recurrence else { return "its rule is not one this app recognises" }
        if rule.afterCompletion { return "Reminders has no repeat-after-completion" }
        if templateDue(t) == nil { return "it has no next date yet" }
        return "RemCTL cannot write that rule"
    }

    // MARK: Merge helpers

    /// Both sides with due and completion forced to the stored values, so `merge` only looks at title, notes and group.
    func neutralized(reminder: ReminderItem, task: ThingsTask, base: Fingerprint) -> (ReminderItem, ThingsTask) {
        var r = reminder, t = task
        r.due = base.due; r.completed = base.completed; r.completionDate = nil
        t.startDate = base.due?.day; t.reminderSeconds = base.due?.minutes.map { $0 * 60 }
        t.status = base.completed ? .completed : .open; t.stopDate = nil
        return (r, t)
    }

    /// True when `to` is the rule's next occurrence after `base` at the same time of day.
    func isAdvance(rule: RepeatRule?, base: DueDate?, to: DueDate?) -> Bool {
        guard let rule, let base, let to, base.minutes == to.minutes, let next = rule.nextOccurrence(after: base.day) else { return false }
        return next == to.day
    }

    // MARK: Existing template pair

    /// Due, completion and rule of a template pair (title, notes and group are already in `plan`).
    /// In a one-way list (`source`) only the source's due, completion and rule are copied; see `SyncPass.merge`.
    func templateExtras(link: LinkRecord, reminder r: ReminderItem, task t: ThingsTask, plan: inout MergePlan, source: Side? = nil) {
        let baseFP = link.fingerprint
        let base = baseFP.due
        let rDue = r.due
        let occurrences = openOccurrences(of: t.id)
        // The Things due is the open occurrence's when there is one, else the template's next day.
        let laterDue = laterSide(r.modified(.due), occurrences.first?.modified(.due) ?? t.modified(.due))
        var fp = plan.fingerprint

        if r.completed {
            // The reminder finished for good (its last occurrence): finish the open occurrence for its day.
            if !baseFP.completed, source != .things {
                if let day = base?.day ?? rDue?.day, let o = occurrences.first(where: { $0.startDate == day }) ?? occurrences.first {
                    plan.occurrenceWrites.append((o.id, ThingsTodoPatch(completed: true)))
                }
                fp.completed = true
            }
        } else if let base, !baseFP.completed {
            let reminderMoved = rDue != base
            if !reminderMoved, source != .reminders, completedOccurrence(of: t.id, on: base.day) != nil {
                // Things completed the occurrence: the reminder advances itself. Never pass a completion date.
                plan.reminderPatch.completed = true
                plan.reminderAdvances = true
            } else {
                let observed = observedThingsDue(t)
                let thingsMoved = observed != nil && observed != base
                var side: Side?
                if let source { side = (source == .reminders ? reminderMoved : thingsMoved) ? source : nil }
                else if reminderMoved && thingsMoved { side = laterDue } else if reminderMoved { side = .reminders } else if thingsMoved { side = .things }
                switch side {
                case .reminders:
                    // A due change that comes with a new rule is a rule edit, never a completion, even when the new
                    // date is the new rule's next occurrence: the open occurrence is moved, not finished.
                    let ruleEdited = baseFP.rule.map { agreed in r.recurrence.map { $0.key != agreed.key } ?? false } ?? false
                    if !ruleEdited, isAdvance(rule: r.recurrence ?? t.recurrence, base: base, to: rDue) {
                        // Completing in Reminders advanced the same reminder: finish the occurrence for the old day.
                        if let o = occurrences.first(where: { $0.startDate == base.day }) {
                            plan.occurrenceWrites.append((o.id, ThingsTodoPatch(completed: true)))
                        } else if occurrences.isEmpty, let rDue {
                            // No occurrence to finish (Things has not generated one yet): move the template's next
                            // day, or the next pass reads the old `tir` as a Things-side change and reverts the reminder.
                            plan.thingsPatch.templateNext = rDue
                        }
                    } else if let rDue {
                        // A reschedule: move the open occurrence, or the template's next day when there is none.
                        if let o = occurrences.first {
                            plan.occurrenceWrites.append((o.id, ThingsTodoPatch(when: .some(rDue))))
                            // A new time on the same day is a new time for the series: without it on the template, Things
                            // makes the next occurrence at the old time and that reads as a change back.
                            if rDue.day == base.day, rDue.minutes != base.minutes { plan.thingsPatch.templateMinutes = .some(rDue.minutes) }
                        } else { plan.thingsPatch.templateNext = rDue }
                    }
                    fp.due = rDue
                case .things:
                    plan.reminderPatch.due = .some(observed)
                    fp.due = observed
                case nil: break
                }
            }
        } else if base == nil, let rDue {
            fp.due = rDue
        }

        // Rule: only rules of a known shape are copied.
        func ruleToThings(_ rule: RepeatRule) {
            if ThingsRepeat.rr(for: rule, start: rDue?.day ?? t.nextDay ?? "2026-01-01") != nil {
                plan.thingsPatch.recurrence = rule; fp.rule = rule
            } else {
                log(.info, "\"\(t.title)\": the reminder's new repeat rule has no verified Things form; the Things rule was left as it is")
                fp.rule = nil
            }
        }
        func ruleToReminders(_ rule: RepeatRule) {
            if RemCTLRecurrence.spec(for: rule, due: rDue ?? templateDue(t)) != nil {
                plan.reminderPatch.recurrence = .some(rule); fp.rule = rule
            } else {
                log(.info, "\"\(t.title)\": the new Things repeat rule cannot be written to Reminders; the reminder's rule was left as it is")
                fp.rule = nil
            }
        }
        if let source {
            // One way: the source's rule is copied when it changed since the agreed rule. A rule only the receiver
            // changed (or a repeat the reminder lost) is ignored, and the agreed rule stays the source's.
            let s = source == .reminders ? r.recurrence : t.recurrence, v = source == .reminders ? t.recurrence : r.recurrence
            if let s {
                if s.key == v?.key { fp.rule = t.recurrence ?? s }
                else if let baseRule = baseFP.rule, s.key != baseRule.key {
                    if source == .reminders { ruleToThings(s) } else { ruleToReminders(s) }
                }
            }
        } else if let rRule = r.recurrence, let tRule = t.recurrence {
            if let baseRule = baseFP.rule {
                if rRule.key != tRule.key {
                    let rChanged = rRule.key != baseRule.key, tChanged = tRule.key != baseRule.key
                    let side: Side = rChanged && !tChanged ? .reminders : tChanged && !rChanged ? .things : laterSide(.rule, r, t)
                    switch side {
                    case .reminders: ruleToThings(rRule)
                    case .things: ruleToReminders(tRule)
                    }
                } else {
                    fp.rule = tRule
                }
            } else if rRule.key == tRule.key {
                fp.rule = tRule
            }
        }
        plan.fingerprint = fp
    }

    // MARK: First link

    /// Pairs a repeating reminder with an existing template (title match on first link). Things' open occurrence
    /// and rule win a disagreement, because Things holds the occurrences.
    func pairTemplate(reminder r: ReminderItem, task t: ThingsTask, mapping m: ListMapping) async {
        var groupInput: GroupInput?
        if sectionsActive(m) {
            groupInput = GroupInput(things: thingsGroup(t, m), reminders: r.section, remindersReadOnly: groceryLists.contains(r.listId))
        }
        let seed = Fingerprint(title: Fingerprint.normalize(r.title), notes: Fingerprint.normalize(r.notes), due: r.due,
                               completed: false, completionDay: nil)
        let (rEff, tEff) = neutralized(reminder: r, task: t, base: seed)
        let source = m.direction.source
        var plan = merge(base: nil, reminder: rEff, task: tEff, group: groupInput, mapping: m)
        plan.fingerprint.due = r.due; plan.fingerprint.completed = false; plan.fingerprint.completionDay = nil
        var occurrenceMove: (id: String, patch: ThingsTodoPatch)?
        if source == .reminders {
            // One way from Reminders: the reminder's date and rule go to Things, and the reminder is not written.
            if let rDue = r.due, let observed = observedThingsDue(t), observed != rDue {
                if let o = openOccurrences(of: t.id).first { occurrenceMove = (o.id, ThingsTodoPatch(when: .some(rDue))) }
                else { plan.thingsPatch.templateNext = rDue }
            }
            if let rRule = r.recurrence, let tRule = t.recurrence {
                if rRule.key == tRule.key { plan.fingerprint.rule = tRule }
                else if ThingsRepeat.rr(for: rRule, start: r.due?.day ?? t.nextDay ?? "2026-01-01") != nil {
                    plan.thingsPatch.recurrence = rRule; plan.fingerprint.rule = rRule
                }
            }
        } else {
            if let observed = observedThingsDue(t), observed != r.due {
                plan.reminderPatch.due = .some(observed); plan.fingerprint.due = observed
            }
            if let rRule = r.recurrence, let tRule = t.recurrence {
                plan.fingerprint.rule = tRule
                if rRule.key != tRule.key {
                    if RemCTLRecurrence.spec(for: tRule, due: plan.fingerprint.due) != nil { plan.reminderPatch.recurrence = .some(tRule) }
                    else { plan.fingerprint.rule = nil }
                }
            }
        }
        if let tag = alwaysTagIds[m.id], !t.tagIds.contains(tag) { plan.thingsPatch.addTagIds = (plan.thingsPatch.addTagIds ?? []) + [tag] }
        enforceDirection(&plan, source: source)
        do {
            var linked = r
            var actual: ReminderItem?
            if case .some(let group) = plan.thingsGroup { plan.thingsPatch.placement = try await placement(forGroup: group, in: m) }
            if !plan.reminderPatch.isEmpty {
                linked = try await reminders.update(id: r.id, patch: plan.reminderPatch)
                actual = linked
                if let wanted = plan.reminderPatch.section {
                    reconcileSection(&plan.fingerprint, wanted: wanted, actual: linked.section, title: r.title)
                }
            }
            let afterwards = try await runSubtaskWrites(plan, reminder: linked.id, listId: linked.listId)
            settle(&plan, actual: actual, afterwards: afterwards, title: r.title)
            if !plan.thingsPatch.isEmpty { try await things.updateTodo(id: t.id, patch: plan.thingsPatch) }
            if let move = occurrenceMove { try await things.updateTodo(id: move.id, patch: move.patch) }
            store.links.append(LinkRecord(reminderId: linked.id, reminderExternalId: linked.externalId ?? r.externalId, thingsId: t.id,
                                          mappingId: m.id, fingerprint: plan.fingerprint, repeatMode: .template))
            report.linked += 1
            log(.change, "Linked repeating \"\(r.title)\" in \"\(m.listTitle)\" with its Things repeating to-do")
        } catch {
            fail("Could not link \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: Creating partners

    /// Placement and tags for a new Things item in a mapping (same rules for to-dos and templates).
    func thingsPlacement(for m: ListMapping, group: String?) async throws -> (ThingsPlacement, [String]) {
        guard let target = m.targetId else { throw ThingsCloudError.notFound("target of \(m.listTitle)") }
        var placement: ThingsPlacement
        var tags: [String] = []
        switch m.mode {
        case .project: placement = .project(target)
        case .area: placement = .area(target)
        case .tag: placement = .inbox; tags = [target]
        case .heading: placement = .heading(target)
        }
        if let group { placement = try await self.placement(forGroup: group, in: m) }
        if let tag = alwaysTagIds[m.id], !tags.contains(tag) { tags.append(tag) }
        return (placement, tags)
    }

    /// A new repeating reminder: a Things template when the rule has a verified Things shape, otherwise a plain
    /// to-do for the current occurrence (`.reminderRepeats`), with one `.info` saying why.
    func createThingsForRepeating(from r: ReminderItem, mapping m: ListMapping) async {
        let group = sectionsActive(m) ? Fingerprint.cleanGroup(r.section) : nil
        do {
            let (placement, tags) = try await thingsPlacement(for: m, group: group)
            let fields = thingsFields(from: r, mapping: m)
            let allTags = tags + fields.tagIds.filter { !tags.contains($0) }
            var fp = fingerprint(forNewThingsFrom: r, group: group, fields: fields)
            if let rule = r.recurrence, let due = r.due, ThingsRepeat.rr(for: rule, start: due.day) != nil {
                let id = try await things.createTodo(ThingsTodoDraft(title: r.title, notes: fields.notes, when: due, placement: placement,
                                                                     tagIds: allTags, recurrence: rule, checklist: fields.checklist))
                fp.rule = rule
                store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: id, mappingId: m.id,
                                              fingerprint: fp, copySide: .things, repeatMode: .template))
                report.createdInThings += 1
                log(.change, "Created repeating Things to-do \"\(r.title)\" from list \"\(m.listTitle)\"")
            } else {
                log(.info, "\"\(r.title)\" repeats in Reminders in a way Things cannot hold; Things gets a plain to-do for the current occurrence")
                let start = arrival(of: r, in: m)
                let id = try await things.createTodo(ThingsTodoDraft(title: r.title, notes: fields.notes, when: start.when, placement: placement,
                                                                     tagIds: allTags, checklist: fields.checklist, someday: start.someday))
                fp.undatedThingsDay = start.undatedDay
                store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: id, mappingId: m.id,
                                              fingerprint: fp, copySide: .things, repeatMode: .reminderRepeats))
                report.createdInThings += 1
                log(.change, "Created Things to-do \"\(r.title)\" from list \"\(m.listTitle)\"")
            }
        } catch {
            fail("Could not create Things to-do \"\(r.title)\": \(error.localizedDescription)")
        }
    }

    /// A new Things template becomes a repeating reminder. A template whose rule Reminders cannot hold is skipped
    /// (its open occurrences sync as plain items, see `createReminder`).
    func createReminderForTemplate(from t: ThingsTask, mapping m: ListMapping) async {
        guard templateSyncs(t), let rule = t.recurrence, let due = templateDue(t) else { return }
        let group = sectionsActive(m) ? thingsGroup(t, m) : nil
        let wanted = groceryLists.contains(m.id) ? nil : group
        do {
            let (r, copied) = try await createReminderCopy(from: t, mapping: m, due: due, completed: false, completionDate: nil,
                                                           section: wanted, recurrence: rule)
            var fp = copied
            fp.title = Fingerprint.normalize(t.title); fp.due = r.due ?? due; fp.completed = false; fp.completionDay = nil
            fp.group = Fingerprint.cleanGroup(group); fp.rule = rule
            if sectionsActive(m) {
                let actual = Fingerprint.cleanGroup(r.section)
                if Fingerprint.groupKey(actual) != Fingerprint.groupKey(group) { fp.group = actual }
            }
            store.links.append(LinkRecord(reminderId: r.id, reminderExternalId: r.externalId, thingsId: t.id, mappingId: m.id,
                                          fingerprint: fp, copySide: .reminders, repeatMode: .template))
            report.createdInReminders += 1
            log(.change, "Created repeating reminder \"\(t.title)\" in \"\(m.listTitle)\"")
            await addAlwaysTag(to: t, mapping: m)
        } catch {
            fail("Could not create reminder \"\(t.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: `.reminderRepeats` pairs

    func reminderRepeatsPlan(link: LinkRecord, reminder r: ReminderItem, task t: ThingsTask, group: GroupInput?,
                             mapping: ListMapping? = nil) -> MergePlan {
        var rEff = r
        var advance = false
        let base = link.fingerprint.due
        if !r.completed, t.status == .open, let base, r.due != base, isAdvance(rule: r.recurrence, base: base, to: r.due) {
            advance = true
            rEff.due = base   // the due change is the advance, not a reschedule
        }
        var plan = merge(base: link.fingerprint, reminder: rEff, task: t, group: group, mapping: mapping)
        plan.fingerprint.rule = nil
        if advance {
            plan.thingsPatch.completed = true
            plan.replaceThings = true
        } else if plan.reminderPatch.completed == true {
            // The to-do was completed: the reminder advances itself, and the to-do is replaced for its next day.
            plan.reminderPatch.completionDate = nil
            plan.reminderAdvances = true
            plan.replaceThings = true
        }
        return plan
    }

    /// After a repeating reminder advanced, creates the Things item for its new due day. The completed to-do stays
    /// behind, detached. A rule Things can hold (a plain pair whose reminder was given a repeat later) gets a repeating
    /// template from here on, and the pair becomes a template pair; any other rule gets a plain to-do again.
    /// Nil when the reminder finished (no next occurrence).
    func replacePlainTodo(link: LinkRecord, task: ThingsTask, plan: MergePlan, mapping: ListMapping?,
                          reminder r: ReminderItem) async throws -> (id: String, fingerprint: Fingerprint, mode: RepeatLinkMode)? {
        guard let mapping, !r.completed, let due = r.due else { return nil }
        let group = sectionsActive(mapping) ? Fingerprint.cleanGroup(plan.fingerprint.group) : nil
        let (placement, tags) = try await thingsPlacement(for: mapping, group: group)
        let fields = thingsFields(from: r, mapping: mapping)
        var draft = ThingsTodoDraft(title: r.title, notes: fields.notes, when: due, placement: placement,
                                    tagIds: tags + fields.tagIds.filter { !tags.contains($0) }, checklist: fields.checklist)
        var fp = fingerprint(forNewThingsFrom: r, group: group, fields: fields)
        fp.stuckSection = plan.fingerprint.stuckSection
        var mode = RepeatLinkMode.reminderRepeats
        if let rule = r.recurrence, ThingsRepeat.rr(for: rule, start: due.day) != nil {
            draft.recurrence = rule
            fp.rule = rule
            mode = .template
        }
        let id = try await things.createTodo(draft)
        store.detachedThingsIds.insert(task.id)
        report.createdInThings += 1
        log(.change, mode == .template ? "Created repeating Things to-do \"\(r.title)\" for the reminder's repeat rule"
                                       : "Created Things to-do \"\(r.title)\" for the next occurrence")
        return (id, fp, mode)
    }

    /// A `.reminderRepeats` pair whose reminder already moved on while the Things to-do for the new day is missing
    /// (`awaitingReplacement`): creates it now. The reminder is not completed again.
    func finishReplacement(_ link: LinkRecord, reminder: ReminderItem, task: ThingsTask, mapping: ListMapping) async {
        do {
            if task.status == .open { try await things.updateTodo(id: task.id, patch: ThingsTodoPatch(completed: true)) }
            var updated = link
            if let fresh = try await replacePlainTodo(link: link, task: task, plan: MergePlan(fingerprint: link.fingerprint),
                                                      mapping: mapping, reminder: reminder) {
                updated.thingsId = fresh.id; updated.fingerprint = fresh.fingerprint; updated.repeatMode = fresh.mode
            } else {
                updated.fingerprint.due = reminder.due
                updated.fingerprint.completed = true
            }
            updated.awaitingReplacement = false
            updated.mappingId = mapping.id
            updated.lastSynced = Date()
            replace(updated)
        } catch {
            fail("Could not create the next Things to-do for \"\(reminder.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: A plain pair that became repeating in Things

    /// The repeating template that took over from a plain linked to-do: the to-do's own template when Things turned it
    /// into the first occurrence, or (when Things removed it because the first date is in the future) the only new,
    /// unlinked template with the same title in the list's target. Nil unless its rule can be written to Reminders.
    func successorTemplate(for link: LinkRecord, task: ThingsTask?, mapping: ListMapping) -> ThingsTask? {
        let taken = Set(store.links.map(\.thingsId))
        func usable(_ t: ThingsTask) -> Bool {
            t.isTemplate && !t.trashed && thingsScope[t.id] != nil && !taken.contains(t.id)
                && !store.detachedThingsIds.contains(t.id) && templateSyncs(t)
        }
        if let task, !task.trashed {
            guard let tid = task.templateId, let template = snapshot.tasks[tid], usable(template) else { return nil }
            return template
        }
        let title = link.fingerprint.title.lowercased()
        let hits = snapshot.tasks.values.filter {
            usable($0) && thingsScope[$0.id] == mapping.id && Fingerprint.normalize($0.title).lowercased() == title
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Moves a plain pair onto the template: the reminder gets the rule (and the template's next day), and the link
    /// points at the template. Without this the pair was dropped and the template got a second reminder.
    func convertToTemplatePair(_ link: LinkRecord, reminder: ReminderItem, template: ThingsTask) async {
        guard let rule = template.recurrence, let due = templateDue(template) else { return }
        var patch = ReminderPatch(recurrence: .some(rule))
        if reminder.due != due { patch.due = .some(due) }
        do {
            let r = try await reminders.update(id: reminder.id, patch: patch)
            var updated = link
            updated.reminderId = r.id; updated.reminderExternalId = r.externalId ?? link.reminderExternalId
            updated.thingsId = template.id
            updated.repeatMode = .template
            updated.fingerprint.rule = rule
            updated.fingerprint.due = r.due ?? due
            updated.fingerprint.completed = false; updated.fingerprint.completionDay = nil
            updated.lastSynced = Date()
            replace(updated)
            report.updatedInReminders += 1
            log(.change, "\"\(template.title)\" now repeats in Things; its reminder repeats the same way")
        } catch {
            fail("Could not make reminder \"\(reminder.title)\" repeat: \(error.localizedDescription)")
        }
    }

    // MARK: A template pair that stopped repeating

    /// Stops the template of a pair whose reminder no longer repeats (`ThingsBackend.stopRepeating`, the shape Things'
    /// own Stop wrote) and moves the link to a plain to-do. Returns the link and that to-do as it now is, so the pass
    /// goes on to merge the pair as a plain one, and the reminder's fields reach the to-do as ordinary changes from
    /// Reminders.
    ///
    /// With no open occurrence the link moves to the plain to-do the Stop commit made for the template's next day.
    /// With one, the link moves to that occurrence, which the commit detached (it is the item the person was looking
    /// at), and the new next-day to-do goes to the Trash with an ordinary update, so Things does not show the item
    /// twice. With several, the occurrence on the reminder's due day is kept when exactly one is, else the earliest;
    /// the others stay in Things as plain to-dos, unlinked, and sync as new items on the next pass.
    func stopTemplate(_ link: LinkRecord, template t: ThingsTask, reminder: ReminderItem) async throws -> (LinkRecord, ThingsTask) {
        guard let day = t.nextDay else { throw ThingsCloudError.invalidChange(["\"\(t.title)\" has no next day"]) }
        let open = openOccurrences(of: t.id)
        let mappingId = thingsScope[t.id]
        let stopped = try await things.stopRepeating(templateId: t.id)
        let id = stopped.todoId

        var plain = t
        plain.id = id
        plain.isRepeating = false; plain.recurrence = nil; plain.instanceDay = nil; plain.instancesCreated = nil
        plain.start = .someday; plain.startDate = day; plain.reminderSeconds = nil
        // The Stop commit made each checklist item again on the new to-do, under a new id.
        plain.checklist = t.checklist.compactMap { item in
            stopped.checklistIds[item.id].map { ThingsChecklistItem(id: $0, title: item.title, completed: item.completed, index: item.index) }
        }
        plain.creationDate = Date(); plain.modificationDate = nil; plain.fieldModified = nil
        snapshot.tasks[t.id] = nil
        snapshot.tasks[id] = plain
        thingsScope[t.id] = nil
        for o in open {
            snapshot.tasks[o.id]?.templateId = nil
            snapshot.tasks[o.id]?.isRepeating = false
        }

        var updated = link
        updated.repeatMode = nil
        updated.fingerprint.rule = nil
        updated.fingerprint.completed = false; updated.fingerprint.completionDay = nil
        updated.lastSynced = Date()
        report.updatedInThings += 1

        let onDueDay = open.filter { $0.startDate != nil && $0.startDate == reminder.due?.day }
        guard let pick = onDueDay.count == 1 ? onDueDay[0] : open.first, let kept = snapshot.tasks[pick.id] else {
            // What the new to-do holds: the template's next day with no time, and the template's checklist (so the
            // agreed checklist items stay agreed).
            thingsScope[id] = mappingId
            updated.thingsId = id
            updated.fingerprint.due = DueDate(day: day)
            replace(updated)
            log(.change, "Stopped the repeat of Things to-do \"\(t.title)\": its reminder no longer repeats")
            return (updated, plain)
        }

        // The link is saved on the occurrence before the trash write, so a failure there cannot leave it on the
        // deleted template. The fingerprint holds the occurrence's own title and date: where the reminder differs,
        // that is a change from Reminders. The occurrence has a checklist of its own, so no items are agreed yet:
        // the merge adds what either side lacks and removes nothing.
        thingsScope[kept.id] = mappingId
        updated.fingerprint.checklist = nil
        updated.thingsId = kept.id
        updated.fingerprint.title = Fingerprint.normalize(kept.title)
        updated.fingerprint.due = kept.due
        replace(updated)
        do {
            try await things.updateTodo(id: id, patch: ThingsTodoPatch(trashed: true))
            snapshot.tasks[id]?.trashed = true
        } catch {
            // Still in Things, and never copied to Reminders: that would be the duplicate this avoids.
            store.detachedThingsIds.insert(id)
            fail("Stopped the repeat of \"\(t.title)\" but could not trash the extra to-do Things made for \(day): \(error.localizedDescription)")
        }
        let others = open.count - 1
        log(.change, "Stopped the repeat of Things to-do \"\(t.title)\": its reminder no longer repeats and is linked to the open to-do"
            + (kept.startDate.map { " for \($0)" } ?? "")
            + (others > 0 ? "; \(others) other open to-do\(others == 1 ? "" : "s") of the repeat stay\(others == 1 ? "s" : "") in Things, not linked to it" : ""))
        return (updated, kept)
    }

    /// The plain to-do Things kept when a linked template was stopped there: the only open, unlinked, non-repeating
    /// to-do in the list's target with the same title whose `tir` and start day are the next day the template had
    /// when it was deleted. Nil when the template was not deleted for good, or nothing (or more than one item) fits.
    func stoppedSuccessor(for link: LinkRecord, mapping: ListMapping) -> ThingsTask? {
        guard let day = snapshot.removedTemplates[link.thingsId] else { return nil }
        let taken = Set(store.links.map(\.thingsId))
        let title = link.fingerprint.title.lowercased()
        let hits = snapshot.tasks.values.filter {
            $0.kind == .todo && !$0.trashed && !$0.isRepeating && $0.status == .open && $0.nextDay == day && $0.startDate == day
                && thingsScope[$0.id] == mapping.id && !taken.contains($0.id) && !store.detachedThingsIds.contains($0.id)
                && Fingerprint.normalize($0.title).lowercased() == title
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// A template stopped in Things: the reminder's repeat is cleared (`remctl edit --recurrence clear`), it takes the
    /// plain to-do's date, and the link moves to that to-do. Title, notes and the rest merge on the next pass.
    func continueStoppedPair(_ link: LinkRecord, reminder: ReminderItem, task plain: ThingsTask) async {
        var patch = ReminderPatch()
        if reminder.isRepeating { patch.recurrence = .some(nil) }
        if reminder.due != plain.due { patch.due = .some(plain.due) }
        do {
            var r = reminder
            if !patch.isEmpty {
                r = try await reminders.update(id: reminder.id, patch: patch)
                report.updatedInReminders += 1
            }
            var updated = link
            updated.reminderId = r.id; updated.reminderExternalId = r.externalId ?? link.reminderExternalId
            updated.thingsId = plain.id
            updated.repeatMode = nil
            updated.fingerprint.rule = nil
            updated.fingerprint.due = r.due
            updated.fingerprint.completed = false; updated.fingerprint.completionDay = nil
            // Things made the template's checklist items again on this to-do (docs/RECURRENCE.md), so the agreed
            // items still hold and the next pass merges the checklist as usual.
            updated.lastSynced = Date()
            replace(updated)
            log(.change, "\"\(plain.title)\" stopped repeating in Things; its reminder no longer repeats")
        } catch {
            fail("Could not remove the repeat from \"\(reminder.title)\": \(error.localizedDescription)")
        }
    }

    /// Deleting a repeating template also trashes its open occurrences (they would otherwise be left behind).
    func trashTemplateOccurrences(of id: String) async throws {
        guard snapshot.tasks[id]?.isTemplate == true else { return }
        for o in openOccurrences(of: id) {
            try await things.updateTodo(id: o.id, patch: ThingsTodoPatch(trashed: true))
        }
    }
}
