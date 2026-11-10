import Foundation
import SyncCore

/// `trs-admin dry-run`: one full pass with writes printed instead of sent (SyncCore's `DryRun`). Nothing is saved.
func runDryRun(config: SyncConfig, links: LinkStore, log: [SyncLogEntry], things: any ThingsBackend, executablePath: String?) async throws {
    let result = try await DryRun.run(config: config, links: links, things: things,
                                      reminders: DryRun.remindersBackend(executablePath: executablePath),
                                      log: log, echo: { print($0) })
    let report = result.report
    print("read: \(report.reminders.count) reminders, \(report.snapshot.tasks.count) Things tasks, \(config.mappings.filter(\.enabled).count) enabled mappings, \(links.links.count) links")
    for entry in report.log { print("[\(entry.level.rawValue)] \(entry.message)") }
    for held in report.heldDeletions { print("HELD    \(held.summary): \(held.detail)") }
    print("DRY RUN: \(result.writes.count) planned writes; would create \(report.createdInThings) in Things, \(report.createdInReminders) in Reminders; update \(report.updatedInThings) / \(report.updatedInReminders); delete \(report.deletedInThings) / \(report.deletedInReminders); link \(report.linked); unlink \(report.unlinked); failures \(report.failures). Nothing was written or saved.")
}
