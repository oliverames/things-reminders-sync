import ServiceManagement
import SwiftUI
import SyncCore

struct OptionsTab: View {
    let coordinator: SyncCoordinator
    @State private var draft = SyncConfig()
    @State private var loaded = false
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: $draft.pollSeconds, in: 10...300, step: 5) {
                    LabeledContent("Check Things every", value: "\(draft.pollSeconds) seconds")
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
        }
        .formStyle(.grouped)
        .onAppear { draft = coordinator.config; loaded = true }
        .onChange(of: draft) { _, new in scheduleCommit(new) }
        .onChange(of: coordinator.config) { _, new in
            // Pick up outside changes (such as list edits) without echoing them back.
            if new != draft { loaded = false; draft = new; loaded = true }
        }
    }

    /// Debounced so holding a stepper does not start a sync per tick.
    private func scheduleCommit(_ new: SyncConfig) {
        guard loaded, new != coordinator.config else { return }
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            var merged = coordinator.config
            merged.pollSeconds = new.pollSeconds
            merged.reconcileMinutes = new.reconcileMinutes
            merged.includeCompletedOnFirstLink = new.includeCompletedOnFirstLink
            merged.propagateDeletes = new.propagateDeletes
            await coordinator.updateConfig(merged)
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
