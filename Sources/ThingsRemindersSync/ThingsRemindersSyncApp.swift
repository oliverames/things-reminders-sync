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
            Image(systemName: coordinator.phase.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

extension SyncCoordinator.Phase {
    var menuBarSymbol: String {
        switch self {
        case .needsSetup: "arrow.triangle.2.circlepath.circle"
        case .idle: "arrow.triangle.2.circlepath"
        case .syncing: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle"
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
