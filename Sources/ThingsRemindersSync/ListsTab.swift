import SwiftUI
import SyncCore

struct ListsTab: View {
    let coordinator: SyncCoordinator

    private var unavailable: [ListMapping] {
        let ids = Set(coordinator.reminderLists.map(\.id))
        return coordinator.config.mappings.filter { !ids.contains($0.id) }
    }

    var body: some View {
        Form {
            if coordinator.thingsAccount == .signedOut || coordinator.remindersAccess != .granted {
                Section {
                    Label("Finish setup on the Account tab: sign in to Things Cloud and make sure RemCTL is ready.",
                          systemImage: "info.circle")
                }
            }
            if coordinator.reminderLists.isEmpty {
                Section {
                    Text("No Reminders lists found yet. Check RemCTL on the Account tab, then reopen this tab.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Turn on a list to keep it in sync with a Things project, area, or tag.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(coordinator.reminderLists) { list in
                    Section { ListRow(coordinator: coordinator, list: list) }
                }
            }
            if !unavailable.isEmpty {
                Section("Unavailable lists") {
                    ForEach(unavailable) { mapping in
                        LabeledContent(mapping.listTitle, value: "Not found in Reminders")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await coordinator.reloadCatalog() }
    }
}

private struct ListRow: View {
    let coordinator: SyncCoordinator
    let list: ReminderList

    private static let newTag = "__new__"
    private static let chooseTag = "__choose__"
    @State private var creatingNew = false
    /// Unsaved edits. Nothing reaches the sync engine until Save.
    @State private var draft: ListMapping?
    /// The saved mapping the draft started from, for a field-wise merge on Save.
    @State private var draftBase: ListMapping?
    @State private var saving = false

    private var saved: ListMapping {
        coordinator.config.mappings.first { $0.id == list.id }
            ?? ListMapping(id: list.id, listTitle: list.title, enabled: false, targetTitle: list.title)
    }
    private var current: ListMapping { draft ?? saved }
    private var isDirty: Bool { draft != nil && draft != saved }

    private func edit(_ change: (inout ListMapping) -> Void) {
        if draft == nil { draft = saved; draftBase = saved }
        draft!.listTitle = list.title
        change(&draft!)
    }

    private func revert() { draft = nil; draftBase = nil; creatingNew = false }

    private func save() {
        guard var updated = draft else { return }
        let latest = saved
        // The app may have filled in a target id (a project it created) since the draft began;
        // keep it unless the user changed the target in this draft.
        if let base = draftBase, updated.targetId == base.targetId, updated.mode == base.mode,
           updated.awaitingTarget == base.awaitingTarget {
            updated.targetId = latest.targetId
        }
        var config = coordinator.config
        if let index = config.mappings.firstIndex(where: { $0.id == list.id }) {
            config.mappings[index] = updated
        } else {
            config.mappings.append(updated)
        }
        saving = true
        Task {
            await coordinator.updateConfig(config)
            saving = false
            revert()
        }
    }

    private var targets: [(id: String, title: String)] {
        switch current.mode {
        case .project: coordinator.thingsProjects.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        case .area: coordinator.thingsAreas.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        case .tag: coordinator.thingsTags.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        }
    }

    var body: some View {
        Toggle(isOn: Binding(get: { current.enabled }, set: { value in
            edit {
                $0.enabled = value
                // Turning a list on reuses an existing Things target with the list's name before creating one.
                if value, $0.targetId == nil, !$0.awaitingTarget, let match = existingTarget(named: list.title, mode: $0.mode) {
                    $0.targetId = match
                }
            }
        })) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: list.colorHex) ?? .gray).frame(width: 10, height: 10)
                Text(list.title)
                if let source = list.sourceTitle { Text(source).foregroundStyle(.secondary) }
            }
        }
        .disabled(!list.allowsModifications && !current.enabled)

        if !list.allowsModifications {
            Text("This list is read-only in Reminders.").font(.callout).foregroundStyle(.secondary)
        }

        if current.enabled {
            Picker("Mirror as", selection: Binding(get: { current.mode }, set: { mode in
                guard mode != current.mode else { return }
                creatingNew = false
                // Never create anything on a mode change: pick a same-named target if one exists,
                // otherwise pause the list until a target is chosen. Linked to-dos move on the next sync.
                let match = existingTarget(named: list.title, mode: mode)
                edit {
                    $0.mode = mode; $0.targetId = match; $0.targetTitle = list.title; $0.projectAreaId = nil
                    $0.awaitingTarget = match == nil
                }
            })) {
                Text("Project").tag(MappingMode.project)
                Text("Area").tag(MappingMode.area)
                Text("Tag").tag(MappingMode.tag)
            }
            Picker(targetLabel, selection: Binding(get: {
                if let id = current.targetId { return id }
                return current.awaitingTarget && !creatingNew ? Self.chooseTag : Self.newTag
            }, set: { value in
                switch value {
                case Self.chooseTag: return
                case Self.newTag: creatingNew = true; edit { $0.targetId = nil; $0.awaitingTarget = false }   // created on Save
                default: creatingNew = false; edit { $0.targetId = value; $0.awaitingTarget = false }
                }
            })) {
                if current.awaitingTarget && current.targetId == nil && !creatingNew { Text("Choose…").tag(Self.chooseTag) }
                ForEach(targets, id: \.id) { Text($0.title).tag($0.id) }
                Text("New…").tag(Self.newTag)
            }
            if current.awaitingTarget && current.targetId == nil && !creatingNew {
                Text("Syncing for this list is paused until you choose a Things \(current.mode.rawValue). Linked to-dos move there on the next sync.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if current.targetId == nil && (creatingNew || !current.awaitingTarget) {
                NewTargetFields(title: current.targetTitle, mode: current.mode, areaId: current.projectAreaId,
                                areas: coordinator.thingsAreas,
                                onTitle: { value in edit { $0.targetTitle = value } },
                                onArea: { value in edit { $0.projectAreaId = value } })
            }
            LabeledContent("Linked items", value: "\(coordinator.linkedCounts[list.id] ?? 0)")
            if current.mode == .tag {
                Text("New items from this list land in the Things Inbox with the tag.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        if isDirty {
            HStack {
                Label(saveSummary, systemImage: "pencil.circle").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Revert", action: revert).disabled(saving)
                Button(saving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.borderedProminent).disabled(saving)
            }
        }
    }

    private var saveSummary: String {
        guard let draft else { return "" }
        if !draft.enabled { return saved.enabled ? "Stops syncing this list" : "Unsaved changes" }
        if !saved.enabled { return draft.targetId == nil && !draft.awaitingTarget ? "Starts syncing; creates \"\(draft.targetTitle)\"" : "Starts syncing this list" }
        if draft.mode != saved.mode || draft.targetId != saved.targetId {
            return draft.awaitingTarget && draft.targetId == nil ? "Pauses until a target is chosen" : "Moves linked to-dos to the new target"
        }
        return "Unsaved changes"
    }

    private func existingTarget(named title: String, mode: MappingMode) -> String? {
        let wanted = title.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates: [(id: String, title: String)] = switch mode {
        case .project: coordinator.thingsProjects.map { ($0.id, $0.title) }
        case .area: coordinator.thingsAreas.map { ($0.id, $0.title) }
        case .tag: coordinator.thingsTags.map { ($0.id, $0.title) }
        }
        let hits = candidates.filter { $0.title.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        return hits.count == 1 ? hits[0].id : nil
    }

    private var targetLabel: String {
        switch current.mode {
        case .project: "Things project"
        case .area: "Things area"
        case .tag: "Things tag"
        }
    }
}

private struct NewTargetFields: View {
    let title: String
    let mode: MappingMode
    let areaId: String?
    let areas: [ThingsArea]
    let onTitle: (String) -> Void
    let onArea: (String?) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("New name", text: $draft)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onAppear { draft = title }
        if mode == .project {
            Picker("Area (optional)", selection: Binding(get: { areaId ?? "" }, set: { onArea($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(areas) { Text($0.title).tag($0.id) }
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != title else { return }
        onTitle(trimmed)
    }
}

extension Color {
    /// Parses `#RRGGBB`.
    init?(hex: String?) {
        guard var hex, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

#Preview {
    ListsTab(coordinator: SyncCoordinator())
        .frame(width: 560, height: 420)
}
