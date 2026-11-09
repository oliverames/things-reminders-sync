import SwiftUI
import SyncCore

struct SettingsView: View {
    let coordinator: SyncCoordinator

    var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") { AccountTab(coordinator: coordinator) }
            Tab("Lists", systemImage: "list.bullet") { ListsTab(coordinator: coordinator) }
            Tab("Options", systemImage: "gearshape") { OptionsTab(coordinator: coordinator) }
            Tab("Activity", systemImage: "clock.arrow.circlepath") { ActivityTab(coordinator: coordinator) }
        }
        .scenePadding()
        .frame(width: 560, height: 480)
        .onAppear { NSApplication.shared.activate() }
    }
}

#Preview {
    SettingsView(coordinator: SyncCoordinator())
}
