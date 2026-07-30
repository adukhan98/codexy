import Foundation
import Testing
@testable import CodexHUD

@Suite("Codex app-server client", .serialized)
struct CodexAppServerClientTests {
    @Test("Initialization explicitly declines privileged server capabilities")
    func initializationCapabilities() throws {
        let data = try JSONEncoder().encode(
            CodexInitializeCapabilities.codexHUD
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["experimentalApi"] as? Bool == true)
        #expect(object["requestAttestation"] as? Bool == false)
        #expect(
            object["mcpServerOpenaiFormElicitation"] as? Bool == false
        )
        #expect(
            (object["optOutNotificationMethods"] as? [Any])?.isEmpty == true
        )
    }

    @Test("Only Codex-managed ChatGPT subscription auth is accepted")
    func subscriptionAuthenticationBoundary() throws {
        let accepted = try JSONDecoder().decode(
            CodexAccountReadResponse.self,
            from: Data(
                """
                {"account":{"type":"chatgpt","email":null,\
                "planType":"plus"},"requiresOpenaiAuth":true}
                """.utf8
            )
        )
        try accepted.requireChatGPTSubscription()

        for rejected in [
            #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}"#,
            """
            {"account":{"type":"amazonBedrock",\
            "usesCodexManagedCredentials":true},"requiresOpenaiAuth":false}
            """,
            #"{"account":null,"requiresOpenaiAuth":true}"#,
            """
            {"account":{"type":"chatgpt","email":null,\
            "planType":"plus"},"requiresOpenaiAuth":false}
            """
        ] {
            let response = try JSONDecoder().decode(
                CodexAccountReadResponse.self,
                from: Data(rejected.utf8)
            )
            #expect(
                throws: CodexBridgeFailure
                    .subscriptionAuthenticationRequired
            ) {
                try response.requireChatGPTSubscription()
            }
        }
    }

    @Test("Auth status excludes external token and provider modes")
    func exactManagedAuthModeBoundary() throws {
        let accountParameters = try JSONEncoder().encode(
            CodexAccountReadParameters()
        )
        let accountObject = try #require(
            JSONSerialization.jsonObject(with: accountParameters)
                as? [String: Any]
        )
        #expect(accountObject["refreshToken"] as? Bool == false)

        let statusParameters = try JSONEncoder().encode(
            CodexAuthStatusParameters()
        )
        let statusObject = try #require(
            JSONSerialization.jsonObject(with: statusParameters)
                as? [String: Any]
        )
        #expect(statusObject["includeToken"] as? Bool == false)
        #expect(statusObject["refreshToken"] as? Bool == false)

        let accepted = try JSONDecoder().decode(
            CodexAuthStatusResponse.self,
            from: Data(
                """
                {"authMethod":"chatgpt","authToken":null,\
                "requiresOpenaiAuth":true}
                """.utf8
            )
        )
        try accepted.requireCodexManagedChatGPTAuthentication()

        for rejected in [
            """
            {"authMethod":"chatgptAuthTokens","authToken":null,\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"headers","authToken":null,\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"agentIdentity","authToken":null,\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"personalAccessToken","authToken":null,\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"apikey","authToken":null,\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"bedrockApiKey","authToken":null,\
            "requiresOpenaiAuth":false}
            """,
            """
            {"authMethod":"chatgpt","authToken":"unexpected",\
            "requiresOpenaiAuth":true}
            """,
            """
            {"authMethod":"chatgpt","authToken":null,\
            "requiresOpenaiAuth":false}
            """,
            """
            {"authMethod":null,"authToken":null,\
            "requiresOpenaiAuth":null}
            """
        ] {
            let response = try JSONDecoder().decode(
                CodexAuthStatusResponse.self,
                from: Data(rejected.utf8)
            )
            #expect(
                throws: CodexBridgeFailure
                    .subscriptionAuthenticationRequired
            ) {
                try response.requireCodexManagedChatGPTAuthentication()
            }
        }
    }

    @Test("The official executable launches in app-server realtime mode")
    func launchAndRequestRoundTrip() async throws {
        let fixture = try FakeCodexExecutable(behavior: .echo)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)

        let response: ValueResponse
        do {
            response = try await withStartedClient(client) {
                try await client.request(
                    "echo",
                    params: ValueRequest(value: "hello"),
                    timeout: .seconds(1)
                )
            }
        } catch {
            Issue.record(
                "Unexpected \(error); fake observed methods: \(fixture.methods())"
            )
            return
        }

        #expect(response.value == "subscription-authenticated")
        let arguments = try String(
            contentsOf: fixture.argumentsURL,
            encoding: .utf8
        )
        #expect(arguments.contains("--enable realtime_conversation"))
        #expect(!arguments.contains("code_mode_host"))
        #expect(arguments.hasSuffix("app-server --stdio\n"))
    }

    @Test("Missing bundled executable fails before a process is launched")
    func missingExecutable() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("codex")
        let client = CodexAppServerClient(executableURL: missing)

        do {
            try await client.start()
            Issue.record("Expected an unavailable executable failure.")
        } catch let failure as CodexAppServerClientFailure {
            #expect(failure == .executableUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("RPC errors preserve server code and message")
    func rpcError() async throws {
        let fixture = try FakeCodexExecutable(behavior: .rpcError)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)

        do {
            let _: ValueResponse = try await withStartedClient(client) {
                try await client.request(
                    "explode",
                    params: ValueRequest(value: "now"),
                    timeout: .seconds(1)
                )
            }
            Issue.record("Expected an RPC failure.")
        } catch let failure as CodexAppServerClientFailure {
            if failure != .rpcError(
                code: -32_042,
                message: "realtime unavailable"
            ) {
                Issue.record(
                    "Unexpected \(failure); fake trace: \(fixture.trace())"
                )
            }
        } catch {
            Issue.record(
                "Unexpected \(error); fake observed methods: \(fixture.methods())"
            )
        }
    }

    @Test("Silent methods time out with the exact method name")
    func requestTimeout() async throws {
        let fixture = try FakeCodexExecutable(behavior: .silent)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)

        do {
            let _: ValueResponse = try await withStartedClient(client) {
                try await client.request(
                    "silent/method",
                    params: ValueRequest(value: "wait"),
                    timeout: .milliseconds(30)
                )
            }
            Issue.record("Expected a request timeout.")
        } catch let failure as CodexAppServerClientFailure {
            if failure != .requestTimedOut("silent/method") {
                Issue.record(
                    "Unexpected \(failure); fake trace: \(fixture.trace())"
                )
            }
        } catch {
            Issue.record(
                "Unexpected \(error); fake observed methods: \(fixture.methods())"
            )
        }
    }

    @Test("Malformed response payloads never masquerade as success")
    func malformedResponse() async throws {
        let fixture = try FakeCodexExecutable(behavior: .malformed)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)

        do {
            let _: ValueResponse = try await withStartedClient(client) {
                try await client.request(
                    "wrong-shape",
                    params: ValueRequest(value: "decode"),
                    timeout: .seconds(1)
                )
            }
            Issue.record("Expected a malformed response failure.")
        } catch let failure as CodexAppServerClientFailure {
            if failure != .malformedMessage {
                Issue.record(
                    "Unexpected \(failure); fake trace: \(fixture.trace())"
                )
            }
        } catch {
            Issue.record(
                "Unexpected \(error); fake observed methods: \(fixture.methods())"
            )
        }
    }

    @Test("Protocol duties stay lossless while transcript memory stays bounded")
    func losslessIncomingProtocolStream() async throws {
        let fixture = try FakeCodexExecutable(behavior: .flood)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)
        try await client.start()
        defer {
            Task {
                await client.stop()
            }
        }

        var iterator = client.incoming.makeAsyncIterator()
        var requestCount = 0
        var resolutionCount = 0

        for _ in 0..<2 {
            let message = try #require(await iterator.next())
            switch message {
            case let .notification(method, params):
                if method == "serverRequest/resolved" {
                    resolutionCount += 1
                    let object = try #require(
                        JSONSerialization.jsonObject(with: params)
                            as? [String: Any]
                    )
                    #expect(object["requestId"] as? String == "critical")
                }
            case let .request(id, method, _):
                #expect(id == .string("critical"))
                #expect(
                    method == "item/commandExecution/requestApproval"
                )
                requestCount += 1
            case .disconnected:
                Issue.record("The fake server disconnected during its flood.")
            }
        }

        #expect(requestCount == 1)
        #expect(resolutionCount == 1)

        var transientIterator = client.transientIncoming.makeAsyncIterator()
        var retainedTranscriptNotifications = 0
        for _ in 0..<8 {
            let message = try #require(await transientIterator.next())
            guard case let .notification(method, _) = message else {
                Issue.record("A transient stream item was not a notification.")
                continue
            }
            #expect(method == "thread/realtime/transcript/delta")
            retainedTranscriptNotifications += 1
        }
        #expect(retainedTranscriptNotifications == 8)
        await client.stop()
    }

    @Test("Cancelling a pending request resumes it immediately")
    func requestCancellation() async throws {
        let fixture = try FakeCodexExecutable(behavior: .silent)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)
        try await client.start()
        defer {
            Task {
                await client.stop()
            }
        }

        let request = Task {
            let _: ValueResponse = try await client.request(
                "silent/cancellable",
                params: ValueRequest(value: "wait"),
                timeout: .seconds(30)
            )
        }
        #expect(await eventuallyNonisolated {
            fixture.methods().contains("silent/cancellable")
        })
        request.cancel()

        do {
            try await request.value
            Issue.record("Expected cancellation.")
        } catch is CancellationError {
            // Expected: no 30-second timeout wait and no leaked continuation.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        await client.stop()
    }
}

private struct ValueRequest: Encodable, Sendable {
    let value: String
}

private struct ValueResponse: Decodable, Sendable {
    let value: String
}

private func withStartedClient<Value: Sendable>(
    _ client: CodexAppServerClient,
    operation: () async throws -> Value
) async throws -> Value {
    do {
        try await client.start()
        let value = try await operation()
        await client.stop()
        return value
    } catch {
        await client.stop()
        throw error
    }
}

private func eventuallyNonisolated(
    timeout: Duration = .seconds(1),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

final class FakeCodexExecutable {
    enum Behavior: String {
        case echo
        case rpcError
        case silent
        case malformed
        case flood
        case taskFlow
        case gatedTurnStart
    }

    let directory: URL
    let url: URL
    let argumentsURL: URL
    let methodsURL: URL
    let traceURL: URL
    let turnGateURL: URL

    init(behavior: Behavior) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexHUD-app-server-\(UUID().uuidString)",
                isDirectory: true
            )
        url = directory.appendingPathComponent("codex")
        argumentsURL = directory.appendingPathComponent("arguments.txt")
        methodsURL = directory.appendingPathComponent("methods.txt")
        traceURL = directory.appendingPathComponent("trace.txt")
        turnGateURL = directory.appendingPathComponent("turn-gate")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let argumentsPath = try Self.pythonString(argumentsURL.path)
        let methodsPath = try Self.pythonString(methodsURL.path)
        let tracePath = try Self.pythonString(traceURL.path)
        let turnGatePath = try Self.pythonString(turnGateURL.path)
        let behaviorName = try Self.pythonString(behavior.rawValue)
        let script = """
        #!/usr/bin/env python3
        import json
        import sys

        arguments_path = \(argumentsPath)
        methods_path = \(methodsPath)
        trace_path = \(tracePath)
        turn_gate_path = \(turnGatePath)
        behavior = \(behaviorName)

        with open(arguments_path, "w", encoding="utf-8") as arguments_file:
            arguments_file.write(" ".join(sys.argv[1:]) + "\\n")

        methods_file = open(methods_path, "a", encoding="utf-8", buffering=1)
        trace_file = open(trace_path, "a", encoding="utf-8", buffering=1)

        def emit(method, request_id, payload):
            trace_file.write(f"response:{method}:{request_id}\\n")
            sys.stdout.write(
                json.dumps(payload, separators=(",", ":")) + "\\n"
            )
            sys.stdout.flush()

        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method", "")
            request_id = message.get("id")
            methods_file.write(method + "\\n")
            shown_id = "" if request_id is None else str(request_id)
            trace_file.write(f"request:{method}:{shown_id}\\n")

            if method == "initialize":
                emit(
                    method,
                    request_id,
                    {
                        "id": request_id,
                        "result": {"userAgent": "fake-official-codex"}
                    }
                )
                if behavior == "flood":
                    for index in range(300):
                        emit(
                            "transcript",
                            None,
                            {
                                "method": "thread/realtime/transcript/delta",
                                "params": {
                                    "threadId": "voice-console-thread",
                                    "role": "assistant",
                                    "delta": str(index)
                                }
                            }
                        )
                    emit(
                        "approval",
                        "critical",
                        {
                            "method": "item/commandExecution/requestApproval",
                            "id": "critical",
                            "params": {
                                "threadId": "voice-console-thread",
                                "command": "echo safe"
                            }
                        }
                    )
                    for index in range(300, 600):
                        emit(
                            "transcript",
                            None,
                            {
                                "method": "thread/realtime/transcript/delta",
                                "params": {
                                    "threadId": "voice-console-thread",
                                    "role": "assistant",
                                    "delta": str(index)
                                }
                            }
                        )
                    emit(
                        "resolved",
                        None,
                        {
                            "method": "serverRequest/resolved",
                            "params": {
                                "threadId": "voice-console-thread",
                                "requestId": "critical"
                            }
                        }
                    )
            elif behavior == "echo" and method == "echo":
                emit(
                    method,
                    request_id,
                    {
                        "id": request_id,
                        "result": {"value": "subscription-authenticated"}
                    }
                )
            elif behavior == "rpcError" and method == "explode":
                emit(
                    method,
                    request_id,
                    {
                        "id": request_id,
                        "error": {
                            "code": -32042,
                            "message": "realtime unavailable"
                        }
                    }
                )
            elif behavior == "malformed" and method == "wrong-shape":
                emit(
                    method,
                    request_id,
                    {
                        "id": request_id,
                        "result": {"unexpected": True}
                    }
                )
            elif behavior in ("taskFlow", "gatedTurnStart"):
                if method == "thread/resume":
                    emit(
                        method,
                        request_id,
                        {
                            "id": request_id,
                            "result": {
                                "thread": {
                                    "id": message["params"]["threadId"],
                                    "name": "Coordinated task",
                                    "preview": None,
                                    "cwd": "/tmp",
                                    "updatedAt": 1,
                                    "status": {"type": "idle"}
                                }
                            }
                        }
                    )
                elif method == "turn/start":
                    if behavior == "gatedTurnStart":
                        import os
                        import time
                        deadline = time.time() + 5
                        while (
                            not os.path.exists(turn_gate_path)
                            and time.time() < deadline
                        ):
                            time.sleep(0.01)
                    emit(
                        method,
                        request_id,
                        {
                            "id": request_id,
                            "result": {"turn": {"id": "coordinated-turn"}}
                        }
                    )
                elif method == "turn/interrupt":
                    emit(
                        method,
                        request_id,
                        {"id": request_id, "result": {}}
                    )
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    func remove() {
        if ProcessInfo.processInfo.environment[
            "CODEX_HUD_PRESERVE_FAKE_SERVER"
        ] == "1" {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func methods() -> [String] {
        guard
            let value = try? String(
                contentsOf: methodsURL,
                encoding: .utf8
            )
        else {
            return []
        }
        return value.split(separator: "\n").map(String.init)
    }

    func trace() -> [String] {
        guard
            let value = try? String(
                contentsOf: traceURL,
                encoding: .utf8
            )
        else {
            return []
        }
        return value.split(separator: "\n").map(String.init)
    }

    func releaseTurnStart() throws {
        try Data().write(to: turnGateURL)
    }

    private static func pythonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw TestFailure.injected
        }
        // JSON permits escaped slashes, but embedding `\/` in a Python string
        // literal emits an invalid-escape warning on newer Python versions.
        return encoded.replacingOccurrences(of: "\\/", with: "/")
    }
}
