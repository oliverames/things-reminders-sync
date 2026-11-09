import Foundation
import Testing
@testable import SyncCore

@Suite("ThingsCloud ids and validation")
struct ThingsCloudIDTests {
    @Test func base58RoundTrips() {
        #expect(ThingsID.encodeBase58([]) == "")
        #expect(ThingsID.encodeBase58([0, 0, 1]) == "112")
        #expect(ThingsID.encodeBase58(Array("Hello World!".utf8)) == "2NEpo7TZRRrLZSi2U")
        for bytes in [[UInt8](repeating: 0, count: 16), [0, 0, 0, 255] + [UInt8](repeating: 7, count: 12), [UInt8](repeating: 255, count: 16)] {
            let encoded = ThingsID.encodeBase58(bytes)
            #expect(ThingsID.base58ByteLength(encoded) == bytes.count)
        }
        #expect(ThingsID.base58ByteLength("0OIl") == -1)
        #expect(ThingsID.base58ByteLength("") == -1)
    }

    @Test func generatedIdsAreAlwaysValid() {
        for _ in 0..<5000 { #expect(ThingsID.isValid(ThingsID.generate())) }
    }

    @Test func badAndNativeIds() {
        #expect(ThingsID.isValid("StNiG2avHMHrcvDVCZHHh5")) // native, 22 characters
        #expect(ThingsID.isValid("FAGR63ag8YZfXwXJx6E95")) // native, 21 characters
        #expect(!ThingsID.isValid("fq2hP6DE61h8fAqsQsHsEB")) // 129-bit value
        #expect(!ThingsID.isValid("1HP7bZKWw9EJc6jZzUkCdT")) // leading "1" is a zero byte: 17 bytes
        #expect(!ThingsID.isValid("54ac9b6c-49ce-4f21-9079-74c1324f6a2a"))
        #expect(!ThingsID.isValid("0OIl0OIl0OIl0OIl0OIl0O"))
        #expect(!ThingsID.isValid(""))
    }

    @Test func crc32MatchesKnownValue() {
        #expect(ThingsCRC32.checksum("123456789") == 0xCBF4_3926)
        #expect(ThingsCRC32.checksum("") == 0)
    }

    @Test func validatorRejectsBadChanges() throws {
        func task(_ p: [String: JSONValue] = [:]) -> ThingsChange { ThingsChange(t: 1, e: "Task6", p: p) }
        let good = ThingsID.generate()
        try ThingsChangeValidator.validate([good: task(["pr": .array([.string(ThingsID.generate())]), "cd": 1794089397.169, "dd": 1798848000])])
        func problems(_ map: ThingsChangeMap) -> [String] {
            do { try ThingsChangeValidator.validate(map) } catch let ThingsCloudError.invalidChange(p) { return p } catch { return ["other"] }
            return []
        }
        #expect(problems(["fq2hP6DE61h8fAqsQsHsEB": task()]).first?.contains("not a Things id") == true)
        #expect(problems([good: task(["pr": ["1HP7bZKWw9EJc6jZzUkCdT"]])]).first?.contains("pr reference") == true)
        #expect(problems([good: task(["tg": ["54ac9b6c-49ce-4f21-9079-74c1324f6a2a"]])]).count == 1)
        #expect(problems([good: task(["cd": 1794089397169])]).first?.contains("cd must be unix seconds") == true)
        #expect(problems([good: task(["sp": "2026-11-09T16:00:00Z"])]).first?.contains("sp must be unix seconds") == true)
        #expect(problems([good: task(["dd": 1798848001])]).first?.contains("midnight UTC") == true)
        #expect(problems([good: task(["sr": 1798848001])]).first?.contains("midnight UTC") == true)
        #expect(problems([good: ThingsChange(t: 5, e: "Task6", p: [:])]).count == 1)
        #expect(problems([good: ThingsChange(t: 1, e: "Task", p: [:])]).count == 1)
    }
}

@Suite("ThingsCloud database decoding")
struct ThingsCloudDatabaseTests {
    @Test func decodesVersionedEntitiesAndNotePatches() {
        var db = ThingsDatabase()
        let text = "Hello world"
        db.apply([
            "T1": ThingsChange(t: 0, e: "Task7", p: [
                "tt": "Task", "tp": 0, "ss": 0, "st": 1, "sr": .number(day(2020, 1, 1)), "sb": 1, "ato": 32400, "tg": ["G"],
                "nt": ["_t": "tx", "t": 1, "ch": .number(Double(ThingsCRC32.checksum(text))), "v": .string(text)],
                "pr": ["P"], "ar": [], "cd": 1_700_000_000.5, "rt": [], "rr": nil,
            ]),
            "G": ThingsChange(t: 0, e: "Tag4", p: ["tt": "Tag", "pn": ["PARENT"]]),
            "A": ThingsChange(t: 0, e: "Area3", p: ["tt": "Area"]),
            "C": ThingsChange(t: 0, e: "ChecklistItem3", p: ["tt": "ignored"]),
        ])
        db.apply(["T1": ThingsChange(t: 1, e: "Task6", p: ["nt": ["_t": "tx", "t": 2, "ps": [["r": "Bye", "p": 0, "l": 5]]]])])
        let task = db.snapshot.tasks["T1"]!
        #expect(task.notes == "Bye world")
        #expect(task.startDate == "2020-01-01")
        #expect(task.evening)
        #expect(task.reminderSeconds == 32400)
        #expect(task.projectId == "P")
        #expect(task.tagIds == ["G"])
        #expect(task.creationDate == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(!task.isRepeating)
        #expect(db.snapshot.tags["G"]?.parentId == "PARENT")
        #expect(db.snapshot.areas["A"]?.title == "Area")
        #expect(db.snapshot.tasks.count == 1)
    }

    @Test func repeatingAndDelete() {
        var db = ThingsDatabase()
        db.apply(["R": ThingsChange(t: 0, e: "Task6", p: ["tt": "r", "rr": ["tp": 0]]),
                  "S": ThingsChange(t: 0, e: "Task6", p: ["tt": "s", "rt": ["X"]]),
                  "D": ThingsChange(t: 0, e: "Task6", p: ["tt": "d"])])
        #expect(db.snapshot.tasks["R"]!.isRepeating)
        #expect(db.snapshot.tasks["S"]!.isRepeating)
        let touched = db.apply(["D": ThingsChange(t: 2, e: "Task6", p: [:])])
        #expect(touched == ["D"])
        #expect(db.snapshot.tasks["D"] == nil)
    }

    @Test func notePatchUsesUTF16Units() {
        #expect(ThingsDatabase.applyNotePatches("a😀b", [["p": 3, "l": 1, "r": "c"]]) == "a😀c")
    }
}

@Suite("ThingsCloud client")
struct ThingsCloudClientTests {
    @Test func cappedHistoryPageDoesNotSkipLaterItems() async throws {
        let items = (1...5).map { taskItem("T\($0)", ["tt": .string("task \($0)"), "tp": 0, "ss": 0, "st": 1, "tr": false]) }
        let cloud = FakeThingsCloud(items: items, head: 5, pageCap: 3)
        let client = cloud.client()
        let result = try await client.refresh()
        #expect(result.snapshot.tasks.count == 5)
        #expect(result.fullReload)
        #expect(result.changedTaskIds == ["T1", "T2", "T3", "T4", "T5"])
        let second = try await client.refresh()
        #expect(!second.fullReload)
        #expect(second.changedTaskIds.isEmpty)
        #expect(cloud.requests.filter { $0.url.contains("/items") }.count == 2)
    }

    @Test func headBehindKnownIndexReloads() async throws {
        let items = (1...2).map { taskItem("T\($0)", ["tt": "x"]) }
        let cloud = FakeThingsCloud(items: items)
        let client = cloud.client()
        _ = try await client.refresh()
        cloud.items = [taskItem("N", ["tt": "new"])]
        cloud.head = 1
        let result = try await client.refresh()
        #expect(result.fullReload)
        #expect(Set(result.snapshot.tasks.keys) == ["N"])
    }

    @Test func requestHeadersAndPasswordEncoding() async throws {
        #expect(ThingsCloudTransport.encodePassword("p@ss w!rd*'()~") == "p%40ss%20w%21rd%2A%27%28%29~")
        let cloud = FakeThingsCloud()
        _ = try await cloud.client().refresh()
        let req = try #require(cloud.requests.first)
        #expect(req.headers["Authorization"] == "Password pw")
        #expect(req.headers["User-Agent"] == "ThingsMac/3.21.3")
        #expect(req.url == "https://cloud.culturedcode.com/version/1/history/KEY")
    }

    @Test func verifyMapsInvalidCredentials() async throws {
        let transport = ThingsCloudTransport(password: "bad") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: ThingsCloudError.invalidCredentials) { try await transport.historyKey(email: "a@b.c") }
        let cloud = FakeThingsCloud()
        let ok = ThingsCloudTransport(password: "pw", handler: cloud.handler)
        #expect(try await ok.historyKey(email: " A@B.c ") == "KEY")
        #expect(cloud.requests[0].url == "https://cloud.culturedcode.com/version/1/account/a%40b.c")
    }

    @Test func createTodoPayloadShape() async throws {
        let tag = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [tagItem(tag)], head: 10)
        let id = try await cloud.client().createTodo(ThingsTodoDraft(title: "Buy milk", notes: "2%", tagIds: [tag]))
        #expect(ThingsID.isValid(id))
        let commit = try #require(cloud.commits.first)
        #expect(commit.method == "POST")
        #expect(commit.url.hasSuffix("/commit?ancestor-index=10&_cnt=1"))
        #expect(commit.headers["Schema"] == "301")
        #expect(commit.headers["App-Id"] == "com.culturedcode.ThingsMac")
        #expect(commit.headers["App-Instance-Id"] == "-things-reminders-sync")
        #expect(commit.headers["Push-Priority"] == "5")
        let change = try #require(try cloud.commitBody()[id]?.object)
        #expect(change["t"] == 0)
        #expect(change["e"] == "Task6")
        let p = try #require(change["p"]?.object)
        #expect(p["tt"] == "Buy milk")
        #expect(p["tp"] == 0)
        #expect(p["st"] == 0)
        #expect(p["ss"] == 0)
        #expect(p["sp"] == .null)
        #expect(p["tr"] == false)
        #expect(p["pr"] == [])
        #expect(p["ar"] == [])
        #expect(p["rr"] == .null)
        #expect(p["xx"] == ["sn": [:], "_t": "oo"])
        #expect(p["nt"]?["v"] == "2%")
        #expect(p["nt"]?["ch"] == .number(Double(ThingsCRC32.checksum("2%"))))
        #expect(p["nt"]?["t"] == 1)
        #expect(p["tg"]?.array?.count == 1)
        // Raw wire: numbers stay numbers, nulls stay null.
        let raw = String(decoding: try #require(commit.body), as: UTF8.self)
        #expect(raw.contains("\"sp\":null"))
        #expect(raw.contains("\"ss\":0"))
        #expect(raw.contains("\"cd\":1794186000"))
    }

    @Test func schedulingTodayFutureNoneAndReminder() async throws {
        // now = 2026-11-09 01:00 UTC; in New York it is still 2026-11-08, so 11-09 is a future day there.
        let ny = TimeZone(identifier: "America/New_York")!
        let project = ThingsID.generate(), area = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [projectItem(project), areaItem(area)])
        let client = cloud.client(timeZone: ny)
        func created(_ draft: ThingsTodoDraft) async throws -> [String: JSONValue] {
            let id = try await client.createTodo(draft)
            return try #require(try cloud.commitBody(cloud.commits.count - 1)[id]?["p"]?.object)
        }
        let today = try await created(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-08")))
        #expect(today["st"] == 1)
        #expect(today["sr"] == .number(day(2026, 11, 8)))
        #expect(today["tir"] == today["sr"])
        #expect(today["ato"] == .null)
        let past = try await created(ThingsTodoDraft(title: "t", when: DueDate(day: "2020-01-01")))
        #expect(past["st"] == 1)
        let tomorrow = try await created(ThingsTodoDraft(title: "t", when: DueDate(day: "2026-11-09", minutes: 9 * 60 + 30)))
        #expect(tomorrow["st"] == 2)
        #expect(tomorrow["sr"] == .number(day(2026, 11, 9)))
        #expect(tomorrow["ato"] == .number(34_200))
        let none = try await created(ThingsTodoDraft(title: "t", placement: .project(project)))
        #expect(none["st"] == 1)
        #expect(none["sr"] == .null)
        #expect(none["tir"] == .null)
        #expect(none["pr"]?.array?.count == 1)
        #expect(none["ar"] == [])
        let inArea = try await created(ThingsTodoDraft(title: "t", placement: .area(area)))
        #expect(inArea["ar"]?.array?.count == 1)
        #expect(inArea["pr"] == [])
        let done = try await created(ThingsTodoDraft(title: "t", completed: true, completionDate: Date(timeIntervalSince1970: 1_700_000_000.5)))
        #expect(done["ss"] == 3)
        #expect(done["sp"] == 1_700_000_000.5)
    }

    @Test func updatePayloadsContainOnlyChangedKeys() async throws {
        let tagA = ThingsID.generate(), tagB = ThingsID.generate(), tagC = ThingsID.generate()
        let task = ThingsID.generate(), project = ThingsID.generate()
        let cloud = FakeThingsCloud(items: [
            taskItem(task, ["tt": "old", "tp": 0, "ss": 0, "st": 1, "sr": .number(day(2026, 11, 9)), "tg": .array([.string(tagA), .string(tagB)])]),
            tagItem(tagA), tagItem(tagB), tagItem(tagC), projectItem(project)])
        let client = cloud.client()
        func patch(_ p: ThingsTodoPatch) async throws -> [String: JSONValue] {
            try await client.updateTodo(id: task, patch: p)
            return try #require(try cloud.commitBody(cloud.commits.count - 1)[task]?["p"]?.object)
        }
        let title = try await patch(ThingsTodoPatch(title: "new"))
        #expect(Set(title.keys) == ["tt", "md"])
        #expect(try cloud.commitBody()[task]?["t"] == 1)

        let anytime = try await patch(ThingsTodoPatch(when: .some(nil)))
        #expect(anytime["st"] == 1 && anytime["sr"] == .null && anytime["tir"] == .null && anytime["ato"] == .null)
        #expect(anytime["sb"] == nil)   // not in This Evening, so the evening flag is not written

        let reopen = try await patch(ThingsTodoPatch(completed: false))
        #expect(reopen["ss"] == 0 && reopen["sp"] == .null)

        let tags = try await patch(ThingsTodoPatch(addTagIds: [tagC, tagA], removeTagIds: [tagB]))
        #expect(tags["tg"] == .array([.string(tagA), .string(tagC)]))

        let move = try await patch(ThingsTodoPatch(placement: .project(project)))
        #expect(move["pr"] == .array([.string(project)]) && move["ar"] == [] && move["agr"] == [])
        #expect(move["st"] == nil)   // already Anytime: the start state is left alone

        let trash = try await patch(ThingsTodoPatch(trashed: true))
        #expect(trash["tr"] == true)

        await #expect(throws: ThingsCloudError.notFound("to-do nope")) {
            try await client.updateTodo(id: "nope", patch: ThingsTodoPatch(title: "x"))
        }
    }

    @Test func ownWriteIsAppliedLocallyAndRetryOnStaleIndex() async throws {
        let cloud = FakeThingsCloud(head: 4)
        cloud.commitStatuses = [409]
        let client = cloud.client()
        let id = try await client.createTodo(ThingsTodoDraft(title: "x"))
        #expect(cloud.commits.count == 2)
        #expect(cloud.requests.filter { $0.url.hasSuffix("/history/KEY") }.count == 2) // head for the first ancestor, again after 409
        #expect(cloud.commits[1].url.contains("ancestor-index=4"))
        _ = id

        // After a refresh the index is known; our own write is applied locally and not re-pulled.
        let quiet = FakeThingsCloud(head: 0)
        let c = quiet.client()
        _ = try await c.refresh()
        let newId = try await c.createTodo(ThingsTodoDraft(title: "mine"))
        quiet.items = [taskItem(newId, ["tt": "mine"])]
        let result = try await c.refresh()
        #expect(result.snapshot.tasks[newId]?.title == "mine")
        #expect(result.changedTaskIds.isEmpty)
    }

    @Test func createProjectAreaTag() async throws {
        let cloud = FakeThingsCloud()
        let client = cloud.client()
        let area = try await client.createArea(title: "Home")
        let tagParent = try await client.createTag(title: "Parent", parentId: nil)
        let tag = try await client.createTag(title: "Child", parentId: tagParent)
        let project = try await client.createProject(title: "Proj", areaId: area)
        func p(_ i: Int, _ id: String) throws -> (JSONValue?, [String: JSONValue]) {
            let c = try cloud.commitBody(i)[id]!
            return (c["e"], c["p"]!.object!)
        }
        let (areaE, areaP) = try p(0, area)
        #expect(areaE == "Area3" && areaP["tt"] == "Home" && areaP["tg"] == [] && areaP["ix"] == 0)
        let (tagE, tagP) = try p(2, tag)
        #expect(tagE == "Tag4" && tagP["pn"] == .array([.string(tagParent)]) && tagP["sh"] == .null)
        let (projE, projP) = try p(3, project)
        #expect(projE == "Task6" && projP["tp"] == 1 && projP["st"] == 1 && projP["ar"] == .array([.string(area)]))
    }

    @Test func invalidIdNeverSendsARequest() async throws {
        let cloud = FakeThingsCloud()
        let client = cloud.client()
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "x", placement: .project("1HP7bZKWw9EJc6jZzUkCdT")))
        }
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTag(title: "x", parentId: "fq2hP6DE61h8fAqsQsHsEB")
        }
        await #expect(throws: ThingsCloudError.self) {
            _ = try await client.createTodo(ThingsTodoDraft(title: "x", tagIds: ["not-an-id"]))
        }
        #expect(cloud.requests.isEmpty)
    }
}
