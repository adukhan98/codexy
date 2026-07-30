import AppKit
import SwiftUI

enum HUDVisualStyle {
    static let compactCornerRadius: CGFloat = 16.5
    static let activeCornerRadius: CGFloat = 20.5
    static let expandedCornerRadius: CGFloat = 26

    static func accent(for phase: HUDPhase) -> Color {
        switch phase {
        case .dormant:
            Color(red: 0.58, green: 0.62, blue: 0.72)
        case .connecting:
            Color(red: 0.30, green: 0.67, blue: 1.00)
        case .listening:
            Color(red: 1.00, green: 0.31, blue: 0.36)
        case .thinking:
            Color(red: 0.48, green: 0.43, blue: 1.00)
        case .speaking:
            Color(red: 0.24, green: 0.84, blue: 0.92)
        case .approval:
            Color(red: 1.00, green: 0.66, blue: 0.18)
        case .result:
            Color(red: 0.27, green: 0.82, blue: 0.51)
        case .recoverableError:
            Color(red: 1.00, green: 0.39, blue: 0.25)
        }
    }

    static func secondaryAccent(for phase: HUDPhase) -> Color {
        switch phase {
        case .dormant:
            Color(red: 0.39, green: 0.42, blue: 0.52)
        case .connecting:
            Color(red: 0.28, green: 0.95, blue: 0.91)
        case .listening:
            Color(red: 1.00, green: 0.67, blue: 0.27)
        case .thinking:
            Color(red: 0.91, green: 0.36, blue: 0.92)
        case .speaking:
            Color(red: 0.32, green: 0.52, blue: 1.00)
        case .approval:
            Color(red: 1.00, green: 0.38, blue: 0.21)
        case .result:
            Color(red: 0.19, green: 0.67, blue: 0.97)
        case .recoverableError:
            Color(red: 0.87, green: 0.20, blue: 0.31)
        }
    }

    static func glassTint(for phase: HUDPhase) -> Color {
        accent(for: phase).opacity(phase.isExpanded ? 0.11 : 0.075)
    }

    static func surfaceFill(
        colorScheme: ColorScheme,
        reduceTransparency: Bool
    ) -> AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }

        return AnyShapeStyle(.ultraThinMaterial)
    }

    static func surfaceStroke(
        colorScheme: ColorScheme,
        increasedContrast: Bool
    ) -> Color {
        if increasedContrast {
            return colorScheme == .dark
                ? Color.white.opacity(0.62)
                : Color.black.opacity(0.46)
        }

        return colorScheme == .dark
            ? Color.white.opacity(0.17)
            : Color.white.opacity(0.68)
    }

    static func innerStroke(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.34)
            : Color.black.opacity(0.08)
    }

    static func shadowColor(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.48)
            : Color.black.opacity(0.22)
    }

    static func statusTitle(for phase: HUDPhase) -> String {
        switch phase {
        case .dormant:
            "Ready"
        case .connecting:
            "Connecting"
        case .listening:
            "Listening"
        case .thinking:
            "Thinking"
        case .speaking:
            "Speaking"
        case .approval:
            "Approval needed"
        case .result:
            "Result ready"
        case .recoverableError:
            "Needs attention"
        }
    }

    static func statusSymbol(for phase: HUDPhase) -> String {
        switch phase {
        case .dormant:
            "circle.fill"
        case .connecting:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .listening:
            "mic.fill"
        case .thinking:
            "sparkles"
        case .speaking:
            "waveform"
        case .approval:
            "checkmark.shield.fill"
        case .result:
            "checkmark.circle.fill"
        case .recoverableError:
            "exclamationmark.triangle.fill"
        }
    }

    static func accessibilityDescription(for phase: HUDPhase) -> String {
        switch phase {
        case .dormant:
            "Codex ready. Microphone off."
        case .connecting:
            "Connecting to the Voice Console. Microphone muted."
        case .listening:
            "Listening. Microphone live."
        case .thinking:
            "Codex is thinking. Microphone live."
        case .speaking:
            "Codex is speaking. Microphone live. Speak to interrupt."
        case .approval:
            "Codex needs approval before continuing. Microphone paused."
        case .result:
            "Codex has a result ready. Microphone live."
        case .recoverableError:
            "The Codex connection needs attention. Microphone off."
        }
    }

    static func defaultPrimaryAction(for phase: HUDPhase) -> String? {
        switch phase {
        case .approval:
            "Confirm"
        case .result:
            "Open in Codex"
        case .recoverableError:
            "Repair Connection"
        case .dormant, .connecting, .listening, .thinking, .speaking:
            nil
        }
    }

    static func defaultSecondaryAction(for phase: HUDPhase) -> String? {
        phase == .approval ? "Cancel" : nil
    }

    static func footerStatus(for phase: HUDPhase) -> String {
        switch phase {
        case .approval:
            "Mic paused · Awaiting"
        case .result:
            "Mic live · Saved"
        case .recoverableError:
            "Mic off"
        case .dormant, .connecting, .listening, .thinking, .speaking:
            statusTitle(for: phase)
        }
    }

    static func footerAccessibilityDescription(
        for phase: HUDPhase
    ) -> String {
        switch phase.microphoneState {
        case .live:
            phase == .result
                ? "Microphone live. Result saved."
                : "Microphone live."
        case .paused:
            phase == .approval
                ? "Microphone paused. Awaiting approval."
                : "Microphone muted."
        case .off:
            "Microphone off."
        }
    }

    static func microphoneSymbol(for phase: HUDPhase) -> String {
        switch phase.microphoneState {
        case .live:
            "mic.fill"
        case .paused:
            "mic.slash.fill"
        case .off:
            "mic.slash"
        }
    }

    static func microphoneAccent(for phase: HUDPhase) -> Color {
        switch phase.microphoneState {
        case .live:
            Color(red: 1.00, green: 0.31, blue: 0.36)
        case .paused:
            Color(red: 1.00, green: 0.66, blue: 0.18)
        case .off:
            Color.secondary.opacity(0.72)
        }
    }
}

extension HUDPhase {
    var hudVisualSize: CGSize {
        if self == .approval {
            return DesignMetrics.approvalSize
        }

        if isExpanded {
            return DesignMetrics.expandedSize
        }

        return self == .dormant
            ? DesignMetrics.collapsedSize
            : DesignMetrics.activeSize
    }

    var hudWindowSize: CGSize {
        DesignMetrics.windowSize(for: hudVisualSize)
    }

    var hudShadowBottomPadding: CGFloat {
        DesignMetrics.shadowBottomPadding
    }

    var hudShadowTopPadding: CGFloat {
        isExpanded
            ? DesignMetrics.expandedShadowTopPadding
            : DesignMetrics.shadowTopPadding
    }
}
