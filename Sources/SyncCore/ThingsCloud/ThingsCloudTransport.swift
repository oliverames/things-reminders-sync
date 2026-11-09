import Foundation

typealias ThingsRequestHandler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Headers, auth, and bounded 429 retry for Things Cloud requests.
struct ThingsCloudTransport: Sendable {
    static let base = "https://cloud.culturedcode.com"
    static let schemaVersion = "301"
    static let appId = "com.culturedcode.ThingsMac"
    static let appInstanceId = "-things-reminders-sync"
    static let pushPriority = "5"

    let password: String
    let handler: ThingsRequestHandler

    static func urlSessionHandler(_ session: URLSession) -> ThingsRequestHandler {
        { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ThingsCloudError.decoding("response was not HTTP")
            }
            return (data, http)
        }
    }

    /// JS `encodeURIComponent`: leaves `A-Za-z0-9 - _ . ! ~ * ' ( )` unescaped.
    static func encodeURIComponent(_ s: String, extraEscaped: Set<UInt8> = []) -> String {
        let keep = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8).subtracting(extraEscaped)
        var out = ""
        for b in s.utf8 {
            if keep.contains(b) { out.unicodeScalars.append(Unicode.Scalar(b)) } else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    /// `encodeURIComponent`, then also escape `!*'()` (the JS `encodePassword`).
    static func encodePassword(_ raw: String) -> String {
        encodeURIComponent(raw, extraEscaped: Set("!*'()".utf8))
    }

    static func commonHeaders(password: String) -> [String: String] {
        [
            "Content-Type": "application/json; charset=UTF-8",
            "Content-Encoding": "UTF-8",
            "Accept": "application/json",
            "User-Agent": "ThingsMac/3.21.3",
            "things-client-info": #"{"nativeAppVersion":"3.21.3","preferredLanguage":"en","uiWritingDirection":"LTR"}"#,
            "Authorization": "Password \(encodePassword(password))",
        ]
    }

    /// Sends a request and returns the body of a 2xx response; maps 401 and other failures to `ThingsCloudError`.
    func send(_ method: String, _ urlString: String, headers: [String: String] = [:], body: Data? = nil,
              acceptStatuses: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw ThingsCloudError.decoding("bad URL \(urlString)") }
        for attempt in 0... {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            for (k, v) in Self.commonHeaders(password: password).merging(headers, uniquingKeysWith: { $1 }) {
                request.setValue(v, forHTTPHeaderField: k)
            }
            let (data, response) = try await handler(request)
            if response.statusCode == 429, attempt < 2 {
                let retryAfter = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                let wait = min(retryAfter > 0 ? retryAfter : 1.5 * Double(attempt + 1), 6)
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if (200..<300).contains(response.statusCode) || acceptStatuses.contains(response.statusCode) { return (data, response) }
            if response.statusCode == 401 { throw ThingsCloudError.invalidCredentials }
            throw ThingsCloudError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        fatalError("unreachable")
    }

    func accountURL(email: String) -> String {
        "\(Self.base)/version/1/account/\(Self.encodeURIComponent(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))"
    }

    func historyKey(email: String) async throws -> String {
        let (data, response) = try await send("GET", accountURL(email: email), acceptStatuses: [404])
        if response.statusCode == 404 { throw ThingsCloudError.notFound("Things Cloud account for this email") }
        guard let key = try JSONValue.parse(data)["history-key"]?.string, !key.isEmpty else {
            throw ThingsCloudError.decoding("account response has no history-key")
        }
        return key
    }
}
