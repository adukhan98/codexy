import Foundation

enum HUDMicrophoneState: Equatable, Sendable {
    case live
    case paused
    case off
}

enum HUDPhase: String, CaseIterable, Codable, Sendable {
    case dormant
    case connecting
    case listening
    case thinking
    case speaking
    case approval
    case result
    case recoverableError

    var isVoiceSessionActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking, .approval, .result:
            true
        case .dormant, .recoverableError:
            false
        }
    }

    var isExpanded: Bool {
        switch self {
        case .approval, .result, .recoverableError:
            true
        case .dormant, .connecting, .listening, .thinking, .speaking:
            false
        }
    }

    var microphoneState: HUDMicrophoneState {
        switch self {
        case .listening, .thinking, .speaking, .result:
            .live
        case .connecting, .approval:
            .paused
        case .dormant, .recoverableError:
            .off
        }
    }
}
