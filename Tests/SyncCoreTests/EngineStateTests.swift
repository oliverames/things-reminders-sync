import Foundation
import Testing
@testable import SyncCore

@Test func stateStoreRoundTripsAndCapsLog() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = StateStore(directory: dir)
    #expect(store.loadConfig() == SyncConfig())
    let config = SyncConfig(mappings: [ListMapping(id: "L", listTitle: "L", targetTitle: "T")], pollSeconds: 30)
    try store.saveConfig(config)
    #expect(store.loadConfig() == config)
    var links = LinkStore()
    links.links.append(LinkRecord(reminderId: "r", thingsId: "t", mappingId: "L",
                                  fingerprint: Fingerprint(title: "A", notes: "", due: DueDate(day: "2026-01-02", minutes: 60), completed: false, completionDay: nil)))
    links.linkedMappings["L"] = "project:P"
    try store.saveLinks(links)
    #expect(store.loadLinks().links.first?.fingerprint == links.links.first?.fingerprint)
    #expect(store.loadLinks().linkedMappings == ["L": "project:P"])
    try store.saveLog((0..<700).map { SyncLogEntry(level: .info, message: "m\($0)") })
    #expect(store.loadLog().count == StateStore.logLimit)
}

@Test func thingsDueMappingHelpers() {
    let t = ThingsTask(id: "t", title: "x", startDate: "2026-03-04", reminderSeconds: 9 * 3600 + 900)
    #expect(t.due == DueDate(day: "2026-03-04", minutes: 555))
    #expect(DueDate(day: "2026-03-04", minutes: 555).reminderSeconds == 33_300)
    #expect(DueDate(day: "2026-03-04").reminderSeconds == nil)
    #expect(ThingsTask(id: "u", title: "y").due == nil)
}
