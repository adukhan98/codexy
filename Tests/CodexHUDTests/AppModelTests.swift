import Testing
@testable import CodexHUD

@MainActor
@Suite("App model state machine", .serialized)
struct AppModelTests {
    @Test("Startup shows a dormant, non-activating HUD")
    func startup() {
        let harness = Harness()

        harness.model.start()

        #expect(harness.model.phase == .dormant)
        #expect(harness.model.content == .dormant)
        #expect(
            harness.panel.calls == [
                .show,
                .updateLayout(phase: .dormant, animated: false)
            ]
        )
    }

    @Test("A successful toggle binds Voice Console before opening the microphone")
    func successfulStart() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .listening &&
                !harness.model.isTransitioning
        })
        #expect(
            harness.codex.calls == [
                .prepareVoiceConsole,
                .startVoiceConversation
            ]
        )
        #expect(harness.audio.calls == [.start])
        #expect(
            harness.model.voiceConsoleTaskIdentifier ==
                "voice-console-42"
        )
        #expect(harness.model.content.eyebrow == "MICROPHONE LIVE")
        #expect(harness.model.content.title == "Listening")
        #expect(harness.panel.calls.contains(.show))
        #expect(
            harness.panel.calls.contains(
                .updateLayout(phase: .connecting, animated: true)
            )
        )
        #expect(
            harness.panel.calls.contains(
                .updateLayout(phase: .listening, animated: true)
            )
        )
    }

    @Test("An immediate double toggle cannot start two conversations")
    func immediateDoubleToggleIsDebounced() async {
        let harness = Harness()
        let gate = TestGate()
        harness.codex.prepareGate = gate
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )

        harness.model.toggleVoiceSession()
        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.codex.calls.filter {
                $0 == .prepareVoiceConsole
            }.count >= 1
        })
        let prepareCountBeforeRelease = harness.codex.calls.filter {
            $0 == .prepareVoiceConsole
        }.count
        await gate.open()
        #expect(await eventually { !harness.model.isTransitioning })

        #expect(prepareCountBeforeRelease == 1)
        #expect(
            harness.codex.calls.filter {
                $0 == .startVoiceConversation
            }.count == 1
        )
        #expect(
            harness.audio.calls.filter { $0 == .start }.count == 1
        )
    }

    @Test("Stopping shuts down metering and the Codex voice conversation")
    func stopSession() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.level = 0.72
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })
        #expect(await eventually { harness.model.audioLevel == 0.72 })

        harness.model.setIdleOrbVisible(false)
        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .dormant &&
                !harness.model.isTransitioning
        })
        #expect(
            harness.codex.calls.contains(.stopVoiceConversation)
        )
        #expect(harness.audio.calls.last == .stop)
        #expect(harness.model.audioLevel == 0)
        #expect(harness.panel.calls.last == .hide)
    }

    @Test("A bridge start failure pauses the microphone and presents repair")
    func startFailure() async {
        let harness = Harness()
        harness.codex.prepareError =
            CodexBridgeFailure.accessibilityPermissionRequired

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .recoverableError &&
                !harness.model.isTransitioning
        })
        #expect(
            harness.model.lastFailure ==
                .accessibilityPermissionRequired
        )
        #expect(harness.model.content.eyebrow == "CONNECTION PAUSED")
        #expect(
            harness.model.content.primaryActionTitle ==
                "Repair Connection"
        )
        #expect(
            harness.model.content.secondaryActionTitle == "Not Now"
        )
        #expect(harness.audio.calls.contains(.stop))
        #expect(
            !harness.codex.calls.contains(.startVoiceConversation)
        )
    }

    @Test("An unknown integration error maps to a precise safe failure")
    func unknownErrorMapping() async {
        let harness = Harness()
        harness.codex.prepareError = TestFailure.injected

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        #expect(harness.model.lastFailure == .automationTimedOut)
        #expect(harness.model.audioLevel == 0)
    }

    @Test("An audio-start failure closes an already-started voice conversation")
    func audioFailureRollsBackCodex() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.startError = TestFailure.injected

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .recoverableError &&
                !harness.model.isTransitioning
        })
        #expect(
            harness.codex.calls.contains(.startVoiceConversation)
        )
        #expect(
            harness.codex.calls.contains(.stopVoiceConversation)
        )
        #expect(harness.audio.calls.contains(.stop))
    }

    @Test("An approval arriving during startup is never overwritten by listening")
    func approvalDuringStartupIsPreserved() async {
        let harness = Harness()
        let audioGate = TestGate()
        harness.audio.startGate = audioGate
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )

        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.audio.calls.contains(.start)
        })

        harness.codex.emit(
            .approval(
                title: "Send the message?",
                detail: "This is externally visible."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })

        await audioGate.open()
        #expect(await eventually { !harness.model.isTransitioning })
        #expect(harness.model.phase == .approval)
        #expect(harness.model.content.title == "Send the message?")
        #expect(
            harness.model.content.detail ==
                "This is externally visible."
        )
        #expect(
            !harness.codex.calls.contains(.stopVoiceConversation)
        )
    }

    @Test("Speaking supports immediate barge-in")
    func bargeIn() async {
        let harness = Harness()
        harness.codex.emit(.speaking)
        #expect(await eventually { harness.model.phase == .speaking })

        harness.model.handleOrbTap()

        #expect(await eventually { harness.model.phase == .listening })
        #expect(
            harness.codex.calls.contains(.interruptSpeechAndListen)
        )
    }

    @Test("A failed barge-in becomes a recoverable error")
    func failedBargeIn() async {
        let harness = Harness()
        harness.codex.interruptError =
            CodexBridgeFailure.voiceControlNotExposed
        harness.codex.emit(.speaking)
        #expect(await eventually { harness.model.phase == .speaking })

        harness.model.handleOrbTap()

        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        #expect(harness.model.lastFailure == .voiceControlNotExposed)
        #expect(harness.audio.calls.contains(.stop))
    }

    @Test("Approval always offers explicit approve and reject paths")
    func approvalPaths() async {
        let harness = Harness()
        harness.codex.emit(
            .approval(
                title: "Send the message?",
                detail: "This is externally visible."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })
        #expect(harness.model.content.primaryActionTitle == "Approve")
        #expect(harness.model.content.secondaryActionTitle == "Reject")

        harness.model.performSecondaryAction()
        #expect(await eventually { harness.model.phase == .listening })
        #expect(
            harness.codex.calls.contains(.rejectPendingAction)
        )

        harness.codex.emit(
            .approval(
                title: "Delete this file?",
                detail: "This cannot be undone."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })
        harness.model.performPrimaryAction()
        #expect(await eventually { harness.model.phase == .thinking })
        #expect(
            harness.codex.calls.contains(.approvePendingAction)
        )
    }

    @Test("Keyboard focus is explicit and exits through the safe action")
    func explicitKeyboardFocus() async {
        let harness = Harness()
        harness.codex.emit(
            .approval(
                title: "Create this Codex task?",
                detail: "This action is externally visible."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })
        #expect(!harness.panel.calls.contains(.focusControls))

        harness.model.focusHUDControls()

        #expect(harness.model.keyboardFocusRequest == 1)
        #expect(harness.panel.calls.last == .focusControls)

        harness.model.performSecondaryAction()

        #expect(await eventually { harness.model.phase == .listening })
        #expect(
            harness.panel.calls.contains(.releaseKeyboardFocus)
        )
        #expect(
            harness.codex.calls.contains(.rejectPendingAction)
        )
    }

    @Test("An external compact transition always releases HUD keyboard focus")
    func externalTransitionReleasesKeyboardFocus() async {
        let harness = Harness()
        harness.codex.emit(
            .result(title: "Done", detail: "The task completed.")
        )
        #expect(await eventually { harness.model.phase == .result })
        harness.model.focusHUDControls()
        #expect(harness.panel.calls.last == .focusControls)

        harness.codex.emit(.listening)

        #expect(await eventually { harness.model.phase == .listening })
        #expect(harness.panel.calls.last == .updateLayout(
            phase: .listening,
            animated: true
        ))
        #expect(
            harness.panel.calls.contains(.releaseKeyboardFocus)
        )
    }

    @Test("An immediate double approval cannot execute an action twice")
    func immediateDoubleApprovalIsDebounced() async {
        let harness = Harness()
        let gate = TestGate()
        harness.codex.approveGate = gate
        harness.codex.emit(
            .approval(
                title: "Create this Codex task?",
                detail: "This action is externally visible."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })

        harness.model.performPrimaryAction()
        harness.model.performPrimaryAction()

        #expect(await eventually {
            harness.codex.calls.contains(.approvePendingAction)
        })
        #expect(
            harness.codex.calls.filter {
                $0 == .approvePendingAction
            }.count == 1
        )
        await gate.open()
        #expect(await eventually {
            harness.model.phase == .thinking &&
                !harness.model.isTransitioning
        })
    }

    @Test("The one-button stop leaves Approval visibly off before RPC cleanup")
    func stopDuringApprovalIsImmediate() async {
        let harness = Harness()
        let stopGate = TestGate()
        harness.codex.stopGate = stopGate
        harness.codex.emit(
            .approval(
                title: "Run this command?",
                detail: "Exact request"
            )
        )
        #expect(await eventually { harness.model.phase == .approval })

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.codex.calls.contains(.stopVoiceConversation)
        })
        #expect(harness.model.phase == .dormant)
        #expect(harness.model.content == .dormant)
        #expect(harness.model.isTransitioning)

        await stopGate.open()
        #expect(await eventually { !harness.model.isTransitioning })
        #expect(harness.model.phase == .dormant)
    }

    @Test("A terminal bridge failure wins over an approval completion")
    func terminalFailureDuringApprovalWins() async {
        let harness = Harness()
        let approvalGate = TestGate()
        harness.codex.approveGate = approvalGate
        harness.codex.approveResult = .sessionEnded
        harness.codex.emit(
            .approval(
                title: "Publish?",
                detail: "Exact request"
            )
        )
        #expect(await eventually { harness.model.phase == .approval })

        harness.model.performPrimaryAction()
        #expect(await eventually {
            harness.codex.calls.contains(.approvePendingAction)
        })
        harness.codex.emit(
            .recoverableFailure(.applicationUnavailable)
        )
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })

        await approvalGate.open()
        #expect(await eventually { !harness.model.isTransitioning })
        #expect(harness.model.phase == .recoverableError)
        #expect(harness.model.lastFailure == .applicationUnavailable)
    }

    @Test("A replacement approval is never hidden by the prior completion")
    func replacementApprovalWins() async {
        let harness = Harness()
        let approvalGate = TestGate()
        harness.codex.approveGate = approvalGate
        harness.codex.approveResult = .superseded
        harness.codex.emit(
            .approval(title: "Action A?", detail: "Exact request A")
        )
        #expect(await eventually { harness.model.phase == .approval })

        harness.model.performPrimaryAction()
        #expect(await eventually {
            harness.codex.calls.contains(.approvePendingAction)
        })
        harness.codex.emit(
            .approval(title: "Action B?", detail: "Exact request B")
        )
        #expect(await eventually {
            harness.model.content.title == "Action B?"
        })

        await approvalGate.open()
        #expect(await eventually { !harness.model.isTransitioning })
        #expect(harness.model.phase == .approval)
        #expect(harness.model.content.title == "Action B?")
        #expect(harness.model.content.detail == "Exact request B")
    }

    @Test("Approval failure never pretends the action succeeded")
    func approvalFailure() async {
        let harness = Harness()
        harness.codex.approveError =
            CodexBridgeFailure.automationTimedOut
        harness.codex.emit(
            .approval(
                title: "Publish?",
                detail: "This is externally visible."
            )
        )
        #expect(await eventually { harness.model.phase == .approval })

        harness.model.performPrimaryAction()

        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        #expect(harness.model.lastFailure == .automationTimedOut)
    }

    @Test("Result opens only after an explicit user action")
    func resultAction() async {
        let harness = Harness()
        harness.codex.emit(
            .result(
                title: "Done",
                detail: "Three files changed."
            )
        )
        #expect(await eventually { harness.model.phase == .result })
        #expect(
            !harness.codex.calls.contains(.openVoiceConsole)
        )

        harness.model.performPrimaryAction()

        #expect(harness.codex.calls.last == .openVoiceConsole)
        #expect(harness.model.phase == .result)
    }

    @Test("Dismissed results return to listening without opening Codex")
    func dismissResult() async {
        let harness = Harness()
        harness.codex.emit(.result(title: "Done", detail: nil))
        #expect(await eventually { harness.model.phase == .result })

        harness.model.performSecondaryAction()

        #expect(harness.model.phase == .listening)
        #expect(
            !harness.codex.calls.contains(.openVoiceConsole)
        )
    }

    @Test("Repair reconnects, restarts metering, and clears failure state")
    func repair() async {
        let harness = Harness()
        harness.codex.emit(
            .recoverableFailure(.applicationUnavailable)
        )
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })

        await harness.model.repairConnection()

        #expect(harness.model.phase == .listening)
        #expect(harness.model.lastFailure == nil)
        #expect(
            Array(harness.codex.calls.suffix(2)) == [
                .repairConnection,
                .startVoiceConversation
            ]
        )
        #expect(harness.audio.calls.contains(.start))
    }

    @Test("Failed repair keeps the microphone paused")
    func failedRepair() async {
        let harness = Harness()
        harness.codex.repairError =
            CodexBridgeFailure.applicationUnavailable
        harness.codex.emit(
            .recoverableFailure(.applicationUnavailable)
        )
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })

        await harness.model.repairConnection()

        #expect(harness.model.phase == .recoverableError)
        #expect(harness.model.lastFailure == .applicationUnavailable)
        #expect(harness.model.audioLevel == 0)
        #expect(harness.audio.calls.last == .stop)
    }

    @Test("A successful retry clears stale failure metadata")
    func successfulRetryClearsFailure() async {
        let harness = Harness()
        harness.codex.prepareError =
            CodexBridgeFailure.applicationUnavailable
        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        #expect(harness.model.lastFailure == .applicationUnavailable)

        harness.model.performSecondaryAction()
        harness.codex.prepareError = nil
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .listening &&
                !harness.model.isTransitioning
        })
        #expect(harness.model.lastFailure == nil)
    }

    @Test("Metering is clamped to a safe normalized range")
    func meterClamping() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.level = 2.4
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })
        #expect(await eventually { harness.model.audioLevel == 1 })

        harness.audio.level = 0.41
        #expect(await eventually { harness.model.audioLevel == 0.41 })
        harness.audio.level = -0.8
        #expect(await eventually { harness.model.audioLevel == 0 })
    }

    @Test("Lock or display sleep mutes media and cancels visual metering")
    func inactiveSystemSuspendsMedia() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.level = 0.72
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })
        #expect(await eventually { harness.model.audioLevel == 0.72 })

        harness.model.setSystemInteractionActive(false)
        harness.audio.level = 0.98

        #expect(harness.codex.calls.last == .suspendVoiceMedia)
        #expect(harness.model.audioLevel == 0)
        #expect(harness.model.orbAudioLevel.level == 0)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(harness.model.audioLevel == 0)
    }

    @Test("Wake resumes the prior media policy and visual meter")
    func activeSystemResumesMedia() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.level = 0.37
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })

        harness.model.setSystemInteractionActive(false)
        harness.audio.level = 0.81
        harness.model.setSystemInteractionActive(true)

        #expect(harness.codex.calls.last == .resumeVoiceMedia)
        #expect(await eventually { harness.model.audioLevel == 0.81 })
        #expect(
            await eventually {
                harness.model.orbAudioLevel.level == 0.81
            }
        )
    }

    @Test("Stop while locked cannot poison the next unlocked session")
    func stopWhileLockedThenRestartAfterUnlock() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })

        harness.model.setSystemInteractionActive(false)
        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.model.phase == .dormant &&
                !harness.model.isTransitioning
        })
        #expect(
            Array(harness.codex.calls.suffix(2)) == [
                .suspendVoiceMedia,
                .stopVoiceConversation
            ]
        )

        harness.model.setSystemInteractionActive(true)
        #expect(harness.codex.calls.last == .resumeVoiceMedia)

        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.model.phase == .listening &&
                !harness.model.isTransitioning
        })
        #expect(
            Array(harness.codex.calls.suffix(2)) == [
                .prepareVoiceConsole,
                .startVoiceConversation
            ]
        )
        #expect(
            harness.audio.calls.filter { $0 == .start }.count == 2
        )
    }

    @Test("Starting while inactive performs no voice or meter work")
    func inactiveStartIsRejectedBeforePreparation() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.level = 0.66
        harness.model.setSystemInteractionActive(false)

        harness.model.toggleVoiceSession()

        #expect(await eventually {
            harness.model.phase == .dormant &&
                !harness.model.isTransitioning
        })
        #expect(harness.codex.calls.isEmpty)
        #expect(harness.audio.calls.isEmpty)
        #expect(harness.model.audioLevel == 0)
        #expect(harness.model.orbAudioLevel.level == 0)
    }

    @Test("A newly initialized model rejects voice work before activation")
    func rawModelRequiresPositiveLifecycleSnapshot() async {
        let harness = Harness(activateSystemInteraction: false)
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )

        harness.model.toggleVoiceSession()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(harness.model.phase == .dormant)
        #expect(!harness.model.isTransitioning)
        #expect(harness.codex.calls.isEmpty)
        #expect(harness.audio.calls.isEmpty)
    }

    @Test("An inactive start request cannot queue across immediate wake")
    func inactiveStartDoesNotQueueAcrossWake() async {
        let harness = Harness()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.model.setSystemInteractionActive(false)

        harness.model.toggleVoiceSession()
        harness.model.setSystemInteractionActive(true)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(harness.model.phase == .dormant)
        #expect(!harness.model.isTransitioning)
        #expect(harness.codex.calls.isEmpty)
        #expect(harness.audio.calls.isEmpty)
    }

    @Test("Lock during Voice Console preparation cannot start media")
    func lockDuringPreparationAbortsBeforeVoiceStart() async {
        let harness = Harness()
        let prepareGate = TestGate()
        harness.codex.prepareGate = prepareGate
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )

        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.codex.calls.contains(.prepareVoiceConsole)
        })

        harness.model.setSystemInteractionActive(false)
        await prepareGate.open()

        #expect(await eventually {
            harness.model.phase == .dormant &&
                !harness.model.isTransitioning
        })
        #expect(
            harness.codex.calls == [
                .prepareVoiceConsole,
                .suspendVoiceMedia
            ]
        )
        #expect(harness.audio.calls.isEmpty)

        harness.model.setSystemInteractionActive(true)
        #expect(harness.codex.calls.last == .resumeVoiceMedia)

        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.model.phase == .listening &&
                !harness.model.isTransitioning
        })
        #expect(
            Array(harness.codex.calls.suffix(2)) == [
                .prepareVoiceConsole,
                .startVoiceConversation
            ]
        )
        #expect(harness.audio.calls == [.start])
    }

    @Test("Lock after voice start tears down before metering can remain live")
    func lockDuringMeterStartupStopsConversation() async {
        let harness = Harness()
        let meterGate = TestGate()
        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.audio.startGate = meterGate

        harness.model.toggleVoiceSession()
        #expect(await eventually {
            harness.audio.calls.contains(.start)
        })

        harness.model.setSystemInteractionActive(false)
        await meterGate.open()

        #expect(await eventually {
            harness.model.phase == .dormant &&
                !harness.model.isTransitioning
        })
        #expect(
            Array(harness.codex.calls.suffix(2)) == [
                .suspendVoiceMedia,
                .stopVoiceConversation
            ]
        )
        #expect(harness.audio.calls == [.start, .stop])
        #expect(harness.model.audioLevel == 0)
        #expect(harness.model.orbAudioLevel.level == 0)
    }

    @Test("Repair while inactive performs no bridge or media work")
    func inactiveRepairIsRejectedBeforeBridgeWork() async {
        let harness = Harness()
        harness.codex.emit(
            .recoverableFailure(.applicationUnavailable)
        )
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        harness.model.setSystemInteractionActive(false)
        let bridgeCallsBeforeRepair = harness.codex.calls
        let meterCallsBeforeRepair = harness.audio.calls

        await harness.model.repairConnection()

        #expect(harness.model.phase == .recoverableError)
        #expect(
            harness.model.lastFailure == .applicationUnavailable
        )
        #expect(harness.codex.calls == bridgeCallsBeforeRepair)
        #expect(harness.audio.calls == meterCallsBeforeRepair)
    }

    @Test("An inactive repair request cannot queue across immediate wake")
    func inactiveRepairDoesNotQueueAcrossWake() async {
        let harness = Harness()
        harness.codex.emit(
            .recoverableFailure(.applicationUnavailable)
        )
        #expect(await eventually {
            harness.model.phase == .recoverableError
        })
        harness.model.setSystemInteractionActive(false)
        let bridgeCallsBeforeRepair = harness.codex.calls
        let meterCallsBeforeRepair = harness.audio.calls

        harness.model.performPrimaryAction()
        harness.model.setSystemInteractionActive(true)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(harness.model.phase == .recoverableError)
        #expect(
            harness.model.lastFailure == .applicationUnavailable
        )
        #expect(harness.codex.calls == bridgeCallsBeforeRepair)
        #expect(harness.audio.calls == meterCallsBeforeRepair)
    }

    @Test("The dormant orb can hide without hiding an active session")
    func idleVisibility() async {
        let harness = Harness()

        harness.model.setIdleOrbVisible(false)
        #expect(harness.panel.calls.last == .hide)
        harness.model.setIdleOrbVisible(true)
        #expect(harness.panel.calls.last == .show)

        harness.codex.preparedConnectionState = .ready(
            taskIdentifier: "voice-console-42"
        )
        harness.model.toggleVoiceSession()
        #expect(await eventually { harness.model.phase == .listening })
        harness.model.setIdleOrbVisible(false)
        #expect(harness.panel.calls.last == .show)
    }
}

@MainActor
private struct Harness {
    let codex: FakeCodexController
    let audio: FakeAudioMeter
    let panel: FakeHUDPresenter
    let model: AppModel

    init(activateSystemInteraction: Bool = true) {
        let codex = FakeCodexController()
        let audio = FakeAudioMeter()
        let panel = FakeHUDPresenter()
        self.codex = codex
        self.audio = audio
        self.panel = panel
        model = AppModel(
            codex: codex,
            audioMeter: audio,
            panel: panel
        )
        if activateSystemInteraction {
            model.setSystemInteractionActive(true)
        }
    }
}
