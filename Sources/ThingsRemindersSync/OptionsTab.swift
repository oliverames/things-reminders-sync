import ServiceManagement
import SwiftUI
import SyncCore

struct OptionsTab: View {
    let coordinator: SyncCoordinator
    @State private var draft = SyncConfig()
    @State private var saving = false
    /// Counts of completed copies, set while the user decides what to do with them (turning the toggle off).
    @State private var completedCopies: CompletedCopiesPreview?

    /// Only the option fields; list mappings are edited on the Lists tab.
    private static func options(_ c: SyncConfig) -> [String] {
        ["\(c.pollSeconds)", "\(c.remindersPollSeconds)", "\(c.reconcileMinutes)",
         "\(c.includeCompletedOnFirstLink)", "\(c.propagateDeletes)", "\(c.syncChecklists)",
         "\(c.createMissingTags)", c.flaggedTagTitle, c.priorityTag ?? ""]
    }
    private var isDirty: Bool { Self.options(draft) != Self.options(coordinator.config) }

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: $draft.pollSeconds, in: 10...300, step: 5) {
                    LabeledContent("Check Things every", value: "\(draft.pollSeconds) seconds")
                }
                .accessibilityLabel("Check Things every")
                .accessibilityValue("\(draft.pollSeconds) seconds")
                Stepper(value: $draft.remindersPollSeconds, in: 5...120, step: 5) {
                    LabeledContent("Check Reminders every", value: "\(draft.remindersPollSeconds) seconds")
                }
                .accessibilityLabel("Check Reminders every")
                .accessibilityValue("\(draft.remindersPollSeconds) seconds")
                Stepper(value: $draft.reconcileMinutes, in: 5...120, step: 5) {
                    LabeledContent("Full reconcile every", value: "\(draft.reconcileMinutes) minutes")
                }
                .accessibilityLabel("Full reconcile every")
                .accessibilityValue("\(draft.reconcileMinutes) minutes")
            }
            Section("Behavior") {
                Toggle("Include completed items on first link", isOn: $draft.includeCompletedOnFirstLink)
                Toggle("Propagate deletes", isOn: $draft.propagateDeletes)
                Text("Deleting a reminder moves its Things item to the Trash, and deleting a Things item deletes the reminder. Nothing is permanently deleted in Things.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Sync checklists", isOn: $draft.syncChecklists)
                Text("A to-do's checklist and its reminder's subtasks are kept in step. A list can override this in its options.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Tags") {
                let tags = coordinator.thingsTags.map(\.title)
                TagPicker(label: "Flagged reminders get the tag",
                          selection: Binding(get: { draft.effectiveFlaggedTag }, set: { draft.flaggedTagTitle = $0 ?? "" }),
                          known: tags, excluded: draft.effectivePriorityTag)
                Text("A flagged reminder's to-do carries this tag, and the tag flags the reminder. With None, flags are not synced.")
                    .font(.callout).foregroundStyle(.secondary)
                TagPicker(label: "High priority reminders get the tag",
                          selection: Binding(get: { draft.effectivePriorityTag }, set: { draft.priorityTag = $0 }),
                          known: tags, excluded: draft.effectiveFlaggedTag)
                if draft.priorityTagClashesWithFlag {
                    Text("The priority tag is the same as the flag tag, so it is ignored. Choose a different tag.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("A high priority reminder's to-do carries this tag, and the tag sets high priority. It cannot be the flag tag.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Create missing tags", isOn: $draft.createMissingTags)
                Text("A reminder tag that Things does not have is created there, and removed again once nothing uses it. When off, such tags stay in Reminders only.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("General") {
                LoginItemRow()
            }
            if isDirty {
                Section {
                    HStack {
                        Label("Unsaved changes", systemImage: "pencil.circle").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revert") { draft = coordinator.config }.disabled(saving)
                            .accessibilityLabel("Revert option changes")
                        Button(saving ? "Saving…" : "Save", action: save).buttonStyle(.borderedProminent).disabled(saving)
                            .accessibilityLabel(saving ? "Saving options" : "Save options")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Completed copies", isPresented: Binding(get: { completedCopies != nil }, set: { if !$0 { completedCopies = nil } }),
                            titleVisibility: .visible, presenting: completedCopies) { preview in
            Button("Keep Them") { save(removingCompletedCopies: false) }
            Button("Remove \(preview.count) completed cop\(preview.count == 1 ? "y" : "ies")", role: .destructive) {
                save(removingCompletedCopies: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Completed to-dos and reminders this app copied over on first link can be removed. Things copies go to the Trash and reminders to Recently Deleted. Items that existed on both sides are kept.")
        }
        .onAppear { draft = coordinator.config }
        .onChange(of: coordinator.config) { old, new in
            // Follow outside changes, but never discard edits the user has not saved yet.
            if Self.options(draft) == Self.options(old) { draft = new }
        }
    }

    private func save() {
        if coordinator.config.includeCompletedOnFirstLink && !draft.includeCompletedOnFirstLink {
            let preview = coordinator.completedCopiesPreview()
            if preview.count > 0 { completedCopies = preview; return }
        }
        save(removingCompletedCopies: false)
    }

    private func save(removingCompletedCopies: Bool) {
        var merged = coordinator.config
        merged.pollSeconds = draft.pollSeconds
        merged.remindersPollSeconds = draft.remindersPollSeconds
        merged.reconcileMinutes = draft.reconcileMinutes
        merged.includeCompletedOnFirstLink = draft.includeCompletedOnFirstLink
        merged.propagateDeletes = draft.propagateDeletes
        merged.syncChecklists = draft.syncChecklists
        merged.flaggedTagTitle = draft.flaggedTagTitle
        merged.priorityTag = draft.priorityTag
        merged.createMissingTags = draft.createMissingTags
        saving = true
        Task {
            await coordinator.updateConfig(merged)
            if removingCompletedCopies { await coordinator.removeCompletedCopies() }
            saving = false
        }
    }
}

private struct LoginItemRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorText: String?

    private var isOn: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    errorText = nil
                } catch {
                    errorText = error.localizedDescription
                }
                status = SMAppService.mainApp.status
            }
        )
    }

    var body: some View {
        Toggle("Open at Login", isOn: isOn)
        switch status {
        case .requiresApproval:
            Text("Approval needed in System Settings > General > Login Items.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                .accessibilityLabel("Open Login Items Settings")
        case .notFound:
            Text("Login item unavailable. Run the app from the built bundle in /Applications.")
                .font(.callout).foregroundStyle(.secondary)
        case .enabled:
            Text("Enabled").font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
        if let errorText {
            Text(errorText).font(.callout).foregroundStyle(.red)
        }
    }
}

#Preview {
    OptionsTab(coordinator: SyncCoordinator())
        .frame(width: 560, height: 420)
}
