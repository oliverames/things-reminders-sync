import Foundation
import Testing
@testable import SyncCore

@Suite("ThingsCloud templates")
struct ThingsCloudTemplateTests {
    private let rule = RepeatRule(frequency: .weekly, weekdays: [1])

    @Test func templateCreateWritesTheObservedKeysAndNoOccurrence() async throws {
        let project = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project)], head: 10)
        let client = cloud.client()
        // A plain create gives the reference key set (every key the app writes for a to-do).
        let plainId = try await client.createTodo(ThingsTodoDraft(title: "plain", placement: .project(project)))
        let plainKeys = Set(try #require(try cloud.commitBody(0)[plainId]?["p"]?.object).keys)

        let id = try await client.createTodo(ThingsTodoDraft(title: "Water plants", notes: "n", when: DueDate(day: "2026-11-16", minutes: 540),
                                                              placement: .project(project), recurrence: rule))
        let body = try cloud.commitBody(1)
        #expect(body.count == 1, "exactly one entity: the template, never an occurrence")
        let change = try #require(body[id]?.object)
        #expect(change["t"] == 0 && change["e"] == "Task6")
        let p = try #require(change["p"]?.object)
        #expect(Set(p.keys) == plainKeys)
        let monday = 1_794_787_200.0   // 2026-11-16
        #expect(p["rr"] == ThingsRepeat.rr(for: rule, start: "2026-11-16"))
        #expect(p["st"] == 2 && p["sr"] == .null && p["sb"] == 0)
        #expect(p["tir"] == .number(monday) && p["icsd"] == .number(monday))
        #expect(p["icc"] == 0)
        #expect(p["ato"] == 32400)
        #expect(p["tp"] == 0 && p["ss"] == 0 && p["rt"] == [])
        #expect(p["pr"] == [.string(project)])
        #expect(p["tt"] == "Water plants")
    }

    @Test func allDayTemplateHasNoReminderTime() async throws {
        let cloud = FakeThingsCloud()
        let id = try await cloud.client().createTodo(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-16"), recurrence: rule))
        #expect(try cloud.commitBody()[id]?["p"]?["ato"] == .null)
    }

    @Test func aRuleWithoutAVerifiedShapeOrDayIsRefusedBeforeAnythingIsSent() async throws {
        let cloud = FakeThingsCloud()
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-16"), recurrence: RepeatRule(frequency: .yearly, monthDays: [1])))
        }
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "t", recurrence: RepeatRule(frequency: .daily)))
        }
        #expect(cloud.commits.isEmpty)
    }

    // The template of the 2026-11-09 samples (docs/RECURRENCE.md): daily from Mon 2026-11-09, next day Tue 2026-11-10.
    private static let sampledDaily: JSONValue = ["of": [["dy": 0]], "rrv": 4, "tp": 0, "ts": 0, "fu": 16, "ia": 1_794_182_400, "fa": 1,
                                                  "sr": 1_794_182_400, "rc": 0, "ed": 64_092_211_200]
    private func sampledTemplate(_ id: String, project: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        taskItem(id, ["tt": "Repeat edit sample", "tp": 0, "ss": 0, "tr": false, "st": 2, "sr": nil, "rt": [], "rr": Self.sampledDaily,
                      "tir": 1_794_268_800, "icsd": 1_794_268_800, "icc": 1, "pr": [.string(project)]].merging(extra) { $1 }, entity: "Task7")
    }

    @Test func ruleEditWritesTheSampledShape() async throws {
        let project = ThingsID.generate(), tpl = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project), sampledTemplate(tpl, project: project)])
        let client = cloud.client()
        _ = try await client.refresh()
        // Daily changed to weekly on Tuesday, the template's next day, as in the sampled edit.
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .weekly, weekdays: [2])))
        let body = try cloud.commitBody()
        // Things wrote: {"t":1,"e":"Task7","p":{"md":<now>,"rr":{...}}}. `sr` is the old rule's, `ia` the template's `tir`.
        let sampled: JSONValue = ["of": [["wd": 2]], "rrv": 4, "tp": 0, "ts": 0, "fu": 256, "ia": 1_794_268_800, "fa": 1,
                                  "sr": 1_794_182_400, "rc": 0, "ed": 64_092_211_200]
        #expect(body == [tpl: ["t": 1, "e": "Task6", "p": ["md": 1_794_186_000, "rr": sampled]]])
    }

    @Test func ruleEditThatMovesTheNextDayWritesTheSampledShape() async throws {
        // Second sampling session: daily with tir = icsd = Tue 2026-11-10, changed to weekly on Friday. Things wrote
        // {"ti":-543,"rr":{...},"md":<now>,"icsd":1794528000,"tir":1794528000}; `ti` is incidental and is not written.
        let project = ThingsID.generate(), tpl = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project), sampledTemplate(tpl, project: project)])
        let client = cloud.client()
        _ = try await client.refresh()
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .weekly, weekdays: [5]),
                                                                    templateNext: DueDate(day: "2026-11-13")))
        let sampled = try JSONValue.parse(Data(#"""
        {"rr":{"of":[{"wd":5}],"rrv":4,"tp":0,"ts":0,"fu":256,"ia":1794268800,"fa":1,"sr":1794182400,"rc":0,"ed":64092211200},"md":1794186000,"icsd":1794528000,"tir":1794528000}
        """#.utf8))
        #expect(try cloud.commitBody() == [tpl: ["t": 1, "e": "Task6", "p": sampled]])
    }

    @Test func ruleEditThatMovesTheNextDayWritesTheTimeOnlyWhenItChanges() async throws {
        // `ato` with a rule edit is the app's own combination: only when the reminder time changes in the same edit.
        let project = ThingsID.generate(), tpl = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project), sampledTemplate(tpl, project: project, ["ato": 32400])])
        let client = cloud.client()
        _ = try await client.refresh()
        let weekly = RepeatRule(frequency: .weekly, weekdays: [5])
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(recurrence: weekly, templateNext: DueDate(day: "2026-11-13", minutes: 540)))
        #expect(Set(try #require(try cloud.commitBody(0)[tpl]?["p"]?.object).keys) == ["md", "rr", "tir", "icsd"])
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .weekly, weekdays: [4]),
                                                                    templateNext: DueDate(day: "2026-11-19", minutes: 600)))
        let p = try #require(try cloud.commitBody(1)[tpl]?["p"]?.object)
        #expect(Set(p.keys) == ["md", "rr", "tir", "icsd", "ato"] && p["ato"] == 36000)
        #expect(p["rr"]?["ia"] == 1_794_528_000 && p["rr"]?["sr"] == 1_794_182_400, "ia is the next day before this edit")
    }

    // MARK: Stop

    @Test func stopWritesTheThreeSampledEntriesInOneCommit() async throws {
        let project = ThingsID.generate(), tpl = ThingsID.generate()
        let open = ThingsID.generate(), done = ThingsID.generate(), trashed = ThingsID.generate()
        func occurrence(_ id: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            taskItem(id, ["tt": "Repeat edit sample", "tp": 0, "ss": 0, "tr": false, "rt": [.string(tpl)], "sr": 1_794_182_400,
                          "tir": 1_794_182_400, "pr": [.string(project)]].merging(extra) { $1 }, entity: "Task7")
        }
        let cloud = FakeThingsCloud(items: [projectItem(project), sampledTemplate(tpl, project: project), occurrence(open),
                                            occurrence(done, ["ss": 3, "sp": 1_794_100_000]), occurrence(trashed, ["tr": true])])
        let client = cloud.client()
        let newId = try await client.stopRepeating(templateId: tpl).todoId
        #expect(cloud.commits.count == 1)
        let body = try cloud.commitBody()
        #expect(Set(body.keys) == [newId, open, tpl], "the plain to-do, the open occurrence and the template; nothing else")

        // The create Things 3.24.2 wrote, verbatim, with this test's clock for `cd` and its project for `pr`.
        let sampled = try JSONValue.parse(Data(#"""
        {"tp":0,"sr":1794268800,"dds":null,"rt":[],"rmd":null,"ss":0,"tr":false,"dl":[],"icp":false,"st":2,"ar":[],"tt":"Repeat edit sample","do":0,"lai":null,"tir":1794268800,"tg":[],"agr":[],"ix":0,"cd":1794274999.166278,"lt":true,"icc":0,"ti":0,"md":null,"dd":null,"ato":null,"nt":{"_t":"tx","ch":0,"v":"","t":1},"icsd":null,"pr":["XN4eGArARmEF2vzS84p12i"],"rp":null,"acrd":null,"sp":null,"sb":0,"rr":null,"xx":{"sn":{},"_t":"oo"}}
        """#.utf8))
        var expected = try #require(sampled.object)
        expected["cd"] = 1_794_186_000
        expected["pr"] = [.string(project)]
        #expect(body[newId] == ["t": 0, "e": "Task6", "p": .object(expected)])
        // {"t":1,"e":"Task7","p":{"rt":[]}}: detached, with no `md`.
        #expect(body[open] == ["t": 1, "e": "Task6", "p": ["rt": []]])
        // {"t":2,"e":"Task7","p":{}}
        #expect(body[tpl] == ["t": 2, "e": "Task6", "p": [:]])

        // The local database agrees: no template, two plain to-dos, and the template's last next day is remembered.
        let snapshot = try await client.refresh().snapshot
        #expect(snapshot.tasks[tpl] == nil && snapshot.removedTemplates[tpl] == "2026-11-10")
        let plain = try #require(snapshot.tasks[newId])
        #expect(!plain.isRepeating && plain.startDate == "2026-11-10" && plain.nextDay == "2026-11-10" && plain.projectId == project)
        #expect(snapshot.tasks[open]?.isRepeating == false && snapshot.tasks[open]?.templateId == nil)
        #expect(snapshot.tasks[done]?.templateId == tpl, "a completed occurrence is left as it is")
    }

    @Test func stopCarriesTheTemplatesNotesTagsAndContainer() async throws {
        let project = ThingsID.generate(), heading = ThingsID.generate(), tag = ThingsID.generate(), tpl = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project), headingItem(heading, project: project), tagItem(tag),
                                            sampledTemplate(tpl, project: project, ["pr": [], "agr": [.string(heading)], "tg": [.string(tag)],
                                                                                    "nt": ThingsChanges.noteObject("Bring *water*"), "ato": 32400])])
        let newId = try await cloud.client().stopRepeating(templateId: tpl).todoId
        let p = try #require(try cloud.commitBody()[newId]?["p"]?.object)
        #expect(p["pr"] == [] && p["agr"] == [.string(heading)] && p["ar"] == [] && p["tg"] == [.string(tag)])
        #expect(p["nt"] == ThingsChanges.noteObject("Bring *water*"))
        #expect(p["ato"] == .null && p["md"] == .null && p["lt"] == true, "the sampled values stay as sampled")
    }

    @Test func stopOnATemplateWithNotesATagAndChecklistItemsWritesTheSampledCommit() async throws {
        // Second sampling session ("Stop sample B"): notes, one tag, two checklist items, one open occurrence.
        let project = "JVH7o2GV7gnw7YsLPKuCZP", tag = "H96sVJwE7VJveAnv7itmux", tpl = "42z5x6HRuXwRLnakSF6teh"
        let one = "TKnz93jLYf8GVtyVrDmG5e", two = "JSvw5KYxebS5HuDk6u2jz1", occurrence = "2ERKk97mjgwvtiBNL8cYVZ"
        func item(_ id: String, _ title: String, _ ix: Double, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            taskItem(id, ["tt": .string(title), "ss": 0, "sp": nil, "ix": .number(ix), "ts": [.string(tpl)], "lt": false, "cd": 1_794_270_000,
                          "md": 1_794_270_000, "xx": ThingsChanges.emptyXX].merging(extra) { $1 }, entity: "ChecklistItem3")
        }
        let cloud = FakeThingsCloud(items: [
            projectItem(project), tagItem(tag),
            sampledTemplate(tpl, project: project, ["tt": "Stop sample B", "tg": [.string(tag)], "nt": ThingsChanges.noteObject("Sample **notes**")]),
            item(two, "Two", 7), item(one, "One", -3),
            taskItem(occurrence, ["tt": "Stop sample B", "tp": 0, "ss": 0, "tr": false, "rt": [.string(tpl)], "sr": 1_794_182_400,
                                  "tir": 1_794_182_400, "pr": [.string(project)]], entity: "Task7"),
        ])
        let client = cloud.client()
        let result = try await client.stopRepeating(templateId: tpl)
        #expect(cloud.commits.count == 1, "everything in one commit")
        let body = try cloud.commitBody()
        let newOne = try #require(result.checklistIds[one]), newTwo = try #require(result.checklistIds[two])
        #expect(Set(body.keys) == [result.todoId, newOne, newTwo, one, two, occurrence, tpl])

        // The to-do: the first Stop sample's create with the title, tag, notes (and their checksum) and project of sample B.
        let sampledTodo = try JSONValue.parse(Data(#"""
        {"tp":0,"sr":1794268800,"dds":null,"rt":[],"rmd":null,"ss":0,"tr":false,"dl":[],"icp":false,"st":2,"ar":[],"tt":"Stop sample B","do":0,"lai":null,"tir":1794268800,"tg":["H96sVJwE7VJveAnv7itmux"],"agr":[],"ix":0,"cd":1794186000,"lt":true,"icc":0,"ti":0,"md":null,"dd":null,"ato":null,"nt":{"t":1,"ch":2335530048,"v":"Sample **notes**","_t":"tx"},"icsd":null,"pr":["JVH7o2GV7gnw7YsLPKuCZP"],"rp":null,"acrd":null,"sp":null,"sb":0,"rr":null,"xx":{"sn":{},"_t":"oo"}}
        """#.utf8))
        #expect(body[result.todoId] == ["t": 0, "e": "Task6", "p": sampledTodo])
        // The checklist items as sampled, with this test's clock for `cd` (the same `cd` as the to-do) and its new to-do in `ts`.
        func sampledItem(_ json: String) throws -> JSONValue {
            var p = try #require(try JSONValue.parse(Data(json.utf8)).object)
            p["cd"] = 1_794_186_000
            p["ts"] = [.string(result.todoId)]
            return ["t": 0, "e": "ChecklistItem3", "p": .object(p)]
        }
        #expect(body[newOne] == (try sampledItem(#"{"ix":0,"cd":1794276623.623518,"ts":["UigGY7zyRphxNeq29WvYSn"],"sp":null,"ss":0,"xx":{"sn":{},"_t":"oo"},"tt":"One","md":null,"lt":true}"#)))
        #expect(body[newTwo] == (try sampledItem(#"{"lt":true,"cd":1794276623.623518,"ts":["UigGY7zyRphxNeq29WvYSn"],"sp":null,"ss":0,"xx":{"sn":{},"_t":"oo"},"md":null,"tt":"Two","ix":1}"#)))
        // The template's own items, the open occurrence and the template, as sampled.
        #expect(body[one] == ["t": 2, "e": "ChecklistItem3", "p": [:]] && body[two] == ["t": 2, "e": "ChecklistItem3", "p": [:]])
        #expect(body[occurrence] == ["t": 1, "e": "Task6", "p": ["rt": []]])
        #expect(body[tpl] == ["t": 2, "e": "Task6", "p": [:]])

        let plain = try #require(try await client.refresh().snapshot.tasks[result.todoId])
        #expect(plain.checklist.map(\.id) == [newOne, newTwo] && plain.checklist.map(\.title) == ["One", "Two"])
        #expect(plain.notes == "Sample **notes**" && plain.tagIds == [tag])
    }

    @Test func stopCarriesAChecklistItemsStatusAndStopDate() async throws {
        let project = ThingsID.generate(), tpl = ThingsID.generate(), done = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            projectItem(project), sampledTemplate(tpl, project: project),
            taskItem(done, ["tt": "Done", "ss": 3, "sp": 1_794_100_000, "ix": 0, "ts": [.string(tpl)]], entity: "ChecklistItem3"),
        ])
        let result = try await cloud.client().stopRepeating(templateId: tpl)
        let copy = try #require(result.checklistIds[done])
        let p = try #require(try cloud.commitBody()[copy]?["p"]?.object)
        #expect(p["ss"] == 3 && p["sp"] == 1_794_100_000 && p["md"] == .null && p["lt"] == true && p["ix"] == 0)
    }

    @Test func stopIsRefusedForAnythingButALiveTemplateWithANextDay() async throws {
        let plain = ThingsID.generate(), bare = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(plain, ["tt": "t", "tp": 0, "ss": 0, "tr": false]),
                                            taskItem(bare, ["tt": "t", "tp": 0, "ss": 0, "tr": false, "rr": Self.sampledDaily])])
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) { _ = try await client.stopRepeating(templateId: plain) }
        await #expect(throws: ThingsCloudError.self) { _ = try await client.stopRepeating(templateId: bare) }
        await #expect(throws: ThingsCloudError.self) { _ = try await client.stopRepeating(templateId: ThingsID.generate()) }
        #expect(cloud.commits.isEmpty)
    }

    // MARK: Reading what Things wrote (history indexes 1688 to 1700)

    @Test func databaseReadsTheSampledRepeatEdits() throws {
        let todo = "7FxH2V7SdsAwEvq59evaxb", tpl = "LFwb2zkVA7nCqRm1BMEfkk", plain = "BZyaBocoogxB7WEcbQT7r", project = "XN4eGArARmEF2vzS84p12i"
        var db = ThingsDatabase()
        db.apply([todo: ThingsChange(t: 0, e: "Task7", p: ["tt": "Repeat edit sample", "tp": 0, "ss": 0, "tr": false, "pr": [.string(project)]])])
        // To-do made repeating: it becomes today's occurrence and a new template holds the rule.
        db.apply([todo: ThingsChange(t: 1, e: "Task7", p: ["tir": 1_794_182_400, "md": 1_794_274_843.075597, "rt": [.string(tpl)], "sr": 1_794_182_400])])
        db.apply([tpl: ThingsChange(t: 0, e: "Task7", p: ["sr": nil, "rt": [], "ss": 0, "tr": false, "st": 2, "tt": "Repeat edit sample",
                                                           "tir": 1_794_268_800, "icc": 1, "icsd": 1_794_268_800, "md": 1_794_274_843.07671,
                                                           "rr": Self.sampledDaily, "pr": [.string(project)]])])
        #expect(db.snapshot.tasks[todo]?.isOccurrence == true && db.snapshot.tasks[todo]?.templateId == tpl)
        #expect(db.snapshot.tasks[tpl]?.isTemplate == true && db.snapshot.tasks[tpl]?.recurrence == RepeatRule(frequency: .daily))
        // Rule edited to weekly on Tuesday.
        db.apply([tpl: ThingsChange(t: 1, e: "Task7", p: ["md": 1_794_274_921.023453, "rr": [
            "of": [["wd": 2]], "rrv": 4, "tp": 0, "ts": 0, "fu": 256, "ia": 1_794_268_800, "fa": 1, "sr": 1_794_182_400, "rc": 0, "ed": 64_092_211_200]])])
        #expect(db.snapshot.tasks[tpl]?.recurrence == RepeatRule(frequency: .weekly, weekdays: [2]) && db.snapshot.tasks[tpl]?.nextDay == "2026-11-10")
        // Paused and resumed: still a template, never a deletion.
        db.apply([tpl: ThingsChange(t: 1, e: "Task7", p: ["icp": true, "md": 1_794_274_947.122859])])
        #expect(db.snapshot.tasks[tpl]?.isTemplate == true && db.snapshot.tasks[tpl]?.trashed == false && db.snapshot.removedTemplates.isEmpty)
        db.apply([tpl: ThingsChange(t: 1, e: "Task7", p: ["icp": false, "md": 1_794_274_971.49046])])
        #expect(db.snapshot.tasks[tpl]?.isTemplate == true)
        // Stopped: one commit with three entries.
        db.apply([
            plain: ThingsChange(t: 0, e: "Task7", p: ["tp": 0, "sr": 1_794_268_800, "rt": [], "ss": 0, "tr": false, "st": 2, "tt": "Repeat edit sample",
                                                       "tir": 1_794_268_800, "cd": 1_794_274_999.166278, "lt": true, "md": nil, "icsd": nil,
                                                       "pr": [.string(project)], "rr": nil]),
            todo: ThingsChange(t: 1, e: "Task7", p: ["rt": []]),
            tpl: ThingsChange(t: 2, e: "Task7", p: [:]),
        ])
        let snapshot = db.snapshot
        #expect(snapshot.tasks[tpl] == nil && snapshot.removedTemplates == [tpl: "2026-11-10"])
        #expect(snapshot.tasks[todo]?.isRepeating == false && snapshot.tasks[todo]?.startDate == "2026-11-09")
        let kept = try #require(snapshot.tasks[plain])
        #expect(!kept.isRepeating && kept.startDate == "2026-11-10" && kept.nextDay == "2026-11-10" && kept.status == .open)
    }

    @Test func templateNextMovesOnlyTheNextDayKeys() async throws {
        let tpl = ThingsID.generate()
        let rr = try #require(ThingsRepeat.rr(for: rule, start: "2026-11-09"))
        let cloud = FakeThingsCloud(items: [taskItem(tpl, ["tt": "t", "tp": 0, "ss": 0, "tr": false, "rr": rr])])
        let client = cloud.client()
        try await client.updateTodo(id: tpl, patch: ThingsTodoPatch(templateNext: DueDate(day: "2026-11-23", minutes: 60)))
        let p = try #require(try cloud.commitBody()[tpl]?["p"]?.object)
        #expect(Set(p.keys) == ["md", "tir", "icsd", "ato"])
        #expect(p["tir"] == .number(1_795_392_000) && p["icsd"] == .number(1_795_392_000) && p["ato"] == 3600)
    }

    @Test func rulePatchOnAPlainTodoIsRefused() async throws {
        let id = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [taskItem(id, ["tt": "t", "tp": 0, "ss": 0, "tr": false])])
        await #expect(throws: ThingsCloudError.self) {
            try await cloud.client().updateTodo(id: id, patch: ThingsTodoPatch(recurrence: RepeatRule(frequency: .daily)))
        }
        #expect(cloud.commits.isEmpty)
    }

    @Test func databaseDecodesTemplatesAndOccurrences() throws {
        let tpl = ThingsID.generate(), occ = ThingsID.generate()
        var db = ThingsDatabase()
        db.apply([
            tpl: ThingsChange(t: 0, e: "Task7", p: ["tt": "T", "rr": try #require(ThingsRepeat.rr(for: rule, start: "2026-11-09")), "st": 2,
                                                     "tir": .number(1_794_787_200), "icsd": .number(1_794_787_200), "icc": 3, "ato": 32400]),
            occ: ThingsChange(t: 0, e: "Task7", p: ["tt": "T", "rt": [.string(tpl)], "sr": .number(1_794_182_400)]),
        ])
        let t = try #require(db.snapshot.tasks[tpl]), o = try #require(db.snapshot.tasks[occ])
        #expect(t.isTemplate && !t.isOccurrence && t.recurrence == rule)
        #expect(t.nextDay == "2026-11-16" && t.instanceDay == "2026-11-16" && t.instancesCreated == 3 && t.reminderSeconds == 32400)
        #expect(o.isOccurrence && !o.isTemplate && o.templateId == tpl && o.recurrence == nil)
    }
}
