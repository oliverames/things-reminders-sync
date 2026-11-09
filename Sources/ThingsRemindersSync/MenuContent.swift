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
