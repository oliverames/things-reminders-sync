import Foundation

/// Things repeat rules (`rr`). The ONLY shapes this app reads or writes are the ones Things 3.24.2 itself
/// wrote (docs/RECURRENCE.md). Things' format is undocumented and a malformed write can crash the Mac app,
/// so there is exactly one builder (`rr(for:)`), one decoder (`rule(from:)`), and one validator
/// (`problems(in:)`) that the commit path runs on every `rr` before anything is sent.
private extension JSONValue {
    /// An integer-valued number only (`int` truncates 1.5 to 1, which the validator must not accept).
    var exactInt: Int? {
        guard case let .number(n) = self, n.isFinite, n == n.rounded(), abs(n) < 9e15 else { return nil }
        return Int(n)
    }
}

enum ThingsRepeat {
    /// `ed` for a rule that never ends.
    static let farFuture = 64_092_211_200.0
    static let keysFixed: Set<String> = ["fu", "fa", "of", "tp", "ia", "sr", "rc", "ts", "rrv", "ed"]

    private static func unit(_ f: RepeatRule.Frequency) -> Int {
        switch f { case .daily: 16; case .weekly: 256; case .monthly: 8; case .yearly: 4 }
    }
    private static func frequency(_ fu: Int) -> RepeatRule.Frequency? {
        switch fu { case 16: .daily; case 256: .weekly; case 8: .monthly; case 4: .yearly; default: nil }
    }

    /// The `rr` object for a rule, or nil when the rule has no observed Things shape. `start` is the first
    /// occurrence day. `anchors` (an existing template's `ia`/`sr`) are kept when a rule is rewritten, so the
    /// interval phase does not move.
    static func rr(for rule: RepeatRule, start: String, anchors: (ia: Double, sr: Double)? = nil) -> JSONValue? {
        guard rule.isWellFormed, let startTs = try? ThingsDates.timestamp(forDay: start) else { return nil }
        var of: [JSONValue] = []
        if !rule.afterCompletion {
            switch rule.frequency {
            case .daily: of = [["dy": 0]]
            case .weekly: of = rule.weekdays.map { ["wd": .number(Double($0))] }
            case .monthly:
                if let nth = rule.nthWeekdays.first {
                    of = [["wdo": .number(Double(nth.ordinal)), "wd": .number(Double(nth.weekday))]]
                } else {
                    of = rule.monthDays.map { ["dy": .number(Double($0 == -1 ? -1 : $0 - 1))] }
                }
            case .yearly:
                guard let month = rule.month else { return nil }
                let mo = JSONValue.number(Double(month - 1))
                if let nth = rule.nthWeekdays.first {
                    of = [["wdo": .number(Double(nth.ordinal)), "mo": mo, "wd": .number(Double(nth.weekday))]]
                } else if let md = rule.monthDays.first {
                    of = [["dy": .number(Double(md == -1 ? -1 : md - 1)), "mo": mo]]
                }
            }
        }
        var rc = 0.0
        var ed: Double? = farFuture
        switch rule.end {
        case .never: break
        case .afterCount(let n): rc = Double(n); ed = nil
        case .until(let day):
            guard let t = try? ThingsDates.timestamp(forDay: day) else { return nil }
            ed = t
        }
        var o: [String: JSONValue] = [
            "fu": .number(Double(unit(rule.frequency))), "fa": .number(Double(rule.interval)), "of": .array(of),
            "tp": rule.afterCompletion ? 1 : 0,
            "ia": rule.afterCompletion ? 0 : .number(anchors?.ia ?? startTs),
            "sr": .number(anchors?.sr ?? startTs),
            "rc": .number(rc), "ts": 0, "rrv": 4,
        ]
        if let ed { o["ed"] = .number(ed) }
        let value = JSONValue.object(o)
        return problems(in: value).isEmpty ? value : nil
    }

    /// The rule an `rr` holds, or nil when it is not exactly one of the observed shapes.
    static func rule(from rr: JSONValue) -> RepeatRule? {
        guard problems(in: rr).isEmpty, let o = rr.object, let fu = o["fu"]?.int, let freq = frequency(fu),
              let fa = o["fa"]?.int, let entries = o["of"]?.array else { return nil }
        let after = o["tp"]?.int == 1
        var weekdays: [Int] = [], days: [Int] = [], nth: [RepeatRule.NthWeekday] = []
        var month: Int?
        for e in entries {
            let wd = e["wd"]?.int, wdo = e["wdo"]?.int, dy = e["dy"]?.int, mo = e["mo"]?.int
            if let mo { month = mo + 1 }
            if let wdo, let wd { nth.append(.init(ordinal: wdo, weekday: wd)) }
            else if let wd { weekdays.append(wd) }
            else if let dy, freq != .daily { days.append(dy == -1 ? -1 : dy + 1) }
        }
        var end = RepeatRule.End.never
        if let rc = o["rc"]?.int, rc > 0 { end = .afterCount(rc) }
        else if let ed = o["ed"]?.double, ed != farFuture { end = .until(ThingsDates.day(fromTimestamp: ed)) }
        let rule = RepeatRule(frequency: freq, interval: fa, weekdays: weekdays, monthDays: days, nthWeekdays: nth,
                              month: month, end: end, afterCompletion: after)
        return rule.isWellFormed ? rule : nil
    }

    // MARK: Validator

    private static func isMidnight(_ v: JSONValue?) -> Double? {
        guard let d = v?.double, d.isFinite, d >= 0, d <= farFuture, d.truncatingRemainder(dividingBy: 86400) == 0 else { return nil }
        return d
    }

    /// Everything wrong with an `rr`; empty means it is one of the observed shapes.
    static func problems(in rr: JSONValue) -> [String] {
        guard let o = rr.object else { return ["rr must be an object"] }
        var out: [String] = []
        let extra = Set(o.keys).subtracting(keysFixed)
        if !extra.isEmpty { out.append("unknown keys \(extra.sorted())") }
        for key in keysFixed.subtracting(["ed"]) where o[key] == nil { out.append("missing key \(key)") }
        guard out.isEmpty else { return out }

        guard let fu = o["fu"]?.exactInt, let freq = frequency(fu) else { return ["fu must be 16, 256, 8, or 4"] }
        if o["fa"]?.exactInt == nil || !(1...999).contains(o["fa"]!.exactInt!) { out.append("fa must be an integer 1...999") }
        guard let tp = o["tp"]?.exactInt, tp == 0 || tp == 1 else { return out + ["tp must be 0 or 1"] }
        if o["rrv"]?.exactInt != 4 { out.append("rrv must be 4") }
        if o["ts"]?.exactInt != 0 { out.append("ts must be 0") }
        guard let rc = o["rc"]?.exactInt, rc >= 0 else { return out + ["rc must be an integer >= 0"] }
        if isMidnight(o["sr"]) == nil || o["sr"]!.double! <= 0 { out.append("sr must be a midnight-UTC day") }
        let ia = isMidnight(o["ia"])
        if tp == 1 { if ia != 0 { out.append("ia must be 0 for an after-completion rule") } }
        else if ia == nil || ia! <= 0 { out.append("ia must be a midnight-UTC day") }
        if rc > 0 {
            if o["ed"] != nil { out.append("ed must be absent when rc > 0") }
        } else if let ed = o["ed"] {
            if ed.double != farFuture && isMidnight(ed) == nil { out.append("ed must be 64092211200 or a midnight-UTC day") }
        } else { out.append("ed is required when rc is 0") }

        guard let entries = o["of"]?.array else { return out + ["of must be an array"] }
        if tp == 1 { if !entries.isEmpty { out.append("of must be empty for an after-completion rule") } }
        else if entries.isEmpty { out.append("of must not be empty") }
        else { out += offsetProblems(entries, freq) }
        return out
    }

    private static func offsetProblems(_ entries: [JSONValue], _ freq: RepeatRule.Frequency) -> [String] {
        func int(_ e: JSONValue, _ k: String) -> Int? { e[k]?.exactInt }
        func keys(_ e: JSONValue) -> Set<String> { Set(e.object?.keys.map { $0 } ?? []) }
        let wdoOK: (Int?) -> Bool = { $0.map { [-1, 1, 2, 3, 4, 5].contains($0) } ?? false }
        let wdOK: (Int?) -> Bool = { $0.map { (0...6).contains($0) } ?? false }
        let moOK: (Int?) -> Bool = { $0.map { (0...11).contains($0) } ?? false }
        let dyOK: (Int?) -> Bool = { $0.map { (0...30).contains($0) || $0 == -1 } ?? false }
        let bad = ["of entry is not one of the observed shapes for this unit"]
        switch freq {
        case .daily:
            return entries.count == 1 && keys(entries[0]) == ["dy"] && int(entries[0], "dy") == 0 ? [] : bad
        case .weekly:
            let wds = entries.map { keys($0) == ["wd"] ? int($0, "wd") : nil }
            return wds.allSatisfy(wdOK) && Set(wds.compactMap { $0 }).count == wds.count ? [] : bad
        case .monthly:
            if entries.count == 1, keys(entries[0]) == ["wdo", "wd"] {
                return wdoOK(int(entries[0], "wdo")) && wdOK(int(entries[0], "wd")) ? [] : bad
            }
            let dys = entries.map { keys($0) == ["dy"] ? int($0, "dy") : nil }
            return dys.allSatisfy(dyOK) && Set(dys.compactMap { $0 }).count == dys.count ? [] : bad
        case .yearly:
            guard entries.count == 1 else { return bad }
            let e = entries[0]
            if keys(e) == ["dy", "mo"] { return dyOK(int(e, "dy")) && moOK(int(e, "mo")) ? [] : bad }
            if keys(e) == ["wdo", "mo", "wd"] { return wdoOK(int(e, "wdo")) && moOK(int(e, "mo")) && wdOK(int(e, "wd")) ? [] : bad }
            return bad
        }
    }
}
