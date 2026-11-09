import ServiceManagement
import SwiftUI
import SyncCore

struct OptionsTab: View {
    let coordinator: SyncCoordinator
    @State private var draft = SyncConfig()
    @State private var saving = false

    /// Only the option fields; list mappings are edited on the Lists tab.
    private static func options(_ c: SyncConfig) -> [Int] {
        [c.pollSeconds, c.remindersPollSeconds, c.reconcileMinutes,
         c.includeCompletedOnFirstLink ? 1 : 0, c.propagateDeletes ? 1 : 0]
    }
    private var isDirty: Bool { Self.options(draft) != Self.options(coordinator.config) }

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: $draft.pollSeconds, in: 10...300, step: 5) {
                    LabeledContent("Check Things every", value: "\(draft.pollSeconds) seconds")
                }
                Stepper(value: $draft.remindersPollSeconds, in: 5...120, step: 5) {
                    LabeledContent("Check Reminders every", value: "\(draft.remindersPollSeconds) seconds")
                }
                Stepper(value: $draft.reconcileMinutes, in: 5...120, step: 5) {
                    LabeledContent("Full reconcile every", value: "\(draft.reconcileMinutes) minutes")
                }
            }
            Section("Behavior") {
                Toggle("Include completed items on first link", isOn: $draft.includeCompletedOnFirstLink)
                Toggle("Propagate deletes", isOn: $draft.propagateDeletes)
                Text("Deleting a reminder moves its Things item to the Trash, and deleting a Things item deletes the reminder. Nothing is permanently deleted in Things.")
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
                        Button(saving ? "Saving…" : "Save", action: save).buttonStyle(.borderedProminent).disabled(saving)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = coordinator.config }
        .onChange(of: coordinator.config) { old, new in
            // Follow outside changes, but never discard edits the user has not saved yet.
            if Self.options(draft) == Self.options(old) { draft = new }
        }
    }

    private func save() {
        var merged = coordinator.config
        merged.pollSeconds = draft.pollSeconds
        merged.remindersPollSeconds = draft.remindersPollSeconds
        merged.reconcileMinutes = draft.reconcileMinutes
        merged.includeCompletedOnFirstLink = draft.includeCompletedOnFirstLink
        merged.propagateDeletes = draft.propagateDeletes
        saving = true
        Task { await coordinator.updateConfig(merged); saving = false }
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
