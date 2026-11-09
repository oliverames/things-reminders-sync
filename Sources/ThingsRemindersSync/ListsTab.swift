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
                    Label("Finish setup on the Account tab: sign in to Things Cloud and allow Reminders access.",
                          systemImage: "info.circle")
                }
            }
            if coordinator.reminderLists.isEmpty {
                Section {
                    Text("No Reminders lists found yet. Grant Reminders access, then reopen this tab.")
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

    private var mapping: ListMapping? { coordinator.config.mappings.first { $0.id == list.id } }
    private var current: ListMapping {
        mapping ?? ListMapping(id: list.id, listTitle: list.title, enabled: false, targetTitle: list.title)
    }

    private func edit(_ change: (inout ListMapping) -> Void) {
        var config = coordinator.config
        var updated = current
        updated.listTitle = list.title
        change(&updated)
        if let index = config.mappings.firstIndex(where: { $0.id == list.id }) {
            config.mappings[index] = updated
        } else {
            config.mappings.append(updated)
        }
        Task { await coordinator.updateConfig(config) }
    }

    private var targets: [(id: String, title: String)] {
        switch current.mode {
        case .project: coordinator.thingsProjects.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        case .area: coordinator.thingsAreas.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        case .tag: coordinator.thingsTags.map { ($0.id, $0.title) }.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        }
    }

    var body: some View {
        Toggle(isOn: Binding(get: { current.enabled }, set: { value in edit { $0.enabled = value } })) {
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
                edit { $0.mode = mode; $0.targetId = nil; $0.targetTitle = list.title; $0.projectAreaId = nil }
            })) {
                Text("Project").tag(MappingMode.project)
                Text("Area").tag(MappingMode.area)
                Text("Tag").tag(MappingMode.tag)
            }
            Picker(targetLabel, selection: Binding(get: { current.targetId ?? Self.newTag }, set: { value in
                edit { $0.targetId = value == Self.newTag ? nil : value }
            })) {
                ForEach(targets, id: \.id) { Text($0.title).tag($0.id) }
                Text("New…").tag(Self.newTag)
            }
            if current.targetId == nil {
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
