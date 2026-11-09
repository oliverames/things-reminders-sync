import Foundation

/// JSON persistence under `~/Library/Application Support/ThingsRemindersSync/`, written atomically.
public struct StateStore: Sendable {
    public static let logLimit = 500
    public let directory: URL

    public init(directory: URL = StateStore.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThingsRemindersSync", isDirectory: true)
    }

    public func loadConfig() -> SyncConfig { load(SyncConfig.self, "config.json") ?? SyncConfig() }
    public func saveConfig(_ config: SyncConfig) throws { try save(config, "config.json") }

    public func loadLinks() -> LinkStore { load(LinkStore.self, "links.json") ?? LinkStore() }
    public func saveLinks(_ links: LinkStore) throws { try save(links, "links.json") }

    /// Newest entry first.
    public func loadLog() -> [SyncLogEntry] { load([SyncLogEntry].self, "log.json") ?? [] }
    public func saveLog(_ log: [SyncLogEntry]) throws { try save(Array(log.prefix(Self.logLimit)), "log.json") }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
