import Foundation

@MainActor
protocol CodexControlling: AnyObject {
    var connectionState: CodexConnectionState { get }
    var events: AsyncStream<CodexBridgeEvent> { get }

    func prepareVoiceConsole() async throws
    func startVoiceConversation() async throws
    func stopVoiceConversation() async
    func suspendVoiceMedia()
    func resumeVoiceMedia()
    func interruptSpeechAndListen() async throws
    @discardableResult
    func approvePendingAction() async throws -> CodexApprovalActionResult
    @discardableResult
    func rejectPendingAction() async -> CodexApprovalActionResult
    func repairConnection() async throws
    func openVoiceConsole()
}

enum CodexApprovalActionResult: Equatable, Sendable {
    case completed
    case deferredUntilRealtimeStarts
    case stale
    case superseded
    case sessionEnded
}

enum CodexBridgeEvent: Equatable, Sendable {
    case listening
    case thinking
    case speaking
    case approval(title: String, detail: String)
    case result(title: String, detail: String?)
    case recoverableFailure(CodexBridgeFailure)
}

enum CodexConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready(taskIdentifier: String)
    case unavailable(CodexBridgeFailure)
}

enum CodexBridgeFailure: Error, Equatable, Sendable {
    case accessibilityPermissionRequired
    case microphonePermissionRequired
    case applicationUnavailable
    case untrustedCodexInstallation
    case subscriptionAuthenticationRequired
    case voiceConsoleNotFound
    case voiceControlNotExposed
    case automationTimedOut
    case unsupportedApplicationVersion(String)

    var userFacingMessage: String {
        switch self {
        case .accessibilityPermissionRequired:
            """
            Codex could not open Voice Console directly. Allow Accessibility \
            for the optional fallback, or open the task in Codex.
            """
        case .microphonePermissionRequired:
            """
            Microphone access is off. Enable Codex HUD in System Settings › \
            Privacy & Security › Microphone, then try again.
            """
        case .applicationUnavailable:
            "The official Codex app could not be opened."
        case .untrustedCodexInstallation:
            """
            This Codex installation could not be verified as an official OpenAI \
            build. Reinstall Codex from OpenAI, then repair the connection.
            """
        case .subscriptionAuthenticationRequired:
            """
            Sign in to the official Codex app with your ChatGPT subscription, \
            then repair the connection. Codex HUD never uses API-key billing.
            """
        case .voiceConsoleNotFound:
            "Voice Console could not be restored."
        case .voiceControlNotExposed:
            "This Codex version does not expose its voice control."
        case .automationTimedOut:
            "Codex did not respond in time."
        case let .unsupportedApplicationVersion(version):
            "Codex \(version) needs a compatibility update."
        }
    }
}
