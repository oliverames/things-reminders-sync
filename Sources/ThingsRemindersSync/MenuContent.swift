import SwiftUI
import SyncCore

struct MenuContent: View {
    let coordinator: SyncCoordinator

    private var isPaused: Bool { coordinator.phase == .paused }
    private var canSync: Bool {
        switch coordinator.phase {
        case .needsSetup, .syncing, .paused: false
        default: true
        }
    }

    var body: some View {
        Text(coordinator.phase.statusText)
        if let last = coordinator.lastSync {
            Text("Last synced \(last, format: .relative(presentation: .named))")
        } else {
            Text("Not synced yet")
        }

        let held = coordinator.heldDeletions
        if !held.isEmpty {
            Divider()
            ForEach(held) { item in
                Text(item.summary)
                Button(held.count == 1 ? "Apply Deletions…" : "Apply Deletions in \(item.listTitle)…") {
                    HeldDeletionsPrompt.confirmAndApply(item, coordinator: coordinator)
                }
                .accessibilityLabel("Apply deletions in \(item.listTitle)")
                .disabled(!canSync)
            }
        }

        Divider()

        Button("Sync Now") { Task { await coordinator.syncNow() } }
            .keyboardShortcut("r")
            .disabled(!canSync)
        Button(isPaused ? "Resume" : "Pause") {
            if isPaused { coordinator.resume() } else { coordinator.pause() }
        }
        .disabled(coordinator.phase == .needsSetup)

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Things Reminders Sync") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
