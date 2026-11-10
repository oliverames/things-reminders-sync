import SwiftUI
import SyncCore

/// A picker over the existing Things tags. The engine needs the tag to exist, so there is no free text.
struct TagPicker: View {
    let label: String
    /// The chosen tag title, or nil for none.
    @Binding var selection: String?
    /// Titles of the tags Things has.
    let known: [String]
    var noneLabel = "None"
    /// A tag that cannot be chosen here, shown disabled.
    var excluded: String?

    var body: some View {
        let menu = TagMenu(known: known, current: selection)
        let current = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Picker(label, selection: Binding(get: { current }, set: { selection = $0.isEmpty ? nil : $0 })) {
            Text(noneLabel).tag("")
            if let missing = menu.missing { Text("\(missing) (not in Things)").tag(missing) }
            ForEach(menu.titles, id: \.self) { title in
                Text(title).tag(title).disabled(title == excluded && title != current)
            }
        }
    }
}

/// The preferences of one list. It edits the list row's draft, so the row's Save and Revert cover everything here.
struct ListOptionsSheet: View {
    let listTitle: String
    let mapping: ListMapping
    /// The saved global settings, for the "Use global setting" choices.
    let config: SyncConfig
    /// Titles of the tags Things has.
    let tags: [String]
    let edit: ((inout ListMapping) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var assignees: [AssigneeTagRow] = []

    private func reason(_ preference: ListPreference) -> String? {
        mapping.reasonIgnored(preference, deletesPropagate: config.propagateDeletes)
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    /// The reason a control is switched off, or its usual help line.
    private func help(_ text: String, unless preference: ListPreference) -> some View {
        help(reason(preference) ?? text)
    }

    private func overridePicker(_ label: String, value: Bool?, global: Bool,
                                set: @escaping (inout ListMapping, Bool?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { OverrideChoice(value) },
                                         set: { choice in edit { set(&$0, choice.value) } })) {
            Text("Use global setting (\(global ? "On" : "Off"))").tag(OverrideChoice.global)
            Text("On").tag(OverrideChoice.on)
            Text("Off").tag(OverrideChoice.off)
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        guard let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) else {
            return "\(hour):00"
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Options for \(listTitle)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Form {
                direction
                dates
                deletes
                tagsAndPeople
                sections
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Changes apply when you save the list.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Done with options for \(listTitle)")
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .navigationTitle("Options for \(listTitle)")
        .onAppear { assignees = AssigneeTagRow.rows(from: mapping.assigneeTags) }
        .onChange(of: assignees) { _, rows in
            let value = AssigneeTagRow.assigneeTags(from: rows)
            if value != mapping.assigneeTags { edit { $0.assigneeTags = value } }
        }
    }

    private var direction: some View {
        Section("Direction") {
            Picker("Sync", selection: Binding(get: { mapping.direction }, set: { value in edit { $0.direction = value } })) {
                Text("Two-way").tag(SyncDirection.twoWay)
                Text("Reminders to Things only").tag(SyncDirection.remindersToThings)
                Text("Things to Reminders only").tag(SyncDirection.thingsToReminders)
            }
            switch mapping.direction {
            case .twoWay:
                help("Changes on either side are copied to the other.")
            case .remindersToThings:
                help("The app never changes Reminders. New items and deletions come from Reminders only, and an edit you make in Things stays until the same field changes in Reminders.")
            case .thingsToReminders:
                help("The app never changes Things. New items and deletions come from Things only, and an edit you make in Reminders stays until the same field changes in Things.")
            }
        }
    }

    private var dates: some View {
        Section("Dates") {
            Picker("Due date becomes", selection: Binding(get: { mapping.dueMapsTo }, set: { value in edit { $0.dueMapsTo = value } })) {
                Text("When").tag(DueTarget.when)
                Text("Deadline").tag(DueTarget.deadline)
            }
            help("With Deadline, a reminder's due date is the to-do's deadline and its When is left alone. A due time stays in Reminders. Repeating items still use the When.")

            Picker("Reminders with no date arrive in", selection: Binding(get: { mapping.undatedArriveAs },
                                                                         set: { value in edit { $0.undatedArriveAs = value } })) {
                Text("Anytime").tag(UndatedArrival.anytime)
                Text("Someday").tag(UndatedArrival.someday)
                Text("Today").tag(UndatedArrival.today)
            }
            .disabled(reason(.undatedArriveAs) != nil)
            help("Used once, when the to-do is created. It never moves a to-do that already exists.", unless: .undatedArriveAs)

            Picker("This Evening from", selection: Binding(get: { mapping.eveningFromMinutes == nil ? -1 : (mapping.eveningFromHour ?? -1) },
                                                           set: { value in edit { $0.eveningFromHour = value < 0 ? nil : value } })) {
                Text("Off").tag(-1)
                ForEach(0..<24, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
            }
            .disabled(reason(.eveningFromHour) != nil)
            help("A reminder due today at or after this hour arrives in This Evening. A to-do you move back to Today stays there.",
                 unless: .eveningFromHour)

            Toggle("Sync Someday to-dos", isOn: Binding(get: { mapping.syncSomeday }, set: { value in edit { $0.syncSomeday = value } }))
            help("When off, a to-do in Someday has no reminder. Moving a linked to-do to Someday deletes its reminder, and the reminder is made again when the to-do leaves Someday.")
        }
    }

    private var deletes: some View {
        Section("Deletes and completed items") {
            overridePicker("Propagate deletes", value: mapping.propagateDeletes, global: config.propagateDeletes) { $0.propagateDeletes = $1 }
            help("Whether deleting an item on one side deletes its partner, for this list only.")

            Picker("A canceled to-do", selection: Binding(get: { mapping.canceledBecomes }, set: { value in edit { $0.canceledBecomes = value } })) {
                Text("Completes the reminder").tag(CanceledOutcome.completed)
                Text("Deletes the reminder").tag(CanceledOutcome.deleted)
            }
            .disabled(mapping.direction == .remindersToThings)
            help("What happens to the reminder when you cancel its to-do in Things. A to-do you complete always completes the reminder.",
                 unless: .canceledBecomes)

            overridePicker("Include completed items on first link", value: mapping.includeCompletedOnFirstLink,
                           global: config.includeCompletedOnFirstLink) { $0.includeCompletedOnFirstLink = $1 }
            help("Whether completed items come across when this list is first turned on.")

            overridePicker("Sync checklists", value: mapping.syncChecklists, global: config.syncChecklists) { $0.syncChecklists = $1 }
            help("Whether a to-do's checklist is kept in step with its reminder, for this list only.")
        }
    }

    private var tagsAndPeople: some View {
        Section("Tags and people") {
            TagPicker(label: "Tag every to-do with",
                      selection: Binding(get: { mapping.effectiveAlwaysTag }, set: { value in edit { $0.alwaysTag = value } }),
                      known: tags)
                .disabled(reason(.alwaysTag) != nil)
            help("The app adds this tag to every to-do linked through the list. It never removes it and never copies it to Reminders.",
                 unless: .alwaysTag)

            ForEach($assignees) { $row in
                HStack {
                    TextField("Person", text: $row.sharee, prompt: Text("Email, sharee id or me"))
                        .labelsHidden()
                        .accessibilityLabel("Person to assign in \(listTitle)")
                    TagPicker(label: "Tag for \(row.sharee.isEmpty ? "this person" : row.sharee)",
                              selection: Binding(get: { row.tag.isEmpty ? nil : row.tag }, set: { row.tag = $0 ?? "" }),
                              known: tags, noneLabel: "Choose a tag…")
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    Button {
                        assignees.removeAll { $0.id == row.id }
                    } label: {
                        Label("Remove \(row.sharee.isEmpty ? "this person" : row.sharee)", systemImage: "minus.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(row.sharee.isEmpty ? "this person" : row.sharee)")
                    .help("Remove this person")
                }
            }
            .disabled(reason(.assigneeTags) != nil)
            Button("Add Person…") { assignees.append(AssigneeTagRow()) }
                .accessibilityLabel("Add a person for \(listTitle)")
                .disabled(reason(.assigneeTags) != nil)
            help("Give a to-do a person's tag and its reminder is assigned to them. This works from Things to Reminders only, and only in a shared list. The app cannot list the people a list is shared with, so type the person's email address, sharee id or objectUUID, or \"me\" for yourself.",
                 unless: .assigneeTags)
        }
    }

    private var sections: some View {
        Section("Sections") {
            Toggle("Mirror sections as projects",
                   isOn: Binding(get: { mapping.sectionsAreProjects }, set: { value in edit { $0.sectionsAsProjects = value } }))
                .disabled(reason(.sectionsAsProjects) != nil)
            help("Each Reminders section becomes a Things project inside the area, and a reminder with no section sits loose in the area.",
                 unless: .sectionsAsProjects)
            switch mapping.mode {
            case .project: help("A list mirrored as a project syncs its sections as headings. That switch is on the list itself.")
            case .heading, .tag: help("A list mirrored as a \(mapping.mode.rawValue) syncs no sections.")
            case .area: EmptyView()
            }
        }
    }
}

#Preview {
    ListOptionsSheet(listTitle: "Home", mapping: ListMapping(id: "1", listTitle: "Home", targetTitle: "Home"),
                     config: SyncConfig(), tags: ["Errands", "Important"], edit: { _ in })
}
