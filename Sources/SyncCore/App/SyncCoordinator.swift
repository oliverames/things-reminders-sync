import Foundation
import Observation

/// The app-facing facade: owns credentials, configuration, the backends, the engine, and the timers.
/// The UI reads its observable properties and calls its methods; nothing in the UI talks to a backend.
///
/// PUBLIC API IS A CONTRACT (docs/SPEC.md). The engine agent fills in the bodies; the UI agent only
/// consumes the API. Change the signatures only together with both.
@MainActor
@Observable
public final class SyncCoordinator {
    public enum Phase: Equatable, Sendable {
        case needsSetup          // no Things credentials yet, or no Reminders access
        case idle
        case syncing
        case paused
        case error(String)
    }

    public enum ThingsAccount: Equatable, Sendable {
        case signedOut
        case signedIn(email: String)
    }

    // Observable state for the UI.
    public private(set) var phase: Phase = .needsSetup
    public private(set) var thingsAccount: ThingsAccount = .signedOut
    public private(set) var remindersAccess: RemindersAccess = .notDetermined
    public private(set) var lastSync: Date?
    public private(set) var log: [SyncLogEntry] = []
    public private(set) var reminderLists: [ReminderList] = []
    public private(set) var thingsProjects: [ThingsTask] = []
    public private(set) var thingsAreas: [ThingsArea] = []
    public private(set) var thingsTags: [ThingsTag] = []
    /// Number of linked item pairs per Reminders list id.
    public private(set) var linkedCounts: [String: Int] = [:]
    public private(set) var config: SyncConfig = SyncConfig()

    public init() {}

    /// Loads saved config and credentials, then starts observers and timers if setup is complete.
    public func start() async {}

    /// Verifies Things Cloud credentials, stores them in the Keychain, and loads the Things database.
    public func signIn(email: String, password: String) async throws {}

    /// Forgets the Things credentials and stops syncing. Links are kept so re-signing in resumes cleanly.
    public func signOut() {}

    public func requestRemindersAccess() async {}

    /// Replaces the configuration, persists it, and runs a sync. New mappings are linked on this run.
    public func updateConfig(_ config: SyncConfig) async {}

    /// Runs a full two-way reconcile now.
    public func syncNow() async {}

    public func pause() {}
    public func resume() {}

    /// Reloads Reminders lists and Things projects/areas/tags for the pickers.
    public func reloadCatalog() async {}
}
