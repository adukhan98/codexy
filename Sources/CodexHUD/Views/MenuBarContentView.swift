import SwiftUI

struct MenuBarContentView: View {
    let phase: HUDPhase
    let shortcutDisplay: String
    let showIdleOrb: Bool
    let onToggleSession: () -> Void
    let onToggleIdleOrb: () -> Void
    let onOpenVoiceConsole: () -> Void
    let onRepairConnection: () -> Void
    let onFocusHUDControls: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    init(
        phase: HUDPhase,
        shortcutDisplay: String,
        showIdleOrb: Bool,
        onToggleSession: @escaping () -> Void,
        onToggleIdleOrb: @escaping () -> Void,
        onOpenVoiceConsole: @escaping () -> Void,
        onRepairConnection: @escaping () -> Void,
        onFocusHUDControls: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.phase = phase
        self.shortcutDisplay = shortcutDisplay
        self.showIdleOrb = showIdleOrb
        self.onToggleSession = onToggleSession
        self.onToggleIdleOrb = onToggleIdleOrb
        self.onOpenVoiceConsole = onOpenVoiceConsole
        self.onRepairConnection = onRepairConnection
        self.onFocusHUDControls = onFocusHUDControls
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    var body: some View {
        Label {
            Text(menuSafeTitle("Status: \(HUDVisualStyle.statusTitle(for: phase))"))
        } icon: {
            Image(systemName: HUDVisualStyle.statusSymbol(for: phase))
                .foregroundStyle(HUDVisualStyle.accent(for: phase))
        }
        .accessibilityLabel(HUDVisualStyle.accessibilityDescription(for: phase))

        Text(menuSafeTitle("Shortcut: \(shortcutDisplay)"))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Voice shortcut \(shortcutDisplay)")

        Divider()

        Button(
            phase.isVoiceSessionActive ? "Stop Voice Session" : "Start Voice Session",
            systemImage: phase.isVoiceSessionActive ? "stop.fill" : "mic.fill",
            action: onToggleSession
        )

        Button(
            showIdleOrb ? "Hide Idle Orb" : "Show Idle Orb",
            systemImage: showIdleOrb ? "eye.slash" : "eye",
            action: onToggleIdleOrb
        )

        Divider()

        Button(
            "Open Voice Console",
            systemImage: "bubble.left.and.text.bubble.right",
            action: onOpenVoiceConsole
        )

        Button(
            "Repair Connection",
            systemImage: "wrench.and.screwdriver",
            action: onRepairConnection
        )

        Button(
            "Focus HUD Controls",
            systemImage: "keyboard",
            action: onFocusHUDControls
        )
        .disabled(!phase.isExpanded)

        Button(
            "Settings…",
            systemImage: "gearshape",
            action: onOpenSettings
        )

        Divider()

        Button(
            "Quit Codex HUD",
            systemImage: "power",
            action: onQuit
        )
    }
}

private func menuSafeTitle(_ value: String) -> String {
    guard value.count > 30 else {
        return value
    }

    return String(value.prefix(27)) + "..."
}
