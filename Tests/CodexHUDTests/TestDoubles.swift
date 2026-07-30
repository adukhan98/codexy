import Foundation
import Testing
@testable import CodexHUD

enum TestFailure: Error, Equatable, Sendable {
    case injected
}

actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@MainActor
final class FakeCodexController: CodexControlling {
    enum Call: Equatable {
        case prepareVoiceConsole
        case startVoiceConversation
        case stopVoiceConversation
        case suspendVoiceMedia
        case resumeVoiceMedia
        case interruptSpeechAndListen
        case approvePendingAction
        case rejectPendingAction
        case repairConnection
        case openVoiceConsole
    }

    var connectionState: CodexConnectionState = .disconnected
    let events: AsyncStream<CodexBridgeEvent>

    var calls: [Call] = []
    var preparedConnectionState: CodexConnectionState?
    var prepareError: (any Error)?
    var startError: (any Error)?
    var interruptError: (any Error)?
    var approveError: (any Error)?
    var approveResult: CodexApprovalActionResult = .completed
    var rejectResult: CodexApprovalActionResult = .completed
    var repairError: (any Error)?
    var prepareGate: TestGate?
    var stopGate: TestGate?
    var approveGate: TestGate?

    private let eventContinuation: AsyncStream<CodexBridgeEvent>.Continuation

    init() {
        let stream = AsyncStream<CodexBridgeEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func prepareVoiceConsole() async throws {
        calls.append(.prepareVoiceConsole)
        if let prepareGate {
            await prepareGate.wait()
        }
        if let prepareError {
            throw prepareError
        }
        if let preparedConnectionState {
            connectionState = preparedConnectionState
        }
    }

    func startVoiceConversation() async throws {
        calls.append(.startVoiceConversation)
        if let startError {
            throw startError
        }
    }

    func stopVoiceConversation() async {
        calls.append(.stopVoiceConversation)
        if let stopGate {
            await stopGate.wait()
        }
    }

    func suspendVoiceMedia() {
        calls.append(.suspendVoiceMedia)
    }

    func resumeVoiceMedia() {
        calls.append(.resumeVoiceMedia)
    }

    func interruptSpeechAndListen() async throws {
        calls.append(.interruptSpeechAndListen)
        if let interruptError {
            throw interruptError
        }
    }

    @discardableResult
    func approvePendingAction() async throws -> CodexApprovalActionResult {
        calls.append(.approvePendingAction)
        if let approveGate {
            await approveGate.wait()
        }
        if let approveError {
            throw approveError
        }
        if approveResult == .completed {
            eventContinuation.yield(.thinking)
        }
        return approveResult
    }

    @discardableResult
    func rejectPendingAction() async -> CodexApprovalActionResult {
        calls.append(.rejectPendingAction)
        if rejectResult == .completed {
            eventContinuation.yield(.listening)
        }
        return rejectResult
    }

    func repairConnection() async throws {
        calls.append(.repairConnection)
        if let repairError {
            throw repairError
        }
    }

    func openVoiceConsole() {
        calls.append(.openVoiceConsole)
    }

    func emit(_ event: CodexBridgeEvent) {
        eventContinuation.yield(event)
    }
}

@MainActor
final class FakeAudioMeter: AudioMetering {
    enum Call: Equatable {
        case start
        case stop
    }

    var level: Double = 0
    var startError: (any Error)?
    var startGate: TestGate?
    var calls: [Call] = []

    func start() async throws {
        calls.append(.start)
        if let startGate {
            await startGate.wait()
        }
        if let startError {
            throw startError
        }
    }

    func stop() {
        calls.append(.stop)
    }
}

@MainActor
final class FakeHUDPresenter: HUDPresenting {
    enum Call: Equatable {
        case show
        case hide
        case reposition
        case updateLayout(phase: HUDPhase, animated: Bool)
        case focusControls
        case releaseKeyboardFocus
    }

    var calls: [Call] = []

    func show() {
        calls.append(.show)
    }

    func hide() {
        calls.append(.hide)
    }

    func reposition() {
        calls.append(.reposition)
    }

    func updateLayout(for phase: HUDPhase, animated: Bool) {
        calls.append(.updateLayout(phase: phase, animated: animated))
    }

    func focusControls() {
        calls.append(.focusControls)
    }

    func releaseKeyboardFocus() {
        calls.append(.releaseKeyboardFocus)
    }
}

@MainActor
func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }

    return condition()
}
