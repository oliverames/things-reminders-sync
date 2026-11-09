import Foundation
import AppKit
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
        case needsSetup          // no Things credentials yet, or RemCTL is not ready
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
    /// RemCTL status for the UI: "Ready via RemCTL 2.5.0", or the reason it is unavailable.
    public private(set) var remindersDetail: String = "Not checked yet"
    public private(set) var lastSync: Date?
    public private(set) var log: [SyncLogEntry] = []
    public private(set) var reminderLists: [ReminderList] = []
    public private(set) var thingsProjects: [ThingsTask] = []
    public private(set) var thingsAreas: [ThingsArea] = []
    public private(set) var thingsTags: [ThingsTag] = []
    /// Number of linked item pairs per Reminders list id.
    public private(set) var linkedCounts: [String: Int] = [:]
    public private(set) var config: SyncConfig = SyncConfig()

    // MARK: Dependencies (internal so tests and previews can supply fakes)

    struct Dependencies {
        var stateStore: StateStore
        var credentials: any CredentialStore
        var reminders: any RemindersBackend
        /// The RemCTL backend when `reminders` is one; settings (path, poll interval, watched lists) are pushed to it.
        var remctl: RemCTLReminders?
        var makeThings: @Sendable (_ email: String, _ password: String) -> any ThingsBackend
        var verifyThings: @Sendable (_ email: String, _ password: String) async throws -> String
        /// Tests turn the timers, the Reminders stream, and the wake observer off.
        var runsObservers = true

        static func live() -> Dependencies {
            let remctl = RemCTLReminders()
            return Dependencies(
                stateStore: StateStore(), credentials: Keychain(), reminders: remctl, remctl: remctl,
                makeThings: { ThingsCloudClient(email: $0, password: $1, timeZone: .current) },
                verifyThings: { try await ThingsCloudClient.verify(email: $0, password: $1) })
        }
    }

    /// Work waiting for the serialized pass loop. Triggers arriving while a pass runs merge into one.
    private struct PendingWork {
        var full = false
        var force = false
        var pollThings = false
        var remindersChanged = false
        var thingsIds: Set<String> = []
        var isEmpty: Bool { !full && !pollThings && !remindersChanged && thingsIds.isEmpty }
        mutating func merge(_ o: PendingWork) {
            full = full || o.full; force = force || o.force; pollThings = pollThings || o.pollThings
            remindersChanged = remindersChanged || o.remindersChanged; thingsIds.formUnion(o.thingsIds)
        }
    }

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var thingsBackend: (any ThingsBackend)?
    @ObservationIgnored private var links = LinkStore()
    @ObservationIgnored private var pending = PendingWork()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var userPaused = false
    /// Set when the deletion safety limit held deletions back; cleared by a forced (Sync Now) pass.
    @ObservationIgnored private var safetyHold = false

    public init() { deps = .live() }

    init(dependencies: Dependencies) { deps = dependencies }

    // MARK: Public API

    /// Loads saved config and credentials, then starts observers and timers if setup is complete.
    public func start() async {
        config = deps.stateStore.loadConfig()
        links = deps.stateStore.loadLinks()
        log = deps.stateStore.loadLog()
        await applyRemindersConfig()
        linkedCounts = links.countsByMapping
        if let creds = try? deps.credentials.loadAccount() {
            thingsBackend = deps.makeThings(creds.email, creds.password)
            thingsAccount = .signedIn(email: creds.email)
        }
        remindersAccess = await deps.reminders.access()
        await refreshRemindersDetail()
        refreshPhase()
        await reloadCatalog()
        startObserversIfReady()
        await request(PendingWork(full: true))
    }

    /// Verifies Things Cloud credentials, stores them in the Keychain, and loads the Things database.
    public func signIn(email: String, password: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await deps.verifyThings(email, password)
        if case .signedIn(let old) = thingsAccount, old != email { try? deps.credentials.delete(email: old) }
        try deps.credentials.save(email: email, password: password)
        thingsBackend = deps.makeThings(email, password)
        thingsAccount = .signedIn(email: email)
        refreshPhase()
        await reloadCatalog()
        startObserversIfReady()
        await request(PendingWork(full: true))
    }

    /// Forgets the Things credentials and stops syncing. Links are kept so re-signing in resumes cleanly.
    public func signOut() {
        if case .signedIn(let email) = thingsAccount { try? deps.credentials.delete(email: email) }
        thingsBackend = nil
        thingsAccount = .signedOut
        thingsProjects = []; thingsAreas = []; thingsTags = []
        stopObservers()
        refreshPhase()
    }

    /// Re-checks RemCTL (there is nothing to prompt for) and resumes syncing when it is ready.
    public func requestRemindersAccess() async {
        await applyRemindersConfig()
        if let granted = try? await deps.reminders.requestAccess() { remindersAccess = granted }
        else { remindersAccess = await deps.reminders.access() }
        await refreshRemindersDetail()
        refreshPhase()
        await reloadCatalog()
        startObserversIfReady()
        await request(PendingWork(full: true))
    }

    /// Replaces the configuration, persists it, and runs a sync. New mappings are linked on this run.
    public func updateConfig(_ config: SyncConfig) async {
        let pathChanged = config.remctlPath != self.config.remctlPath
        self.config = config
        await applyRemindersConfig()
        let ids = Set(config.mappings.map(\.id))
        links.links.removeAll { !ids.contains($0.mappingId) }
        links.linkedMappings = links.linkedMappings.filter { ids.contains($0.key) }
        linkedCounts = links.countsByMapping
        persist()
        if pathChanged {
            await requestRemindersAccess()   // a new RemCTL path may fix (or break) readiness
            return
        }
        if !observerTasks.isEmpty { stopObservers(); startObserversIfReady() }
        await request(PendingWork(full: true))
    }

    /// Runs a full two-way reconcile now. After a held deletion batch this also applies the deletions.
    public func syncNow() async {
        await request(PendingWork(full: true, force: safetyHold))
    }

    public func pause() {
        userPaused = true
        stopObservers()
        phase = .paused
    }

    public func resume() {
        userPaused = false
        refreshPhase()
        startObserversIfReady()
        Task { await request(PendingWork(full: true)) }
    }

    /// Reloads Reminders lists and Things projects/areas/tags for the pickers.
    public func reloadCatalog() async {
        if remindersAccess == .granted, let lists = try? await deps.reminders.lists() { reminderLists = lists }
        if let things = thingsBackend, let result = try? await things.refresh() { applyCatalog(result.snapshot) }
    }

    // MARK: State

    /// Pushes the RemCTL path, poll interval, and the enabled lists to the backend.
    private func applyRemindersConfig() async {
        guard let remctl = deps.remctl else { return }
        await remctl.configure(executablePath: config.remctlPath, pollSeconds: config.remindersPollSeconds)
        await remctl.setWatchedLists(config.mappings.filter(\.enabled).map(\.id))
    }

    private func refreshRemindersDetail() async {
        if let remctl = deps.remctl { remindersDetail = await remctl.statusDetail() }
        else { remindersDetail = remindersAccess == .granted ? "Ready" : "Reminders unavailable" }
    }

    private var canSync: Bool { thingsBackend != nil && remindersAccess == .granted && !userPaused }

    private func refreshPhase() {
        if userPaused { phase = .paused; return }
        guard thingsBackend != nil, remindersAccess == .granted else { phase = .needsSetup; return }
        if phase == .needsSetup || phase == .paused { phase = .idle }
    }

    private func applyCatalog(_ snapshot: ThingsSnapshot) {
        thingsProjects = snapshot.projects.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        thingsAreas = snapshot.areas.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        thingsTags = snapshot.tags.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func persist() {
        try? deps.stateStore.saveConfig(config)
        try? deps.stateStore.saveLinks(links)
        try? deps.stateStore.saveLog(log)
    }

    private func append(_ entries: [SyncLogEntry]) {
        log = Array((entries.reversed() + log).prefix(StateStore.logLimit))
    }

    // MARK: Observers and timers

    private func startObserversIfReady() {
        guard deps.runsObservers, canSync, observerTasks.isEmpty else { return }
        let reminders = deps.reminders

        // Things: poll the history head; a targeted sync follows only when something changed.
        observerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let seconds = max(5, self?.config.pollSeconds ?? 15)
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self?.request(PendingWork(pollThings: true))
            }
        })
        // Reminders: RemCTL export poll.
        let stream = reminders.changes()
        observerTasks.append(Task { [weak self] in
            for await _ in stream {
                if Task.isCancelled { return }
                await self?.request(PendingWork(remindersChanged: true))
            }
        })
        // Full reconcile on an interval.
        observerTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let minutes = max(1, self?.config.reconcileMinutes ?? 10)
                try? await Task.sleep(for: .seconds(minutes * 60))
                if Task.isCancelled { return }
                await self?.request(PendingWork(full: true))
            }
        })
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))   // let the network come back
                    await self?.request(PendingWork(full: true))
                }
            }
        }
    }

    private func stopObservers() {
        observerTasks.forEach { $0.cancel() }
        observerTasks = []
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: Serialized passes

    /// Queues work and runs it. Never two passes at once; triggers that arrive meanwhile coalesce and
    /// their callers wait for the same drain loop.
    private func request(_ work: PendingWork) async {
        guard canSync else { return }
        pending.merge(work)
        if running {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        while !pending.isEmpty, canSync {
            let next = pending
            pending = PendingWork()
            await execute(next)
        }
        running = false
        let ready = waiters
        waiters = []
        ready.forEach { $0.resume() }
    }

    private func execute(_ work: PendingWork) async {
        guard let things = thingsBackend else { return }
        do {
            var scope: SyncScope
            var ids = work.thingsIds
            var full = work.full
            if work.pollThings && !full {
                let result = try await things.refresh()
                if result.fullReload { full = true } else { ids.formUnion(result.changedTaskIds) }
            }
            if full { scope = .full }
            else if ids.isEmpty && !work.remindersChanged { return }
            else { scope = .targeted(thingsIds: ids, remindersChanged: work.remindersChanged) }

            phase = .syncing
            let engine = SyncEngine(things: things, reminders: deps.reminders)
            let startedWith = config
            let report = try await engine.sync(config: startedWith, links: links, scope: scope, forceDeletions: work.force)
            apply(report, startedWith: startedWith, forced: work.force)
        } catch {
            let message = error.localizedDescription
            if phase != .error(message) { append([SyncLogEntry(level: .error, message: "Sync failed: \(message)")]) }
            phase = userPaused ? .paused : .error(message)
            persist()
        }
    }

    /// Copies target ids the engine created into the live config, but only where the user has not
    /// since changed that mapping's target. Everything else in `current` wins.
    static func mergeEngineConfig(current: SyncConfig, startedWith: SyncConfig, engine: SyncConfig) -> SyncConfig {
        var merged = current
        for created in engine.mappings {
            guard let newId = created.targetId,
                  let before = startedWith.mappings.first(where: { $0.id == created.id }), before.targetId == nil,
                  let i = merged.mappings.firstIndex(where: { $0.id == created.id }),
                  merged.mappings[i].targetId == nil, merged.mappings[i].mode == before.mode,
                  merged.mappings[i].targetTitle == before.targetTitle
            else { continue }
            merged.mappings[i].targetId = newId
        }
        return merged
    }

    /// Drops links (and first-link markers) for mappings removed from the live config mid-pass.
    static func pruneLinks(_ store: LinkStore, to config: SyncConfig) -> LinkStore {
        let ids = Set(config.mappings.map(\.id))
        var pruned = store
        pruned.links.removeAll { !ids.contains($0.mappingId) }
        pruned.linkedMappings = pruned.linkedMappings.filter { ids.contains($0.key) }
        return pruned
    }

    private func apply(_ report: SyncReport, startedWith: SyncConfig, forced: Bool) {
        // The user may have edited settings while the pass ran; keep those edits and take only what
        // the engine adds (ids of targets it created). updateConfig already queued the next pass.
        let configChanged = config != startedWith
        config = Self.mergeEngineConfig(current: config, startedWith: startedWith, engine: report.config)
        links = Self.pruneLinks(report.links, to: config)
        if configChanged { persist() }
        linkedCounts = links.countsByMapping
        append(report.log)
        reminderLists = report.reminderLists
        Task { await applyRemindersConfig() }
        applyCatalog(report.snapshot)
        lastSync = Date()
        if forced { safetyHold = false }
        if report.deletionsHeld { safetyHold = true }
        persist()
        if userPaused { phase = .paused }
        else if let failure = report.firstFailure { phase = .error(failure) }
        else if safetyHold { phase = .error("Deletions held back by the safety limit. Choose Sync Now to apply them.") }
        else { phase = .idle }
    }
}
