import Foundation
import Testing
@testable import CodexHUD

@Suite("Content and service contracts")
struct ContentAndServiceContractTests {
    @Test("Dormant content is quiet and action-free")
    func dormantContent() {
        #expect(
            HUDContent.dormant == HUDContent(
                eyebrow: nil,
                title: "Codex ready",
                detail: nil,
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            )
        )
    }

    @Test("Every bridge failure has distinct actionable copy")
    func failureCopy() {
        let failures: [CodexBridgeFailure] = [
            .accessibilityPermissionRequired,
            .microphonePermissionRequired,
            .applicationUnavailable,
            .untrustedCodexInstallation,
            .subscriptionAuthenticationRequired,
            .voiceConsoleNotFound,
            .voiceControlNotExposed,
            .automationTimedOut,
            .unsupportedApplicationVersion("99.4")
        ]
        let messages = failures.map(\.userFacingMessage)

        #expect(messages.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(messages).count == failures.count)
        #expect(messages[0].contains("Accessibility"))
        #expect(messages[1].contains("Microphone"))
        #expect(messages[2].contains("official Codex app"))
        #expect(messages[3].contains("Reinstall Codex"))
        #expect(messages[4].contains("ChatGPT subscription"))
        #expect(messages[5].contains("Voice Console"))
        #expect(messages[6].contains("voice control"))
        #expect(messages[7].contains("in time"))
        #expect(messages[8].contains("99.4"))
    }

    @Test("Connection identity preserves the dedicated task identifier")
    func connectionIdentity() {
        let state = CodexConnectionState.ready(taskIdentifier: "voice-console-id")
        #expect(state == .ready(taskIdentifier: "voice-console-id"))
        #expect(state != .ready(taskIdentifier: "another-task"))
    }

    @Test("Approval events preserve the exact decision content")
    func approvalEventContent() {
        #expect(
            CodexBridgeEvent.approval(
                title: "Delete the draft?",
                detail: "This cannot be undone."
            ) == .approval(
                title: "Delete the draft?",
                detail: "This cannot be undone."
            )
        )
    }

    @Test("Permission state names remain stable for onboarding")
    func permissionStateNames() {
        #expect(
            [
                PermissionState.unknown.rawValue,
                PermissionState.notDetermined.rawValue,
                PermissionState.denied.rawValue,
                PermissionState.granted.rawValue
            ] == [
                "unknown",
                "notDetermined",
                "denied",
                "granted"
            ]
        )
    }

    @Test("Global shortcut failures remain distinguishable")
    func shortcutFailures() {
        #expect(GlobalHotKeyFailure.registrationFailed != .shortcutUnavailable)
    }

    @MainActor
    @Test("The installed official Codex resolves to its bundled executable")
    func officialCodexInstallationTrust() throws {
        let installation = try CodexInstallation.locate()
        let expectedExecutable = installation.applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)

        #expect(
            Bundle(url: installation.applicationURL)?.bundleIdentifier
                == CodexInstallation.bundleIdentifier
        )
        #expect(installation.executableURL == expectedExecutable)
        #expect(
            FileManager.default.isExecutableFile(
                atPath: installation.executableURL.path
            )
        )
    }

    @MainActor
    @Test("An unsigned Codex bundle-ID spoof fails the trust validator")
    func unsignedCodexSpoofIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexHUD-spoof-\(UUID().uuidString)",
                isDirectory: true
            )
        let appURL = root.appendingPathComponent(
            "Codex.app",
            isDirectory: true
        )
        let contentsURL = appURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let macOSURL = contentsURL.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(
            at: macOSURL,
            withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": CodexInstallation.bundleIdentifier,
                "CFBundleExecutable": "Codex",
                "CFBundlePackageType": "APPL"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        let executableURL = macOSURL.appendingPathComponent("Codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

        #expect(!CodexInstallation.isOfficialCodexApplication(appURL))
        #expect(!CodexInstallation.isOfficialCodexExecutable(executableURL))
    }
}
