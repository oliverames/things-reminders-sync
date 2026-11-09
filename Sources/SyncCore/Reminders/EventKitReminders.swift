import EventKit
import Foundation

public struct EventKitRemindersError: LocalizedError {
    public var message: String
    public var errorDescription: String? { message }
}

/// `RemindersBackend` over one `EKEventStore`. The store is not Sendable, so every use of it happens
/// inside this actor; only plain value types cross the boundary.
public actor EventKitReminders: RemindersBackend {
    /// Only used for notification identity in `changes()`; never called from outside the actor.
    nonisolated(unsafe) private let store: EKEventStore

    public init() { store = EKEventStore() }

    // MARK: Access

    public func access() async -> RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func requestAccess() async throws -> RemindersAccess {
        _ = try await store.requestFullAccessToReminders()
        return await access()
    }

    // MARK: Reading

    public func lists() async throws -> [ReminderList] {
        store.calendars(for: .reminder).map { cal in
            ReminderList(id: cal.calendarIdentifier, title: cal.title, colorHex: Self.hex(cal.cgColor),
                         sourceTitle: cal.source?.title, allowsModifications: cal.allowsContentModifications)
        }
    }

    public func reminders(inLists listIds: [String]) async throws -> [ReminderItem] {
        let calendars = listIds.compactMap { store.calendar(withIdentifier: $0) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).map(Self.item))
            }
        }
    }

    // MARK: Writing

    public func create(title: String, notes: String, due: DueDate?, completed: Bool, completionDate: Date?, listId: String) async throws -> ReminderItem {
        guard let calendar = store.calendar(withIdentifier: listId) else {
            throw EventKitRemindersError(message: "Reminders list not found")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        Self.setDue(reminder, due)
        if completed {
            reminder.isCompleted = true
            if let completionDate { reminder.completionDate = completionDate }
        }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func update(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        guard let reminder = find(id) else { throw EventKitRemindersError(message: "Reminder not found") }
        if let title = patch.title { reminder.title = title }
        if let notes = patch.notes { reminder.notes = notes.isEmpty ? nil : notes }
        if let due = patch.due { Self.setDue(reminder, due) }
        if let completed = patch.completed {
            reminder.isCompleted = completed
            if completed, let date = patch.completionDate { reminder.completionDate = date }
        }
        if let listId = patch.listId {
            guard let calendar = store.calendar(withIdentifier: listId) else {
                throw EventKitRemindersError(message: "Reminders list not found")
            }
            reminder.calendar = calendar
        }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func delete(id: String) async throws {
        guard let reminder = find(id) else { return }
        try store.remove(reminder, commit: true)
    }

    // MARK: Changes

    public nonisolated func changes() -> AsyncStream<Void> {
        let store = self.store
        return AsyncStream { continuation in
            let debouncer = Debouncer(delay: 1.0) { continuation.yield() }
            let token = ObserverToken(NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: nil) { _ in debouncer.poke() })
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(token.value)
                debouncer.cancel()
            }
        }
    }

    // MARK: Helpers

    private func find(_ id: String) -> EKReminder? {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder { return r }
        return store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }.first
    }

    static func item(_ r: EKReminder) -> ReminderItem {
        ReminderItem(id: r.calendarItemIdentifier, externalId: r.calendarItemExternalIdentifier,
                     listId: r.calendar?.calendarIdentifier ?? "", title: r.title ?? "", notes: r.notes ?? "",
                     due: due(r.dueDateComponents), completed: r.isCompleted, completionDate: r.completionDate,
                     lastModified: r.lastModifiedDate, isRepeating: r.hasRecurrenceRules)
    }

    static func due(_ c: DateComponents?) -> DueDate? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        let day = String(format: "%04d-%02d-%02d", y, m, d)
        guard let h = c.hour else { return DueDate(day: day) }
        return DueDate(day: day, minutes: h * 60 + (c.minute ?? 0))
    }

    /// All-day dues carry only year/month/day. Timed dues add hour/minute plus calendar and time zone,
    /// and get an absolute alarm at the due time so Reminders notifies like Things does.
    static func setDue(_ reminder: EKReminder, _ due: DueDate?) {
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil && alarm.structuredLocation == nil {
            reminder.removeAlarm(alarm)
        }
        guard let due, let parts = parse(due.day) else { reminder.dueDateComponents = nil; return }
        guard let minutes = due.minutes else {
            reminder.dueDateComponents = DateComponents(year: parts.0, month: parts.1, day: parts.2)
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        let comps = DateComponents(calendar: calendar, timeZone: .current, year: parts.0, month: parts.1, day: parts.2,
                                   hour: minutes / 60, minute: minutes % 60)
        reminder.dueDateComponents = comps
        if let date = calendar.date(from: comps) { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
    }

    static func parse(_ day: String) -> (Int, Int, Int)? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : nil
    }

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = color.converted(to: space, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        func byte(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(comps[0]), byte(comps[1]), byte(comps[2]))
    }
}

private final class ObserverToken: @unchecked Sendable {
    let value: NSObjectProtocol
    init(_ value: NSObjectProtocol) { self.value = value }
}

/// Collapses bursts of change notifications into one callback after `delay` seconds of quiet.
private final class Debouncer: @unchecked Sendable {
    private let lock = NSLock()
    private var item: DispatchWorkItem?
    private let delay: TimeInterval
    private let action: @Sendable () -> Void

    init(delay: TimeInterval, action: @escaping @Sendable () -> Void) { self.delay = delay; self.action = action }

    func poke() {
        lock.lock(); defer { lock.unlock() }
        item?.cancel()
        let work = DispatchWorkItem { [action] in action() }
        item = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() { lock.lock(); item?.cancel(); item = nil; lock.unlock() }
}
