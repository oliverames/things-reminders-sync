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
    func templateExtras(link: LinkRecord, reminder r: ReminderItem, task t: ThingsTask, plan: inout MergePlan) {
        let baseFP = link.fingerprint
        let base = baseFP.due
        let rDue = r.due
        let occurrences = openOccurrences(of: t.id)
        // The Things due is the open occurrence's when there is one, else the template's next day.
        let laterDue = laterSide(r.modified(.due), occurrences.first?.modified(.due) ?? t.modified(.due))
        var fp = plan.fingerprint

        if r.completed {
            // The reminder finished for good (its last occurrence): finish the open occurrence for its day.
            if !baseFP.completed {
                if let day = base?.day ?? rDue?.day, let o = occurrences.first(where: { $0.startDate == day }) ?? occurrences.first {
                    plan.occurrenceWrites.append((o.id, ThingsTodoPatch(completed: true)))
                }
                fp.completed = true
            }
        } else if let base, !baseFP.completed {
            let reminderMoved = rDue != base
            if !reminderMoved, completedOccurrence(of: t.id, on: base.day) != nil {
                // Things completed the occurrence: the reminder advances itself. Never pass a completion date.
                plan.reminderPatch.completed = true
                plan.reminderAdvances = true
            } else {
                let observed = observedThingsDue(t)
                let thingsMoved = observed != nil && observed != base
                var side: Side?
                if reminderMoved && thingsMoved { side = laterDue } else if reminderMoved { side = .reminders } else if thingsMoved { side = .things }
                switch side {
                case .reminders:
                    if isAdvance(rule: r.recurrence ?? t.recurrence, base: base, to: rDue) {
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

        // Rule: only when both sides' rules are known shapes.
        if let rRule = r.recurrence, let tRule = t.recurrence {
            if let baseRule = baseFP.rule {
                if rRule.key != tRule.key {
                    let rChanged = rRule.key != baseRule.key, tChanged = tRule.key != baseRule.key
                    let side: Side = rChanged && !tChanged ? .reminders : tChanged && !rChanged ? .things : laterSide(.rule, r, t)
                    switch side {
                    case .reminders:
                        if ThingsRepeat.rr(for: rRule, start: rDue?.day ?? t.nextDay ?? "2026-01-01") != nil {
                            plan.thingsPatch.recurrence = rRule; fp.rule = rRule
                        } else {
                            log(.info, "\"\(t.title)\": the reminder's new repeat rule has no verified Things form; the Things rule was left as it is")
                            fp.rule = nil
                        }
                    case .things:
                        if RemCTLRecurrence.spec(for: tRule, due: rDue ?? templateDue(t)) != nil {
                            plan.reminderPatch.recurrence = .some(tRule); fp.rule = tRule
                        } else {
                            log(.info, "\"\(t.title)\": the new Things repeat rule cannot be written to Reminders; the reminder's rule was left as it is")
                            fp.rule = nil
                        }
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
        var plan = merge(base: nil, reminder: rEff, task: tEff, group: groupInput)
        plan.fingerprint.due = r.due; plan.fingerprint.completed = false; plan.fingerprint.completionDay = nil
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
        return (placement, tags)
    }

    /// A new repeating reminder: a Things template when the rule has a verified Things shape, otherwise a plain
    /// to-do for the current occurrence (`.reminderRepeats`), with one `.info` saying why.
    func createThingsForRepeating(from r: ReminderItem, mapping m: ListMapping) async {
        let group = sectionsActive(m) ? Fingerprint.cleanGroup(r.section) : nil
        do {
            let (placement, tags) = try await thingsPlacement(for: m, group: group)
            let fields = thingsFields(from: r)
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
                let id = try await things.createTodo(ThingsTodoDraft(title: r.title, notes: fields.notes, when: r.due, placement: placement,
                                                                     tagIds: allTags, checklist: fields.checklist))
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
        } catch {
            fail("Could not create reminder \"\(t.title)\": \(error.localizedDescription)")
        }
    }

    // MARK: `.reminderRepeats` pairs

    func reminderRepeatsPlan(link: LinkRecord, reminder r: ReminderItem, task t: ThingsTask, group: GroupInput?) -> MergePlan {
        var rEff = r
        var advance = false
        let base = link.fingerprint.due
        if !r.completed, t.status == .open, let base, r.due != base, isAdvance(rule: r.recurrence, base: base, to: r.due) {
            advance = true
            rEff.due = base   // the due change is the advance, not a reschedule
        }
        var plan = merge(base: link.fingerprint, reminder: rEff, task: t, group: group)
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
        let fields = thingsFields(from: r)
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

    /// Deleting a repeating template also trashes its open occurrences (they would otherwise be left behind).
    func trashTemplateOccurrences(of id: String) async throws {
        guard snapshot.tasks[id]?.isTemplate == true else { return }
        for o in openOccurrences(of: id) {
            try await things.updateTodo(id: o.id, patch: ThingsTodoPatch(trashed: true))
        }
    }
}
