// Maintenance tool for Things Reminders Sync. Runs the app's own engine operations (the ones behind
// the Settings confirmation dialogs) against the app's saved state. Quit the app first: both write
// the same state files. Credentials come from the environment, never from the app's Keychain item.
//
//   THINGS_EMAIL=... THINGS_PASSWORD=... trs-admin remove-completed-copies
//   THINGS_EMAIL=... THINGS_PASSWORD=... trs-admin teardown <listId> [--remove-copies] [--remove-mapping]
//   THINGS_EMAIL=... THINGS_PASSWORD=... trs-admin dry-run   (one full pass; prints the writes it would make, saves nothing)
import Foundation
import SyncCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: trs-admin remove-completed-copies | teardown <listId> [--remove-copies] [--remove-mapping] | dry-run") }
let env = ProcessInfo.processInfo.environment
guard let email = env["THINGS_EMAIL"], let password = env["THINGS_PASSWORD"] else { fail("Set THINGS_EMAIL and THINGS_PASSWORD.") }

let store = StateStore()
let config = store.loadConfig()
let links = store.loadLinks()
guard links.ledgerBackfilled else { fail("The ledger has not been backfilled yet; let the app run one full sync first.") }
let remindersPath = config.remctlPath
let engine = SyncEngine(things: ThingsCloudClient(email: email, password: password),
                        reminders: RemCTLReminders(executablePath: remindersPath))

if command == "dry-run" {
    try await runDryRun(config: config, links: links, things: ThingsCloudClient(email: email, password: password),
                        reminders: RemCTLReminders(executablePath: remindersPath))
    exit(0)
}

let report: TeardownReport
switch command {
case "remove-completed-copies":
    report = try await engine.removeCompletedCopies(config: config, links: links)
case "teardown":
    guard args.count >= 2 else { fail("teardown needs a list id") }
    let listId = args[1]
    guard config.mappings.contains(where: { $0.id == listId }) else { fail("No mapping for list \(listId).") }
    report = try await engine.teardown(config: config, links: links, listId: listId,
                                       removeCopies: args.contains("--remove-copies"),
                                       removeMapping: args.contains("--remove-mapping"))
default:
    fail("unknown command \(command)")
}

for entry in report.log { print("[\(entry.level.rawValue)] \(entry.message)") }
print("things trashed: \(report.thingsTrashed), reminders deleted: \(report.remindersDeleted), containers removed: \(report.containersRemoved), sections removed: \(report.sectionsRemoved), failures: \(report.failures)")
try store.saveConfig(report.config)
try store.saveLinks(report.links)
try store.saveLog(report.log.reversed() + store.loadLog())
if !report.completed { fail("Not complete: \(report.firstFailure ?? "unknown failure"). Links were kept; run it again.") }
