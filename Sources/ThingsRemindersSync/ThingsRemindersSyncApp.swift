import SwiftUI
import SyncCore

@main
struct ThingsRemindersSyncApp: App {
    @State private var coordinator: SyncCoordinator

    init() {
        let coordinator = SyncCoordinator()
        _coordinator = State(initialValue: coordinator)
        Task { await coordinator.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: coordinator.phase.menuBarIconState))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

extension SyncCoordinator.Phase {
    var menuBarIconState: MenuBarIconState {
        switch self {
        case .needsSetup: .needsSetup
        case .idle: .idle
        case .syncing: .syncing
        case .paused: .paused
        case .error: .error
        }
    }


    var statusText: String {
        switch self {
        case .needsSetup: "Setup needed"
        case .idle: "Up to date"
        case .syncing: "Syncing…"
        case .paused: "Paused"
        case .error(let message): "Error: \(message)"
        }
    }
}
