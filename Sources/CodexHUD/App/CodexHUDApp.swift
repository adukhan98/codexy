import AppKit
import Observation
import SwiftUI

@main
@MainActor
struct CodexHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Codex HUD", systemImage: "waveform.circle.fill") {
            MenuBarHost(runtime: appDelegate.runtime)
        }

        Settings {
            SettingsHost(runtime: appDelegate.runtime)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        runtime.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}

@MainActor
@Observable
final class AppRuntime {
    let model: AppModel
    let panel: HUDPanelController
    private(set) var shortcutDisplay: String
    private(set) var microphonePermission: SettingsView.PermissionStatus
    private(set) var accessibilityPermission: SettingsView.PermissionStatus

    private static let idleOrbDefaultsKey = "CodexHUD.showIdleOrb"
    private static let launchAtLoginDefaultsKey = "CodexHUD.launchAtLogin"

    private let codex: CodexAppServerBridge
    private let media: RealtimeWebRTCTransport
    private let hotKey: GlobalHotKeyService
    private let launchAtLogin: LaunchAtLoginService
    private let permissions: PermissionService
    private let defaults: UserDefaults
    private var hasStarted = false
    @ObservationIgnored private var systemActivityObserver: UUID?

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Self.idleOrbDefaultsKey: true,
            Self.launchAtLoginDefaultsKey: true
        ])

        let panel = HUDPanelController()
        let media = RealtimeWebRTCTransport()
        let codex = CodexAppServerBridge(
            mediaTransport: media,
            defaults: defaults
        )
        let hotKey = GlobalHotKeyService()
        let launchAtLogin = LaunchAtLoginService()
        let permissions = PermissionService()

        self.panel = panel
        self.media = media
        self.codex = codex
        self.hotKey = hotKey
        self.launchAtLogin = launchAtLogin
        self.permissions = permissions
        self.defaults = defaults
        shortcutDisplay = hotKey.shortcutDescription
        microphonePermission = Self.settingsStatus(
            for: permissions.microphone
        )
        accessibilityPermission = Self.settingsStatus(
            for: permissions.accessibility
        )
        model = AppModel(codex: codex, audioMeter: media, panel: panel)
        model.showIdleOrb = defaults.bool(forKey: Self.idleOrbDefaultsKey)
        model.launchAtLogin = defaults.bool(
            forKey: Self.launchAtLoginDefaultsKey
        )

        panel.install {
            HUDModelHost(model: self.model)
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        systemActivityObserver = SystemSessionLifecycle.shared.observeActivity {
            [weak model = model] isActive in
            model?.setSystemInteractionActive(isActive)
        }

        do {
            try hotKey.register { [weak self] in
                self?.model.toggleVoiceSession()
            }
            shortcutDisplay = hotKey.shortcutDescription
        } catch {
            shortcutDisplay = "Unavailable"
        }

        applyLaunchAtLoginPreference()
        refreshPermissions()
        model.start()
    }

    func stop() {
        if let systemActivityObserver {
            SystemSessionLifecycle.shared.removeActivityObserver(
                systemActivityObserver
            )
            self.systemActivityObserver = nil
        }
        hotKey.unregister()
        media.stop()
        hasStarted = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
            model.launchAtLogin = launchAtLogin.isEnabled
            defaults.set(
                model.launchAtLogin,
                forKey: Self.launchAtLoginDefaultsKey
            )
        } catch {
            model.launchAtLogin = launchAtLogin.isEnabled
        }
    }

    func setIdleOrbVisible(_ visible: Bool) {
        model.setIdleOrbVisible(visible)
        defaults.set(visible, forKey: Self.idleOrbDefaultsKey)
    }

    func refreshPermissions() {
        permissions.refresh()
        microphonePermission = Self.settingsStatus(
            for: permissions.microphone
        )
        accessibilityPermission = Self.settingsStatus(
            for: permissions.accessibility
        )
    }

    func reviewMicrophonePermission() {
        guard permissions.microphone == .notDetermined else {
            openMicrophoneSettings()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            _ = await permissions.requestMicrophone()
            refreshPermissions()
        }
    }

    func reviewAccessibilityPermission() {
        _ = permissions.requestAccessibility(prompt: true)
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    func openAccessibilitySettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    private func openSystemSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyLaunchAtLoginPreference() {
        let desired = defaults.bool(
            forKey: Self.launchAtLoginDefaultsKey
        )
        do {
            try launchAtLogin.setEnabled(desired)
            model.launchAtLogin = launchAtLogin.isEnabled
        } catch {
            model.launchAtLogin = launchAtLogin.isEnabled
        }
    }

    private static func settingsStatus(
        for state: PermissionState
    ) -> SettingsView.PermissionStatus {
        switch state {
        case .granted:
            .granted
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        case .unknown:
            .unavailable
        }
    }
}

private struct HUDModelHost: View {
    @Bindable var model: AppModel

    var body: some View {
        HUDView(
            phase: model.phase,
            content: model.content,
            audioLevel: 0,
            liveAudioLevel: model.orbAudioLevel,
            onToggleSession: { model.toggleVoiceSession() },
            onPrimaryAction: { model.performPrimaryAction() },
            onSecondaryAction: { model.performSecondaryAction() },
            keyboardFocusRequest: model.keyboardFocusRequest,
            onExitKeyboardFocus: { model.releaseKeyboardFocus() }
        )
    }
}

private struct MenuBarHost: View {
    let runtime: AppRuntime

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarContentView(
            phase: runtime.model.phase,
            shortcutDisplay: runtime.shortcutDisplay,
            showIdleOrb: runtime.model.showIdleOrb,
            onToggleSession: {
                runtime.model.toggleVoiceSession()
            },
            onToggleIdleOrb: {
                runtime.setIdleOrbVisible(!runtime.model.showIdleOrb)
            },
            onOpenVoiceConsole: {
                runtime.model.openVoiceConsole()
            },
            onRepairConnection: {
                Task { await runtime.model.repairConnection() }
            },
            onFocusHUDControls: {
                runtime.model.focusHUDControls()
            },
            onOpenSettings: {
                openSettings()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }
}

private struct SettingsHost: View {
    let runtime: AppRuntime

    var body: some View {
        SettingsView(
            launchAtLogin: Binding(
                get: { runtime.model.launchAtLogin },
                set: { runtime.setLaunchAtLogin($0) }
            ),
            showIdleOrb: Binding(
                get: { runtime.model.showIdleOrb },
                set: { runtime.setIdleOrbVisible($0) }
            ),
            shortcutDisplay: runtime.shortcutDisplay,
            microphonePermission: runtime.microphonePermission,
            accessibilityPermission: runtime.accessibilityPermission,
            onReviewMicrophonePermission: {
                runtime.reviewMicrophonePermission()
            },
            onReviewAccessibilityPermission: {
                runtime.reviewAccessibilityPermission()
            },
            onOpenVoiceConsole: {
                runtime.model.openVoiceConsole()
            },
            onRepairConnection: {
                Task { await runtime.model.repairConnection() }
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
        .onAppear {
            runtime.refreshPermissions()
        }
    }
}
