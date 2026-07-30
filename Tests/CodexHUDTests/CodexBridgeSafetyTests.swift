import Foundation
import Testing
@testable import CodexHUD

@MainActor
@Suite("Codex bridge media safety", .serialized)
struct CodexBridgeSafetyTests {
    @Test("Voice Console and coordinated turns require untrusted approval")
    func executionPoliciesAreFailSafe() throws {
        let payloads = try [
            JSONEncoder().encode(
                CodexThreadResumeParameters(threadId: "voice")
            ),
            JSONEncoder().encode(
                CodexThreadStartParameters(
                    cwd: "/workspace",
                    developerInstructions: "Voice Console",
                    dynamicTools: []
                )
            ),
            JSONEncoder().encode(
                CodexTaskResumeParameters(threadId: "child")
            ),
            JSONEncoder().encode(
                CodexTaskStartParameters(cwd: "/workspace")
            )
        ]

        for payload in payloads {
            let object = try jsonObject(payload)
            #expect(object["approvalPolicy"] as? String == "untrusted")
            #expect(object["approvalsReviewer"] as? String == "user")
            #expect(object["sandbox"] as? String == "workspace-write")
        }
    }

    @Test("Realtime start notifications cannot cross Voice Console task boundaries")
    func realtimeStartNotificationBoundary() throws {
        let payload = Data(
            #"{"threadId":"voice-console-thread","version":"v3"}"#.utf8
        )

        let matching = try #require(
            CodexRealtimeStartedNotification.decode(
                from: payload,
                matching: "voice-console-thread"
            )
        )

        #expect(matching.threadId == "voice-console-thread")
        #expect(matching.version == "v3")
        #expect(
            CodexRealtimeStartedNotification.decode(
                from: payload,
                matching: "another-thread"
            ) == nil
        )
        #expect(
            CodexRealtimeStartedNotification.decode(
                from: payload,
                matching: nil
            ) == nil
        )
    }

    @Test("Every media policy has one deterministic transport command sequence")
    func mediaPolicyMapping() {
        let expected: [
            CodexRealtimeMediaPolicyState: [FakeRealtimeTransport.Call]
        ] = [
            .connecting: [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ],
            .live: [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ],
            .assistantLive: [
                .setMicrophoneMuted(false),
                .setOutputMuted(false)
            ],
            .approval: [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ],
            .dormant: [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        ]

        for state in [
            CodexRealtimeMediaPolicyState.connecting,
            .live,
            .assistantLive,
            .approval,
            .dormant
        ] {
            let transport = FakeRealtimeTransport()
            let bridge = makeBridge(transport: transport)

            bridge.applyMediaPolicy(state)

            #expect(bridge.mediaPolicyState == state)
            #expect(transport.calls == expected[state])
        }
    }

    @Test("Approval always pauses both input and output before waiting")
    func approvalPausesAllMedia() {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)

        bridge.applyMediaPolicy(.assistantLive)
        transport.calls.removeAll()
        bridge.applyMediaPolicy(.approval)

        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ]
        )
        #expect(bridge.mediaPolicyState == .approval)
    }

    @Test("An unconfirmed mute rejects approval and tears media down")
    func muteConfirmationFailureFailsClosed() async throws {
        let transport = FakeRealtimeTransport()
        transport.muteConfirmationError = .connectionFailed(
            "injected mute failure"
        )
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        bridge.applyMediaPolicy(.assistantLive)
        transport.calls.removeAll()
        var events = bridge.events.makeAsyncIterator()

        await stageCommandApproval(on: bridge)

        #expect(
            try #require(await events.next()) ==
                .recoverableFailure(.voiceControlNotExposed)
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            transport.calls == [
                .confirmMediaMuted,
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(try await bridge.approvePendingAction() == .stale)
        for _ in 0..<100 {
            if await responder.responses().count == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await responder.responses().count == 1)
        let response = try #require(await responder.responses().first)
        let object = try jsonObject(response.rawResult)
        #expect(object["decision"] as? String == "decline")
    }

    @Test("Suspension mutes and resume restores live and assistant media policies")
    func suspensionRestoresActivePolicies() async {
        let expectations: [
            (
                CodexRealtimeMediaPolicyState,
                [FakeRealtimeTransport.Call]
            )
        ] = [
            (
                .live,
                [
                    .setMicrophoneMuted(false),
                    .setOutputMuted(true)
                ]
            ),
            (
                .assistantLive,
                [
                    .setMicrophoneMuted(false),
                    .setOutputMuted(false)
                ]
            )
        ]

        for (state, resumedCalls) in expectations {
            let transport = FakeRealtimeTransport()
            let bridge = makeBridge(transport: transport)
            bridge.applyMediaPolicy(state)
            transport.calls.removeAll()

            bridge.suspendVoiceMedia()

            #expect(await eventually {
                transport.calls.contains(.confirmMediaMuted)
            })
            #expect(
                transport.calls == [
                    .setMicrophoneMuted(true),
                    .setOutputMuted(true),
                    .confirmMediaMuted
                ]
            )
            #expect(bridge.mediaPolicyState == state)

            transport.calls.removeAll()
            bridge.resumeVoiceMedia()

            #expect(transport.calls == resumedCalls)
            #expect(bridge.mediaPolicyState == state)
        }
    }

    @Test("A lock mute that cannot be confirmed tears media down fail closed")
    func suspensionMuteFailureFailsClosed() async throws {
        let transport = FakeRealtimeTransport()
        transport.muteConfirmationError = .connectionFailed(
            "injected lock mute failure"
        )
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.live)
        transport.calls.removeAll()
        var events = bridge.events.makeAsyncIterator()

        bridge.suspendVoiceMedia()

        #expect(
            try #require(await events.next()) ==
                .recoverableFailure(.voiceControlNotExposed)
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .confirmMediaMuted,
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
    }

    @Test("A stale lock confirmation cannot mute a resumed session")
    func staleSuspensionConfirmationRestoresResumedPolicy() async {
        let transport = FakeRealtimeTransport()
        let confirmationGate = TestGate()
        transport.muteConfirmationGate = confirmationGate
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.live)
        transport.calls.removeAll()

        bridge.suspendVoiceMedia()
        #expect(await eventually {
            transport.calls.contains(.confirmMediaMuted)
        })
        bridge.resumeVoiceMedia()
        await confirmationGate.open()

        #expect(await eventually {
            transport.calls.suffix(2) == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        })
        #expect(bridge.mediaPolicyState == .live)
    }

    @Test("Policy changes remain logical while suspended and resume the latest policy")
    func suspendedPolicyChanges() async {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.live)
        bridge.suspendVoiceMedia()
        #expect(await eventually {
            transport.calls.contains(.confirmMediaMuted)
        })
        transport.calls.removeAll()

        bridge.applyMediaPolicy(.assistantLive)

        #expect(bridge.mediaPolicyState == .assistantLive)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ]
        )

        transport.calls.removeAll()
        bridge.resumeVoiceMedia()

        #expect(
            transport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(false)
            ]
        )
        #expect(bridge.mediaPolicyState == .assistantLive)
    }

    @Test("Dormant teardown preserves suspension until explicit resume")
    func dormantPreservesSuspension() async {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.assistantLive)
        bridge.suspendVoiceMedia()
        #expect(await eventually {
            transport.calls.contains(.confirmMediaMuted)
        })
        transport.calls.removeAll()

        bridge.applyMediaPolicy(.dormant)

        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(bridge.mediaPolicyState == .dormant)

        transport.calls.removeAll()
        bridge.applyMediaPolicy(.live)

        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ]
        )
        #expect(bridge.mediaPolicyState == .live)

        transport.calls.removeAll()
        bridge.resumeVoiceMedia()

        #expect(
            transport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        )
        #expect(bridge.mediaPolicyState == .live)
    }

    @Test("Realtime started cannot unmute a dormant suspension latch")
    func realtimeStartedCannotBypassDormantSuspension() async throws {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)
        var events = bridge.events.makeAsyncIterator()

        bridge.suspendVoiceMedia()
        #expect(transport.calls.isEmpty)

        await markRealtimeStarted(on: bridge)

        #expect(try #require(await events.next()) == .listening)
        #expect(bridge.mediaPolicyState == .live)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ]
        )
        #expect(
            !transport.calls.contains(.setMicrophoneMuted(false))
        )

        transport.calls.removeAll()
        bridge.resumeVoiceMedia()

        #expect(
            transport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        )
    }

    @Test("A media failure immediately stops capture and marks the bridge unavailable")
    func mediaFailureStopsCapture() throws {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.assistantLive)
        transport.calls.removeAll()

        let callback = try #require(transport.onFailure)
        callback(.connectionFailed("injected transport loss"))

        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            bridge.connectionState ==
                .unavailable(.voiceControlNotExposed)
        )
    }

    @Test("Publishing an approval first pauses both media directions")
    func approvalPublicationOrder() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        bridge.applyMediaPolicy(.assistantLive)
        transport.calls.removeAll()
        var events = bridge.events.makeAsyncIterator()

        await stageCommandApproval(on: bridge)
        let event = try #require(await events.next())

        guard case let .approval(title, detail) = event else {
            Issue.record("Expected an approval event.")
            return
        }
        #expect(title == "Run this command?")
        #expect(detail.contains("Action: Run a command"))
        #expect(detail.contains("Source: Voice Console"))
        #expect(detail.contains(#""command" : ["#))
        #expect(detail.contains(#""cwd" : "/tmp""#))
        #expect(detail.contains(#""threadId" : "voice-console-thread""#))
        #expect(
            transport.calls == [
                .confirmMediaMuted,
                .setMicrophoneMuted(true),
                .setOutputMuted(true)
            ]
        )
        #expect(bridge.mediaPolicyState == .approval)
    }

    @Test("Approving resumes input only after the response succeeds")
    func approvalSuccessResumesInput() async {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        await markRealtimeStarted(on: bridge)
        await stageCommandApproval(on: bridge)
        transport.calls.removeAll()

        do {
            try await bridge.approvePendingAction()
        } catch {
            Issue.record("Unexpected approval error: \(error)")
        }

        #expect(
            transport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        )
        #expect(bridge.mediaPolicyState == .live)
    }

    @Test("Approval cards expose every security-relevant field exactly")
    func approvalDetailIsCompleteAndExact() async throws {
        let commandBridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: FakeAppServerResponder(mode: .success)
        )
        var commandEvents = commandBridge.events.makeAsyncIterator()
        await commandBridge.handleServerRequest(
            id: .string("exact-command"),
            method: "item/commandExecution/requestApproval",
            params: Data(
                #"""
                {
                  "threadId":"voice-console-thread",
                  "turnId":"turn-exact",
                  "itemId":"item-exact",
                  "command":"printf 'a  b'\n\t&& echo \"$HOME\"",
                  "cwd":"/tmp/space dir",
                  "reason":"needs  exact  spacing",
                  "grantRoot":"/private/tmp/granted",
                  "proposedExecpolicyAmendment":["printf","echo"],
                  "proposedNetworkPolicyAmendments":[{"host":"example.com"}],
                  "networkApprovalContext":{"host":"example.com","port":443}
                }
                """#.utf8
            )
        )

        guard case let .approval(_, commandDetail) = try #require(
            await commandEvents.next()
        ) else {
            Issue.record("Expected a command approval.")
            return
        }
        for requiredText in [
            #"printf 'a  b'\n\t&& echo \"$HOME\""#,
            #""cwd" : "/tmp/space dir""#,
            #""grantRoot" : "/private/tmp/granted""#,
            #""proposedExecpolicyAmendment""#,
            #""proposedNetworkPolicyAmendments""#,
            #""networkApprovalContext""#,
            #""turnId" : "turn-exact""#,
            #""itemId" : "item-exact""#
        ] {
            #expect(commandDetail.contains(requiredText))
        }

        let permissionBridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: FakeAppServerResponder(mode: .success)
        )
        var permissionEvents = permissionBridge.events.makeAsyncIterator()
        await permissionBridge.handleServerRequest(
            id: .string("exact-permissions"),
            method: "item/permissions/requestApproval",
            params: Data(
                #"""
                {
                  "threadId":"voice-console-thread",
                  "turnId":"turn-permissions",
                  "itemId":"item-permissions",
                  "environmentId":"local",
                  "cwd":"/workspace",
                  "reason":"write and network",
                  "permissions":{
                    "fileSystem":{"write":["/workspace/src"]},
                    "network":{"enabled":true}
                  }
                }
                """#.utf8
            )
        )
        guard case let .approval(_, permissionDetail) = try #require(
            await permissionEvents.next()
        ) else {
            Issue.record("Expected a permissions approval.")
            return
        }
        #expect(permissionDetail.contains(#""fileSystem""#))
        #expect(permissionDetail.contains(#""/workspace/src""#))
        #expect(permissionDetail.contains(#""network""#))
        #expect(permissionDetail.contains(#""enabled" : true"#))
        #expect(permissionDetail.contains(#""environmentId" : "local""#))
    }

    @Test("Approval response failures shut down all media")
    func approvalFailureStopsMedia() async {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .failure)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        await markRealtimeStarted(on: bridge)
        await stageCommandApproval(on: bridge)
        transport.calls.removeAll()

        do {
            try await bridge.approvePendingAction()
            Issue.record("Expected approval response failure.")
        } catch let failure as CodexBridgeFailure {
            #expect(failure == .automationTimedOut)
        } catch {
            Issue.record("Unexpected approval error: \(error)")
        }

        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            bridge.connectionState == .unavailable(.automationTimedOut)
        )
        #expect((try? await bridge.approvePendingAction()) == .stale)
    }

    @Test("File approval requires and displays the latest exact diff")
    func fileApprovalIncludesExactDiff() async throws {
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await bridge.handle(
            .notification(
                method: "item/started",
                params: Data(
                    #"""
                    {
                      "threadId":"voice-console-thread",
                      "turnId":"turn-files",
                      "startedAtMs":1,
                      "item":{
                        "type":"fileChange",
                        "id":"item-files",
                        "status":"inProgress",
                        "changes":[{
                          "path":"/workspace/old.swift",
                          "kind":{"type":"update","move_path":null},
                          "diff":"-old\n+intermediate"
                        }]
                      }
                    }
                    """#.utf8
                )
            )
        )
        await bridge.handle(
            .notification(
                method: "item/fileChange/patchUpdated",
                params: Data(
                    #"""
                    {
                      "threadId":"voice-console-thread",
                      "turnId":"turn-files",
                      "itemId":"item-files",
                      "changes":[{
                        "path":"/workspace/final.swift",
                        "kind":{"type":"update","move_path":null},
                        "diff":"-before\n+after  exact"
                      }]
                    }
                    """#.utf8
                )
            )
        )
        await bridge.handleServerRequest(
            id: .string("file-approval"),
            method: "item/fileChange/requestApproval",
            params: Data(
                """
                {"threadId":"voice-console-thread","turnId":"turn-files",\
                "itemId":"item-files","reason":"apply final patch",\
                "grantRoot":"/workspace"}
                """.utf8
            )
        )

        guard case let .approval(_, detail) = try #require(
            await events.next()
        ) else {
            Issue.record("Expected a file approval.")
            return
        }
        #expect(detail.contains("Proposed file changes — paths and diffs (exact)"))
        #expect(detail.contains(#""path" : "/workspace/final.swift""#))
        #expect(detail.contains(#""diff" : "-before\n+after  exact""#))
        #expect(!detail.contains("intermediate"))
        #expect(try await bridge.approvePendingAction() == .sessionEnded)
    }

    @Test("A missing file diff is rejected instead of inviting blind approval")
    func missingFileDiffFailsClosed() async throws {
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()

        await bridge.handleServerRequest(
            id: .string("missing-diff"),
            method: "item/fileChange/requestApproval",
            params: Data(
                """
                {"threadId":"voice-console-thread","turnId":"turn-files",\
                "itemId":"item-files","reason":"unknown patch"}
                """.utf8
            )
        )

        let rejection = try #require(await responder.rejections().first)
        #expect(rejection.id == .string("missing-diff"))
        #expect(rejection.message.contains("exact file diff"))
        #expect(try await bridge.approvePendingAction() == .stale)
        #expect(
            try #require(await events.next()) ==
                .result(
                    title: "Review file changes in Codex",
                    detail: """
                    No changes were approved. Open the source task to \
                    inspect the complete diff.
                    """
                )
        )
    }

    @Test("Reject success resumes listening; reject failure stops media")
    func rejectionPaths() async {
        let successTransport = FakeRealtimeTransport()
        let successBridge = makeBridge(
            transport: successTransport,
            approvalResponder: FakeAppServerResponder(mode: .success)
        )
        await markRealtimeStarted(on: successBridge)
        await stageCommandApproval(on: successBridge)
        successTransport.calls.removeAll()

        await successBridge.rejectPendingAction()

        #expect(
            successTransport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        )
        #expect(successBridge.mediaPolicyState == .live)

        let failureTransport = FakeRealtimeTransport()
        let failureBridge = makeBridge(
            transport: failureTransport,
            approvalResponder: FakeAppServerResponder(mode: .failure)
        )
        await markRealtimeStarted(on: failureBridge)
        await stageCommandApproval(on: failureBridge)
        failureTransport.calls.removeAll()

        await failureBridge.rejectPendingAction()

        #expect(
            failureTransport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(failureBridge.mediaPolicyState == .dormant)
        #expect(
            failureBridge.connectionState ==
                .unavailable(.automationTimedOut)
        )
        #expect((try? await failureBridge.approvePendingAction()) == .stale)
    }

    @Test("Unknown requests are rejected without fake approval state")
    func unknownRequestIsNotApproval() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        bridge.applyMediaPolicy(.live)
        transport.calls.removeAll()
        var events = bridge.events.makeAsyncIterator()

        await bridge.handleServerRequest(
            id: .string("unknown-1"),
            method: "future/unknown/request",
            params: Data(#"{"secret":"must-not-surface"}"#.utf8)
        )

        #expect(bridge.mediaPolicyState == .live)
        #expect(transport.calls.isEmpty)
        let rejection = try #require(await responder.rejections().first)
        #expect(rejection.id == .string("unknown-1"))
        #expect(rejection.code == -32_601)
        #expect(!rejection.message.contains("secret"))

        await stageCommandApproval(on: bridge)
        let event = try #require(await events.next())
        guard case let .approval(title, detail) = event else {
            Issue.record("Expected an approval event.")
            return
        }
        #expect(title == "Run this command?")
        #expect(detail.contains(#""command" : ["#))
        #expect(detail.contains(#""cwd" : "/tmp""#))
    }

    @Test("Automatic protocol duties never disturb a genuine approval")
    func automaticProtocolDutiesPreserveApproval() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        _ = try #require(await events.next())
        await stageCommandApproval(on: bridge)
        _ = try #require(await events.next())
        transport.calls.removeAll()

        await bridge.handleServerRequest(
            id: .integer(51),
            method: "item/tool/requestUserInput",
            params: Data(
                """
                {"threadId":"voice-console-thread","questions":[\
                {"id":"password","isSecret":true,"question":"private"}]}
                """.utf8
            )
        )
        await bridge.handleServerRequest(
            id: .integer(52),
            method: "mcpServer/elicitation/request",
            params: Data(
                """
                {"threadId":"voice-console-thread","mode":"url",\
                "url":"https://example.invalid/private"}
                """.utf8
            )
        )
        let before = Int64(Date().timeIntervalSince1970.rounded(.down))
        await bridge.handleServerRequest(
            id: .integer(53),
            method: "currentTime/read",
            params: Data(
                #"{"threadId":"voice-console-thread"}"#.utf8
            )
        )
        let after = Int64(Date().timeIntervalSince1970.rounded(.down))

        #expect(bridge.mediaPolicyState == .approval)
        #expect(transport.calls.isEmpty)

        let responses = await responder.responses()
        #expect(responses.count == 3)
        let input = try jsonObject(responses[0].rawResult)
        #expect((input["answers"] as? [String: Any])?.isEmpty == true)
        #expect(
            String(data: responses[0].rawResult, encoding: .utf8)?
                .contains("private") == false
        )

        let elicitation = try jsonObject(responses[1].rawResult)
        #expect(elicitation["action"] as? String == "decline")
        #expect(elicitation["content"] is NSNull)
        #expect(elicitation["_meta"] is NSNull)

        let currentTime = try jsonObject(responses[2].rawResult)
        let currentTimeAt = try #require(
            (currentTime["currentTimeAt"] as? NSNumber)?.int64Value
        )
        #expect((before...after).contains(currentTimeAt))

        try await bridge.approvePendingAction()
        #expect(bridge.mediaPolicyState == .live)
        #expect(await responder.responses().count == 4)
    }

    @Test("Wrong-task and malformed automatic requests are isolated")
    func wrongTaskRequestsAreIsolated() async {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        bridge.applyMediaPolicy(.live)
        transport.calls.removeAll()

        for (index, method, params) in [
            (
                61,
                "item/tool/requestUserInput",
                #"{"threadId":"another-thread","questions":[]}"#
            ),
            (
                62,
                "mcpServer/elicitation/request",
                #"{"threadId":"another-thread","mode":"form"}"#
            ),
            (
                63,
                "currentTime/read",
                #"{"threadId":"another-thread"}"#
            ),
            (
                64,
                "item/commandExecution/requestApproval",
                #"{"threadId":"another-thread","command":"echo unsafe"}"#
            ),
            (
                65,
                "execCommandApproval",
                #"{"conversationId":"another-thread","command":["echo"]}"#
            )
        ] {
            await bridge.handleServerRequest(
                id: .integer(index),
                method: method,
                params: Data(params.utf8)
            )
        }

        #expect(bridge.mediaPolicyState == .live)
        #expect(transport.calls.isEmpty)
        #expect(await responder.responses().isEmpty)
        let rejections = await responder.rejections()
        #expect(rejections.count == 5)
        #expect(rejections.allSatisfy { $0.code == -32_602 })
    }

    @Test("Authentication-token and attestation requests fail closed")
    func forbiddenConnectionRequestsFailClosed() async throws {
        let authTransport = FakeRealtimeTransport()
        let authResponder = FakeAppServerResponder(mode: .success)
        let authBridge = makeBridge(
            transport: authTransport,
            approvalResponder: authResponder
        )
        authBridge.applyMediaPolicy(.assistantLive)
        authTransport.calls.removeAll()
        var authEvents = authBridge.events.makeAsyncIterator()

        await authBridge.handleServerRequest(
            id: .integer(71),
            method: "account/chatgptAuthTokens/refresh",
            params: Data(#"{"reason":"unauthorized"}"#.utf8)
        )

        #expect(
            authBridge.connectionState ==
                .unavailable(.subscriptionAuthenticationRequired)
        )
        #expect(authBridge.mediaPolicyState == .dormant)
        #expect(
            authTransport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        let authRejection = try #require(
            await authResponder.rejections().first
        )
        #expect(authRejection.code == -32_000)
        #expect(
            try #require(await authEvents.next()) ==
                .recoverableFailure(.subscriptionAuthenticationRequired)
        )

        let attestationTransport = FakeRealtimeTransport()
        let attestationResponder = FakeAppServerResponder(mode: .success)
        let attestationBridge = makeBridge(
            transport: attestationTransport,
            approvalResponder: attestationResponder
        )
        attestationBridge.applyMediaPolicy(.live)

        await attestationBridge.handleServerRequest(
            id: .integer(72),
            method: "attestation/generate",
            params: Data("{}".utf8)
        )

        #expect(attestationBridge.mediaPolicyState == .dormant)
        let attestationRejection = try #require(
            await attestationResponder.rejections().first
        )
        #expect(attestationRejection.code == -32_601)
        #expect(await attestationResponder.responses().isEmpty)
    }

    @Test("Only an exact resolution clears the pending approval")
    func serverResolutionIsExactAndStaleClicksAreHarmless() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await bridge.handle(
            .notification(
                method: "thread/realtime/started",
                params: Data(
                    #"{"threadId":"voice-console-thread","version":"v3"}"#.utf8
                )
            )
        )
        #expect(try #require(await events.next()) == .listening)
        await stageCommandApproval(on: bridge)
        _ = try #require(await events.next())
        transport.calls.removeAll()

        await bridge.handle(
            .notification(
                method: "serverRequest/resolved",
                params: Data(
                    #"{"threadId":"another-thread","requestId":42}"#.utf8
                )
            )
        )
        await bridge.handle(
            .notification(
                method: "serverRequest/resolved",
                params: Data(
                    #"{"threadId":"voice-console-thread","requestId":"42"}"#.utf8
                )
            )
        )
        #expect(bridge.mediaPolicyState == .approval)
        #expect(transport.calls.isEmpty)

        await bridge.handle(
            .notification(
                method: "serverRequest/resolved",
                params: Data(
                    #"{"threadId":"voice-console-thread","requestId":42}"#.utf8
                )
            )
        )
        #expect(try #require(await events.next()) == .listening)
        #expect(bridge.mediaPolicyState == .live)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(false),
                .setOutputMuted(true)
            ]
        )

        try await bridge.approvePendingAction()
        await bridge.rejectPendingAction()
        #expect(await responder.responses().isEmpty)
        #expect(await responder.rejections().isEmpty)
        #expect(bridge.connectionState == .ready(taskIdentifier: "voice-console-thread"))
    }

    @Test("External resolution cannot corrupt an approval response in flight")
    func resolutionRaceIsHarmless() async throws {
        let approveTransport = FakeRealtimeTransport()
        let approveResponder = FakeAppServerResponder(mode: .gatedSuccess)
        let approveBridge = makeBridge(
            transport: approveTransport,
            approvalResponder: approveResponder
        )
        var approveEvents = approveBridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: approveBridge)
        _ = try #require(await approveEvents.next())
        await stageCommandApproval(on: approveBridge)
        _ = try #require(await approveEvents.next())

        let approveTask = Task { @MainActor in
            try await approveBridge.approvePendingAction()
        }
        await approveResponder.waitUntilRequestBegins()
        await resolveCommandApproval(on: approveBridge)

        #expect(approveBridge.mediaPolicyState == .approval)
        #expect(
            approveBridge.connectionState ==
                .ready(taskIdentifier: "voice-console-thread")
        )

        await approveResponder.releaseRequest()
        let approveResult = try await approveTask.value

        #expect(approveResult == .stale)
        #expect(try #require(await approveEvents.next()) == .listening)
        #expect(approveBridge.mediaPolicyState == .live)
        #expect(
            approveBridge.connectionState ==
                .ready(taskIdentifier: "voice-console-thread")
        )
        #expect(await approveResponder.responses().count == 1)

        let rejectTransport = FakeRealtimeTransport()
        let rejectResponder = FakeAppServerResponder(mode: .gatedSuccess)
        let rejectBridge = makeBridge(
            transport: rejectTransport,
            approvalResponder: rejectResponder
        )
        var rejectEvents = rejectBridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: rejectBridge)
        _ = try #require(await rejectEvents.next())
        await stageCommandApproval(on: rejectBridge)
        _ = try #require(await rejectEvents.next())

        let rejectTask = Task { @MainActor in
            await rejectBridge.rejectPendingAction()
        }
        await rejectResponder.waitUntilRequestBegins()
        await resolveCommandApproval(on: rejectBridge)

        #expect(rejectBridge.mediaPolicyState == .approval)
        await rejectResponder.releaseRequest()
        let rejectResult = await rejectTask.value

        #expect(rejectResult == .stale)
        #expect(try #require(await rejectEvents.next()) == .listening)
        #expect(rejectBridge.mediaPolicyState == .live)
        #expect(
            rejectBridge.connectionState ==
                .ready(taskIdentifier: "voice-console-thread")
        )
        #expect(await rejectResponder.responses().count == 1)
    }

    @Test("Auth-mode changes away from ChatGPT stop active media")
    func authModeChangeStopsMedia() async {
        let transport = FakeRealtimeTransport()
        let bridge = makeBridge(transport: transport)
        bridge.applyMediaPolicy(.assistantLive)
        transport.calls.removeAll()

        await bridge.handle(
            .notification(
                method: "account/updated",
                params: Data(
                    #"{"authMode":"apikey","planType":null}"#.utf8
                )
            )
        )

        #expect(
            bridge.connectionState ==
                .unavailable(.subscriptionAuthenticationRequired)
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )

        let malformedBridge = makeBridge(
            transport: FakeRealtimeTransport()
        )
        await malformedBridge.handle(
            .notification(
                method: "account/updated",
                params: Data(#"{"authMode":42}"#.utf8)
            )
        )
        #expect(
            malformedBridge.connectionState ==
                .unavailable(.subscriptionAuthenticationRequired)
        )
        #expect(malformedBridge.mediaPolicyState == .dormant)
    }

    @Test("Auth failure rejects later approvals until fresh verification")
    func authFailureInvalidatesApprovalEpoch() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        #expect(try #require(await events.next()) == .listening)
        transport.calls.removeAll()

        await bridge.handle(
            .notification(
                method: "account/updated",
                params: Data(
                    #"{"authMode":"apikey","planType":null}"#.utf8
                )
            )
        )
        #expect(
            try #require(await events.next()) ==
                .recoverableFailure(.subscriptionAuthenticationRequired)
        )

        // A later notification is not proof that both account/read and
        // getAuthStatus passed, so it must not silently reopen the epoch.
        await bridge.handle(
            .notification(
                method: "account/updated",
                params: Data(
                    #"{"authMode":"chatgpt","planType":"plus"}"#.utf8
                )
            )
        )
        let requestID = CodexAppServerRequestID.string("after-auth-failure")
        await bridge.handleServerRequest(
            id: requestID,
            method: "item/commandExecution/requestApproval",
            params: Data(
                """
                {"threadId":"voice-console-thread",\
                "command":["echo","must-not-run"],"cwd":"/tmp"}
                """.utf8
            )
        )

        #expect(try await bridge.approvePendingAction() == .stale)
        #expect(await responder.responses().isEmpty)
        let rejection = try #require(await responder.rejections().first)
        #expect(rejection.id == requestID)
        #expect(
            rejection.message ==
                "No active authenticated Voice Console session."
        )

        await markRealtimeStarted(on: bridge)
        #expect(
            bridge.connectionState ==
                .unavailable(.subscriptionAuthenticationRequired)
        )
        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            transport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
    }

    @Test("One-button stop rejects every later approval request")
    func stopInvalidatesApprovalEpoch() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        #expect(try #require(await events.next()) == .listening)

        await bridge.stopVoiceConversation()
        await bridge.handle(
            .notification(
                method: "account/updated",
                params: Data(
                    #"{"authMode":"chatgpt","planType":"plus"}"#.utf8
                )
            )
        )
        let requestID = CodexAppServerRequestID.string("after-stop")
        await bridge.handleServerRequest(
            id: requestID,
            method: "item/commandExecution/requestApproval",
            params: Data(
                """
                {"threadId":"voice-console-thread",\
                "command":["echo","must-not-run"],"cwd":"/tmp"}
                """.utf8
            )
        )
        for (id, method, params) in [
            (
                CodexAppServerRequestID.string("input-after-stop"),
                "item/tool/requestUserInput",
                #"{"threadId":"voice-console-thread","questions":[]}"#
            ),
            (
                .string("elicitation-after-stop"),
                "mcpServer/elicitation/request",
                #"{"threadId":"voice-console-thread","mode":"form"}"#
            ),
            (
                .string("time-after-stop"),
                "currentTime/read",
                #"{"threadId":"voice-console-thread"}"#
            )
        ] {
            await bridge.handleServerRequest(
                id: id,
                method: method,
                params: Data(params.utf8)
            )
        }

        #expect(try await bridge.approvePendingAction() == .stale)
        #expect(await responder.responses().isEmpty)
        let rejections = await responder.rejections()
        #expect(rejections.count == 4)
        #expect(rejections.contains { $0.id == requestID })
        #expect(
            rejections.allSatisfy {
                $0.code == -32_000
                    && $0.message
                        == "No active authenticated Voice Console session."
            }
        )
        #expect(bridge.mediaPolicyState == .dormant)
    }

    @Test("Disconnect and explicit stop both terminate local media")
    func terminalPathsStopMedia() async {
        let disconnectTransport = FakeRealtimeTransport()
        let disconnectBridge = makeBridge(
            transport: disconnectTransport
        )
        disconnectBridge.applyMediaPolicy(.assistantLive)
        disconnectTransport.calls.removeAll()

        await disconnectBridge.handle(
            .disconnected("injected app-server loss")
        )

        #expect(
            disconnectTransport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(disconnectBridge.mediaPolicyState == .dormant)
        #expect(
            disconnectBridge.connectionState ==
                .unavailable(.applicationUnavailable)
        )

        let stopTransport = FakeRealtimeTransport()
        let stopBridge = makeBridge(transport: stopTransport)
        stopBridge.applyMediaPolicy(.assistantLive)
        stopTransport.calls.removeAll()

        await stopBridge.stopVoiceConversation()

        #expect(
            stopTransport.calls == [
                .setMicrophoneMuted(true),
                .setOutputMuted(true),
                .stop
            ]
        )
        #expect(stopBridge.mediaPolicyState == .dormant)
    }

    @Test("Stopping from Approval declines and invalidates the exact request")
    func stopDeclinesPendingApproval() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        await stageCommandApproval(on: bridge)

        await bridge.stopVoiceConversation()

        #expect(bridge.mediaPolicyState == .dormant)
        #expect(
            try await bridge.approvePendingAction() == .stale
        )
        let response = try #require(await responder.responses().first)
        let object = try jsonObject(response.rawResult)
        #expect(object["decision"] as? String == "decline")
    }

    @Test("A terminal event during approval is surfaced and cannot resurrect it")
    func terminalEventDuringApproval() async throws {
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .gatedSuccess)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        _ = try #require(await events.next())
        await stageCommandApproval(on: bridge)
        _ = try #require(await events.next())

        let approval = Task { @MainActor in
            try await bridge.approvePendingAction()
        }
        await responder.waitUntilRequestBegins()
        await bridge.handle(
            .notification(
                method: "account/updated",
                params: Data(
                    #"{"authMode":"apikey","planType":null}"#.utf8
                )
            )
        )

        #expect(
            try #require(await events.next()) ==
                .recoverableFailure(.subscriptionAuthenticationRequired)
        )
        #expect(bridge.mediaPolicyState == .dormant)
        await responder.releaseRequest()
        #expect(try await approval.value == .sessionEnded)
        #expect(try await bridge.approvePendingAction() == .stale)
        #expect(await responder.responses().isEmpty)
    }

    @Test("One-button stop cancels an accept at the response write boundary")
    func stopCancelsApprovalResponseWrite() async throws {
        let responder = FakeAppServerResponder(mode: .gatedSuccess)
        let bridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: responder
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        _ = try #require(await events.next())
        await stageCommandApproval(on: bridge)
        _ = try #require(await events.next())

        let approval = Task { @MainActor in
            try await bridge.approvePendingAction()
        }
        await responder.waitUntilRequestBegins()

        await bridge.stopVoiceConversation()
        await responder.releaseRequest()

        #expect(try await approval.value == .sessionEnded)
        #expect(await responder.responses().isEmpty)
        #expect(try await bridge.approvePendingAction() == .stale)
        #expect(bridge.mediaPolicyState == .dormant)
    }

    @Test("Coordinated-task approvals restore the exact Voice Console state")
    func coordinatedTaskApprovalRestoresVoiceState() async throws {
        let fixture = try FakeCodexExecutable(behavior: .taskFlow)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)
        try await client.start()
        defer {
            Task {
                await client.stop()
            }
        }
        let transport = FakeRealtimeTransport()
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: transport,
            approvalResponder: responder,
            appServerClient: client
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        _ = try #require(await events.next())
        await stageSendTaskToolApproval(
            on: bridge,
            id: .string("task-tool")
        )
        _ = try #require(await events.next())

        #expect(try await bridge.approvePendingAction() == .completed)
        #expect(try #require(await events.next()) == .thinking)

        await bridge.handle(
            .notification(
                method: "thread/realtime/transcript/delta",
                params: Data(
                    """
                    {"threadId":"voice-console-thread",\
                    "role":"assistant","delta":"speaking"}
                    """.utf8
                )
            )
        )
        #expect(try #require(await events.next()) == .speaking)
        #expect(bridge.mediaPolicyState == .assistantLive)

        await bridge.handleServerRequest(
            id: .string("child-command"),
            method: "item/commandExecution/requestApproval",
            params: Data(
                """
                {"threadId":"target-thread","turnId":"coordinated-turn",\
                "itemId":"child-item","command":"echo child"}
                """.utf8
            )
        )
        guard case let .approval(_, detail) = try #require(
            await events.next()
        ) else {
            Issue.record("Expected a coordinated-task approval.")
            return
        }
        #expect(detail.contains("Source: Coordinated task target-thread"))
        #expect(bridge.mediaPolicyState == .approval)

        #expect(try await bridge.approvePendingAction() == .completed)
        #expect(try #require(await events.next()) == .speaking)
        #expect(bridge.mediaPolicyState == .assistantLive)
        #expect(await responder.responses().count == 2)
        await client.stop()
    }

    @Test("Cancellation after turn start is accepted interrupts that exact turn")
    func coordinatedTaskTurnCancellationIsClosed() async throws {
        let fixture = try FakeCodexExecutable(behavior: .gatedTurnStart)
        defer { fixture.remove() }
        let client = CodexAppServerClient(executableURL: fixture.url)
        try await client.start()
        defer {
            Task {
                await client.stop()
            }
        }
        let responder = FakeAppServerResponder(mode: .success)
        let bridge = makeBridge(
            transport: FakeRealtimeTransport(),
            approvalResponder: responder,
            appServerClient: client
        )
        var events = bridge.events.makeAsyncIterator()
        await markRealtimeStarted(on: bridge)
        _ = try #require(await events.next())
        await stageSendTaskToolApproval(
            on: bridge,
            id: .string("cancel-tool")
        )
        _ = try #require(await events.next())

        let approval = Task { @MainActor in
            try await bridge.approvePendingAction()
        }
        #expect(await eventually(timeout: .seconds(2)) {
            fixture.methods().contains("turn/start")
        })
        await bridge.handle(
            .notification(
                method: "serverRequest/resolved",
                params: Data(
                    """
                    {"threadId":"voice-console-thread",\
                    "requestId":"cancel-tool"}
                    """.utf8
                )
            )
        )
        #expect(try #require(await events.next()) == .listening)

        try fixture.releaseTurnStart()
        let approvalResult = try await approval.value
        #expect(approvalResult == .stale)
        #expect(await eventually(timeout: .seconds(2)) {
            fixture.methods().contains("turn/interrupt")
        })
        #expect(await responder.responses().isEmpty)
        await client.stop()
    }

    private func makeBridge(
        transport: FakeRealtimeTransport,
        approvalResponder: (any CodexAppServerResponding)? = nil,
        appServerClient: CodexAppServerClient? = nil
    ) -> CodexAppServerBridge {
        let suiteName = "CodexBridgeSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
            ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return CodexAppServerBridge(
            mediaTransport: transport,
            defaults: defaults,
            approvalResponder: approvalResponder,
            voiceConsoleThreadIdentifier: "voice-console-thread",
            appServerClient: appServerClient
        )
    }

    private func stageCommandApproval(
        on bridge: CodexAppServerBridge
    ) async {
        await bridge.handleServerRequest(
            id: .integer(42),
            method: "item/commandExecution/requestApproval",
            params: Data(
                """
                {"threadId":"voice-console-thread",\
                "command":["echo","hello"],"cwd":"/tmp"}
                """.utf8
            )
        )
    }

    private func stageSendTaskToolApproval(
        on bridge: CodexAppServerBridge,
        id: CodexAppServerRequestID
    ) async {
        await bridge.handleServerRequest(
            id: id,
            method: "item/tool/call",
            params: Data(
                """
                {"threadId":"voice-console-thread","turnId":"voice-turn",\
                "callId":"call-send","namespace":"codex_tasks",\
                "tool":"send_message_to_thread","arguments":{\
                "threadId":"target-thread","prompt":"Continue the audit",\
                "intent":"followUp"}}
                """.utf8
            )
        )
    }

    private func markRealtimeStarted(
        on bridge: CodexAppServerBridge
    ) async {
        await bridge.handle(
            .notification(
                method: "thread/realtime/started",
                params: Data(
                    #"{"threadId":"voice-console-thread","version":"v3"}"#.utf8
                )
            )
        )
    }

    private func resolveCommandApproval(
        on bridge: CodexAppServerBridge
    ) async {
        await bridge.handle(
            .notification(
                method: "serverRequest/resolved",
                params: Data(
                    #"{"threadId":"voice-console-thread","requestId":42}"#.utf8
                )
            )
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

@Suite("Voice Console task tools")
struct CodexTaskToolCatalogTests {
    private let voiceConsoleID = "voice-console-thread"

    @Test("The catalog exposes only the bounded four-task surface")
    func catalogSurface() throws {
        let namespace = try #require(
            CodexTaskToolCatalog.specifications.first
        )

        #expect(CodexTaskToolCatalog.specifications.count == 1)
        #expect(namespace.name == "codex_tasks")
        #expect(
            namespace.tools.map(\.name) == [
                "list_threads",
                "read_thread",
                "create_thread",
                "send_message_to_thread"
            ]
        )

        let encoded = try JSONEncoder().encode(namespace)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        #expect(object["type"] as? String == "namespace")
        #expect(object["name"] as? String == "codex_tasks")
    }

    @Test("Read-only task tools never request mutation approval")
    func readOnlyActions() throws {
        let list = try action(
            tool: "list_threads",
            arguments: [:]
        )
        let inspect = try action(
            tool: "read_thread",
            arguments: ["threadId": .string("target-thread")]
        )

        #expect(list == .list(limit: 20, searchTerm: nil))
        #expect(inspect == .inspect(threadId: "target-thread"))
        #expect(!list.requiresConfirmation)
        #expect(!inspect.requiresConfirmation)
    }

    @Test("Creation and cross-task messages always request approval")
    func mutatingActions() throws {
        let create = try action(
            tool: "create_thread",
            arguments: [
                "prompt": .string("Investigate the regression"),
                "name": .string("Regression audit"),
                "cwd": .string("/tmp/workspace")
            ]
        )
        let send = try action(
            tool: "send_message_to_thread",
            arguments: [
                "threadId": .string("target-thread"),
                "prompt": .string("Continue the bounded audit"),
                "intent": .string("handoff")
            ]
        )

        #expect(create.requiresConfirmation)
        #expect(send.requiresConfirmation)
        #expect(create.approvalTitle == "Create this Codex task?")
        #expect(send.approvalTitle == "Hand off this work?")
        #expect(create.approvalDetail.contains("Regression audit"))
        #expect(send.approvalDetail.contains("target-thread"))
        #expect(create.approvalDetail.hasPrefix("Request:"))
        #expect(send.approvalDetail.hasPrefix("Request:"))
        #expect(
            send.approvalDetail.range(of: "Request:")!.lowerBound
                < send.approvalDetail.range(of: "Target task:")!.lowerBound
        )
    }

    @Test("Calls cannot escape the Voice Console namespace or origin task")
    func originBoundary() {
        #expect(throws: CodexTaskToolFailure.wrongNamespace) {
            try action(
                namespace: "other_namespace",
                tool: "list_threads",
                arguments: [:]
            )
        }
        #expect(throws: CodexTaskToolFailure.wrongThread) {
            try action(
                sourceThreadID: "another-thread",
                tool: "list_threads",
                arguments: [:]
            )
        }
    }

    @Test("Invalid limits, paths, intents, and self-messages are rejected")
    func argumentBoundary() {
        #expect(throws: CodexTaskToolFailure.self) {
            try action(
                tool: "list_threads",
                arguments: ["limit": .integer(26)]
            )
        }
        #expect(throws: CodexTaskToolFailure.self) {
            try action(
                tool: "create_thread",
                arguments: [
                    "prompt": .string("Do the work"),
                    "cwd": .string("relative/path")
                ]
            )
        }
        #expect(throws: CodexTaskToolFailure.self) {
            try action(
                tool: "send_message_to_thread",
                arguments: [
                    "threadId": .string(voiceConsoleID),
                    "prompt": .string("Loop this back"),
                    "intent": .string("followUp")
                ]
            )
        }
        #expect(throws: CodexTaskToolFailure.self) {
            try action(
                tool: "send_message_to_thread",
                arguments: [
                    "threadId": .string("target-thread"),
                    "prompt": .string("Do the work"),
                    "intent": .string("unknown")
                ]
            )
        }
    }

    @Test("Maximum task prompts remain complete in the scrollable approval")
    func approvalSummaryIsComplete() throws {
        let tail = "UNTRUNCATED-SECURITY-TAIL"
        let prompt = String(repeating: "x", count: 19_000) + tail
        let create = try action(
            tool: "create_thread",
            arguments: [
                "prompt": .string(prompt)
            ]
        )

        #expect(create.approvalDetail.contains(tail))
        #expect(create.approvalDetail.contains(prompt))
        #expect(!create.approvalDetail.hasSuffix("…"))
    }

    private func action(
        namespace: String? = "codex_tasks",
        sourceThreadID: String? = nil,
        tool: String,
        arguments: [String: CodexJSONValue]
    ) throws -> CodexTaskToolAction {
        try CodexTaskToolCatalog.action(
            for: CodexDynamicToolCallParameters(
                threadId: sourceThreadID ?? voiceConsoleID,
                turnId: "turn-1",
                callId: "call-1",
                namespace: namespace,
                tool: tool,
                arguments: arguments
            ),
            voiceConsoleThreadId: voiceConsoleID
        )
    }
}

@MainActor
private final class FakeRealtimeTransport: RealtimeVoiceTransporting {
    enum Call: Equatable {
        case start
        case prepareOffer
        case acceptAnswer(String)
        case interrupt
        case confirmMediaMuted
        case setMicrophoneMuted(Bool)
        case setOutputMuted(Bool)
        case stop
    }

    var onFailure: (@MainActor (RealtimeWebRTCFailure) -> Void)?
    var calls: [Call] = []
    var muteConfirmationError: RealtimeWebRTCFailure?
    var muteConfirmationGate: TestGate?

    func start() async throws {
        calls.append(.start)
    }

    func prepareOffer() async throws -> String {
        calls.append(.prepareOffer)
        return "fake-offer"
    }

    func acceptAnswer(_ sdp: String) async throws {
        calls.append(.acceptAnswer(sdp))
    }

    func interrupt() async throws {
        calls.append(.interrupt)
    }

    func confirmMediaMuted() async throws {
        calls.append(.confirmMediaMuted)
        if let muteConfirmationGate {
            await muteConfirmationGate.wait()
        }
        if let muteConfirmationError {
            throw muteConfirmationError
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        calls.append(.setMicrophoneMuted(muted))
    }

    func setOutputMuted(_ muted: Bool) {
        calls.append(.setOutputMuted(muted))
    }

    func stop() {
        calls.append(.stop)
    }
}

private actor FakeAppServerResponder: CodexAppServerResponding {
    enum Mode: Equatable, Sendable {
        case success
        case failure
        case gatedSuccess
    }

    struct RecordedResponse: Sendable {
        let id: CodexAppServerRequestID
        let rawResult: Data
    }

    struct RecordedRejection: Sendable {
        let id: CodexAppServerRequestID
        let code: Int
        let message: String
    }

    private let mode: Mode
    private var recordedResponses: [RecordedResponse] = []
    private var recordedRejections: [RecordedRejection] = []
    private var requestDidBegin = false
    private var requestStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseGate: CheckedContinuation<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
    }

    func respond(
        to id: CodexAppServerRequestID,
        rawResult: Data
    ) async throws {
        if mode == .failure {
            throw TestFailure.injected
        }
        try Task.checkCancellation()
        await pauseIfGated()
        try Task.checkCancellation()
        recordedResponses.append(
            RecordedResponse(id: id, rawResult: rawResult)
        )
    }

    func reject(
        _ id: CodexAppServerRequestID,
        code: Int,
        message: String
    ) async throws {
        if mode == .failure {
            throw TestFailure.injected
        }
        try Task.checkCancellation()
        await pauseIfGated()
        try Task.checkCancellation()
        recordedRejections.append(
            RecordedRejection(
                id: id,
                code: code,
                message: message
            )
        )
    }

    func responses() -> [RecordedResponse] {
        recordedResponses
    }

    func rejections() -> [RecordedRejection] {
        recordedRejections
    }

    func waitUntilRequestBegins() async {
        if requestDidBegin {
            return
        }
        await withCheckedContinuation { continuation in
            requestStartWaiters.append(continuation)
        }
    }

    func releaseRequest() {
        responseGate?.resume()
        responseGate = nil
    }

    private func pauseIfGated() async {
        guard mode == .gatedSuccess else { return }
        requestDidBegin = true
        let waiters = requestStartWaiters
        requestStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            responseGate = continuation
        }
    }
}
