import Foundation

/// A repeat rule both apps can hold (docs/RECURRENCE.md). Conversions to and from each app's wire format
/// live next to that app's code and return nil when the rule cannot be represented exactly.
public struct RepeatRule: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Sendable { case daily, weekly, monthly, yearly }

    public struct NthWeekday: Codable, Hashable, Sendable, Comparable {
        /// 1...5, or -1 for the last.
        public var ordinal: Int
        /// 0 Sunday ... 6 Saturday (Things numbering; EventKit is this plus 1).
        public var weekday: Int
        public init(ordinal: Int, weekday: Int) { self.ordinal = ordinal; self.weekday = weekday }
        public static func < (a: NthWeekday, b: NthWeekday) -> Bool { (a.weekday, a.ordinal) < (b.weekday, b.ordinal) }
    }

    public enum End: Codable, Hashable, Sendable {
        case never
        /// Occurrences remaining (Reminders counts this down on every completion).
        case afterCount(Int)
        /// Last day, `YYYY-MM-DD`.
        case until(String)
    }

    public var frequency: Frequency
    /// Every N units, 1...999.
    public var interval: Int
    /// Weekly: 0 Sunday ... 6 Saturday.
    public var weekdays: [Int]
    /// Monthly/yearly: 1...31, or -1 for the last day.
    public var monthDays: [Int]
    public var nthWeekdays: [NthWeekday]
    /// Yearly: 1...12.
    public var month: Int?
    public var end: End
    /// Things only: repeat N units after the item is completed.
    public var afterCompletion: Bool

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = [], monthDays: [Int] = [],
                nthWeekdays: [NthWeekday] = [], month: Int? = nil, end: End = .never, afterCompletion: Bool = false) {
        self.frequency = frequency; self.interval = interval
        self.weekdays = Array(Set(weekdays)).sorted()
        self.monthDays = Array(Set(monthDays)).sorted { a, b in (a < 0 ? 99 : a) < (b < 0 ? 99 : b) }
        self.nthWeekdays = Array(Set(nthWeekdays)).sorted()
        self.month = month; self.end = end; self.afterCompletion = afterCompletion
    }

    /// Comparison form: a remaining-occurrence count is masked, because Reminders counts it down on every
    /// completion and that must not read as a rule edit.
    public var key: RepeatRule {
        var r = self
        if case .afterCount = r.end { r.end = .afterCount(0) }
        return r
    }

    /// Shape and range check; both conversions use it.
    public var isWellFormed: Bool {
        guard (1...999).contains(interval), weekdays.allSatisfy({ (0...6).contains($0) }),
              monthDays.allSatisfy({ (1...31).contains($0) || $0 == -1 }),
              nthWeekdays.allSatisfy({ ([-1, 1, 2, 3, 4, 5].contains($0.ordinal)) && (0...6).contains($0.weekday) }),
              month.map({ (1...12).contains($0) }) ?? true else { return false }
        switch end {
        case .afterCount(let n): if n < 1 { return false }
        case .until(let d): if RepeatCalendar.date(d) == nil { return false }
        case .never: break
        }
        if afterCompletion { return weekdays.isEmpty && monthDays.isEmpty && nthWeekdays.isEmpty && month == nil }
        switch frequency {
        case .daily: return weekdays.isEmpty && monthDays.isEmpty && nthWeekdays.isEmpty && month == nil
        case .weekly: return !weekdays.isEmpty && monthDays.isEmpty && nthWeekdays.isEmpty && month == nil
        case .monthly:
            return weekdays.isEmpty && month == nil && (monthDays.isEmpty != nthWeekdays.isEmpty) && nthWeekdays.count <= 1
        case .yearly:
            return weekdays.isEmpty && month != nil && (monthDays.count + nthWeekdays.count == 1)
        }
    }

    /// The first occurrence strictly after `day` (`YYYY-MM-DD`), or nil when the rule ends first or cannot be
    /// computed (after-completion rules depend on when the item is completed). Weeks start on Sunday.
    public func nextOccurrence(after day: String) -> String? {
        guard !afterCompletion, isWellFormed, let d = RepeatCalendar.date(day) else { return nil }
        var found: Date?
        switch frequency {
        case .daily:
            found = RepeatCalendar.add(days: interval, to: d)
        case .weekly:
            let w = RepeatCalendar.weekday(d)
            if let x = weekdays.first(where: { $0 > w }) {
                found = RepeatCalendar.add(days: x - w, to: d)
            } else if let x0 = weekdays.first {
                found = RepeatCalendar.add(days: 7 * interval - w + x0, to: d)
            }
        case .monthly:
            let (y, m) = RepeatCalendar.yearMonth(d)
            for k in 0..<240 {
                let total = (y * 12 + m - 1) + k * interval
                let cy = total / 12, cm = total % 12 + 1
                let hits = monthCandidates(year: cy, month: cm).filter { $0 > d }
                if let first = hits.min() { found = first; break }
            }
        case .yearly:
            let (y, _) = RepeatCalendar.yearMonth(d)
            for k in 0..<60 {
                let hits = monthCandidates(year: y + k * interval, month: month ?? 1).filter { $0 > d }
                if let first = hits.min() { found = first; break }
            }
        }
        guard let found else { return nil }
        let result = RepeatCalendar.string(found)
        if case .until(let last) = end, result > last { return nil }
        return result
    }

    private func monthCandidates(year: Int, month: Int) -> [Date] {
        var out: [Date] = []
        let dim = RepeatCalendar.daysIn(year: year, month: month)
        for md in monthDays {
            let n = md == -1 ? dim : md
            if n <= dim, let d = RepeatCalendar.date(year: year, month: month, day: n) { out.append(d) }
        }
        for nth in nthWeekdays {
            let first = RepeatCalendar.weekday(RepeatCalendar.date(year: year, month: month, day: 1)!)
            let n: Int
            if nth.ordinal > 0 {
                n = 1 + ((nth.weekday - first + 7) % 7) + 7 * (nth.ordinal - 1)
            } else {
                let last = RepeatCalendar.weekday(RepeatCalendar.date(year: year, month: month, day: dim)!)
                n = dim - ((last - nth.weekday + 7) % 7)
            }
            if n <= dim, let d = RepeatCalendar.date(year: year, month: month, day: n) { out.append(d) }
        }
        return out
    }
}

/// Gregorian day arithmetic on `YYYY-MM-DD` strings, in UTC so it never shifts with the time zone.
enum RepeatCalendar {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return date(year: y, month: m, day: d)
    }

    static func date(year: Int, month: Int, day: Int) -> Date? {
        let c = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: c), calendar.dateComponents([.year, .month, .day], from: date) == c else { return nil }
        return date
    }

    static func string(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func add(days: Int, to date: Date) -> Date { calendar.date(byAdding: .day, value: days, to: date)! }
    /// 0 Sunday ... 6 Saturday.
    static func weekday(_ date: Date) -> Int { calendar.component(.weekday, from: date) - 1 }
    static func yearMonth(_ date: Date) -> (Int, Int) {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year!, c.month!)
    }
    static func daysIn(year: Int, month: Int) -> Int {
        calendar.range(of: .day, in: .month, for: date(year: year, month: month, day: 1)!)!.count
    }
}
