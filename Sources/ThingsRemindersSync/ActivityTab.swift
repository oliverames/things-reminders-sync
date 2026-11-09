import SwiftUI
import SyncCore

struct ActivityTab: View {
    let coordinator: SyncCoordinator
    /// "Clear" only hides older entries in this view; the coordinator's log is untouched.
    @State private var clearedBefore: Date?

    private var entries: [SyncLogEntry] {
        coordinator.log.filter { entry in clearedBefore.map { entry.date > $0 } ?? true }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 8) {
            if entries.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock",
                                       description: Text("Sync events and problems appear here."))
            } else {
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.level.symbol).foregroundStyle(entry.level.color).frame(width: 18)
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.message).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Copy") { copy() }.disabled(entries.isEmpty)
                Button("Clear View") { clearedBefore = Date() }.disabled(entries.isEmpty)
            }
        }
    }

    private func copy() {
        let text = entries.map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension SyncLogEntry.Level {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .change: "arrow.left.arrow.right.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
    var color: Color {
        switch self {
        case .info: .secondary
        case .change: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

#Preview {
    ActivityTab(coordinator: SyncCoordinator())
        .frame(width: 560, height: 420)
}
