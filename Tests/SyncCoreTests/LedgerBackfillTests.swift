import Foundation
import Testing
@testable import SyncCore

// One-time inference of the ownership ledger from the activity log (synthetic data only).

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(_ message: String, at date: Date) -> SyncLogEntry { SyncLogEntry(date: date, level: .change, message: message) }

private func link(_ title: String, mapping: String = "L1", thing: String? = nil, reminder: String? = nil) -> LinkRecord {
    LinkRecord(reminderId: reminder ?? "r-\(title)", reminderExternalId: "x-\(reminder ?? title)", thingsId: thing ?? "t-\(title)", mappingId: mapping,
               fingerprint: Fingerprint(title: title, notes: "", due: nil, completed: false, completionDay: nil))
}

private func defaultConfig() -> SyncConfig {
    SyncConfig(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PA", targetTitle: "Alpha"),
                          ListMapping(id: "L2", listTitle: "Beta", mode: .project, targetId: "PB", targetTitle: "Beta")])
}

private func infer(_ log: [SyncLogEntry], links: [LinkRecord], snapshot: ThingsSnapshot = ThingsSnapshot(),
                   reminders: [ReminderItem] = [], config: SyncConfig? = nil) -> LedgerBackfill.Result {
    LedgerBackfill.infer(log: log, store: LinkStore(links: links), config: config ?? defaultConfig(), snapshot: snapshot, reminders: reminders)
}

@Test func createdEntriesMarkCopiesAndLinkedEntriesStayOriginals() {
    let links = [link("Made from reminder"), link("Made from todo"), link("Paired"), link("No log entry")]
    let log = [
        entry("Created Things to-do \"Made from reminder\" from list \"Alpha\"", at: t0),
        entry("Created reminder \"made from TODO\" in \"alpha\"", at: t0),            // case-insensitive
        entry("Linked \"Paired\" in \"Alpha\" with its Things to-do", at: t0),
    ]
    let r = infer(log, links: links)
    let by = Dictionary(uniqueKeysWithValues: r.store.links.map { ($0.fingerprint.title, $0) })
    #expect(by["Made from reminder"]?.copySide == .things)
    #expect(by["Made from todo"]?.copySide == .reminders)
    #expect(by["Paired"]?.copySide == nil && by["No log entry"]?.copySide == nil)
    #expect(r.copiesInThings == 1 && r.copiesInReminders == 1 && r.pairedOriginals == 1)
}

@Test func copyMatchesOnlyItsOwnList() {
    let r = infer([entry("Created reminder \"Same\" in \"Beta\"", at: t0)], links: [link("Same", mapping: "L1")])
    #expect(r.store.links[0].copySide == nil)
}

@Test func ambiguousTitlesAreLeftAsOriginals() {
    // Two links share a title but the log shows one creation: which one is unknown.
    let two = infer([entry("Created reminder \"Dup\" in \"Alpha\"", at: t0)], links: [link("Dup", thing: "ta", reminder: "ra"), link("Dup", thing: "tb", reminder: "rb")])
    #expect(two.store.links.allSatisfy { $0.copySide == nil })
    // Mixed history for two links: undecidable.
    let mixed = infer([entry("Created reminder \"Dup\" in \"Alpha\"", at: t0), entry("Created Things to-do \"Dup\" from list \"Alpha\"", at: t0)],
                      links: [link("Dup", thing: "ta", reminder: "ra"), link("Dup", thing: "tb", reminder: "rb")])
    #expect(mixed.store.links.allSatisfy { $0.copySide == nil })
}

@Test func theSnapshotBreaksTiesAndRejectsLookalikes() {
    // One link, created-reminder at t0 and created-todo at t0+1h: the to-do's creation date says which event is its own.
    let log = [entry("Created reminder \"X\" in \"Alpha\"", at: t0), entry("Created Things to-do \"X\" from list \"Alpha\"", at: t0.addingTimeInterval(3600))]
    var snap = ThingsSnapshot()
    snap.tasks["t-X"] = ThingsTask(id: "t-X", title: "X", creationDate: t0.addingTimeInterval(-86400))   // existed long before: not created by the app
    #expect(infer(log, links: [link("X")], snapshot: snap).store.links[0].copySide == .reminders)
    snap.tasks["t-X"]?.creationDate = t0.addingTimeInterval(3600)                                       // born with the second entry
    #expect(infer(log, links: [link("X")], snapshot: snap).store.links[0].copySide == .things)
    // A single "created to-do" entry whose title match is a to-do that predates it: not a copy.
    let single = [entry("Created Things to-do \"X\" from list \"Alpha\"", at: t0)]
    snap.tasks["t-X"]?.creationDate = t0.addingTimeInterval(-86400)
    #expect(infer(single, links: [link("X")], snapshot: snap).store.links[0].copySide == nil)
}

@Test func completedCopiesAreThoseCompletedBeforeTheAppMadeThem() {
    let doneBefore = t0.addingTimeInterval(-86400), doneAfter = t0.addingTimeInterval(3600)
    var snap = ThingsSnapshot()
    snap.tasks["t-A"] = ThingsTask(id: "t-A", title: "A", status: .completed, stopDate: doneBefore)   // Things copy completed earlier
    snap.tasks["t-B"] = ThingsTask(id: "t-B", title: "B", status: .completed, stopDate: doneAfter)    // finished after creation
    snap.tasks["t-C"] = ThingsTask(id: "t-C", title: "C", status: .completed, stopDate: nil)          // no time: cannot tell
    snap.tasks["t-D"] = ThingsTask(id: "t-D", title: "D", status: .completed, stopDate: doneBefore)
    let reminders = [ReminderItem(id: "r-D", externalId: "x-r-D", listId: "L1", title: "D", completed: true, completionDate: doneBefore)]
    let log = ["A", "B", "C"].map { entry("Created Things to-do \"\($0)\" from list \"Alpha\"", at: t0) }
        + [entry("Created reminder \"D\" in \"Alpha\"", at: t0)]
    let r = infer(log, links: ["A", "B", "C", "D"].map { link($0) }, snapshot: snap, reminders: reminders)
    let by = Dictionary(uniqueKeysWithValues: r.store.links.map { ($0.fingerprint.title, $0) })
    #expect(by["A"]?.copiedCompleted == true && by["D"]?.copiedCompleted == true)
    #expect(by["B"]?.copiedCompleted == false && by["C"]?.copiedCompleted == false)
    #expect(r.completedCopies == 2)
}

@Test func parkedLinksAreInferredToo() {
    var store = LinkStore()
    store.parkedLinks = [link("P")]
    let r = LedgerBackfill.infer(log: [entry("Created reminder \"P\" in \"Alpha\"", at: t0)], store: store, config: defaultConfig(), snapshot: ThingsSnapshot(), reminders: [])
    #expect(r.store.parkedLinks[0].copySide == .reminders)
}

@Test func containersAreRecordedWhenTheMatchIsUnique() {
    var snap = ThingsSnapshot()
    snap.tasks["PN"] = ThingsTask(id: "PN", kind: .project, title: "Gamma", creationDate: t0)
    snap.areas["AN"] = ThingsArea(id: "AN", title: "Delta")
    let log = [entry("Created Things project \"Gamma\" for list \"Alpha\"", at: t0), entry("Created Things area \"Delta\" for list \"Beta\"", at: t0)]
    let r = infer(log, links: [], snapshot: snap)
    #expect(Set(r.store.ownedThings.map(\.id)) == ["PN", "AN"])
    #expect(r.store.ownedThings.first { $0.id == "PN" }?.mappingId == "L1" && r.store.ownedThings.first { $0.id == "PN" }?.kind == .project)
    #expect(r.containersRecorded == 2)
}

@Test func sameTitledContainersAreRecordedOnlyWhenEmptyOrReferenced() {
    let log = [entry("Created Things project \"Gamma\" for list \"Alpha\"", at: t0)]
    // Both candidates look right by time. One holds a to-do: only the empty one is recorded.
    var snap = ThingsSnapshot()
    snap.tasks["P1"] = ThingsTask(id: "P1", kind: .project, title: "Gamma", creationDate: t0)
    snap.tasks["P2"] = ThingsTask(id: "P2", kind: .project, title: "Gamma", creationDate: t0)
    snap.tasks["t"] = ThingsTask(id: "t", title: "x", projectId: "P1")
    #expect(infer(log, links: [], snapshot: snap).store.ownedThings.map(\.id) == ["P2"])
    // Both empty, none referenced: unsure, so nothing.
    snap.tasks["t"] = nil
    #expect(infer(log, links: [], snapshot: snap).store.ownedThings.isEmpty)
    // Both non-empty, one referenced by the config: that one.
    snap.tasks["t1"] = ThingsTask(id: "t1", title: "x", projectId: "P1")
    snap.tasks["t2"] = ThingsTask(id: "t2", title: "y", projectId: "P2")
    var c = defaultConfig(); c.mappings[0].targetId = "P2"
    #expect(infer(log, links: [], snapshot: snap, config: c).store.ownedThings.map(\.id) == ["P2"])
    // Both non-empty, none referenced: nothing.
    #expect(infer(log, links: [], snapshot: snap).store.ownedThings.isEmpty)
}

@Test func aSameTitledContainerCreatedAtAnotherTimeIsNotRecorded() {
    var snap = ThingsSnapshot()
    snap.tasks["P1"] = ThingsTask(id: "P1", kind: .project, title: "Gamma", creationDate: t0.addingTimeInterval(-86400 * 30))   // the user's
    let r = infer([entry("Created Things project \"Gamma\" for list \"Alpha\"", at: t0)], links: [], snapshot: snap)
    #expect(r.store.ownedThings.isEmpty)
}

@Test func sectionHeadingsAreRecordedThroughTheirProject() {
    var snap = ThingsSnapshot()
    snap.tasks["PA"] = ThingsTask(id: "PA", kind: .project, title: "Alpha")
    snap.tasks["H1"] = ThingsTask(id: "H1", kind: .heading, title: "Errands", projectId: "PA", creationDate: t0)
    snap.tasks["H2"] = ThingsTask(id: "H2", kind: .heading, title: "Errands", projectId: "PB", creationDate: t0)
    let r = infer([entry("Created Things heading \"Errands\" in \"Alpha\"", at: t0)], links: [], snapshot: snap)
    #expect(r.store.ownedThings.map(\.id) == ["H1"] && r.store.ownedThings[0].mappingId == "L1")
}

@Test func recordedContainersAreNotDuplicated() {
    var snap = ThingsSnapshot()
    snap.areas["AN"] = ThingsArea(id: "AN", title: "Delta")
    var store = LinkStore()
    store.ownedThings = [OwnedThingsContainer(id: "AN", kind: .area, mappingId: "L2", title: "Delta")]
    let r = LedgerBackfill.infer(log: [entry("Created Things area \"Delta\" for list \"Beta\"", at: t0)], store: store, config: defaultConfig(), snapshot: snap, reminders: [])
    #expect(r.store.ownedThings.count == 1 && r.containersRecorded == 0)
}

// MARK: Through the engine

@Test func theEngineBackfillsOnceOnAFullPassAndSetsTheFlag() async throws {
    var w = World(mappings: [ListMapping(id: "L1", listTitle: "Alpha", mode: .project, targetId: "PX", targetTitle: "Alpha")])
    await w.things.add(projectTask("PX"))
    await w.reminders.add(reminder("r1", "L1", "Old copy"))
    try await w.sync()
    // Simulate a link made before this version: no copy side recorded.
    w.links.links[0].copySide = nil
    let log = [entry("Created Things to-do \"Old copy\" from list \"Alpha\"", at: Date())]
    let engine = SyncEngine(things: w.things, reminders: w.reminders)
    let r = try await engine.sync(config: w.config, links: w.links, scope: .full, backfillLog: log)
    #expect(r.links.links[0].copySide == .things && r.links.ledgerBackfilled)
    // A targeted pass does not backfill, and without a log nothing is marked done.
    let t = try await engine.sync(config: w.config, links: w.links, scope: .targeted(thingsIds: [], remindersChanged: true), backfillLog: log)
    #expect(t.links.ledgerBackfilled == false && t.links.links[0].copySide == nil)
    let n = try await engine.sync(config: w.config, links: w.links, scope: .full)
    #expect(n.links.ledgerBackfilled == false)
}
