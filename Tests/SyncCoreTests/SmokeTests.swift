import Foundation
import Testing
@testable import SyncCore

@Test func sharedTypesRoundTrip() throws {
    let config = SyncConfig(mappings: [ListMapping(id: "L1", listTitle: "Family", targetTitle: "Family")])
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(SyncConfig.self, from: data) == config)
}
