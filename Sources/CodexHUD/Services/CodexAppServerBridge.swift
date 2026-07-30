import Foundation
import OSLog

private struct EmptyCodexResponse: Codable, Sendable {}

private struct CodexThreadSummary: Decodable, Sendable {
    let id: String
    let name: String?
}

private struct CodexThreadListParameters: Encodable, Sendable {
    let searchTerm: String
    let limit: Int
    let archived = false
    let sortKey = "updated_at"
    let sortDirection = "desc"
}

private struct CodexThreadListResponse: Decodable, Sendable {
    let data: [CodexThreadSummary]
}

private struct CodexThreadEnvelope: Decodable, Sendable {
    let thread: CodexThreadSummary
}

struct CodexThreadResumeParameters: Encodable, Sendable {
    let threadId: String
    let excludeTurns = true
    // Voice control must never let the model silently decide that a mutation
    // is safe. `untrusted` keeps known read-only commands frictionless while
    // forcing patches and unsafe commands through an app-server approval.
    let approvalPolicy = "untrusted"
    let approvalsReviewer = "user"
    let sandbox = "workspace-write"
}

struct CodexThreadStartParameters: Encodable, Sendable {
    let cwd: String
    let ephemeral = false
    let approvalPolicy = "untrusted"
    let approvalsReviewer = "user"
    let sandbox = "workspace-write"
    let developerInstructions: String
    let dynamicTools: [CodexDynamicToolNamespaceSpec]
}

private struct CodexThreadSetNameParameters: Encodable, Sendable {
    let threadId: String
    let name: String
}

private struct CodexRealtimeTransportParameters: Encodable, Sendable {
    let type = "webrtc"
    let sdp: String
}

private struct CodexRealtimeStartParameters: Encodable, Sendable {
    let threadId: String
    let outputModality = "audio"
    let transport: CodexRealtimeTransportParameters
    let version = "v3"
    let voice = "cove"
    let includeStartupContext = true
    let flushTranscriptTailOnSessionEnd = true
    let clientManagedHandoffs = false
    let codexResponseHandoffMode = "thinking"
    let prompt: String
}

private struct CodexThreadIdentifierParameters: Encodable, Sendable {
    let threadId: String
}

private struct CodexTurnInterruptParameters: Encodable, Sendable {
    let threadId: String
    let turnId: String
}

private struct CodexRealtimeSDPNotification: Decodable, Sendable {
    let threadId: String
    let sdp: String
}

struct CodexRealtimeStartedNotification: Decodable, Sendable {
    let threadId: String
    let version: String

    static func decode(
        from data: Data,
        matching expectedThreadId: String?
    ) -> Self? {
        guard
            let notification = try? JSONDecoder().decode(Self.self, from: data),
            notification.threadId == expectedThreadId
        else {
            return nil
        }
        return notification
    }
}

private struct CodexRealtimeTranscriptDelta: Decodable, Sendable {
    let threadId: String
    let role: String
    let delta: String
}

private struct CodexRealtimeTranscriptDone: Decodable, Sendable {
    let threadId: String
    let role: String
    let text: String
}

private struct CodexRealtimeErrorNotification: Decodable, Sendable {
    let threadId: String
    let message: String
}

private struct CodexRealtimeClosedNotification: Decodable, Sendable {
    let threadId: String
    let reason: String?
}

private struct CodexThreadScopedNotification: Decodable, Sendable {
    let threadId: String
}

private struct CodexFileChangeKey: Hashable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
}

private struct CodexFileChangeItemStartedNotification: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let type: String
        let id: String
        let changes: [CodexJSONValue]?
    }

    let threadId: String
    let turnId: String
    let item: Item
}

private struct CodexFileChangePatchUpdatedNotification: Decodable, Sendable {
    let threadId: String
    let turnId: String
    let itemId: String
    let changes: [CodexJSONValue]
}

private struct CodexServerRequestResolvedNotification: Decodable, Sendable {
    let threadId: String
    let requestId: CodexAppServerRequestID
}

private struct CodexAccountUpdatedNotification: Decodable, Sendable {
    let authMode: String?
}

struct CodexAccountReadParameters: Encodable, Sendable {
    let refreshToken = false
}

struct CodexAuthStatusParameters: Encodable, Sendable {
    let includeToken = false
    let refreshToken = false
}

struct CodexAccountReadResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let type: String
    }

    let account: Account?
    let requiresOpenaiAuth: Bool

    func requireChatGPTSubscription() throws {
        guard
            account?.type == "chatgpt",
            requiresOpenaiAuth
        else {
            throw CodexBridgeFailure.subscriptionAuthenticationRequired
        }
    }
}

struct CodexAuthStatusResponse: Decodable, Sendable {
    let authMethod: String?
    let authToken: String?
    let requiresOpenaiAuth: Bool?

    func requireCodexManagedChatGPTAuthentication() throws {
        guard
            authMethod == "chatgpt",
            authToken == nil,
            requiresOpenaiAuth == true
        else {
            throw CodexBridgeFailure.subscriptionAuthenticationRequired
        }
    }
}

private struct CodexCurrentTimeResponse: Encodable, Sendable {
    let currentTimeAt: Int64
}

private struct CodexApprovalDecision: Encodable, Sendable {
    let decision: String
}

private struct CodexLegacyDenial: Encodable, Sendable {
    struct Decision: Encodable, Sendable {
        struct Denied: Encodable, Sendable {
            let rejection: String
        }

        let denied: Denied
    }

    let decision: Decision
}

private enum PendingApprovalKind: Sendable {
    case command
    case fileChange
    case legacy
    case permissions
    case taskTool
}

private struct PendingCodexApproval: Sendable {
    let id: CodexAppServerRequestID
    let sourceThreadIdentifier: String
    let method: String
    let params: Data
    let kind: PendingApprovalKind
    let restorationMediaPolicy: CodexRealtimeMediaPolicyState
    let restorationEvent: CodexBridgeEvent?
}

enum CodexRealtimeMediaPolicyState: Equatable, Sendable {
    case connecting
    case live
    case assistantLive
    case approval
    case dormant
}

/// Subscription-authenticated Codex control backed by the official bundled
/// app-server and its WebRTC transport.
///
/// The bridge owns only transient protocol state. The sole persisted value is
/// the official Codex thread identifier for the task named "Voice Console".
/// Audio is never recorded and transcript notification text is never retained.
@MainActor
final class CodexAppServerBridge: CodexControlling {
    private(set) var connectionState: CodexConnectionState = .disconnected
    private(set) var mediaPolicyState: CodexRealtimeMediaPolicyState = .dormant
    let events: AsyncStream<CodexBridgeEvent>

    private static let voiceConsoleName = "Voice Console"
    private static let logger = Logger(
        subsystem: "com.adnaankhan.CodexHUD",
        category: "CodexBridge"
    )
    private static let threadDefaultsKey = "CodexHUD.voiceConsoleThreadIdentifier"
    private static let capabilityVersionDefaultsKey =
        "CodexHUD.voiceConsoleCapabilityVersion"
    private static let voicePrompt = """
    You are the user's persistent Voice Console for Codex. Speak naturally and \
    concisely. You may inspect, create, or coordinate other Codex tasks. Before \
    any destructive or externally visible action, explain the exact action and \
    wait for explicit user confirmation. Ask clarifying questions aloud in the \
    conversation; do not call request_user_input.
    """

    private let mediaTransport: any RealtimeVoiceTransporting
    private let defaults: UserDefaults
    private let approvalResponderOverride: (any CodexAppServerResponding)?
    private let eventContinuation: AsyncStream<CodexBridgeEvent>.Continuation
    private var installation: CodexInstallation?
    private var launcher: CodexAccessibilityLauncher?
    private var client: CodexAppServerClient?
    private var incomingTask: Task<Void, Never>?
    private var transientIncomingTask: Task<Void, Never>?
    private var threadIdentifier: String?
    private var pendingApproval: PendingCodexApproval?
    private var approvalResponseInFlight: CodexAppServerRequestID?
    private var approvalResolvedWhileInFlight = false
    private var approvalResponseWrite: (
        token: UUID,
        task: Task<Void, Error>
    )?
    private var taskToolExecution: (
        id: CodexAppServerRequestID,
        task: Task<CodexDynamicToolCallResponse, Error>
    )?
    private var authorizedTaskThreadIdentifiers: Set<String> = []
    private var coordinatedTaskTurns: [String: String] = [:]
    private var pendingFileChanges:
        [CodexFileChangeKey: [CodexJSONValue]] = [:]
    private var voiceSessionGeneration: UInt64 = 0
    private var subscriptionAuthenticationEpoch: UInt64 = 0
    private var verifiedSubscriptionAuthenticationEpoch: UInt64?
    private var activeApprovalSessionAuthenticationEpoch: UInt64?
    private var realtimeStarted = false
    private var realtimeStartToken: UUID?
    private var realtimeStartWaiter: CheckedContinuation<Void, Error>?
    private var stoppingRealtime = false
    private var hasPresentedResult = false
    private var voiceMediaIsSuspended = false
    private var mediaSuspensionGeneration: UInt64 = 0
    private var lastVoicePresentationEvent: CodexBridgeEvent?

    init(
        mediaTransport: any RealtimeVoiceTransporting,
        defaults: UserDefaults = .standard,
        approvalResponder: (any CodexAppServerResponding)? = nil,
        voiceConsoleThreadIdentifier: String? = nil,
        appServerClient: CodexAppServerClient? = nil
    ) {
        self.mediaTransport = mediaTransport
        self.defaults = defaults
        approvalResponderOverride = approvalResponder
        threadIdentifier = voiceConsoleThreadIdentifier
        client = appServerClient
        if let voiceConsoleThreadIdentifier {
            connectionState = .ready(
                taskIdentifier: voiceConsoleThreadIdentifier
            )
            // The injected identifier is a test seam. Production never supplies
            // it and must complete both app-server authentication checks before
            // an approval session can become active.
            subscriptionAuthenticationEpoch = 1
            verifiedSubscriptionAuthenticationEpoch = 1
            activeApprovalSessionAuthenticationEpoch = 1
        }
        let pair = AsyncStream.makeStream(
            of: CodexBridgeEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        events = pair.stream
        eventContinuation = pair.continuation
        mediaTransport.onFailure = { [weak self] failure in
            self?.handleMediaFailure(failure)
        }
    }

    deinit {
        incomingTask?.cancel()
        transientIncomingTask?.cancel()
        taskToolExecution?.task.cancel()
        approvalResponseWrite?.task.cancel()
        eventContinuation.finish()
    }

    func prepareVoiceConsole() async throws {
        connectionState = .connecting

        do {
            let client = try await ensureClient()
            let thread = try await restoreOrCreateVoiceConsole(using: client)
            threadIdentifier = thread.id
            defaults.set(thread.id, forKey: Self.threadDefaultsKey)
            connectionState = .ready(taskIdentifier: thread.id)
        } catch {
            let failure = bridgeFailure(from: error)
            connectionState = .unavailable(failure)
            throw failure
        }
    }

    func startVoiceConversation() async throws {
        if threadIdentifier == nil {
            try await prepareVoiceConsole()
        }
        guard
            let threadIdentifier,
            let client
        else {
            throw CodexBridgeFailure.voiceConsoleNotFound
        }

        do {
            let authenticationEpoch = try activateApprovalSession()
            voiceSessionGeneration &+= 1
            applyMediaPolicy(.connecting)
            try await mediaTransport.start()
            try requireActiveApprovalSession(epoch: authenticationEpoch)
            let offer = try await mediaTransport.prepareOffer()
            try requireActiveApprovalSession(epoch: authenticationEpoch)
            stoppingRealtime = false
            hasPresentedResult = false
            realtimeStarted = false
            realtimeStartToken = UUID()
            let _: EmptyCodexResponse = try await client.request(
                "thread/realtime/start",
                params: CodexRealtimeStartParameters(
                    threadId: threadIdentifier,
                    transport: .init(sdp: offer),
                    prompt: Self.voicePrompt
                ),
                timeout: .seconds(20)
            )
            try await waitForRealtimeStarted()
        } catch {
            invalidateSubscriptionAuthentication()
            finishRealtimeStart(
                throwing: RealtimeWebRTCFailure.connectionFailed(
                    "Codex did not start the realtime media session."
                )
            )
            applyMediaPolicy(.dormant)
            let failure = bridgeFailure(from: error)
            connectionState = .unavailable(failure)
            throw failure
        }
    }

    func stopVoiceConversation() async {
        invalidateSubscriptionAuthentication()
        stoppingRealtime = true
        hasPresentedResult = false
        let strandedApproval = invalidatePendingApproval()
        let coordinatedTurns = invalidateCoordinatedTaskTurns()
        pendingFileChanges.removeAll()
        lastVoicePresentationEvent = nil
        finishRealtimeStart(
            throwing: RealtimeWebRTCFailure.connectionFailed(
                "The realtime media session was stopped."
            )
        )
        applyMediaPolicy(.dormant)
        if let strandedApproval {
            await declineForSessionEnd(strandedApproval)
        }
        await interruptCoordinatedTaskTurns(coordinatedTurns)
        guard let client, let threadIdentifier else { return }

        do {
            let _: EmptyCodexResponse = try await client.request(
                "thread/realtime/stop",
                params: CodexThreadIdentifierParameters(threadId: threadIdentifier)
            )
        } catch {
            let failure = bridgeFailure(from: error)
            eventContinuation.yield(.recoverableFailure(failure))
        }
    }

    func suspendVoiceMedia() {
        guard !voiceMediaIsSuspended else { return }
        voiceMediaIsSuspended = true
        mediaSuspensionGeneration &+= 1
        guard mediaPolicyState != .dormant else {
            // Suspension is a lifecycle latch, not a transport-state detail.
            // Startup may still be in flight while policy is dormant, so only
            // an explicit resume after unlock may clear it.
            return
        }
        let suspensionGeneration = mediaSuspensionGeneration
        muteMediaTransport()
        Task { @MainActor [weak self] in
            await self?.confirmSuspendedMedia(
                generation: suspensionGeneration
            )
        }
    }

    func resumeVoiceMedia() {
        guard voiceMediaIsSuspended else { return }
        voiceMediaIsSuspended = false
        mediaSuspensionGeneration &+= 1
        // Clearing a dormant latch prepares a future active start but cannot
        // open either input or output on its own.
        guard mediaPolicyState != .dormant else { return }
        applyTransportPolicy(mediaPolicyState)
    }

    func interruptSpeechAndListen() async throws {
        do {
            try await mediaTransport.interrupt()
            applyMediaPolicy(.live)
            yieldVoiceEvent(.listening)
        } catch {
            let failure = bridgeFailure(from: error)
            applyMediaPolicy(.dormant)
            connectionState = .unavailable(failure)
            throw failure
        }
    }

    @discardableResult
    func approvePendingAction() async throws -> CodexApprovalActionResult {
        guard let approval = pendingApproval else {
            // The official Codex app may resolve an approval at the same moment
            // the user clicks the HUD. A stale click is harmless.
            return .stale
        }
        guard isApprovalSessionAuthorized else {
            if let strandedApproval = invalidatePendingApproval() {
                await declineForSessionEnd(strandedApproval)
            }
            return .sessionEnded
        }
        guard let responder = appServerResponder() else { return .stale }
        let generation = voiceSessionGeneration
        let authenticationEpoch = subscriptionAuthenticationEpoch
        approvalResponseInFlight = approval.id
        approvalResolvedWhileInFlight = false
        defer {
            if approvalResponseInFlight == approval.id {
                approvalResponseInFlight = nil
                approvalResolvedWhileInFlight = false
            }
            if taskToolExecution?.id == approval.id {
                taskToolExecution = nil
            }
        }

        do {
            switch approval.kind {
            case .command, .fileChange:
                try await respondToAuthorizedApproval(
                    using: responder,
                    to: approval.id,
                    result: CodexApprovalDecision(decision: "accept"),
                    authenticationEpoch: authenticationEpoch
                )
            case .legacy:
                try await respondToAuthorizedApproval(
                    using: responder,
                    to: approval.id,
                    result: CodexApprovalDecision(decision: "approved"),
                    authenticationEpoch: authenticationEpoch
                )
            case .permissions:
                let result = try permissionApprovalResult(from: approval.params)
                try await respondToAuthorizedApproval(
                    using: responder,
                    to: approval.id,
                    rawResult: result,
                    authenticationEpoch: authenticationEpoch
                )
            case .taskTool:
                guard
                    let client,
                    let threadIdentifier,
                    let call = try? JSONDecoder().decode(
                        CodexDynamicToolCallParameters.self,
                        from: approval.params
                    ),
                    let action = try? CodexTaskToolCatalog.action(
                        for: call,
                        voiceConsoleThreadId: threadIdentifier
                    )
                else {
                    throw CodexBridgeFailure.voiceControlNotExposed
                }
                let execution = Task {
                    try await CodexTaskToolExecutor.execute(
                        action,
                        using: client,
                        turnLifecycle: coordinatedTaskTurnLifecycle(
                            generation: generation
                        )
                    )
                }
                taskToolExecution = (approval.id, execution)
                let response = try await execution.value
                try await respondToAuthorizedApproval(
                    using: responder,
                    to: approval.id,
                    result: response,
                    authenticationEpoch: authenticationEpoch
                )
            }
            return finishApprovalResponse(
                approval,
                generation: generation,
                event: .thinking
            )
        } catch {
            if let outcome = interruptedApprovalOutcome(
                approval,
                generation: generation
            ) {
                return outcome
            }
            let failure = bridgeFailure(from: error)
            approvalResponseInFlight = nil
            _ = invalidatePendingApproval()
            invalidateAppServerAfterRevokedApprovalResponse()
            invalidateSubscriptionAuthentication()
            applyMediaPolicy(.dormant)
            connectionState = .unavailable(failure)
            throw failure
        }
    }

    @discardableResult
    func rejectPendingAction() async -> CodexApprovalActionResult {
        guard let approval = pendingApproval else {
            return .stale
        }
        guard isApprovalSessionAuthorized else {
            if let strandedApproval = invalidatePendingApproval() {
                await declineForSessionEnd(strandedApproval)
            }
            return .sessionEnded
        }
        guard let responder = appServerResponder() else { return .stale }
        let generation = voiceSessionGeneration
        approvalResponseInFlight = approval.id
        approvalResolvedWhileInFlight = false
        defer {
            if approvalResponseInFlight == approval.id {
                approvalResponseInFlight = nil
                approvalResolvedWhileInFlight = false
            }
        }

        do {
            switch approval.kind {
            case .command, .fileChange:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexApprovalDecision(decision: "decline")
                )
            case .legacy:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexLegacyDenial(
                        decision: .init(
                            denied: .init(
                                rejection: "The user rejected this action in Codex HUD."
                            )
                        )
                    )
                )
            case .taskTool:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexDynamicToolCallResponse.failure(
                        "The user declined this Codex task action."
                    )
                )
            case .permissions:
                try await responder.reject(
                    approval.id,
                    code: -32_000,
                    message: "The user rejected this action in Codex HUD."
                )
            }
            return finishApprovalResponse(
                approval,
                generation: generation,
                event: .listening
            )
        } catch {
            if let outcome = interruptedApprovalOutcome(
                approval,
                generation: generation
            ) {
                return outcome
            }
            let failure = bridgeFailure(from: error)
            approvalResponseInFlight = nil
            _ = invalidatePendingApproval()
            invalidateAppServerAfterRevokedApprovalResponse()
            invalidateSubscriptionAuthentication()
            applyMediaPolicy(.dormant)
            connectionState = .unavailable(failure)
            eventContinuation.yield(.recoverableFailure(failure))
            return .sessionEnded
        }
    }

    func repairConnection() async throws {
        invalidateSubscriptionAuthentication()
        applyMediaPolicy(.dormant)
        lastVoicePresentationEvent = nil
        pendingFileChanges.removeAll()
        incomingTask?.cancel()
        incomingTask = nil
        transientIncomingTask?.cancel()
        transientIncomingTask = nil
        if let strandedApproval = invalidatePendingApproval() {
            await declineForSessionEnd(strandedApproval)
        }
        await interruptCoordinatedTaskTurns(
            invalidateCoordinatedTaskTurns()
        )
        threadIdentifier = nil
        finishRealtimeStart(
            throwing: RealtimeWebRTCFailure.connectionFailed(
                "The realtime connection was reset."
            )
        )
        if let client {
            await client.stop()
        }
        self.client = nil
        connectionState = .disconnected
        try await prepareVoiceConsole()
    }

    func openVoiceConsole() {
        guard let threadIdentifier else {
            eventContinuation.yield(
                .recoverableFailure(.voiceConsoleNotFound)
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let launcher = try ensureLauncher()
                try await launcher.openThread(
                    identifier: threadIdentifier,
                    activate: true
                )
            } catch {
                let failure = bridgeFailure(from: error)
                eventContinuation.yield(.recoverableFailure(failure))
            }
        }
    }

    private func ensureClient() async throws -> CodexAppServerClient {
        if let client {
            do {
                try await client.start()
                beginIncomingTasks(for: client)
                try await verifySubscription(using: client)
                return client
            } catch {
                incomingTask?.cancel()
                incomingTask = nil
                transientIncomingTask?.cancel()
                transientIncomingTask = nil
                await client.stop()
                self.client = nil
                throw error
            }
        }

        let installation = try installation ?? CodexInstallation.locate()
        self.installation = installation
        launcher = CodexAccessibilityLauncher(installation: installation)

        let client = CodexAppServerClient(
            executableURL: installation.executableURL
        )
        self.client = client
        do {
            try await client.start()

            beginIncomingTasks(for: client)
            try await verifySubscription(using: client)
            return client
        } catch {
            incomingTask?.cancel()
            incomingTask = nil
            transientIncomingTask?.cancel()
            transientIncomingTask = nil
            await client.stop()
            self.client = nil
            throw error
        }
    }

    private func beginIncomingTasks(for client: CodexAppServerClient) {
        incomingTask?.cancel()
        incomingTask = Task { [weak self, incoming = client.incoming] in
            for await message in incoming {
                guard !Task.isCancelled else { return }
                await self?.handle(message)
            }
        }

        transientIncomingTask?.cancel()
        transientIncomingTask = Task {
            [weak self, incoming = client.transientIncoming] in
            for await message in incoming {
                guard !Task.isCancelled else { return }
                await self?.handle(message)
            }
        }
    }

    private func verifySubscription(
        using client: CodexAppServerClient
    ) async throws {
        let epoch = beginSubscriptionAuthenticationVerification()
        do {
            let response: CodexAccountReadResponse = try await client.request(
                "account/read",
                params: CodexAccountReadParameters()
            )
            try response.requireChatGPTSubscription()

            let authStatus: CodexAuthStatusResponse = try await client.request(
                "getAuthStatus",
                params: CodexAuthStatusParameters()
            )
            try authStatus.requireCodexManagedChatGPTAuthentication()
            try completeSubscriptionAuthenticationVerification(epoch)
        } catch {
            if epoch == subscriptionAuthenticationEpoch {
                verifiedSubscriptionAuthenticationEpoch = nil
                activeApprovalSessionAuthenticationEpoch = nil
            }
            throw error
        }
    }

    private var hasVerifiedSubscriptionAuthentication: Bool {
        verifiedSubscriptionAuthenticationEpoch
            == subscriptionAuthenticationEpoch
    }

    private var isApprovalSessionAuthorized: Bool {
        hasVerifiedSubscriptionAuthentication
            && activeApprovalSessionAuthenticationEpoch
                == subscriptionAuthenticationEpoch
            && isCurrentVoiceSessionReady
    }

    @discardableResult
    private func beginSubscriptionAuthenticationVerification() -> UInt64 {
        subscriptionAuthenticationEpoch &+= 1
        verifiedSubscriptionAuthenticationEpoch = nil
        activeApprovalSessionAuthenticationEpoch = nil
        return subscriptionAuthenticationEpoch
    }

    private func completeSubscriptionAuthenticationVerification(
        _ epoch: UInt64
    ) throws {
        guard epoch == subscriptionAuthenticationEpoch else {
            throw CodexBridgeFailure.subscriptionAuthenticationRequired
        }
        verifiedSubscriptionAuthenticationEpoch = epoch
    }

    private func invalidateSubscriptionAuthentication() {
        subscriptionAuthenticationEpoch &+= 1
        verifiedSubscriptionAuthenticationEpoch = nil
        activeApprovalSessionAuthenticationEpoch = nil
    }

    @discardableResult
    private func activateApprovalSession() throws -> UInt64 {
        guard
            hasVerifiedSubscriptionAuthentication,
            isCurrentVoiceSessionReady
        else {
            throw CodexBridgeFailure.subscriptionAuthenticationRequired
        }
        activeApprovalSessionAuthenticationEpoch =
            subscriptionAuthenticationEpoch
        return subscriptionAuthenticationEpoch
    }

    private func requireActiveApprovalSession(epoch: UInt64) throws {
        guard
            epoch == subscriptionAuthenticationEpoch,
            isApprovalSessionAuthorized
        else {
            throw CodexBridgeFailure.subscriptionAuthenticationRequired
        }
    }

    private func appServerResponder() -> (any CodexAppServerResponding)? {
        if let approvalResponderOverride {
            return approvalResponderOverride
        }
        guard let client else { return nil }
        return CodexAppServerClientResponder(client: client)
    }

    private func respond<Result: Encodable & Sendable>(
        using responder: any CodexAppServerResponding,
        to id: CodexAppServerRequestID,
        result: Result
    ) async throws {
        let data = try JSONEncoder().encode(result)
        try await responder.respond(to: id, rawResult: data)
    }

    private func respondToAuthorizedApproval<
        Result: Encodable & Sendable
    >(
        using responder: any CodexAppServerResponding,
        to id: CodexAppServerRequestID,
        result: Result,
        authenticationEpoch: UInt64
    ) async throws {
        try await respondToAuthorizedApproval(
            using: responder,
            to: id,
            rawResult: JSONEncoder().encode(result),
            authenticationEpoch: authenticationEpoch
        )
    }

    private func respondToAuthorizedApproval(
        using responder: any CodexAppServerResponding,
        to id: CodexAppServerRequestID,
        rawResult: Data,
        authenticationEpoch: UInt64
    ) async throws {
        try requireActiveApprovalSession(epoch: authenticationEpoch)
        let token = UUID()
        let task = Task {
            try Task.checkCancellation()
            try await responder.respond(to: id, rawResult: rawResult)
        }
        approvalResponseWrite = (token, task)
        defer {
            if approvalResponseWrite?.token == token {
                approvalResponseWrite = nil
            }
        }
        try await task.value
    }

    private func respondAutomatically<Result: Encodable & Sendable>(
        to id: CodexAppServerRequestID,
        result: Result
    ) async {
        guard let responder = appServerResponder() else {
            failClosed(.applicationUnavailable)
            return
        }
        do {
            try await respond(
                using: responder,
                to: id,
                result: result
            )
        } catch {
            failClosed(bridgeFailure(from: error))
        }
    }

    private func respondAutomatically(
        to id: CodexAppServerRequestID,
        object: [String: Any]
    ) async {
        guard let responder = appServerResponder() else {
            failClosed(.applicationUnavailable)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            try await responder.respond(to: id, rawResult: data)
        } catch {
            failClosed(bridgeFailure(from: error))
        }
    }

    private func rejectPreservingSession(
        _ id: CodexAppServerRequestID,
        code: Int,
        message: String
    ) async {
        guard let responder = appServerResponder() else {
            failClosed(.applicationUnavailable)
            return
        }
        do {
            try await responder.reject(
                id,
                code: code,
                message: message
            )
        } catch {
            failClosed(bridgeFailure(from: error))
        }
    }

    private func rejectAndFailClosed(
        _ id: CodexAppServerRequestID,
        code: Int,
        message: String,
        failure: CodexBridgeFailure
    ) async {
        if let responder = appServerResponder() {
            try? await responder.reject(
                id,
                code: code,
                message: message
            )
        }
        failClosed(failure)
    }

    /// Invalidates the local approval atomically. If no response was already
    /// being written, the returned request still needs a fail-safe decline so
    /// the app-server cannot remain blocked after the HUD turns off.
    private func invalidatePendingApproval() -> PendingCodexApproval? {
        taskToolExecution?.task.cancel()
        taskToolExecution = nil
        let responseWriteWasActive = approvalResponseWrite != nil
        approvalResponseWrite?.task.cancel()
        approvalResponseWrite = nil
        if responseWriteWasActive {
            invalidateAppServerAfterRevokedApprovalResponse()
        }

        let approval = pendingApproval
        clearFileChangeContext(for: approval)
        let responseAlreadyInFlight = approval.map {
            approvalResponseInFlight == $0.id
        } ?? false
        pendingApproval = nil
        approvalResponseInFlight = nil
        approvalResolvedWhileInFlight = false
        return responseAlreadyInFlight ? nil : approval
    }

    private func invalidateAppServerAfterRevokedApprovalResponse() {
        incomingTask?.cancel()
        incomingTask = nil
        transientIncomingTask?.cancel()
        transientIncomingTask = nil
        guard let client else { return }
        self.client = nil
        Task {
            await client.stop()
        }
    }

    private func declineForSessionEnd(
        _ approval: PendingCodexApproval
    ) async {
        guard let responder = appServerResponder() else { return }
        do {
            switch approval.kind {
            case .command, .fileChange:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexApprovalDecision(decision: "decline")
                )
            case .legacy:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexLegacyDenial(
                        decision: .init(
                            denied: .init(
                                rejection: "The Voice Console session ended."
                            )
                        )
                    )
                )
            case .taskTool:
                try await respond(
                    using: responder,
                    to: approval.id,
                    result: CodexDynamicToolCallResponse.failure(
                        "The Voice Console session ended before approval."
                    )
                )
            case .permissions:
                try await responder.reject(
                    approval.id,
                    code: -32_000,
                    message: "The Voice Console session ended before approval."
                )
            }
        } catch {
            // The session is already fail-closed and media is already stopped.
            // There is no safe retry once the app-server transport is gone.
        }
    }

    private func invalidateCoordinatedTaskTurns() -> [(String, String)] {
        let turns = coordinatedTaskTurns.map { ($0.key, $0.value) }
        coordinatedTaskTurns.removeAll()
        authorizedTaskThreadIdentifiers.removeAll()
        return turns
    }

    private func interruptCoordinatedTaskTurns(
        _ turns: [(String, String)]
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for (threadIdentifier, turnIdentifier) in turns {
                group.addTask { [weak self] in
                    await self?.interruptCoordinatedTaskTurn(
                        threadIdentifier: threadIdentifier,
                        turnIdentifier: turnIdentifier
                    )
                }
            }
        }
    }

    private func interruptCoordinatedTaskTurn(
        threadIdentifier: String,
        turnIdentifier: String
    ) async {
        guard let client else { return }
        do {
            let _: EmptyCodexResponse = try await client.request(
                "turn/interrupt",
                params: CodexTurnInterruptParameters(
                    threadId: threadIdentifier,
                    turnId: turnIdentifier
                ),
                timeout: .seconds(5)
            )
        } catch {
            Self.logger.error(
                "Could not interrupt a coordinated Codex task turn."
            )
        }
    }

    private func requestMatchesVoiceConsole(
        _ data: Data,
        key: String
    ) -> Bool {
        requestThreadIdentifier(in: data, key: key) == threadIdentifier
    }

    private func requestThreadIdentifier(
        in data: Data,
        key: String
    ) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return object[key] as? String
    }

    private func isAuthorizedApprovalSource(_ identifier: String) -> Bool {
        identifier == threadIdentifier
            || authorizedTaskThreadIdentifiers.contains(identifier)
    }

    private func fileChangeKey(in data: Data) -> CodexFileChangeKey? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let threadId = object["threadId"] as? String,
            let turnId = object["turnId"] as? String,
            let itemId = object["itemId"] as? String
        else {
            return nil
        }
        return CodexFileChangeKey(
            threadId: threadId,
            turnId: turnId,
            itemId: itemId
        )
    }

    private func cacheFileChanges(
        _ changes: [CodexJSONValue],
        key: CodexFileChangeKey
    ) {
        guard
            isApprovalSessionAuthorized,
            isAuthorizedApprovalSource(key.threadId)
        else {
            return
        }
        guard
            !changes.isEmpty,
            let encoded = try? JSONEncoder().encode(changes),
            encoded.count <= 4 * 1_024 * 1_024
        else {
            pendingFileChanges.removeValue(forKey: key)
            return
        }
        pendingFileChanges[key] = changes
    }

    private func clearFileChangeContext(
        for approval: PendingCodexApproval?
    ) {
        guard let approval else { return }
        guard case .fileChange = approval.kind else { return }
        guard let key = fileChangeKey(in: approval.params) else { return }
        pendingFileChanges.removeValue(forKey: key)
    }

    private func finishApprovalResponse(
        _ approval: PendingCodexApproval,
        generation: UInt64,
        event: CodexBridgeEvent
    ) -> CodexApprovalActionResult {
        guard
            generation == voiceSessionGeneration,
            isCurrentVoiceSessionReady
        else {
            return .sessionEnded
        }

        if let pendingApproval, pendingApproval.id != approval.id {
            applyMediaPolicy(.approval)
            return .superseded
        }

        if approvalResolvedWhileInFlight {
            restoreAfterServerResolution(approval)
            return .stale
        }

        guard pendingApproval?.id == approval.id else {
            restoreAfterServerResolution(approval)
            return .stale
        }
        pendingApproval = nil
        clearFileChangeContext(for: approval)

        if approval.sourceThreadIdentifier != threadIdentifier {
            restoreAfterServerResolution(approval)
            return .completed
        }

        if realtimeStarted {
            applyMediaPolicy(.live)
            yieldVoiceEvent(event)
            return .completed
        }
        if realtimeStartToken != nil || realtimeStartWaiter != nil {
            applyMediaPolicy(.connecting)
            return .deferredUntilRealtimeStarts
        }
        applyMediaPolicy(.dormant)
        return .sessionEnded
    }

    private func interruptedApprovalOutcome(
        _ approval: PendingCodexApproval,
        generation: UInt64
    ) -> CodexApprovalActionResult? {
        guard
            generation == voiceSessionGeneration,
            isCurrentVoiceSessionReady
        else {
            return .sessionEnded
        }
        if let pendingApproval, pendingApproval.id != approval.id {
            applyMediaPolicy(.approval)
            return .superseded
        }
        if approvalResolvedWhileInFlight {
            restoreAfterServerResolution(approval)
            return .stale
        }
        return nil
    }

    private var isCurrentVoiceSessionReady: Bool {
        guard
            case let .ready(taskIdentifier) = connectionState,
            taskIdentifier == threadIdentifier
        else {
            return false
        }
        return true
    }

    private func coordinatedTaskTurnLifecycle(
        generation: UInt64
    ) -> CodexTaskToolExecutor.TurnLifecycle {
        CodexTaskToolExecutor.TurnLifecycle(
            willStart: { [weak self] identifier in
                await self?.authorizeCoordinatedTaskThread(
                    identifier,
                    generation: generation
                )
            },
            didStart: { [weak self] identifier, turnIdentifier in
                await self?.recordCoordinatedTaskTurn(
                    threadIdentifier: identifier,
                    turnIdentifier: turnIdentifier,
                    generation: generation
                )
            },
            abandoned: { [weak self] identifier in
                await self?.abandonCoordinatedTaskThread(identifier)
            },
            cancelledAfterStart: {
                [weak self] identifier, turnIdentifier in
                await self?.cancelCoordinatedTaskTurn(
                    threadIdentifier: identifier,
                    turnIdentifier: turnIdentifier
                )
            }
        )
    }

    private func authorizeCoordinatedTaskThread(
        _ identifier: String,
        generation: UInt64
    ) {
        guard
            generation == voiceSessionGeneration,
            isCurrentVoiceSessionReady,
            mediaPolicyState != .dormant
        else {
            return
        }
        authorizedTaskThreadIdentifiers.insert(identifier)
    }

    private func recordCoordinatedTaskTurn(
        threadIdentifier: String,
        turnIdentifier: String,
        generation: UInt64
    ) async {
        guard
            generation == voiceSessionGeneration,
            isCurrentVoiceSessionReady,
            mediaPolicyState != .dormant
        else {
            await interruptCoordinatedTaskTurn(
                threadIdentifier: threadIdentifier,
                turnIdentifier: turnIdentifier
            )
            return
        }
        authorizedTaskThreadIdentifiers.insert(threadIdentifier)
        coordinatedTaskTurns[threadIdentifier] = turnIdentifier
    }

    private func abandonCoordinatedTaskThread(_ identifier: String) {
        guard coordinatedTaskTurns[identifier] == nil else { return }
        authorizedTaskThreadIdentifiers.remove(identifier)
    }

    private func cancelCoordinatedTaskTurn(
        threadIdentifier: String,
        turnIdentifier: String
    ) async {
        authorizedTaskThreadIdentifiers.remove(threadIdentifier)
        coordinatedTaskTurns.removeValue(forKey: threadIdentifier)
        await interruptCoordinatedTaskTurn(
            threadIdentifier: threadIdentifier,
            turnIdentifier: turnIdentifier
        )
    }

    private func restoreAfterServerResolution(
        _ resolvedApproval: PendingCodexApproval? = nil
    ) {
        guard
            isCurrentVoiceSessionReady
        else {
            applyMediaPolicy(.dormant)
            return
        }

        if pendingApproval != nil {
            applyMediaPolicy(.approval)
            return
        }
        if
            let resolvedApproval,
            resolvedApproval.sourceThreadIdentifier != threadIdentifier,
            realtimeStarted
        {
            applyMediaPolicy(resolvedApproval.restorationMediaPolicy)
            if let event = resolvedApproval.restorationEvent {
                yieldVoiceEvent(event)
            }
            return
        }
        if realtimeStarted {
            applyMediaPolicy(.live)
            yieldVoiceEvent(.listening)
        } else if realtimeStartToken != nil || realtimeStartWaiter != nil {
            applyMediaPolicy(.connecting)
        } else {
            applyMediaPolicy(.dormant)
        }
    }

    private func failClosed(_ failure: CodexBridgeFailure) {
        invalidateSubscriptionAuthentication()
        let strandedApproval = invalidatePendingApproval()
        let coordinatedTurns = invalidateCoordinatedTaskTurns()
        pendingFileChanges.removeAll()
        hasPresentedResult = false
        lastVoicePresentationEvent = nil
        finishRealtimeStart(throwing: failure)
        applyMediaPolicy(.dormant)
        connectionState = .unavailable(failure)
        yieldFailureIfUnsolicited(failure)
        if let strandedApproval {
            Task { [weak self] in
                await self?.declineForSessionEnd(strandedApproval)
            }
        }
        if !coordinatedTurns.isEmpty {
            Task { [weak self] in
                await self?.interruptCoordinatedTaskTurns(
                    coordinatedTurns
                )
            }
        }
    }

    private func ensureLauncher() throws -> CodexAccessibilityLauncher {
        if let launcher {
            return launcher
        }
        let installation = try installation ?? CodexInstallation.locate()
        self.installation = installation
        let launcher = CodexAccessibilityLauncher(installation: installation)
        self.launcher = launcher
        return launcher
    }

    private func restoreOrCreateVoiceConsole(
        using client: CodexAppServerClient
    ) async throws -> CodexThreadSummary {
        let persisted = defaults.string(forKey: Self.threadDefaultsKey)
        let capabilityVersion = defaults.integer(
            forKey: Self.capabilityVersionDefaultsKey
        )

        if capabilityVersion >= CodexTaskToolCatalog.capabilityVersion {
            if let persisted,
               let thread = try? await resume(persisted, using: client)
            {
                if thread.name != Self.voiceConsoleName {
                    try await setVoiceConsoleName(thread.id, using: client)
                }
                return CodexThreadSummary(
                    id: thread.id,
                    name: Self.voiceConsoleName
                )
            }
            if let exact = try await exactVoiceConsole(using: client) {
                let resumed = try await resume(exact.id, using: client)
                defaults.set(resumed.id, forKey: Self.threadDefaultsKey)
                return resumed
            }
        }

        var legacy: CodexThreadSummary?
        if let persisted {
            legacy = try? await resume(persisted, using: client)
        }
        if legacy == nil {
            legacy = try await exactVoiceConsole(using: client)
        }

        let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let started: CodexThreadEnvelope = try await client.request(
            "thread/start",
            params: CodexThreadStartParameters(
                cwd: documentsURL.path,
                developerInstructions: Self.voicePrompt,
                dynamicTools: CodexTaskToolCatalog.specifications
            ),
            timeout: .seconds(30)
        )
        try await setVoiceConsoleName(started.thread.id, using: client)
        defaults.set(started.thread.id, forKey: Self.threadDefaultsKey)
        defaults.set(
            CodexTaskToolCatalog.capabilityVersion,
            forKey: Self.capabilityVersionDefaultsKey
        )

        if let legacy, legacy.id != started.thread.id {
            // A dynamic-tool contract is fixed at thread/start and persisted in
            // rollout metadata. Preserve the previous history under a clearly
            // non-active name rather than mutating its rollout or deleting it.
            try? await setVoiceConsoleName(
                legacy.id,
                name: "Voice Console (Legacy \(legacy.id.prefix(8)))",
                using: client
            )
        }
        return CodexThreadSummary(
            id: started.thread.id,
            name: Self.voiceConsoleName
        )
    }

    private func exactVoiceConsole(
        using client: CodexAppServerClient
    ) async throws -> CodexThreadSummary? {
        let listed: CodexThreadListResponse = try await client.request(
            "thread/list",
            params: CodexThreadListParameters(
                searchTerm: Self.voiceConsoleName,
                limit: 50
            )
        )
        return listed.data.first(where: {
            $0.name?.caseInsensitiveCompare(Self.voiceConsoleName) == .orderedSame
        })
    }

    private func resume(
        _ identifier: String,
        using client: CodexAppServerClient
    ) async throws -> CodexThreadSummary {
        let response: CodexThreadEnvelope = try await client.request(
            "thread/resume",
            params: CodexThreadResumeParameters(threadId: identifier),
            timeout: .seconds(30)
        )
        return response.thread
    }

    private func setVoiceConsoleName(
        _ identifier: String,
        using client: CodexAppServerClient
    ) async throws {
        try await setVoiceConsoleName(
            identifier,
            name: Self.voiceConsoleName,
            using: client
        )
    }

    private func setVoiceConsoleName(
        _ identifier: String,
        name: String,
        using client: CodexAppServerClient
    ) async throws {
        let _: EmptyCodexResponse = try await client.request(
            "thread/name/set",
            params: CodexThreadSetNameParameters(
                threadId: identifier,
                name: name
            )
        )
    }

    func handle(_ message: CodexAppServerIncoming) async {
        switch message {
        case let .notification(method, params):
            await handleNotification(method: method, params: params)
        case let .request(id, method, params):
            await handleServerRequest(id: id, method: method, params: params)
        case .disconnected:
            failClosed(.applicationUnavailable)
        }
    }

    private func handleNotification(method: String, params: Data) async {
        switch method {
        case "thread/realtime/sdp":
            guard
                isApprovalSessionAuthorized,
                let notification = try? JSONDecoder().decode(
                    CodexRealtimeSDPNotification.self,
                    from: params
                ),
                notification.threadId == threadIdentifier
            else {
                return
            }
            do {
                try await mediaTransport.acceptAnswer(notification.sdp)
            } catch {
                handleMediaFailure(
                    (error as? RealtimeWebRTCFailure)
                        ?? .connectionFailed(error.localizedDescription)
                )
            }

        case "thread/realtime/started":
            guard
                isApprovalSessionAuthorized,
                CodexRealtimeStartedNotification.decode(
                    from: params,
                    matching: threadIdentifier
                ) != nil
            else {
                return
            }
            realtimeStarted = true
            realtimeStartToken = nil
            realtimeStartWaiter?.resume()
            realtimeStartWaiter = nil
            hasPresentedResult = false
            if pendingApproval != nil {
                applyMediaPolicy(.approval)
                return
            }
            applyMediaPolicy(.live)
            yieldVoiceEvent(.listening)

        case "thread/realtime/transcript/delta":
            guard
                isApprovalSessionAuthorized,
                let notification = try? JSONDecoder().decode(
                    CodexRealtimeTranscriptDelta.self,
                    from: params
                ),
                notification.threadId == threadIdentifier,
                !notification.delta.isEmpty
            else {
                return
            }
            if pendingApproval != nil {
                applyMediaPolicy(.approval)
                return
            }
            if notification.role != "assistant" {
                hasPresentedResult = false
            } else {
                applyMediaPolicy(.assistantLive)
            }
            if notification.role != "assistant" {
                applyMediaPolicy(.live)
            }
            yieldVoiceEvent(
                notification.role == "assistant" ? .speaking : .listening
            )

        case "thread/realtime/transcript/done":
            guard
                isApprovalSessionAuthorized,
                let notification = try? JSONDecoder().decode(
                    CodexRealtimeTranscriptDone.self,
                    from: params
                ),
                notification.threadId == threadIdentifier,
                !notification.text.isEmpty
            else {
                return
            }
            if pendingApproval != nil {
                applyMediaPolicy(.approval)
                return
            }
            if notification.role == "assistant" {
                hasPresentedResult = true
                applyMediaPolicy(.assistantLive)
                yieldVoiceEvent(
                    .result(
                        title: "Codex replied",
                        detail: transientExcerpt(from: notification.text)
                    )
                )
            } else {
                hasPresentedResult = false
                applyMediaPolicy(.live)
                yieldVoiceEvent(.thinking)
            }

        case "item/started":
            guard
                let notification = try? JSONDecoder().decode(
                    CodexFileChangeItemStartedNotification.self,
                    from: params
                ),
                notification.item.type == "fileChange",
                let changes = notification.item.changes
            else {
                return
            }
            cacheFileChanges(
                changes,
                key: CodexFileChangeKey(
                    threadId: notification.threadId,
                    turnId: notification.turnId,
                    itemId: notification.item.id
                )
            )

        case "item/fileChange/patchUpdated":
            guard
                let notification = try? JSONDecoder().decode(
                    CodexFileChangePatchUpdatedNotification.self,
                    from: params
                )
            else {
                return
            }
            cacheFileChanges(
                notification.changes,
                key: CodexFileChangeKey(
                    threadId: notification.threadId,
                    turnId: notification.turnId,
                    itemId: notification.itemId
                )
            )

        case "turn/started":
            guard
                isApprovalSessionAuthorized,
                let notification = try? JSONDecoder().decode(
                    CodexThreadScopedNotification.self,
                    from: params
                ),
                notification.threadId == threadIdentifier
            else {
                return
            }
            if pendingApproval != nil {
                applyMediaPolicy(.approval)
                return
            }
            hasPresentedResult = false
            applyMediaPolicy(.live)
            yieldVoiceEvent(.thinking)

        case "turn/completed":
            guard
                let notification = try? JSONDecoder().decode(
                    CodexThreadScopedNotification.self,
                    from: params
                )
            else {
                return
            }
            pendingFileChanges = pendingFileChanges.filter {
                $0.key.threadId != notification.threadId
            }
            if notification.threadId != threadIdentifier {
                guard authorizedTaskThreadIdentifiers.contains(
                    notification.threadId
                ) else {
                    return
                }
                authorizedTaskThreadIdentifiers.remove(notification.threadId)
                coordinatedTaskTurns.removeValue(forKey: notification.threadId)
                return
            }
            guard isApprovalSessionAuthorized else { return }
            if pendingApproval != nil {
                applyMediaPolicy(.approval)
                return
            }
            if !hasPresentedResult {
                applyMediaPolicy(.live)
                yieldVoiceEvent(.listening)
            }

        case "thread/realtime/error":
            guard
                isApprovalSessionAuthorized,
                let notification = try? JSONDecoder().decode(
                    CodexRealtimeErrorNotification.self,
                    from: params
                ),
                notification.threadId == threadIdentifier
            else {
                return
            }
            let failure: CodexBridgeFailure = notification.message
                .localizedCaseInsensitiveContains("version")
                ? .unsupportedApplicationVersion(installation?.version ?? "unknown")
                : .voiceControlNotExposed
            failClosed(failure)

        case "thread/realtime/closed":
            guard
                let notification = try? JSONDecoder().decode(
                    CodexRealtimeClosedNotification.self,
                    from: params
                ),
                notification.threadId == threadIdentifier,
                stoppingRealtime || isApprovalSessionAuthorized
            else {
                return
            }
            if stoppingRealtime {
                if let strandedApproval = invalidatePendingApproval() {
                    await declineForSessionEnd(strandedApproval)
                }
                finishRealtimeStart(
                    throwing: RealtimeWebRTCFailure.connectionFailed(
                        "The realtime media session was stopped."
                    )
                )
                applyMediaPolicy(.dormant)
                hasPresentedResult = false
            } else {
                failClosed(.voiceControlNotExposed)
            }
            stoppingRealtime = false

        case "serverRequest/resolved":
            guard
                let notification = try? JSONDecoder().decode(
                    CodexServerRequestResolvedNotification.self,
                    from: params
                ),
                pendingApproval?.sourceThreadIdentifier
                    == notification.threadId,
                pendingApproval?.id == notification.requestId
            else {
                return
            }
            let resolvedApproval = pendingApproval
            pendingApproval = nil
            clearFileChangeContext(for: resolvedApproval)
            if approvalResponseInFlight == notification.requestId {
                approvalResolvedWhileInFlight = true
                if taskToolExecution?.id == notification.requestId {
                    taskToolExecution?.task.cancel()
                    restoreAfterServerResolution(resolvedApproval)
                }
                return
            }
            restoreAfterServerResolution(resolvedApproval)

        case "account/updated":
            guard let notification = try? JSONDecoder().decode(
                CodexAccountUpdatedNotification.self,
                from: params
            ) else {
                failClosed(.subscriptionAuthenticationRequired)
                return
            }
            guard notification.authMode == "chatgpt" else {
                failClosed(.subscriptionAuthenticationRequired)
                return
            }

        default:
            break
        }
    }

    func handleServerRequest(
        id: CodexAppServerRequestID,
        method: String,
        params: Data
    ) async {
        switch method {
        case "item/tool/call":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            await handleTaskToolRequest(id: id, params: params)
            return

        case "item/tool/requestUserInput":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            guard requestMatchesVoiceConsole(params, key: "threadId") else {
                await rejectPreservingSession(
                    id,
                    code: -32_602,
                    message: "Invalid Voice Console user-input request."
                )
                return
            }
            await respondAutomatically(
                to: id,
                object: ["answers": [String: Any]()]
            )
            return

        case "mcpServer/elicitation/request":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            guard requestMatchesVoiceConsole(params, key: "threadId") else {
                await rejectPreservingSession(
                    id,
                    code: -32_602,
                    message: "Invalid Voice Console elicitation request."
                )
                return
            }
            await respondAutomatically(
                to: id,
                object: [
                    "action": "decline",
                    "content": NSNull(),
                    "_meta": NSNull()
                ]
            )
            return

        case "account/chatgptAuthTokens/refresh":
            await rejectAndFailClosed(
                id,
                code: -32_000,
                message: """
                Codex HUD does not manage ChatGPT authentication tokens. \
                Sign in through Codex.
                """,
                failure: .subscriptionAuthenticationRequired
            )
            return

        case "attestation/generate":
            await rejectAndFailClosed(
                id,
                code: -32_601,
                message: "Attestation was not negotiated by Codex HUD.",
                failure: .unsupportedApplicationVersion(
                    installation?.version ?? "unknown"
                )
            )
            return

        case "currentTime/read":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            guard requestMatchesVoiceConsole(params, key: "threadId") else {
                await rejectPreservingSession(
                    id,
                    code: -32_602,
                    message: "Invalid Voice Console current-time request."
                )
                return
            }
            await respondAutomatically(
                to: id,
                result: CodexCurrentTimeResponse(
                    currentTimeAt: Int64(
                        Date().timeIntervalSince1970.rounded(.down)
                    )
                )
            )
            return

        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "item/permissions/requestApproval":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            guard
                let sourceThreadIdentifier = requestThreadIdentifier(
                    in: params,
                    key: "threadId"
                ),
                isAuthorizedApprovalSource(sourceThreadIdentifier)
            else {
                await rejectPreservingSession(
                    id,
                    code: -32_602,
                    message: """
                    Approval did not originate from Voice Console or a task \
                    explicitly started from it.
                    """
                )
                return
            }

        case "execCommandApproval", "applyPatchApproval":
            guard isApprovalSessionAuthorized else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: "No active authenticated Voice Console session."
                )
                return
            }
            guard
                let sourceThreadIdentifier = requestThreadIdentifier(
                    in: params,
                    key: "conversationId"
                ),
                isAuthorizedApprovalSource(sourceThreadIdentifier)
            else {
                await rejectPreservingSession(
                    id,
                    code: -32_602,
                    message: """
                    Approval did not originate from Voice Console or a task \
                    explicitly started from it.
                    """
                )
                return
            }

        default:
            Self.logger.error(
                "Unsupported app-server request: \(method, privacy: .public)"
            )
            await rejectPreservingSession(
                id,
                code: -32_601,
                message: "Codex HUD does not support this app-server request."
            )
            return
        }

        guard pendingApproval == nil else {
            await rejectPreservingSession(
                id,
                code: -32_000,
                message: "Another Codex approval is already pending."
            )
            return
        }

        let kind: PendingApprovalKind
        let title: String
        let sourceKey: String
        switch method {
        case "item/commandExecution/requestApproval":
            kind = .command
            title = "Run this command?"
            sourceKey = "threadId"
        case "item/fileChange/requestApproval":
            kind = .fileChange
            title = "Apply these file changes?"
            sourceKey = "threadId"
        case "execCommandApproval", "applyPatchApproval":
            kind = .legacy
            title = "Approve this Codex action?"
            sourceKey = "conversationId"
        case "item/permissions/requestApproval":
            kind = .permissions
            title = "Grant these permissions?"
            sourceKey = "threadId"
        default:
            // The exhaustive routing switch above is the only entry point.
            return
        }
        guard
            let sourceThreadIdentifier = requestThreadIdentifier(
                in: params,
                key: sourceKey
            )
        else {
            await rejectPreservingSession(
                id,
                code: -32_602,
                message: "Approval source was missing."
            )
            return
        }

        var exactFileChanges: [CodexJSONValue]?
        if method == "item/fileChange/requestApproval" {
            guard
                let key = fileChangeKey(in: params),
                let cachedChanges = pendingFileChanges[key],
                !cachedChanges.isEmpty
            else {
                await rejectPreservingSession(
                    id,
                    code: -32_000,
                    message: """
                    Codex HUD did not receive the exact file diff. Open the \
                    task in Codex to inspect and approve it.
                    """
                )
                yieldVoiceEvent(
                    .result(
                        title: "Review file changes in Codex",
                        detail: """
                        No changes were approved. Open the source task to \
                        inspect the complete diff.
                        """
                    )
                )
                return
            }
            exactFileChanges = cachedChanges
        }

        pendingApproval = PendingCodexApproval(
            id: id,
            sourceThreadIdentifier: sourceThreadIdentifier,
            method: method,
            params: params,
            kind: kind,
            restorationMediaPolicy: mediaPolicyState,
            restorationEvent: lastVoicePresentationEvent
        )
        guard
            let detail = approvalDetail(
                from: params,
                method: method,
                sourceThreadIdentifier: sourceThreadIdentifier,
                exactFileChanges: exactFileChanges
            )
        else {
            clearFileChangeContext(for: pendingApproval)
            pendingApproval = nil
            await rejectPreservingSession(
                id,
                code: -32_602,
                message: "Codex HUD could not render the exact approval request."
            )
            return
        }
        guard await pauseMediaForApproval(id) else { return }
        eventContinuation.yield(
            .approval(
                title: title,
                detail: detail
            )
        )
    }

    private func handleTaskToolRequest(
        id: CodexAppServerRequestID,
        params: Data
    ) async {
        guard
            isApprovalSessionAuthorized,
            let client,
            let threadIdentifier
        else {
            await respondAutomatically(
                to: id,
                result: CodexDynamicToolCallResponse.failure(
                    "No active authenticated Voice Console session."
                )
            )
            return
        }

        let action: CodexTaskToolAction
        do {
            let call = try JSONDecoder().decode(
                CodexDynamicToolCallParameters.self,
                from: params
            )
            action = try CodexTaskToolCatalog.action(
                for: call,
                voiceConsoleThreadId: threadIdentifier
            )
        } catch let failure as CodexTaskToolFailure {
            await respondAutomatically(
                to: id,
                result: CodexDynamicToolCallResponse.failure(
                    failure.userMessage
                )
            )
            return
        } catch {
            await respondAutomatically(
                to: id,
                result: CodexDynamicToolCallResponse.failure(
                    "Voice Console sent an invalid task request."
                )
            )
            return
        }

        guard pendingApproval == nil else {
            await respondAutomatically(
                to: id,
                result: CodexDynamicToolCallResponse.failure(
                    "Another action is waiting for user approval."
                )
            )
            return
        }

        if action.requiresConfirmation {
            pendingApproval = PendingCodexApproval(
                id: id,
                sourceThreadIdentifier: threadIdentifier,
                method: "item/tool/call",
                params: params,
                kind: .taskTool,
                restorationMediaPolicy: mediaPolicyState,
                restorationEvent: lastVoicePresentationEvent
            )
            guard await pauseMediaForApproval(id) else { return }
            eventContinuation.yield(
                .approval(
                    title: action.approvalTitle,
                    detail: action.approvalDetail
                )
            )
            return
        }

        do {
            let response = try await CodexTaskToolExecutor.execute(
                action,
                using: client
            )
            await respondAutomatically(to: id, result: response)
        } catch is CancellationError {
            return
        } catch {
            failClosed(bridgeFailure(from: error))
        }
    }

    private func approvalDetail(
        from data: Data,
        method: String,
        sourceThreadIdentifier: String,
        exactFileChanges: [CodexJSONValue]?
    ) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }

        let action: String
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            action = "Run a command"
        case "item/fileChange/requestApproval", "applyPatchApproval":
            action = "Change files"
        case "item/permissions/requestApproval":
            action = "Grant permissions"
        default:
            action = method
        }

        let source = sourceThreadIdentifier == threadIdentifier
            ? "Voice Console"
            : "Coordinated task \(sourceThreadIdentifier)"
        var lines = [
            "Action: \(action)",
            "Source: \(source)"
        ]
        let highlightedFields: [(String, String)] = [
            ("command", "Command (exact)"),
            ("cwd", "Working directory"),
            ("reason", "Reason"),
            ("permissions", "Permissions"),
            ("grantRoot", "Granted root"),
            ("fileChanges", "File changes"),
            ("proposedExecpolicyAmendment", "Proposed exec-policy change"),
            ("proposedNetworkPolicyAmendments", "Proposed network-policy changes"),
            ("networkApprovalContext", "Network approval context"),
            ("commandActions", "Command actions"),
            ("parsedCmd", "Parsed command"),
            ("environmentId", "Environment"),
            ("approvalId", "Approval ID"),
            ("turnId", "Turn ID"),
            ("itemId", "Item ID"),
            ("callId", "Call ID")
        ]
        for (key, label) in highlightedFields {
            guard
                let value = object[key],
                let rendered = exactJSON(value)
            else {
                continue
            }
            lines.append("\(label):\n\(rendered)")
        }
        if
            let exactFileChanges,
            let renderedChanges = exactJSON(exactFileChanges)
        {
            lines.append(
                "Proposed file changes — paths and diffs (exact):\n"
                    + renderedChanges
            )
        }

        guard let completeRequest = exactJSON(object) else { return nil }
        lines.append("Exact request — all fields:\n\(completeRequest)")
        return lines.joined(separator: "\n\n")
    }

    private func pauseMediaForApproval(
        _ requestIdentifier: CodexAppServerRequestID
    ) async -> Bool {
        do {
            try await mediaTransport.confirmMediaMuted()
        } catch {
            failClosed(bridgeFailure(from: error))
            return false
        }
        guard pendingApproval?.id == requestIdentifier else {
            return false
        }
        guard isApprovalSessionAuthorized else {
            if let strandedApproval = invalidatePendingApproval() {
                await declineForSessionEnd(strandedApproval)
            }
            return false
        }
        applyMediaPolicy(.approval)
        return true
    }

    private func exactJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(["value": value]) else {
            return nil
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [
                    .prettyPrinted,
                    .sortedKeys,
                    .withoutEscapingSlashes,
                    .fragmentsAllowed
                ]
            )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func exactJSON(_ values: [CodexJSONValue]) -> String? {
        guard
            let data = try? JSONEncoder().encode(values),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return exactJSON(object)
    }

    private func safeText(from value: Any) -> String? {
        guard let raw = value as? String else { return nil }
        let normalized = raw
            .unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0)
                    || $0 == "\n"
                    || $0 == "\t"
            }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private func transientExcerpt(from text: String) -> String? {
        guard let normalized = safeText(from: text) else { return nil }
        let limit = 420
        guard normalized.count > limit else { return normalized }
        let boundary = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<boundary]).trimmingCharacters(
            in: .whitespacesAndNewlines
        ) + "…"
    }

    private func waitForRealtimeStarted() async throws {
        guard !realtimeStarted else { return }
        guard let token = realtimeStartToken else {
            throw RealtimeWebRTCFailure.connectionFailed(
                "No realtime start confirmation was requested."
            )
        }
        guard realtimeStartWaiter == nil else {
            throw RealtimeWebRTCFailure.connectionFailed(
                "A realtime start confirmation is already pending."
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            realtimeStartWaiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard
                    let self,
                    !self.realtimeStarted,
                    self.realtimeStartToken == token
                else {
                    return
                }
                self.finishRealtimeStart(
                    throwing: RealtimeWebRTCFailure.connectionFailed(
                        "Codex did not confirm the realtime session in time."
                    )
                )
            }
        }
    }

    private func finishRealtimeStart(throwing error: Error) {
        realtimeStarted = false
        realtimeStartToken = nil
        realtimeStartWaiter?.resume(throwing: error)
        realtimeStartWaiter = nil
    }

    func applyMediaPolicy(_ state: CodexRealtimeMediaPolicyState) {
        if state == .dormant, mediaPolicyState != .dormant {
            voiceSessionGeneration &+= 1
        }
        mediaPolicyState = state
        if state == .dormant {
            // Inactive-system suspension must survive teardown. Otherwise a
            // late realtime/started notification can resurrect live input
            // between dormant cleanup and AppModel's next lifecycle callback.
            mediaSuspensionGeneration &+= 1
            applyTransportPolicy(state)
            return
        }
        guard !voiceMediaIsSuspended else {
            muteMediaTransport()
            return
        }
        applyTransportPolicy(state)
    }

    private func applyTransportPolicy(
        _ state: CodexRealtimeMediaPolicyState
    ) {
        switch state {
        case .connecting:
            muteMediaTransport()
        case .live:
            mediaTransport.setMicrophoneMuted(false)
            mediaTransport.setOutputMuted(true)
        case .assistantLive:
            mediaTransport.setMicrophoneMuted(false)
            mediaTransport.setOutputMuted(false)
        case .approval:
            muteMediaTransport()
        case .dormant:
            muteMediaTransport()
            mediaTransport.stop()
        }
    }

    private func muteMediaTransport() {
        mediaTransport.setMicrophoneMuted(true)
        mediaTransport.setOutputMuted(true)
    }

    private func confirmSuspendedMedia(generation: UInt64) async {
        do {
            try await mediaTransport.confirmMediaMuted()
        } catch {
            guard
                voiceMediaIsSuspended,
                generation == mediaSuspensionGeneration
            else {
                // A wake or stop superseded this confirmation. Reassert the
                // current policy because the late JavaScript call may have
                // muted a newly resumed session.
                if mediaPolicyState != .dormant {
                    applyTransportPolicy(mediaPolicyState)
                }
                return
            }
            failClosed(bridgeFailure(from: error))
            return
        }

        guard
            voiceMediaIsSuspended,
            generation == mediaSuspensionGeneration
        else {
            // The confirmation can complete after wake. Restore the current
            // policy so a stale mute cannot leave the resumed session silent.
            if mediaPolicyState != .dormant {
                applyTransportPolicy(mediaPolicyState)
            }
            return
        }
    }

    private func handleMediaFailure(_ error: RealtimeWebRTCFailure) {
        failClosed(bridgeFailure(from: error))
    }

    private func yieldVoiceEvent(_ event: CodexBridgeEvent) {
        lastVoicePresentationEvent = event
        eventContinuation.yield(event)
    }

    private func yieldFailureIfUnsolicited(
        _ failure: CodexBridgeFailure
    ) {
        eventContinuation.yield(.recoverableFailure(failure))
    }

    private func permissionApprovalResult(from data: Data) throws -> Data {
        guard
            let params = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let permissions = params["permissions"]
        else {
            throw CodexBridgeFailure.voiceControlNotExposed
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "permissions": permissions,
                "scope": "turn",
                "strictAutoReview": false
            ]
        )
    }

    private func bridgeFailure(from error: Error) -> CodexBridgeFailure {
        if let failure = error as? CodexBridgeFailure {
            return failure
        }
        if let failure = error as? CodexAppServerClientFailure {
            switch failure {
            case .executableUnavailable, .launchFailed, .disconnected:
                return .applicationUnavailable
            case .requestTimedOut:
                return .automationTimedOut
            case let .rpcError(_, message):
                if message.localizedCaseInsensitiveContains("not found") {
                    return .voiceConsoleNotFound
                }
                if message.localizedCaseInsensitiveContains("realtime")
                    || message.localizedCaseInsensitiveContains("experimental")
                {
                    return .voiceControlNotExposed
                }
                return .automationTimedOut
            case .malformedMessage:
                return .unsupportedApplicationVersion(
                    installation?.version ?? "unknown"
                )
            }
        }
        if let failure = error as? RealtimeWebRTCFailure {
            switch failure {
            case .microphoneUnavailable:
                return .microphonePermissionRequired
            case .pageLoadTimedOut:
                return .automationTimedOut
            case .invalidOffer, .invalidAnswer, .connectionFailed:
                return .voiceControlNotExposed
            }
        }
        return .automationTimedOut
    }
}
