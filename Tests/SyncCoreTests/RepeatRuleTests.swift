import Foundation
import Testing
@testable import SyncCore

// Every sample below is from docs/RECURRENCE.md (verified against the real apps).

private let start = 1_794_182_400.0   // 2026-11-09, midnight UTC (a Monday)

private func rr(fu: Int, fa: Int = 1, of: [JSONValue], tp: Int = 0, ia: Double = start, sr: Double = start,
                rc: Int = 0, ed: Double? = ThingsRepeat.farFuture) -> JSONValue {
    var o: [String: JSONValue] = ["fu": .number(Double(fu)), "fa": .number(Double(fa)), "of": .array(of), "tp": .number(Double(tp)),
                                  "ia": .number(ia), "sr": .number(sr), "rc": .number(Double(rc)), "ts": 0, "rrv": 4]
    if let ed { o["ed"] = .number(ed) }
    return .object(o)
}
private func dy(_ n: Int) -> JSONValue { ["dy": .number(Double(n))] }
private func wd(_ n: Int) -> JSONValue { ["wd": .number(Double(n))] }

/// (name, Things rr, expected rule)
private let thingsSamples: [(String, JSONValue, RepeatRule)] = [
    ("every day", rr(fu: 16, of: [dy(0)]), RepeatRule(frequency: .daily)),
    ("every 3 days", rr(fu: 16, fa: 3, of: [dy(0)]), RepeatRule(frequency: .daily, interval: 3)),
    ("weekly Monday", rr(fu: 256, of: [wd(1)]), RepeatRule(frequency: .weekly, weekdays: [1])),
    ("every 2 weeks Mon Thu", rr(fu: 256, fa: 2, of: [wd(1), wd(4)]), RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4])),
    ("weekdays", rr(fu: 256, of: [wd(1), wd(2), wd(3), wd(4), wd(5)]), RepeatRule(frequency: .weekly, weekdays: [1, 2, 3, 4, 5])),
    ("monthly 15th", rr(fu: 8, of: [dy(14)]), RepeatRule(frequency: .monthly, monthDays: [15])),
    ("monthly 1st and 15th", rr(fu: 8, of: [dy(0), dy(14)]), RepeatRule(frequency: .monthly, monthDays: [1, 15])),
    ("monthly 2nd Tuesday", rr(fu: 8, of: [["wdo": 2, "wd": 2]]), RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: 2, weekday: 2)])),
    ("monthly last Friday", rr(fu: 8, of: [["wdo": -1, "wd": 5]]), RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: -1, weekday: 5)])),
    ("monthly last day", rr(fu: 8, of: [dy(-1)]), RepeatRule(frequency: .monthly, monthDays: [-1])),
    ("yearly Nov 20", rr(fu: 4, of: [["dy": 19, "mo": 10]]), RepeatRule(frequency: .yearly, monthDays: [20], month: 11)),
    ("yearly 4th Thursday of November", rr(fu: 4, of: [["wdo": 4, "mo": 10, "wd": 4]]),
     RepeatRule(frequency: .yearly, nthWeekdays: [.init(ordinal: 4, weekday: 4)], month: 11)),
    ("after completion every 4 days", rr(fu: 16, fa: 4, of: [], tp: 1, ia: 0), RepeatRule(frequency: .daily, interval: 4, afterCompletion: true)),
    ("daily 5 times", rr(fu: 16, of: [dy(0)], rc: 5, ed: nil), RepeatRule(frequency: .daily, end: .afterCount(5))),
    ("daily until 2026-12-31", rr(fu: 16, of: [dy(0)], ed: 1_798_675_200), RepeatRule(frequency: .daily, end: .until("2026-12-31"))),
]

@Suite("Things repeat rules")
struct ThingsRepeatTests {
    @Test(arguments: thingsSamples.indices) func sampleRoundTripsByteForByte(_ i: Int) throws {
        let (name, wire, expected) = thingsSamples[i]
        let rule = try #require(ThingsRepeat.rule(from: wire), "\(name) should decode")
        #expect(rule == expected, "\(name)")
        let rebuilt = try #require(ThingsRepeat.rr(for: rule, start: "2026-11-09"), "\(name) should rebuild")
        #expect(rebuilt == wire, "\(name)")
        #expect(rebuilt.serialized() == wire.serialized(), "\(name)")
    }

    @Test func sampleKeysAreExactlyTheObservedSet() throws {
        for (name, wire, _) in thingsSamples {
            let keys = Set(try #require(wire.object).keys)
            let want: Set<String> = ["fu", "fa", "of", "tp", "ia", "sr", "rc", "ts", "rrv"]
            #expect(keys == (name.contains("5 times") ? want : want.union(["ed"])), "\(name)")
        }
    }

    @Test func anchorsAreKeptWhenARuleIsRewritten() throws {
        let rule = RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4])
        let rebuilt = try #require(ThingsRepeat.rr(for: rule, start: "2026-12-01", anchors: (start, start + 86400)))
        #expect(rebuilt["ia"] == .number(start) && rebuilt["sr"] == .number(start + 86400))
    }

    @Test func unrepresentableRulesBuildNothing() {
        #expect(ThingsRepeat.rr(for: RepeatRule(frequency: .yearly, monthDays: [1]), start: "2026-11-09") == nil)             // no month
        #expect(ThingsRepeat.rr(for: RepeatRule(frequency: .weekly), start: "2026-11-09") == nil)                              // no weekday
        #expect(ThingsRepeat.rr(for: RepeatRule(frequency: .daily, interval: 1000), start: "2026-11-09") == nil)               // fa > 999
        #expect(ThingsRepeat.rr(for: RepeatRule(frequency: .monthly, monthDays: [1], nthWeekdays: [.init(ordinal: 1, weekday: 1)]), start: "2026-11-09") == nil)
        #expect(ThingsRepeat.rr(for: RepeatRule(frequency: .daily), start: "not-a-day") == nil)
    }

    // MARK: Validator accept / reject

    @Test func validatorAcceptsEverySample() {
        for (name, wire, _) in thingsSamples { #expect(ThingsRepeat.problems(in: wire).isEmpty, "\(name)") }
    }

    private static func mutate(_ base: JSONValue, _ change: (inout [String: JSONValue]) -> Void) -> JSONValue {
        var o = base.object!
        change(&o)
        return .object(o)
    }

    @Test func validatorRejectsEveryMalformedShape() {
        let daily = rr(fu: 16, of: [dy(0)])
        let weekly = rr(fu: 256, of: [wd(1)])
        let monthly = rr(fu: 8, of: [dy(14)])
        let monthlyNth = rr(fu: 8, of: [["wdo": 2, "wd": 2]])
        let yearly = rr(fu: 4, of: [["dy": 19, "mo": 10]])
        let after = rr(fu: 16, fa: 4, of: [], tp: 1, ia: 0)
        let counted = rr(fu: 16, of: [dy(0)], rc: 5, ed: nil)
        let m = Self.mutate
        let bad: [(String, JSONValue)] = [
            ("not an object", .array([])),
            ("extra key", m(daily) { $0["zz"] = 1 }),
            ("missing fu", m(daily) { $0["fu"] = nil }),
            ("missing rrv", m(daily) { $0["rrv"] = nil }),
            ("fu 1", m(daily) { $0["fu"] = 1 }),
            ("fu 32", m(daily) { $0["fu"] = 32 }),
            ("fa 0", m(daily) { $0["fa"] = 0 }),
            ("fa 1000", m(daily) { $0["fa"] = 1000 }),
            ("fa fractional", m(daily) { $0["fa"] = 1.5 }),
            ("fa string", m(daily) { $0["fa"] = "1" }),
            ("tp 2", m(daily) { $0["tp"] = 2 }),
            ("rrv 3", m(daily) { $0["rrv"] = 3 }),
            ("rrv 5", m(daily) { $0["rrv"] = 5 }),
            ("ts 1", m(daily) { $0["ts"] = 1 }),
            ("ia not midnight", m(daily) { $0["ia"] = .number(start + 5) }),
            ("sr not midnight", m(daily) { $0["sr"] = .number(start + 5) }),
            ("ia milliseconds", m(daily) { $0["ia"] = .number(start * 1000) }),
            ("ia zero for fixed", m(daily) { $0["ia"] = 0 }),
            ("sr null", m(daily) { $0["sr"] = .null }),
            ("after completion with ia", m(after) { $0["ia"] = .number(start) }),
            ("after completion with offsets", m(after) { $0["of"] = [dy(0)] }),
            ("rc negative", m(daily) { $0["rc"] = -1 }),
            ("rc fractional", m(daily) { $0["rc"] = 1.5 }),
            ("rc positive with ed", m(counted) { $0["ed"] = .number(ThingsRepeat.farFuture) }),
            ("rc zero without ed", m(daily) { $0["ed"] = nil }),
            ("ed not midnight", m(daily) { $0["ed"] = .number(1_798_675_201) }),
            ("ed past the far future", m(daily) { $0["ed"] = .number(ThingsRepeat.farFuture + 86400) }),
            ("ed negative", m(daily) { $0["ed"] = -86400 }),
            ("fixed rule with empty offsets", m(daily) { $0["of"] = [] }),
            ("of not an array", m(daily) { $0["of"] = "x" }),
            ("daily dy 1", m(daily) { $0["of"] = [dy(1)] }),
            ("daily two entries", m(daily) { $0["of"] = [dy(0), dy(0)] }),
            ("daily with weekday", m(daily) { $0["of"] = [wd(1)] }),
            ("weekly wd 7", m(weekly) { $0["of"] = [wd(7)] }),
            ("weekly wd -1", m(weekly) { $0["of"] = [wd(-1)] }),
            ("weekly duplicate", m(weekly) { $0["of"] = [wd(1), wd(1)] }),
            ("weekly with dy", m(weekly) { $0["of"] = [dy(1)] }),
            ("weekly with wdo", m(weekly) { $0["of"] = [["wdo": 1, "wd": 1]] }),
            ("monthly dy 31", m(monthly) { $0["of"] = [dy(31)] }),
            ("monthly dy -2", m(monthly) { $0["of"] = [dy(-2)] }),
            ("monthly duplicate", m(monthly) { $0["of"] = [dy(3), dy(3)] }),
            ("monthly mixed dy and wdo", m(monthly) { $0["of"] = [dy(3), ["wdo": 1, "wd": 1]] }),
            ("monthly two wdo", m(monthlyNth) { $0["of"] = [["wdo": 1, "wd": 1], ["wdo": 2, "wd": 1]] }),
            ("monthly wdo 0", m(monthlyNth) { $0["of"] = [["wdo": 0, "wd": 2]] }),
            ("monthly wdo 6", m(monthlyNth) { $0["of"] = [["wdo": 6, "wd": 2]] }),
            ("monthly wdo -2", m(monthlyNth) { $0["of"] = [["wdo": -2, "wd": 2]] }),
            ("monthly wd 7", m(monthlyNth) { $0["of"] = [["wdo": 1, "wd": 7]] }),
            ("monthly with mo", m(monthly) { $0["of"] = [["dy": 3, "mo": 1]] }),
            ("entry with extra key", m(monthly) { $0["of"] = [["dy": 3, "x": 1]] }),
            ("yearly two entries", m(yearly) { $0["of"] = [["dy": 19, "mo": 10], ["dy": 1, "mo": 2]] }),
            ("yearly mo 12", m(yearly) { $0["of"] = [["dy": 19, "mo": 12]] }),
            ("yearly mo -1", m(yearly) { $0["of"] = [["dy": 19, "mo": -1]] }),
            ("yearly dy without mo", m(yearly) { $0["of"] = [dy(19)] }),
            ("yearly dy 31", m(yearly) { $0["of"] = [["dy": 31, "mo": 10]] }),
            ("yearly wdo without mo", m(yearly) { $0["of"] = [["wdo": 1, "wd": 1]] }),
            ("yearly wdo 6", m(yearly) { $0["of"] = [["wdo": 6, "mo": 10, "wd": 1]] }),
        ]
        for (name, wire) in bad { #expect(!ThingsRepeat.problems(in: wire).isEmpty, "\(name) should be rejected") }
        // Rejected shapes never decode into a rule either.
        for (name, wire) in bad { #expect(ThingsRepeat.rule(from: wire) == nil, "\(name) should not decode") }
    }

    @Test func commitPathRejectsABadRuleAndAcceptsAGoodOne() throws {
        let id = ThingsID.generate()
        func change(_ rr: JSONValue) -> ThingsChangeMap {
            ["\(id)": ThingsChange(t: 1, e: "Task6", p: ["rr": rr, "tir": .number(start), "icsd": .number(start), "icc": 0])]
        }
        try ThingsChangeValidator.validate(change(thingsSamples[0].1))
        #expect(throws: ThingsCloudError.self) { try ThingsChangeValidator.validate(change(Self.mutate(thingsSamples[0].1) { $0["fu"] = 1 })) }
        #expect(throws: ThingsCloudError.self) {
            try ThingsChangeValidator.validate(["\(id)": ThingsChange(t: 1, e: "Task6", p: ["icsd": .number(start + 5)])])
        }
        #expect(throws: ThingsCloudError.self) {
            try ThingsChangeValidator.validate(["\(id)": ThingsChange(t: 1, e: "Task6", p: ["icc": -1])])
        }
    }
}

// MARK: - RemCTL

/// (RemCTL --recurrence, export object, rule, due) from docs/RECURRENCE.md.
private let remctlSamples: [(String, JSONValue, RepeatRule)] = [
    ("daily", ["frequency": "daily", "interval": 1], RepeatRule(frequency: .daily)),
    ("daily x3", ["frequency": "daily", "interval": 3], RepeatRule(frequency: .daily, interval: 3)),
    ("weekly tue", ["frequency": "weekly", "interval": 1], RepeatRule(frequency: .weekly, weekdays: [2])),   // weekday from the Tuesday due date
    ("weekly x2 mon,thu", ["frequency": "weekly", "interval": 2, "daysOfWeek": [2, 5],
                           "daysOfWeekDetailed": [["weekNumber": 0, "dayOfTheWeek": 2], ["weekNumber": 0, "dayOfTheWeek": 5]]],
     RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4])),
    ("weekly mon,tue,wed,thu,fri", ["frequency": "weekly", "interval": 1, "daysOfWeek": [2, 3, 4, 5, 6]],
     RepeatRule(frequency: .weekly, weekdays: [1, 2, 3, 4, 5])),
    ("monthly 15", ["frequency": "monthly", "interval": 1, "daysOfMonth": [15]], RepeatRule(frequency: .monthly, monthDays: [15])),
    ("monthly 1,15", ["frequency": "monthly", "interval": 1, "daysOfMonth": [1, 15]], RepeatRule(frequency: .monthly, monthDays: [1, 15])),
    ("monthly 2nd-tue", ["frequency": "monthly", "interval": 1, "daysOfWeek": [3],
                         "daysOfWeekDetailed": [["dayOfTheWeek": 3, "weekNumber": 2]]],
     RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: 2, weekday: 2)])),
    ("monthly last-fri", ["frequency": "monthly", "interval": 1, "daysOfWeekDetailed": [["dayOfTheWeek": 6, "weekNumber": -1]]],
     RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: -1, weekday: 5)])),
    ("yearly", ["frequency": "yearly", "interval": 1], RepeatRule(frequency: .yearly, monthDays: [10], month: 11)),   // date from the due date
]

@Suite("RemCTL recurrence")
struct RemCTLRecurrenceTests {
    private let due = DueDate(day: "2026-11-10")   // a Tuesday, as in every sample

    @Test(arguments: remctlSamples.indices) func exportDecodesAndRewritesToTheGrammar(_ i: Int) throws {
        let (spec, json, expected) = remctlSamples[i]
        let rule = try #require(RemCTLRecurrence.rule(from: json, due: due), "\(spec) should decode")
        #expect(rule == expected, "\(spec)")
        let written = try #require(RemCTLRecurrence.spec(for: rule, due: due))
        // Bare weekly/yearly take their day from the due date, so the rewrite names it; every other sample is verbatim.
        let want = ["weekly tue": "weekly tue", "yearly": "yearly"][spec] ?? spec
        #expect(written == want)
        #expect(RemCTLRecurrence.grammar(for: rule, due: due) == written)
    }

    @Test func objectFormIsUsedOnlyForWhatTheGrammarCannotSay() throws {
        let until = RepeatRule(frequency: .daily, end: .until("2026-12-31"))
        let count = RepeatRule(frequency: .weekly, weekdays: [1], end: .afterCount(5))
        let lastDay = RepeatRule(frequency: .monthly, monthDays: [-1])
        let yearlyNth = RepeatRule(frequency: .yearly, nthWeekdays: [.init(ordinal: 4, weekday: 4)], month: 11)
        for rule in [until, count, lastDay, yearlyNth] {
            #expect(RemCTLRecurrence.grammar(for: rule, due: due) == nil)
            let spec = try #require(RemCTLRecurrence.spec(for: rule, due: due))
            #expect(spec.hasPrefix("{"))
            // The object is exactly the export shape, so it decodes back to the same rule.
            let back = try #require(RemCTLRecurrence.rule(from: try JSONValue.parse(Data(spec.utf8)), due: due))
            #expect(back == rule)
        }
        #expect(try RemCTLRecurrence.spec(for: until, due: due) == #"{"endDate":"2026-12-31","frequency":"daily","interval":1}"#)
        #expect(try RemCTLRecurrence.spec(for: lastDay, due: due) == #"{"daysOfMonth":[-1],"frequency":"monthly","interval":1}"#)
    }

    /// Verified live (RemCTL 2.5.0): these exports are what RemCTL returned for the object form.
    @Test func liveVerifiedExports() throws {
        let until = try #require(RemCTLRecurrence.rule(from: ["frequency": "daily", "interval": 1, "endDate": "2026-12-31T00:00:00"], due: due))
        #expect(until.end == .until("2026-12-31"))
        let counted = try #require(RemCTLRecurrence.rule(from: ["frequency": "daily", "interval": 1, "count": 3], due: due))
        #expect(counted.end == .afterCount(3))
        let yearlyNth = try #require(RemCTLRecurrence.rule(from: [
            "frequency": "yearly", "interval": 1, "daysOfWeekDetailed": [["dayOfTheWeek": 5, "weekNumber": 4]],
            "daysOfWeek": [5], "monthsOfYear": [11]], due: due))
        #expect(yearlyNth == RepeatRule(frequency: .yearly, nthWeekdays: [.init(ordinal: 4, weekday: 4)], month: 11))
        let last = try #require(RemCTLRecurrence.rule(from: ["frequency": "monthly", "interval": 1, "daysOfMonth": [-1]], due: due))
        #expect(last.monthDays == [-1])
    }

    @Test func whatRemCTLCannotWriteReturnsNil() {
        #expect(RemCTLRecurrence.spec(for: RepeatRule(frequency: .daily, interval: 4, afterCompletion: true), due: due) == nil)
        // A yearly date must be the due date's: RemCTL takes it from there.
        #expect(RemCTLRecurrence.spec(for: RepeatRule(frequency: .yearly, monthDays: [20], month: 11), due: due) == nil)
        #expect(RemCTLRecurrence.spec(for: RepeatRule(frequency: .yearly, monthDays: [10], month: 11), due: nil) == nil)
    }

    @Test func unknownExportShapesDecodeToNil() {
        let bad: [JSONValue] = [
            ["frequency": "daily", "interval": 1, "setPositions": [1]],
            ["frequency": "yearly", "interval": 1, "monthsOfYear": [1, 2], "daysOfMonth": [1]],
            ["frequency": "monthly", "interval": 1, "daysOfYear": [4]],
            ["frequency": "hourly", "interval": 1],
            ["frequency": "weekly", "interval": 1, "daysOfWeekDetailed": [["dayOfTheWeek": 2, "weekNumber": 2]]],
            ["frequency": "monthly", "interval": 1, "daysOfMonth": [5], "daysOfWeekDetailed": [["dayOfTheWeek": 2, "weekNumber": 2]]],
            ["frequency": "daily", "interval": 1, "count": 3, "endDate": "2026-12-31T00:00:00"],
        ]
        for json in bad { #expect(RemCTLRecurrence.rule(from: json, due: due) == nil) }
        #expect(RemCTLRecurrence.rule(from: ["frequency": "weekly", "interval": 1], due: nil) == nil)   // needs the due day
    }

    @Test func weekdayAndDayOfMonthNumberingDiffer() throws {
        // EventKit Sunday = 1, Things Sunday = 0; EventKit days of month are 1-based, Things `dy` 0-based.
        let rule = try #require(RemCTLRecurrence.rule(from: ["frequency": "weekly", "interval": 1, "daysOfWeek": [1, 7]], due: due))
        #expect(rule.weekdays == [0, 6])
        let rr = try #require(ThingsRepeat.rr(for: RepeatRule(frequency: .monthly, monthDays: [15]), start: "2026-11-15"))
        #expect(rr["of"] == [["dy": 14]])
    }
}

@Suite("RepeatRule")
struct RepeatRuleMathTests {
    @Test func nextOccurrence() {
        func next(_ r: RepeatRule, _ d: String) -> String? { r.nextOccurrence(after: d) }
        #expect(next(RepeatRule(frequency: .daily, interval: 3), "2026-11-09") == "2026-11-12")
        #expect(next(RepeatRule(frequency: .weekly, weekdays: [1]), "2026-11-09") == "2026-11-16")
        #expect(next(RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4]), "2026-11-09") == "2026-11-12")
        #expect(next(RepeatRule(frequency: .weekly, interval: 2, weekdays: [1, 4]), "2026-11-12") == "2026-11-23")
        #expect(next(RepeatRule(frequency: .monthly, monthDays: [1, 15]), "2026-11-15") == "2026-12-01")
        #expect(next(RepeatRule(frequency: .monthly, monthDays: [-1]), "2026-11-30") == "2026-12-31")
        #expect(next(RepeatRule(frequency: .monthly, monthDays: [31]), "2026-10-31") == "2026-12-31")   // November has no 31st
        #expect(next(RepeatRule(frequency: .monthly, interval: 2, monthDays: [5]), "2026-11-05") == "2027-01-05")
        #expect(next(RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: 2, weekday: 2)]), "2026-11-10") == "2026-12-08")
        #expect(next(RepeatRule(frequency: .monthly, nthWeekdays: [.init(ordinal: -1, weekday: 5)]), "2026-11-27") == "2026-12-25")
        #expect(next(RepeatRule(frequency: .yearly, nthWeekdays: [.init(ordinal: 4, weekday: 4)], month: 11), "2026-11-26") == "2027-11-25")
        #expect(next(RepeatRule(frequency: .yearly, monthDays: [20], month: 11), "2026-11-20") == "2027-11-20")
        #expect(next(RepeatRule(frequency: .daily, end: .until("2026-11-10")), "2026-11-10") == nil)
        #expect(next(RepeatRule(frequency: .daily, interval: 4, afterCompletion: true), "2026-11-10") == nil)
    }

    @Test func countedEndIsMaskedInTheComparisonKey() {
        let a = RepeatRule(frequency: .daily, end: .afterCount(5)), b = RepeatRule(frequency: .daily, end: .afterCount(4))
        #expect(a != b && a.key == b.key)
        #expect(RepeatRule(frequency: .daily, end: .until("2026-12-31")).key != RepeatRule(frequency: .daily).key)
    }
}
