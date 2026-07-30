import Foundation
import Testing
@testable import CodexHUD

@Suite("HUD phase contract")
struct HUDPhaseTests {
    @Test("The eight product phases stay complete and ordered")
    func allCasesMatchProductContract() {
        #expect(
            HUDPhase.allCases == [
                .dormant,
                .connecting,
                .listening,
                .thinking,
                .speaking,
                .approval,
                .result,
                .recoverableError
            ]
        )
    }

    @Test("Only live conversation phases are active")
    func activeSemanticsAreExplicit() {
        let expected: [HUDPhase: Bool] = [
            .dormant: false,
            .connecting: true,
            .listening: true,
            .thinking: true,
            .speaking: true,
            .approval: true,
            .result: true,
            .recoverableError: false
        ]

        for phase in HUDPhase.allCases {
            #expect(phase.isVoiceSessionActive == expected[phase])
        }
    }

    @Test("Only decision, result, and repair states expand")
    func expansionSemanticsAreExplicit() {
        let expectedExpanded: Set<HUDPhase> = [
            .approval,
            .result,
            .recoverableError
        ]

        for phase in HUDPhase.allCases {
            #expect(phase.isExpanded == expectedExpanded.contains(phase))
        }
    }

    @Test("Raw values and Codable round-trip every phase")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for phase in HUDPhase.allCases {
            #expect(HUDPhase(rawValue: phase.rawValue) == phase)
            let data = try encoder.encode(phase)
            #expect(try decoder.decode(HUDPhase.self, from: data) == phase)
        }
    }

    @Test("Dormant and error phases are not active conversations")
    func inactiveConversationInvariant() {
        #expect(!HUDPhase.dormant.isVoiceSessionActive)
        #expect(!HUDPhase.recoverableError.isVoiceSessionActive)
    }

    @Test("Every phase has an explicit microphone truth state")
    func microphoneTruthInvariant() {
        let expected: [HUDPhase: HUDMicrophoneState] = [
            .dormant: .off,
            .connecting: .paused,
            .listening: .live,
            .thinking: .live,
            .speaking: .live,
            .approval: .paused,
            .result: .live,
            .recoverableError: .off
        ]

        for phase in HUDPhase.allCases {
            #expect(phase.microphoneState == expected[phase])
            #expect(
                HUDVisualStyle
                    .accessibilityDescription(for: phase)
                    .localizedCaseInsensitiveContains("microphone")
            )
        }
    }
}
