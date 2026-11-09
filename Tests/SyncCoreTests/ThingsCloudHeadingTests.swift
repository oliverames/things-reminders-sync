import Foundation
import Testing
@testable import SyncCore

@Suite("Things client headings") struct ThingsCloudHeadingTests {
    @Test func createHeadingPayloadShape() async throws {
        let project = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project)], head: 3)
        let id = try await cloud.client().createHeading(title: "Groceries", projectId: project)
        #expect(ThingsID.isValid(id))
        let change = try #require(try cloud.commitBody()[id]?.object)
        #expect(change["t"] == 0 && change["e"] == "Task6")
        let p = try #require(change["p"]?.object)
        #expect(p["tt"] == "Groceries" && p["tp"] == 2)
        #expect(p["pr"] == .array([.string(project)]) && p["agr"] == [] && p["ar"] == [])
        // Anytime, open, not trashed.
        #expect(p["st"] == 1 && p["sr"] == .null && p["ss"] == 0 && p["tr"] == false)
    }

    @Test func headingPlacementKeysAndDecoding() async throws {
        let heading = ThingsID.generate()
        let project = ThingsID.generate()
        let moved = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(moved, ["tt": "x", "tp": 0, "pr": .array([.string(project)])]),
                                            taskItem(heading, ["tt": "H", "tp": 2, "pr": .array([.string(project)])]),
                                            projectItem(project)])
        let client = cloud.client()
        let id = try await client.createTodo(ThingsTodoDraft(title: "In heading", placement: .heading(heading)))
        let p = try #require(try cloud.commitBody()[id]?["p"]?.object)
        #expect(p["agr"] == .array([.string(heading)]) && p["pr"] == [] && p["ar"] == [])

        // Moving an existing to-do into a heading clears project and area; decoding exposes headingId.
        try await client.updateTodo(id: moved, patch: ThingsTodoPatch(placement: .heading(heading)))
        let update = try #require(try cloud.commitBody(cloud.commits.count - 1)[moved]?["p"]?.object)
        #expect(update["agr"] == .array([.string(heading)]) && update["pr"] == [] && update["ar"] == [])
        let snapshot = try await client.refresh().snapshot
        #expect(snapshot.tasks[heading]?.kind == .heading && snapshot.tasks[heading]?.projectId == project)
        #expect(snapshot.headings.map(\.id) == [heading])
        #expect(snapshot.tasks[moved]?.headingId == heading)
    }
}
