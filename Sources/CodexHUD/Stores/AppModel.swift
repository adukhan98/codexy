import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var phase: HUDPhase = .dormant
    private(set) var content: HUDContent = .dormant
    @ObservationIgnored private(set) var audioLevel: Double = 0
    private(set) var isTransitioning = false
    private(set) var lastFailure: CodexBridgeFailure?
    private(set) var keyboardFocusRequest = 0
    @ObservationIgnored let orbAudioLevel = OrbAudioLevelState()

    var showIdleOrb = true
    var launchAtLogin = true
    var voiceConsoleTaskIdentifier: String?

    @ObservationIgnored private let codex: any CodexControlling
    @ObservationIgnored private let audioMeter: any AudioMetering
    @ObservationIgnored private let panel: any HUDPresenting
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var meterIsReady = false
    // Fail closed until SystemSessionLifecycle delivers a positive snapshot.
    @ObservationIgnored private var systemInteractionIsActive = false
    @ObservationIgnored private var voiceMediaIsSuspendedForSystem = false

    init(
        codex: any CodexControlling,
        audioMeter: any AudioMetering,
        panel: any HUDPresenting
    ) {
        self.codex = codex
        self.audioMeter = audioMeter
        self.panel = panel
        observeCodexEvents()
    }

    deinit {
        eventTask?.cancel()
        meterTask?.cancel()
    }

    func start() {
        if showIdleOrb {
            panel.show()
            panel.updateLayout(for: .dormant, animated: false)
        }
    }

    func toggleVoiceSession() {
        guard !isTransitioning else { return }

        if phase.isVoiceSessionActive {
            isTransitioning = true
            Task { await stopVoiceSession() }
        } else {
            // Reject the input synchronously so a button press received while
            // locked cannot sit in the main-actor queue and start after wake.
            guard systemInteractionIsActive else { return }
            isTransitioning = true
            Task { await startVoiceSession() }
        }
    }

    func handleOrbTap() {
        if phase == .speaking {
            Task { await interruptAndListen() }
        } else {
            toggleVoiceSession()
        }
    }

    func performPrimaryAction() {
        switch phase {
        case .approval:
            guard !isTransitioning else { return }
            isTransitioning = true
            panel.releaseKeyboardFocus()
            Task { await approvePendingAction() }
        case .result:
            panel.releaseKeyboardFocus()
            codex.openVoiceConsole()
        case .recoverableError:
            panel.releaseKeyboardFocus()
            guard systemInteractionIsActive else { return }
            Task { await repairConnection() }
        case .dormant, .connecting, .listening, .thinking, .speaking:
            toggleVoiceSession()
        }
    }

    func performSecondaryAction() {
        switch phase {
        case .approval:
            guard !isTransitioning else { return }
            isTransitioning = true
            panel.releaseKeyboardFocus()
            Task {
                defer { isTransitioning = false }
                await codex.rejectPendingAction()
            }
        case .result:
            panel.releaseKeyboardFocus()
            transition(to: .listening, content: listeningContent)
        case .recoverableError:
            panel.releaseKeyboardFocus()
            transition(to: .dormant, content: .dormant)
        case .dormant, .connecting, .listening, .thinking, .speaking:
            break
        }
    }

    func setIdleOrbVisible(_ visible: Bool) {
        showIdleOrb = visible
        if visible || phase.isVoiceSessionActive {
            panel.show()
        } else {
            panel.hide()
        }
    }

    func openVoiceConsole() {
        codex.openVoiceConsole()
    }

    func focusHUDControls() {
        guard phase.isExpanded else { return }
        keyboardFocusRequest &+= 1
        panel.focusControls()
    }

    func releaseKeyboardFocus() {
        panel.releaseKeyboardFocus()
    }

    /// Keeps capture and visual metering aligned with the real macOS session,
    /// rather than merely freezing the HUD's presentation layer.
    func setSystemInteractionActive(_ isActive: Bool) {
        guard systemInteractionIsActive != isActive else { return }
        systemInteractionIsActive = isActive

        if isActive {
            resumeVoiceMediaIfNeeded()
        } else {
            suspendVoiceMedia()
        }
    }

    func repairConnection() async {
        guard !isTransitioning, systemInteractionIsActive else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let failureBeforeRepair =
            lastFailure ?? CodexBridgeFailure.applicationUnavailable
        transition(to: .connecting, content: connectingContent)
        var didStartConversation = false

        do {
            try await codex.repairConnection()
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: false,
                    restoring: failureBeforeRepair
                )
                return
            }
            try await codex.startVoiceConversation()
            didStartConversation = true
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: true,
                    restoring: failureBeforeRepair
                )
                return
            }
            try await audioMeter.start()
            meterIsReady = true
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: true,
                    restoring: failureBeforeRepair
                )
                return
            }
            if phase == .recoverableError {
                meterIsReady = false
                audioMeter.stop()
                await codex.stopVoiceConversation()
                didStartConversation = false
            } else {
                if systemInteractionIsActive {
                    beginMeterPolling()
                }
                lastFailure = nil
                if phase == .connecting {
                    transition(to: .listening, content: listeningContent)
                }
            }
        } catch {
            if didStartConversation {
                await codex.stopVoiceConversation()
            }
            present(error)
        }
    }

    private func startVoiceSession() async {
        defer { isTransitioning = false }
        guard systemInteractionIsActive else { return }

        panel.show()
        transition(to: .connecting, content: connectingContent)
        var didStartConversation = false

        do {
            try await codex.prepareVoiceConsole()
            if case let .ready(taskIdentifier) = codex.connectionState {
                voiceConsoleTaskIdentifier = taskIdentifier
            }
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: false
                )
                return
            }
            try await codex.startVoiceConversation()
            didStartConversation = true
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: true
                )
                return
            }
            try await audioMeter.start()
            meterIsReady = true
            guard systemInteractionIsActive else {
                await settleInterruptedStartup(
                    conversationStarted: true
                )
                return
            }
            if phase == .recoverableError {
                meterIsReady = false
                audioMeter.stop()
                await codex.stopVoiceConversation()
                didStartConversation = false
            } else {
                if systemInteractionIsActive {
                    beginMeterPolling()
                }
                lastFailure = nil
                if phase == .connecting {
                    transition(to: .listening, content: listeningContent)
                }
            }
        } catch {
            if didStartConversation {
                await codex.stopVoiceConversation()
            }
            audioMeter.stop()
            present(error)
        }
    }

    private func stopVoiceSession() async {
        meterTask?.cancel()
        meterTask = nil
        meterIsReady = false
        audioLevel = 0
        orbAudioLevel.level = 0
        audioMeter.stop()
        lastFailure = nil
        // The single on/off control is authoritative: reflect microphone-off
        // immediately, before any app-server cleanup round trip completes.
        transition(to: .dormant, content: .dormant)

        if !showIdleOrb {
            panel.hide()
        }
        await codex.stopVoiceConversation()
        isTransitioning = false
    }

    private func interruptAndListen() async {
        do {
            try await codex.interruptSpeechAndListen()
            transition(to: .listening, content: listeningContent)
        } catch {
            present(error)
        }
    }

    private func approvePendingAction() async {
        defer { isTransitioning = false }
        do {
            // Bridge events are the sole approval-phase authority. Synthesizing
            // a local transition here could hide a newer approval that arrived
            // between the awaited response and this task resuming.
            try await codex.approvePendingAction()
        } catch {
            present(error)
        }
    }

    private func observeCodexEvents() {
        eventTask = Task { [weak self, codex] in
            for await event in codex.events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CodexBridgeEvent) {
        switch event {
        case .listening:
            transition(to: .listening, content: listeningContent)
        case .thinking:
            transition(to: .thinking, content: thinkingContent)
        case .speaking:
            transition(
                to: .speaking,
                content: HUDContent(
                    eyebrow: "VOICE CONSOLE",
                    title: "Codex is speaking",
                    detail: "Speak to interrupt",
                    primaryActionTitle: nil,
                    secondaryActionTitle: nil
                )
            )
        case let .approval(title, detail):
            transition(
                to: .approval,
                content: HUDContent(
                    eyebrow: "APPROVAL REQUIRED",
                    title: title,
                    detail: detail,
                    primaryActionTitle: "Approve",
                    secondaryActionTitle: "Reject"
                )
            )
        case let .result(title, detail):
            transition(
                to: .result,
                content: HUDContent(
                    eyebrow: "VOICE CONSOLE",
                    title: title,
                    detail: detail,
                    primaryActionTitle: "Open in Codex",
                    secondaryActionTitle: "Dismiss"
                )
            )
        case let .recoverableFailure(failure):
            present(failure)
        }
    }

    private func present(_ error: Error) {
        let failure = (error as? CodexBridgeFailure) ?? .automationTimedOut
        present(failure)
    }

    private func present(_ failure: CodexBridgeFailure) {
        meterTask?.cancel()
        meterTask = nil
        meterIsReady = false
        audioMeter.stop()
        audioLevel = 0
        orbAudioLevel.level = 0
        lastFailure = failure
        transition(
            to: .recoverableError,
            content: HUDContent(
                eyebrow: "CONNECTION PAUSED",
                title: "Codex needs attention",
                detail: failure.userFacingMessage,
                primaryActionTitle: "Repair Connection",
                secondaryActionTitle: "Not Now"
            )
        )
    }

    private func transition(to nextPhase: HUDPhase, content nextContent: HUDContent) {
        if phase.isExpanded, !nextPhase.isExpanded {
            panel.releaseKeyboardFocus()
        }
        phase = nextPhase
        content = nextContent
        panel.updateLayout(for: nextPhase, animated: true)
    }

    private func beginMeterPolling() {
        guard systemInteractionIsActive, meterIsReady else { return }
        meterTask?.cancel()
        meterTask = Task { [weak self, audioMeter] in
            while !Task.isCancelled {
                guard let self else { return }
                let nextLevel: Double
                switch phase {
                case .listening, .speaking:
                    nextLevel = min(max(audioMeter.level, 0), 1)
                case .dormant, .connecting, .thinking, .approval, .result,
                     .recoverableError:
                    nextLevel = 0
                }
                if abs(audioLevel - nextLevel) >= 0.003 {
                    audioLevel = nextLevel
                    orbAudioLevel.level = nextLevel
                }
                // Thirty samples per second remains perceptually immediate,
                // while Core Animation interpolates between measurements at
                // the display refresh rate without waking SwiftUI at 60 Hz.
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func suspendVoiceMedia() {
        meterTask?.cancel()
        meterTask = nil
        audioLevel = 0
        orbAudioLevel.level = 0

        guard phase.isVoiceSessionActive || isTransitioning else {
            return
        }
        voiceMediaIsSuspendedForSystem = true
        codex.suspendVoiceMedia()
    }

    private func resumeVoiceMediaIfNeeded() {
        if voiceMediaIsSuspendedForSystem {
            voiceMediaIsSuspendedForSystem = false
            // A lock can win while startup or stop is in flight. Clear the
            // bridge's fail-closed latch even if that operation settled
            // dormant; bridge resume never opens dormant media.
            codex.resumeVoiceMedia()
        }
        if
            (phase.isVoiceSessionActive || isTransitioning),
            meterIsReady
        {
            beginMeterPolling()
        }
    }

    private func settleInterruptedStartup(
        conversationStarted: Bool,
        restoring failure: CodexBridgeFailure? = nil
    ) async {
        meterTask?.cancel()
        meterTask = nil
        if meterIsReady {
            audioMeter.stop()
        }
        meterIsReady = false
        audioLevel = 0
        orbAudioLevel.level = 0

        if let failure {
            lastFailure = failure
            transition(
                to: .recoverableError,
                content: HUDContent(
                    eyebrow: "CONNECTION PAUSED",
                    title: "Codex needs attention",
                    detail: failure.userFacingMessage,
                    primaryActionTitle: "Repair Connection",
                    secondaryActionTitle: "Not Now"
                )
            )
        } else {
            transition(to: .dormant, content: .dormant)
            if !showIdleOrb {
                panel.hide()
            }
        }

        if conversationStarted {
            await codex.stopVoiceConversation()
        }
    }

    private var connectingContent: HUDContent {
        HUDContent(
            eyebrow: "VOICE CONSOLE",
            title: "Connecting to Codex",
            detail: nil,
            primaryActionTitle: nil,
            secondaryActionTitle: nil
        )
    }

    private var listeningContent: HUDContent {
        HUDContent(
            eyebrow: "MICROPHONE LIVE",
            title: "Listening",
            detail: "⇧⌥⌘Space to stop",
            primaryActionTitle: nil,
            secondaryActionTitle: nil
        )
    }

    private var thinkingContent: HUDContent {
        HUDContent(
            eyebrow: "VOICE CONSOLE",
            title: "Codex is thinking",
            detail: nil,
            primaryActionTitle: nil,
            secondaryActionTitle: nil
        )
    }
}
