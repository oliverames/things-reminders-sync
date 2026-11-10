import AppKit
import SwiftUI
import SyncCore

/// The confirmation for deletions the safety limit is holding in one list. Used by the menu and the Lists tab.
@MainActor
enum HeldDeletionsPrompt {
    /// Shows the count and titles. Returns true when the user chose to apply; "Not Now" leaves them held.
    static func confirm(_ held: HeldDeletions) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Apply \(held.count) \(held.count == 1 ? "deletion" : "deletions") in “\(held.listTitle)”?"
        alert.informativeText = held.confirmationMessage
        let apply = alert.addButton(withTitle: "Apply Deletions")
        apply.hasDestructiveAction = true
        apply.keyEquivalent = ""   // Return must not delete: Not Now is the default
        apply.setAccessibilityLabel("Apply \(held.count) deletions in \(held.listTitle)")
        let notNow = alert.addButton(withTitle: "Not Now")
        notNow.keyEquivalent = "\r"
        notNow.setAccessibilityLabel("Not now, keep the deletions in \(held.listTitle) held")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmAndApply(_ held: HeldDeletions, coordinator: SyncCoordinator) {
        guard confirm(held) else { return }
        Task { await coordinator.applyHeldDeletions(listId: held.mappingId) }
    }
}

/// The notice in a list's row of the Lists tab.
struct HeldDeletionsNotice: View {
    let held: HeldDeletions
    let coordinator: SyncCoordinator

    var body: some View {
        LabeledContent {
            Button("Apply Deletions…") { HeldDeletionsPrompt.confirmAndApply(held, coordinator: coordinator) }
                .accessibilityLabel("Apply deletions in \(held.listTitle)")
                .help("Review the held deletions in \(held.listTitle), then apply them or leave them held")
        } label: {
            Label(held.summary, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(held.detail). Held by the safety limit.")
        }
        .accessibilityElement(children: .contain)
    }
}
