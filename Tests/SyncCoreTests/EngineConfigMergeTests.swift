import Testing
@testable import SyncCore

// Regression: toggling several lists while a pass ran turned them back off, because the pass wrote
// its own (stale) copy of the config back over the user's edits.
@MainActor @Test func editsMadeDuringAPassSurviveIt() throws {
    let a = ListMapping(id: "A", listTitle: "A", enabled: true, targetTitle: "A")
    let started = SyncConfig(mappings: [a])
    // While the pass runs, the user enables B and C and changes the poll interval.
    var current = started
    current.mappings += [ListMapping(id: "B", listTitle: "B", enabled: true, targetTitle: "B"),
                         ListMapping(id: "C", listTitle: "C", enabled: true, targetTitle: "C")]
    current.pollSeconds = 30
    // The engine created A's project and wrote its id back into its copy.
    var engine = started
    engine.mappings[0].targetId = "PROJECT_A"

    let merged = SyncCoordinator.mergeEngineConfig(current: current, startedWith: started, engine: engine)
    #expect(merged.mappings.map(\.id) == ["A", "B", "C"])
    #expect(merged.mappings.allSatisfy { $0.enabled })
    #expect(merged.mappings[0].targetId == "PROJECT_A")
    #expect(merged.pollSeconds == 30)
}

@MainActor @Test func engineTargetIdDoesNotOverrideAUserRetarget() throws {
    let started = SyncConfig(mappings: [ListMapping(id: "A", listTitle: "A", targetTitle: "A")])
    var current = started
    current.mappings[0].targetId = "USER_PICK"
    var engine = started
    engine.mappings[0].targetId = "ENGINE_CREATED"
    #expect(SyncCoordinator.mergeEngineConfig(current: current, startedWith: started, engine: engine).mappings[0].targetId == "USER_PICK")
}

@MainActor @Test func linksForMappingsRemovedMidPassArePruned() throws {
    let store = LinkStore(links: [], linkedMappings: ["A": "project:x", "GONE": "project:y"])
    let pruned = SyncCoordinator.pruneLinks(store, to: SyncConfig(mappings: [ListMapping(id: "A", listTitle: "A", targetTitle: "A")]))
    #expect(pruned.linkedMappings.keys.sorted() == ["A"])
}
