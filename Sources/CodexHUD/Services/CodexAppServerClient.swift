import Foundation

enum CodexAppServerClientFailure: Error, Equatable, Sendable {
    case executableUnavailable
    case launchFailed(String)
    case disconnected(String)
    case malformedMessage
    case requestTimedOut(String)
    case rpcError(code: Int, message: String)
}

enum CodexAppServerRequestID: Decodable, Hashable, Sendable {
    case integer(Int)
    case string(String)

    fileprivate var jsonObject: Any {
        switch self {
        case let .integer(value):
            value
        case let .string(value):
            value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.typeMismatch(
            Self.self,
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "A Codex request id must be an integer or string."
            )
        )
    }
}

enum CodexAppServerIncoming: Sendable {
    case notification(method: String, params: Data)
    case request(id: CodexAppServerRequestID, method: String, params: Data)
    case disconnected(String)
}

/// A response sink whose implementations honor task cancellation at the final
/// transport-write boundary. The bridge revokes an in-flight approval by
/// cancelling the task that calls this protocol.
protocol CodexAppServerResponding: Sendable {
    func respond(
        to id: CodexAppServerRequestID,
        rawResult: Data
    ) async throws

    func reject(
        _ id: CodexAppServerRequestID,
        code: Int,
        message: String
    ) async throws
}

struct CodexAppServerClientResponder: CodexAppServerResponding {
    let client: CodexAppServerClient

    func respond(
        to id: CodexAppServerRequestID,
        rawResult: Data
    ) async throws {
        try Task.checkCancellation()
        try await client.respond(to: id, rawResult: rawResult)
    }

    func reject(
        _ id: CodexAppServerRequestID,
        code: Int,
        message: String
    ) async throws {
        try Task.checkCancellation()
        try await client.reject(id, code: code, message: message)
    }
}

private struct CodexAppServerRequest<Parameters: Encodable>: Encodable {
    let id: Int
    let method: String
    let params: Parameters
}

private struct CodexAppServerNotification<Parameters: Encodable>: Encodable {
    let method: String
    let params: Parameters
}

private struct CodexAppServerMethodOnlyNotification: Encodable {
    let method: String
}

struct CodexInitializeCapabilities: Encodable, Equatable, Sendable {
    let experimentalApi: Bool
    let requestAttestation: Bool
    let mcpServerOpenaiFormElicitation: Bool
    let optOutNotificationMethods: [String]

    static let codexHUD = Self(
        experimentalApi: true,
        requestAttestation: false,
        mcpServerOpenaiFormElicitation: false,
        optOutNotificationMethods: []
    )
}

private struct CodexInitializeParameters: Encodable, Sendable {
    struct ClientInfo: Encodable, Sendable {
        let name: String
        let title: String
        let version: String
    }

    let clientInfo: ClientInfo
    let capabilities: CodexInitializeCapabilities
}

private struct CodexInitializeResponse: Decodable, Sendable {
    let userAgent: String
}

private struct PendingCodexRequest {
    let method: String
    let continuation: CheckedContinuation<Data, Error>
}

/// A small newline-delimited JSON-RPC client for the official Codex app-server.
///
/// The executable is taken from the installed, signed Codex desktop bundle. It
/// reads the same ChatGPT subscription authentication as Codex itself; this
/// client never accepts or stores an API key.
actor CodexAppServerClient {
    nonisolated let incoming: AsyncStream<CodexAppServerIncoming>
    nonisolated let transientIncoming: AsyncStream<CodexAppServerIncoming>

    private let executableURL: URL
    private let incomingContinuation: AsyncStream<CodexAppServerIncoming>.Continuation
    private let transientIncomingContinuation:
        AsyncStream<CodexAppServerIncoming>.Continuation
    private var process: Process?
    private var inputHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var pending: [Int: PendingCodexRequest] = [:]
    private var nextRequestID = 1
    private var lastStandardError = ""

    init(executableURL: URL) {
        self.executableURL = executableURL
        let pair = AsyncStream.makeStream(
            of: CodexAppServerIncoming.self,
            // Protocol requests and resolution notifications are duties:
            // dropping either can leave Codex blocked forever.
            bufferingPolicy: .unbounded
        )
        incoming = pair.stream
        incomingContinuation = pair.continuation
        let transientPair = AsyncStream.makeStream(
            of: CodexAppServerIncoming.self,
            // Speech deltas are presentation hints, not protocol duties. Keep
            // only a tiny recent window so a busy MainActor cannot accidentally
            // retain a second transcript history in memory.
            bufferingPolicy: .bufferingNewest(8)
        )
        transientIncoming = transientPair.stream
        transientIncomingContinuation = transientPair.continuation
    }

    deinit {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        process?.terminate()
        incomingContinuation.finish()
        transientIncomingContinuation.finish()
    }

    func start() async throws {
        if process?.isRunning == true {
            return
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAppServerClientFailure.executableUnavailable
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executableURL
        process.arguments = [
            "--enable", "realtime_conversation",
            "app-server", "--stdio"
        ]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw CodexAppServerClientFailure.launchFailed(error.localizedDescription)
        }

        self.process = process
        inputHandle = standardInput.fileHandleForWriting

        let outputHandle = standardOutput.fileHandleForReading
        stdoutTask = Task.detached { [weak self, outputHandle] in
            guard let self else { return }
            var buffered = Data()
            while !Task.isCancelled {
                let chunk = outputHandle.availableData
                guard !chunk.isEmpty else { break }
                buffered.append(chunk)

                while let newline = buffered.firstIndex(of: 0x0A) {
                    let lineData = buffered[..<newline]
                    buffered.removeSubrange(...newline)
                    guard
                        !lineData.isEmpty,
                        let line = String(data: lineData, encoding: .utf8)
                    else {
                        continue
                    }
                    await self.receive(line)
                }
            }
            if !buffered.isEmpty,
               let line = String(data: buffered, encoding: .utf8)
            {
                await self.receive(line)
            }
            if !Task.isCancelled {
                await self.transportEnded(
                    reason: "Codex app-server closed its output stream."
                )
            }
        }

        let errorHandle = standardError.fileHandleForReading
        stderrTask = Task.detached { [weak self, errorHandle] in
            guard let self else { return }
            var buffered = Data()
            while !Task.isCancelled {
                let chunk = errorHandle.availableData
                guard !chunk.isEmpty else { break }
                buffered.append(chunk)

                while let newline = buffered.firstIndex(of: 0x0A) {
                    let lineData = buffered[..<newline]
                    buffered.removeSubrange(...newline)
                    guard
                        !lineData.isEmpty,
                        let line = String(data: lineData, encoding: .utf8)
                    else {
                        continue
                    }
                    await self.rememberStandardError(line)
                }
            }
            if !buffered.isEmpty,
               let line = String(data: buffered, encoding: .utf8)
            {
                await self.rememberStandardError(line)
            }
        }

        do {
            let response: CodexInitializeResponse = try await request(
                "initialize",
                params: CodexInitializeParameters(
                    clientInfo: .init(
                        name: "codex-hud",
                        title: "Codex HUD",
                        version: "0.1.0"
                    ),
                    capabilities: .codexHUD
                )
            )
            guard !response.userAgent.isEmpty else {
                throw CodexAppServerClientFailure.malformedMessage
            }
            try notify("initialized")
        } catch {
            stop()
            throw error
        }
    }

    func request<Parameters: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String,
        params: Parameters,
        timeout: Duration = .seconds(12)
    ) async throws -> Response {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerClientFailure.disconnected("Codex app-server is not running.")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let request = CodexAppServerRequest(id: requestID, method: method, params: params)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)

        try Task.checkCancellation()
        let responseData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = PendingCodexRequest(
                    method: method,
                    continuation: continuation
                )

                do {
                    try inputHandle.write(contentsOf: data)
                } catch {
                    pending.removeValue(forKey: requestID)
                    continuation.resume(
                        throwing: CodexAppServerClientFailure.disconnected(
                            error.localizedDescription
                        )
                    )
                    return
                }

                Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.timeOut(requestID)
                    } catch {
                        // The timeout task is best-effort and has no shared state.
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID)
            }
        }

        do {
            return try JSONDecoder().decode(Response.self, from: responseData)
        } catch {
            throw CodexAppServerClientFailure.malformedMessage
        }
    }

    func notify<Parameters: Encodable & Sendable>(
        _ method: String,
        params: Parameters
    ) throws {
        let notification = CodexAppServerNotification(method: method, params: params)
        try write(JSONEncoder().encode(notification))
    }

    func notify(_ method: String) throws {
        try write(JSONEncoder().encode(CodexAppServerMethodOnlyNotification(method: method)))
    }

    func respond<Result: Encodable & Sendable>(
        to id: CodexAppServerRequestID,
        result: Result
    ) throws {
        let encodedResult = try JSONEncoder().encode(result)
        try respond(to: id, rawResult: encodedResult)
    }

    func respond(to id: CodexAppServerRequestID, rawResult: Data) throws {
        let resultObject = try JSONSerialization.jsonObject(with: rawResult)
        let envelope: [String: Any] = [
            "id": id.jsonObject,
            "result": resultObject
        ]
        try Task.checkCancellation()
        try write(JSONSerialization.data(withJSONObject: envelope))
    }

    func reject(
        _ id: CodexAppServerRequestID,
        code: Int = -32_000,
        message: String
    ) throws {
        let envelope: [String: Any] = [
            "id": id.jsonObject,
            "error": [
                "code": code,
                "message": message
            ]
        ]
        try Task.checkCancellation()
        try write(JSONSerialization.data(withJSONObject: envelope))
    }

    func stop() {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputHandle = nil

        let failure = CodexAppServerClientFailure.disconnected(
            lastStandardError.isEmpty
                ? "Codex app-server stopped."
                : lastStandardError
        )
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.continuation.resume(throwing: failure)
        }
    }

    private func write(_ encoded: Data) throws {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerClientFailure.disconnected("Codex app-server is not running.")
        }
        var framed = encoded
        framed.append(0x0A)
        do {
            try inputHandle.write(contentsOf: framed)
        } catch {
            throw CodexAppServerClientFailure.disconnected(error.localizedDescription)
        }
    }

    private func receive(_ line: String) {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let method = object["method"] as? String {
            let paramsData = Self.jsonData(for: object["params"] ?? [:])
            if let requestID = Self.requestID(from: object["id"]) {
                incomingContinuation.yield(
                    .request(id: requestID, method: method, params: paramsData)
                )
            } else if method == "thread/realtime/transcript/delta"
                        || method == "thread/realtime/transcript/done"
            {
                transientIncomingContinuation.yield(
                    .notification(method: method, params: paramsData)
                )
            } else {
                incomingContinuation.yield(
                    .notification(method: method, params: paramsData)
                )
            }
            return
        }

        guard
            let number = object["id"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let request = pending.removeValue(forKey: number.intValue)
        else {
            return
        }

        if
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            let code = (error["code"] as? NSNumber)?.intValue ?? -32_000
            request.continuation.resume(
                throwing: CodexAppServerClientFailure.rpcError(
                    code: code,
                    message: message
                )
            )
            return
        }

        guard let result = object["result"] else {
            request.continuation.resume(
                throwing: CodexAppServerClientFailure.malformedMessage
            )
            return
        }
        request.continuation.resume(returning: Self.jsonData(for: result))
    }

    private func timeOut(_ requestID: Int) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        request.continuation.resume(
            throwing: CodexAppServerClientFailure.requestTimedOut(request.method)
        )
    }

    private func cancelRequest(_ requestID: Int) {
        guard let request = pending.removeValue(forKey: requestID) else {
            return
        }
        request.continuation.resume(throwing: CancellationError())
    }

    private func rememberStandardError(_ line: String) {
        guard !line.isEmpty else { return }
        lastStandardError = String(line.suffix(1_024))
    }

    private func transportEnded(reason: String) {
        guard process != nil else { return }
        process = nil
        inputHandle = nil

        let detail = lastStandardError.isEmpty ? reason : lastStandardError
        let failure = CodexAppServerClientFailure.disconnected(detail)
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.continuation.resume(throwing: failure)
        }
        incomingContinuation.yield(.disconnected(detail))
    }

    private static func requestID(from value: Any?) -> CodexAppServerRequestID? {
        if let value = value as? String {
            return .string(value)
        }
        if
            let value = value as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID()
        {
            return .integer(value.intValue)
        }
        return nil
    }

    private static func jsonData(for object: Any) -> Data {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object)
        {
            return data
        }
        return Data("{}".utf8)
    }
}
