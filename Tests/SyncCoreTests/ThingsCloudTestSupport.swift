import Foundation
import Testing
@testable import SyncCore

/// Fake Things Cloud for tests: records requests, serves a scripted history, accepts commits.
final class FakeThingsCloud: @unchecked Sendable {
    struct Recorded { var method: String; var url: String; var headers: [String: String]; var body: Data? }

    private let lock = NSLock()
    private var _requests: [Recorded] = []
    var items: [JSONValue]
    var pageCap: Int
    var head: Int
    var commitStatuses: [Int] = []

    init(items: [JSONValue] = [], head: Int? = nil, pageCap: Int = .max) {
        self.items = items
        self.head = head ?? items.count
        self.pageCap = pageCap
    }

    var requests: [Recorded] { lock.withLock { _requests } }
    var commits: [Recorded] { requests.filter { $0.url.contains("/commit") } }

    func commitBody(_ i: Int = 0) throws -> [String: JSONValue] {
        let body = try #require(commits[i].body)
        return try #require(try JSONValue.parse(body).object)
    }

    var handler: ThingsRequestHandler {
        { [self] request in
            let url = request.url!.absoluteString
            let headers = request.allHTTPHeaderFields ?? [:]
            let status: Int = lock.withLock {
                _requests.append(Recorded(method: request.httpMethod ?? "GET", url: url, headers: headers, body: request.httpBody))
                if url.contains("/commit"), !commitStatuses.isEmpty { return commitStatuses.removeFirst() }
                return 200
            }
            func reply(_ value: JSONValue, _ code: Int = status) -> (Data, HTTPURLResponse) {
                (value.data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("/commit") {
                if status != 200 { return reply(["error": "stale"]) }
                return reply(["server-head-index": .number(Double(lock.withLock { head += 1; return head }))])
            }
            if url.contains("/items") {
                let start = Int(URLComponents(string: url)!.queryItems!.first { $0.name == "start-index" }!.value!)!
                let page = Array(items.dropFirst(start).prefix(pageCap))
                return reply(["schema": 301, "current-item-index": .number(Double(head)), "items": .array(page)])
            }
            if url.contains("/account/") { return reply(["history-key": "KEY"]) }
            return reply(["latest-server-index": .number(Double(lock.withLock { head })), "latest-schema-version": 301])
        }
    }

    /// Default clock: 2026-11-09 01:00 UTC, which is still 2026-11-08 in New York.
    func client(timeZone: TimeZone = TimeZone(identifier: "UTC")!, now: Date = Date(timeIntervalSince1970: 1_794_186_000)) -> ThingsCloudClient {
        ThingsCloudClient(email: "A@b.c", password: "pw", timeZone: timeZone, historyKey: "KEY", now: { now }, handler: handler)
    }
}

func taskItem(_ id: String, _ p: [String: JSONValue] = [:], entity: String = "Task6", t: Int = 0) -> JSONValue {
    .object([id: .object(["t": .number(Double(t)), "e": .string(entity), "p": .object(p)])])
}

func day(_ y: Int, _ m: Int, _ d: Int) -> Double {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970
}
