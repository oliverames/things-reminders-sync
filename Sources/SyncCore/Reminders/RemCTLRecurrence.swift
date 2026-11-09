import Foundation

/// RemCTL 2.5.0 recurrence (verified live, docs/RECURRENCE.md): the `--recurrence` grammar for the common
/// rules, and the exported object (`frequency`, `interval`, `daysOfWeek`, `daysOfWeekDetailed`, `daysOfMonth`,
/// `monthsOfYear`, `count`, `endDate`) which `--recurrence` / `recurrence` also accepts as JSON text. The object
/// form is used only for rules the grammar cannot say: an end condition, the last day of the month, and yearly
/// nth-weekday rules.
enum RemCTLRecurrence {
    private static let dayTokens = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    private static let ordinalTokens = [1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 5: "5th", -1: "last"]

    /// The `recurrence` argument for `rule`, or nil when RemCTL cannot write it exactly. `due` is the reminder's
    /// due day: a yearly rule without an explicit date takes it from the due date, so it must match.
    static func spec(for rule: RepeatRule, due: DueDate?) -> String? {
        guard rule.isWellFormed, !rule.afterCompletion else { return nil }
        if let grammar = grammar(for: rule, due: due) { return grammar }
        return object(for: rule, due: due).map { $0.serialized() }
    }

    static func grammar(for rule: RepeatRule, due: DueDate?) -> String? {
        guard rule.isWellFormed, !rule.afterCompletion, rule.end == .never else { return nil }
        var parts = [rule.frequency.rawValue]
        if rule.interval > 1 { parts.append("x\(rule.interval)") }
        switch rule.frequency {
        case .daily: break
        case .weekly: parts.append(rule.weekdays.map { dayTokens[$0] }.joined(separator: ","))
        case .monthly:
            if let nth = rule.nthWeekdays.first {
                guard let o = ordinalTokens[nth.ordinal] else { return nil }
                parts.append("\(o)-\(dayTokens[nth.weekday])")
            } else {
                guard !rule.monthDays.contains(-1) else { return nil }
                parts.append(rule.monthDays.map(String.init).joined(separator: ","))
            }
        case .yearly:
            guard rule.nthWeekdays.isEmpty, let due, let month = rule.month, let day = rule.monthDays.first,
                  due.day.hasSuffix(String(format: "-%02d-%02d", month, day)) else { return nil }
        }
        return parts.joined(separator: " ")
    }

    static func object(for rule: RepeatRule, due: DueDate?) -> JSONValue? {
        guard rule.isWellFormed, !rule.afterCompletion else { return nil }
        var o: [String: JSONValue] = ["frequency": .string(rule.frequency.rawValue), "interval": .number(Double(rule.interval))]
        switch rule.frequency {
        case .daily: break
        case .weekly: o["daysOfWeek"] = .array(rule.weekdays.map { .number(Double($0 + 1)) })
        case .monthly:
            if let nth = rule.nthWeekdays.first { o["daysOfWeekDetailed"] = detailed(nth) }
            else { o["daysOfMonth"] = .array(rule.monthDays.map { .number(Double($0)) }) }
        case .yearly:
            if let nth = rule.nthWeekdays.first, let month = rule.month {
                o["daysOfWeekDetailed"] = detailed(nth)
                o["monthsOfYear"] = [.number(Double(month))]
            } else {
                // A plain yearly date is taken from the due date.
                guard let due, let month = rule.month, let day = rule.monthDays.first,
                      due.day.hasSuffix(String(format: "-%02d-%02d", month, day)) else { return nil }
            }
        }
        switch rule.end {
        case .never: break
        case .afterCount(let n): o["count"] = .number(Double(n))
        case .until(let day): o["endDate"] = .string(day)
        }
        return .object(o)
    }

    private static func detailed(_ nth: RepeatRule.NthWeekday) -> JSONValue {
        [["dayOfTheWeek": .number(Double(nth.weekday + 1)), "weekNumber": .number(Double(nth.ordinal))]]
    }

    private static let knownKeys: Set<String> = ["frequency", "interval", "daysOfWeek", "daysOfWeekDetailed",
                                                  "daysOfMonth", "monthsOfYear", "count", "endDate"]

    /// The rule an exported `recurrence` object holds, or nil for anything outside the verified shapes
    /// (set positions, days of the year, several months, ...). `due` fills in what the object leaves implicit
    /// (the weekday, day of month, or date of the due day).
    static func rule(from json: JSONValue, due: DueDate?) -> RepeatRule? {
        guard let o = json.object, Set(o.keys).isSubset(of: knownKeys), let fs = o["frequency"]?.string,
              let freq = RepeatRule.Frequency(rawValue: fs) else { return nil }
        let interval = o["interval"]?.int ?? 1
        var detailedDays: [(day: Int, week: Int)] = []
        if let d = o["daysOfWeekDetailed"] {
            guard let arr = d.array else { return nil }
            for e in arr {
                guard let day = e["dayOfTheWeek"]?.int, (1...7).contains(day) else { return nil }
                detailedDays.append((day - 1, e["weekNumber"]?.int ?? 0))
            }
        } else if let d = o["daysOfWeek"] {
            guard let arr = d.array else { return nil }
            for e in arr { guard let day = e.int, (1...7).contains(day) else { return nil }; detailedDays.append((day - 1, 0)) }
        }
        let monthDays = (o["daysOfMonth"]?.array ?? []).compactMap(\.int)
        if (o["daysOfMonth"]?.array?.count ?? 0) != monthDays.count { return nil }
        let months = (o["monthsOfYear"]?.array ?? []).compactMap(\.int)
        if (o["monthsOfYear"]?.array?.count ?? 0) != months.count || months.count > 1 { return nil }

        var end = RepeatRule.End.never
        if let c = o["count"] { guard let n = c.int else { return nil }; end = .afterCount(n) }
        if let e = o["endDate"] {
            guard end == .never, let s = e.string, s.count >= 10 else { return nil }
            end = .until(String(s.prefix(10)))
        }
        let anchor = due.flatMap { RepeatCalendar.date($0.day) }
        func plain() -> [Int] { detailedDays.filter { $0.week == 0 }.map(\.day) }
        func nth() -> [RepeatRule.NthWeekday] {
            detailedDays.filter { $0.week != 0 }.map { .init(ordinal: $0.week, weekday: $0.day) }
        }
        var rule: RepeatRule
        switch freq {
        case .daily:
            guard detailedDays.isEmpty, monthDays.isEmpty, months.isEmpty else { return nil }
            rule = RepeatRule(frequency: .daily, interval: interval, end: end)
        case .weekly:
            guard nth().isEmpty, monthDays.isEmpty, months.isEmpty else { return nil }
            var days = plain()
            if days.isEmpty { guard let anchor else { return nil }; days = [RepeatCalendar.weekday(anchor)] }
            rule = RepeatRule(frequency: .weekly, interval: interval, weekdays: days, end: end)
        case .monthly:
            guard months.isEmpty, plain().isEmpty else { return nil }
            if !nth().isEmpty {
                guard monthDays.isEmpty, nth().count == 1 else { return nil }
                rule = RepeatRule(frequency: .monthly, interval: interval, nthWeekdays: nth(), end: end)
            } else {
                var days = monthDays
                if days.isEmpty {
                    guard let anchor else { return nil }
                    days = [Int(RepeatCalendar.string(anchor).suffix(2))!]
                }
                rule = RepeatRule(frequency: .monthly, interval: interval, monthDays: days, end: end)
            }
        case .yearly:
            guard plain().isEmpty else { return nil }
            if let n = nth().first {
                guard nth().count == 1, monthDays.isEmpty, let m = months.first else { return nil }
                rule = RepeatRule(frequency: .yearly, interval: interval, nthWeekdays: [n], month: m, end: end)
            } else {
                var m = months.first, days = monthDays
                if m == nil || days.isEmpty {
                    guard let anchor, months.isEmpty, monthDays.isEmpty else { return nil }
                    let s = RepeatCalendar.string(anchor)
                    m = Int(s.dropFirst(5).prefix(2)); days = [Int(s.suffix(2))!]
                }
                rule = RepeatRule(frequency: .yearly, interval: interval, monthDays: days, month: m, end: end)
            }
        }
        return rule.isWellFormed ? rule : nil
    }
}
