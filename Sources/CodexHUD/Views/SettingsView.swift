import SwiftUI

struct SettingsView: View {
    enum PermissionStatus: String, CaseIterable, Sendable {
        case granted
        case denied
        case notDetermined
        case unavailable

        var title: String {
            switch self {
            case .granted:
                "Allowed"
            case .denied:
                "Needs Access"
            case .notDetermined:
                "Not Requested"
            case .unavailable:
                "Unavailable"
            }
        }

        var systemImage: String {
            switch self {
            case .granted:
                "checkmark.circle.fill"
            case .denied:
                "exclamationmark.triangle.fill"
            case .notDetermined:
                "circle.dashed"
            case .unavailable:
                "minus.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .granted:
                Color(red: 0.20, green: 0.68, blue: 0.39)
            case .denied:
                Color(red: 0.92, green: 0.31, blue: 0.25)
            case .notDetermined:
                Color(red: 0.91, green: 0.57, blue: 0.16)
            case .unavailable:
                .secondary
            }
        }

        var actionTitle: String? {
            switch self {
            case .granted, .unavailable:
                nil
            case .denied:
                "Open Settings"
            case .notDetermined:
                "Allow…"
            }
        }
    }

    @Binding private var launchAtLogin: Bool
    @Binding private var showIdleOrb: Bool

    let shortcutDisplay: String
    let microphonePermission: PermissionStatus
    let accessibilityPermission: PermissionStatus
    let onReviewMicrophonePermission: () -> Void
    let onReviewAccessibilityPermission: () -> Void
    let onOpenVoiceConsole: () -> Void
    let onRepairConnection: () -> Void
    let onQuit: () -> Void

    init(
        launchAtLogin: Binding<Bool>,
        showIdleOrb: Binding<Bool>,
        shortcutDisplay: String,
        microphonePermission: PermissionStatus,
        accessibilityPermission: PermissionStatus,
        onReviewMicrophonePermission: @escaping () -> Void = {},
        onReviewAccessibilityPermission: @escaping () -> Void = {},
        onOpenVoiceConsole: @escaping () -> Void,
        onRepairConnection: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        _launchAtLogin = launchAtLogin
        _showIdleOrb = showIdleOrb
        self.shortcutDisplay = shortcutDisplay
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.onReviewMicrophonePermission = onReviewMicrophonePermission
        self.onReviewAccessibilityPermission = onReviewAccessibilityPermission
        self.onOpenVoiceConsole = onOpenVoiceConsole
        self.onRepairConnection = onRepairConnection
        self.onQuit = onQuit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsHeader

                SettingsSection(title: "General") {
                    SettingsToggleRow(
                        title: "Launch at Login",
                        detail: "Starts Codex HUD after you sign in to this Mac.",
                        isOn: $launchAtLogin
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Show Idle Orb",
                        detail: "Keeps the microphone-off control visible between sessions.",
                        isOn: $showIdleOrb
                    )

                    SettingsDivider()

                    SettingsValueRow(
                        title: "Voice Shortcut",
                        detail: "Starts or stops the dedicated Voice Console session."
                    ) {
                        HStack(spacing: 10) {
                            Text(shortcutDisplay)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text("Fixed in v1")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Current voice shortcut \(shortcutDisplay). Fixed in version one."
                        )
                    }
                }

                SettingsSection(title: "Permissions") {
                    SettingsPermissionRow(
                        title: "Microphone",
                        detail: "Used only during an active voice session.",
                        status: microphonePermission,
                        action: onReviewMicrophonePermission
                    )

                    SettingsDivider()

                    SettingsPermissionRow(
                        title: "Accessibility",
                        detail: "Optional fallback if Codex cannot open Voice Console directly.",
                        status: accessibilityPermission,
                        action: onReviewAccessibilityPermission
                    )

                    SettingsDivider()

                    SettingsValueRow(
                        title: "Screen Recording",
                        detail: "Codex HUD never requests or uses screen capture."
                    ) {
                        Text("Not Used")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsSection(title: "Voice Console") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            voiceConsoleButtons
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            voiceConsoleButtons
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 500,
            idealWidth: 540,
            maxWidth: 720,
            minHeight: 410,
            idealHeight: 470,
            maxHeight: 720
        )
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    Color.white.opacity(0.94),
                    Color(red: 0.18, green: 0.68, blue: 0.96)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex HUD")
                    .font(.title2.weight(.semibold))

                Text("Voice Console controls and privacy")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var voiceConsoleButtons: some View {
        Button(
            "Open Voice Console",
            systemImage: "arrow.up.forward.app",
            action: onOpenVoiceConsole
        )

        Button(
            "Repair Connection",
            systemImage: "wrench.and.screwdriver",
            action: onRepairConnection
        )

        Spacer(minLength: 8)

        Button("Quit Codex HUD", role: .destructive, action: onQuit)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            SettingsRowLabel(title: title, detail: detail)

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .padding(.vertical, 5)
    }
}

private struct SettingsValueRow<Value: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                SettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 12)
                value()
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLabel(title: title, detail: detail)
                value()
            }
        }
        .padding(.vertical, 5)
    }
}

private struct SettingsPermissionRow: View {
    let title: String
    let detail: String
    let status: SettingsView.PermissionStatus
    let action: () -> Void

    var body: some View {
        SettingsValueRow(title: title, detail: detail) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusLabel
                    permissionButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    statusLabel
                    permissionButton
                }
            }
        }
    }

    private var statusLabel: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(status.tint)
    }

    @ViewBuilder
    private var permissionButton: some View {
        if let actionTitle = status.actionTitle {
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 5)
    }
}
