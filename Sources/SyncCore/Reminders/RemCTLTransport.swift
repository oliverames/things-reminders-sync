import Foundation

// Transport layer for the RemCTL Reminders backend. Two seams keep tests off the real `remctl`:
//  - `RemCTLTransport`: what `RemCTLReminders` needs (tool calls, one-shot CLI runs, version).
//  - `RemCTLLink`: one live `remctl mcp serve` session (write a line, read lines). `MCPTransport`
//    owns the JSON-RPC protocol, serialization, timeouts, and restart on top of it.

struct RemCTLError: LocalizedError, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// The executable is missing.
        case notInstalled
        /// The process died, hung, or the pipe broke before a request was sent, or while a read was waiting.
        /// Such a call is retried once with a fresh process.
        case transport
        /// A write was sent and no answer came back (timeout, or the process died). The write may have landed, so it
        /// is never sent again; the caller re-reads and checks.
        case uncertain
        /// RemCTL answered with an error (tool `isError`, JSON-RPC error, bad output). Never retried.
        case tool
    }
    var kind: Kind
    var message: String
    var errorDescription: String? { message }

    static func transport(_ m: String) -> RemCTLError { RemCTLError(kind: .transport, message: m) }
    static func tool(_ m: String) -> RemCTLError { RemCTLError(kind: .tool, message: m) }
    static func uncertain(_ m: String) -> RemCTLError { RemCTLError(kind: .uncertain, message: m) }
    static let notInstalled = RemCTLError(
        kind: .notInstalled,
        message: "RemCTL not found. Install it (~/bin/remctl, /opt/homebrew/bin/remctl, or /usr/local/bin/remctl) or set its path in Settings.")
}

protocol RemCTLTransport: Sendable {
    /// Calls an MCP tool and returns its payload (`structuredContent`, else the JSON text of `content[0]`).
    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue
    /// Runs `remctl <arguments>` as a one-shot process and returns its parsed JSON stdout. Used for the full
    /// export, because MCP tool results are capped (a ~170 KB budget cuts `export` to a fraction of the rows).
    func runCLI(_ arguments: [String]) async throws -> JSONValue
    /// `serverInfo.version` from the last MCP handshake.
    func serverVersion() async -> String?
    /// Changes the executable (nil = search the default locations) and drops the running session.
    func setExecutablePath(_ path: String?) async
}

// MARK: - Locating the executable

enum RemCTLLocator {
    static let defaultPaths = [
        NSHomeDirectory() + "/bin/remctl", "/opt/homebrew/bin/remctl", "/usr/local/bin/remctl",
    ]

    static func resolve(explicit: String?) -> String? {
        let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = trimmed.isEmpty ? defaultPaths : [(trimmed as NSString).expandingTildeInPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Live link: one `remctl mcp serve` child process

protocol RemCTLLink: Sendable {
    /// Stdout lines. Finishes at EOF (process exit).
    var lines: AsyncStream<String> { get }
    func write(_ line: String) throws
    func close()
}

final class ProcessLink: RemCTLLink, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let process = Process()
    private let stdin = Pipe()

    init(executable: String) throws {
        signal(SIGPIPE, SIG_IGN)   // a write to a dead child must throw, not kill the app
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mcp", "serve"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let (stream, continuation) = AsyncStream<String>.makeStream()
        lines = stream
        do { try process.run() } catch { throw RemCTLError.transport("Could not start RemCTL: \(error.localizedDescription)") }

        let out = stdout.fileHandleForReading, err = stderr.fileHandleForReading
        DispatchQueue.global().async {
            var buffer = Data()
            while true {
                let chunk = out.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    continuation.yield(String(decoding: line, as: UTF8.self))
                }
            }
            continuation.finish()
        }
        // Drain stderr so a full pipe can never block the child.
        DispatchQueue.global().async { while !err.availableData.isEmpty {} }
    }

    func write(_ line: String) throws {
        do { try stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        catch { throw RemCTLError.transport("Could not write to RemCTL: \(error.localizedDescription)") }
    }

    func close() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

// MARK: - One-shot CLI runs

enum RemCTLProcess {
    /// Runs the executable to completion off the calling thread. Stdout is read concurrently with stderr
    /// (never leave a pipe undrained) and the process is killed after `timeout` seconds.
    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(), out = Pipe(), err = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: RemCTLError.transport("Could not start RemCTL: \(error.localizedDescription)"))
                    return
                }
                let timedOut = LockedFlag()
                let timer = DispatchWorkItem { timedOut.set(); if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                let errBox = LockedData()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errBox.set(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()

                if timedOut.value {
                    continuation.resume(throwing: RemCTLError.transport("RemCTL timed out after \(Int(timeout)) s"))
                } else if process.terminationStatus != 0 {
                    let text = String(decoding: errBox.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: RemCTLError.tool(text.isEmpty ? "RemCTL exited with status \(process.terminationStatus)" : text))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

// MARK: - JSON-RPC over a link

/// MCP client for `remctl mcp serve`: lazy start, one handshake per process, requests serialized, responses
/// routed by id, a timeout per request, and one restart when the process dies or hangs. Only calls that are safe
/// to repeat are sent again after the restart: reads, and calls that failed before their request line was written.
/// A write that was sent and got no answer throws `.uncertain` instead (it may have landed).
actor MCPTransport {
    /// Tools that only read, so sending them twice is harmless.
    static let readOnlyTools: Set<String> = ["lists", "get_reminder", "get_list"]

    private let connect: @Sendable () throws -> any RemCTLLink
    private let timeout: Duration
    private var link: (any RemCTLLink)?
    private var generation = 0
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<Result<JSONValue, RemCTLError>, Never>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var version: String?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// True once the current tool call's request line went out (from then on a write may have landed).
    private var toolRequestWritten = false

    init(timeout: Duration = .seconds(30), connect: @escaping @Sendable () throws -> any RemCTLLink) {
        self.timeout = timeout
        self.connect = connect
    }

    var serverVersion: String? { version }

    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        await acquire()
        defer { release() }
        var failure = RemCTLError.transport("RemCTL is not responding")
        for _ in 0..<2 {   // the original attempt plus one restart
            toolRequestWritten = false
            do {
                try await ensureSession()
                let result = try await request("tools/call", ["name": .string(name), "arguments": .object(arguments)], isToolCall: true)
                return try Self.payload(of: result)
            } catch let error as RemCTLError where error.kind == .transport {
                failure = error
                teardown()
                if toolRequestWritten, !Self.readOnlyTools.contains(name) {
                    throw RemCTLError.uncertain("RemCTL did not confirm \(name) (\(error.message)); the change may have been made")
                }
            } catch let error as RemCTLError {
                if error.kind == .notInstalled { teardown() }
                throw error
            }
        }
        throw failure
    }

    /// Drops the running process; the next call starts a fresh one.
    func reset() { teardown() }

    // MARK: Serialization

    private func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        else { busy = true }
    }

    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    // MARK: Session

    private func ensureSession() async throws {
        guard link == nil else { return }
        let newLink: any RemCTLLink
        do { newLink = try connect() }
        catch let error as RemCTLError { throw error }
        catch { throw RemCTLError.transport("Could not start RemCTL: \(error.localizedDescription)") }
        generation += 1
        let gen = generation
        link = newLink
        let lines = newLink.lines
        Task { [weak self] in
            for await line in lines { await self?.handle(line, generation: gen) }
            await self?.ended(generation: gen)
        }
        let initialize = try await request("initialize", [
            "protocolVersion": "2026-07-28", "capabilities": .object([:]),
            "clientInfo": ["name": "ThingsRemindersSync", "version": "0.1.0"],
        ])
        version = initialize["serverInfo"]?["version"]?.string
        try newLink.write(JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).serialized())
    }

    private func teardown() {
        generation += 1   // stale readers are ignored from here on
        fail(.transport("RemCTL session closed"))
        link?.close()
        link = nil
    }

    private func fail(_ error: RemCTLError) {
        let waiters = pending
        pending = [:]
        timers.values.forEach { $0.cancel() }
        timers = [:]
        for (_, continuation) in waiters { continuation.resume(returning: .failure(error)) }
    }

    private func ended(generation gen: Int) {
        guard gen == generation else { return }
        fail(.transport("RemCTL exited unexpectedly"))
        link = nil
    }

    // MARK: Requests

    private func request(_ method: String, _ params: JSONValue, isToolCall: Bool = false) async throws -> JSONValue {
        guard let link else { throw RemCTLError.transport("RemCTL is not running") }
        nextId += 1
        let id = nextId
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let outcome: Result<JSONValue, RemCTLError> = await withCheckedContinuation { continuation in
            pending[id] = continuation
            do { try link.write(message.serialized()) }
            catch {
                pending[id] = nil
                continuation.resume(returning: .failure((error as? RemCTLError) ?? .transport(error.localizedDescription)))
                return
            }
            if isToolCall { toolRequestWritten = true }
            timers[id] = Task { [timeout] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self.timedOut(id) }
            }
        }
        return try outcome.get()
    }

    private func timedOut(_ id: Int) {
        timers[id] = nil
        pending.removeValue(forKey: id)?.resume(returning: .failure(.transport("RemCTL did not answer in time")))
    }

    private func handle(_ line: String, generation gen: Int) {
        guard gen == generation, let data = line.data(using: .utf8),
              let message = try? JSONValue.parse(data), let id = message["id"]?.int,
              let continuation = pending.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        if let error = message["error"] {
            continuation.resume(returning: .failure(.tool(error["message"]?.string ?? "RemCTL protocol error")))
        } else {
            continuation.resume(returning: .success(message["result"] ?? .null))
        }
    }

    /// Unwraps a `tools/call` result: error results throw, otherwise `structuredContent` or the parsed text.
    static func payload(of result: JSONValue) throws -> JSONValue {
        let text = result["content"]?.array?.first?["text"]?.string
        if result["isError"]?.flag == true {
            let message = result["structuredContent"]?["error"]?["message"]?.string
                ?? text.flatMap { try? JSONValue.parse(Data($0.utf8))["error"]?["message"]?.string } ?? text
                ?? "RemCTL reported an error"
            throw RemCTLError.tool(message)
        }
        let value: JSONValue
        if let structured = result["structuredContent"], !structured.isNull { value = structured }
        else if let text { value = (try? JSONValue.parse(Data(text.utf8))) ?? .string(text) }
        else { value = .null }
        if value["truncated"]?.flag == true { throw RemCTLError.tool("RemCTL truncated the result") }
        return value
    }
}

// MARK: - Live transport

final class LockedPath: @unchecked Sendable {
    private let lock = NSLock(); private var path: String?
    init(_ path: String?) { self.path = path }
    var value: String? { get { lock.lock(); defer { lock.unlock() }; return path } set { lock.lock(); path = newValue; lock.unlock() } }
}

/// The production transport: an `MCPTransport` over `remctl mcp serve`, plus one-shot CLI runs.
final class LiveRemCTLTransport: RemCTLTransport {
    private let explicitPath: LockedPath
    private let mcp: MCPTransport
    private let timeout: TimeInterval

    init(executablePath: String?, timeout: TimeInterval = 30) {
        let box = LockedPath(executablePath)
        explicitPath = box
        self.timeout = timeout
        mcp = MCPTransport(timeout: .seconds(timeout)) {
            guard let path = RemCTLLocator.resolve(explicit: box.value) else { throw RemCTLError.notInstalled }
            return try ProcessLink(executable: path)
        }
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await mcp.callTool(name, arguments: arguments)
    }

    func runCLI(_ arguments: [String]) async throws -> JSONValue {
        guard let path = RemCTLLocator.resolve(explicit: explicitPath.value) else { throw RemCTLError.notInstalled }
        let data = try await RemCTLProcess.run(executable: path, arguments: arguments, timeout: timeout)
        do { return try JSONValue.parse(data) }
        catch { throw RemCTLError.tool("RemCTL returned output that is not JSON") }
    }

    func serverVersion() async -> String? { await mcp.serverVersion }

    func setExecutablePath(_ path: String?) async {
        explicitPath.value = path
        await mcp.reset()
    }
}
