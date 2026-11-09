import Foundation
import Testing
@testable import SyncCore

@Suite struct RemCTLLedgerTests {
    private func backend(_ fake: FakeRemCTL) async -> RemCTLReminders {
        let b = makeBackend(fake)
        await b.setSectionLists(["1"])
        return b
    }

    @Test func onlySectionsTheBackendCreatedAreReported() async throws {
        let fake = FakeRemCTL()
        await fake.setSections(1, ["Errands"])
        let b = await backend(fake)
        _ = try await b.create(title: "A", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: "errands")   // existing
        #expect(await b.takeCreatedSections().isEmpty)
        _ = try await b.create(title: "B", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: "Later")
        _ = try await b.create(title: "C", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: "later")
        #expect(await b.takeCreatedSections() == [CreatedReminderSection(listId: "1", name: "Later")])
        #expect(await b.takeCreatedSections().isEmpty)                                       // drained
        let made = try await b.create(title: "D", notes: "", due: nil, completed: false, completionDate: nil, listId: "1", section: nil)
        _ = try await b.update(id: made.id, patch: ReminderPatch(section: .some("Fresh")))
        #expect(await b.takeCreatedSections() == [CreatedReminderSection(listId: "1", name: "Fresh")])
    }

    @Test func deleteSectionRunsTheCliAndToleratesAMissingSection() async throws {
        let fake = FakeRemCTL()
        await fake.setSections(1, ["Later"])
        let b = await backend(fake)
        try await b.deleteSection(name: "Later", listId: "1")
        #expect(await fake.cliCalls.last == ["section-delete", "Later", "--list-id", "1", "--force", "--private", "--json"])
        try await b.deleteSection(name: "Later", listId: "1")   // already gone: not an error
    }
}
