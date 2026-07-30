import AppKit
import ApplicationServices
import Foundation
import Security

@MainActor
struct CodexInstallation: Sendable {
    static let bundleIdentifier = "com.openai.codex"
    private static let openAITeamIdentifier = "2DC432GLL2"

    let applicationURL: URL
    let executableURL: URL
    let version: String

    static func locate() throws -> CodexInstallation {
        let workspace = NSWorkspace.shared
        let knownLocations = [
            workspace.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app")
        ].compactMap { $0 }

        let installedApplications = knownLocations.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !installedApplications.isEmpty else {
            throw CodexBridgeFailure.applicationUnavailable
        }
        guard let applicationURL = installedApplications.first(where: {
            isOfficialCodexApplication($0)
        }) else {
            throw CodexBridgeFailure.untrustedCodexInstallation
        }

        let executableURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexBridgeFailure.applicationUnavailable
        }
        guard isOfficialCodexExecutable(executableURL) else {
            throw CodexBridgeFailure.untrustedCodexInstallation
        }

        let version = Bundle(url: applicationURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        return CodexInstallation(
            applicationURL: applicationURL,
            executableURL: executableURL,
            version: version
        )
    }

    static func isOfficialCodexApplication(_ url: URL) -> Bool {
        guard
            FileManager.default.fileExists(atPath: url.path),
            Bundle(url: url)?.bundleIdentifier == bundleIdentifier
        else {
            return false
        }
        return validateStaticCode(
            at: url,
            requirement: """
            anchor apple generic and identifier "\(bundleIdentifier)" and \
            certificate leaf[subject.OU] = "\(openAITeamIdentifier)"
            """
        )
    }

    static func isOfficialCodexExecutable(_ url: URL) -> Bool {
        validateStaticCode(
            at: url,
            requirement: """
            anchor apple generic and identifier "codex" and \
            certificate leaf[subject.OU] = "\(openAITeamIdentifier)"
            """
        )
    }

    private static func validateStaticCode(
        at url: URL,
        requirement requirementString: String
    ) -> Bool {
        let defaultFlags = SecCSFlags(rawValue: 0)
        var staticCode: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(
                url as CFURL,
                defaultFlags,
                &staticCode
            ) == errSecSuccess,
            let staticCode
        else {
            return false
        }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(
                requirementString as CFString,
                defaultFlags,
                &requirement
            ) == errSecSuccess,
            let requirement
        else {
            return false
        }

        let validationFlags = SecCSFlags(
            rawValue: UInt32(
                kSecCSCheckAllArchitectures | kSecCSStrictValidate
            )
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement
        ) == errSecSuccess
    }
}

/// Opens a task through Codex's documented desktop deeplink. Accessibility is
/// only a semantic fallback if a future app build stops routing the deeplink.
/// No coordinate-based input or Screen Recording is used.
@MainActor
final class CodexAccessibilityLauncher {
    private let installation: CodexInstallation

    init(installation: CodexInstallation) {
        self.installation = installation
    }

    func openThread(
        identifier: String,
        activate: Bool
    ) async throws {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(identifier)"
        guard let deepLink = components.url else {
            throw CodexBridgeFailure.voiceConsoleNotFound
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.createsNewApplicationInstance = false

        do {
            try await NSWorkspace.shared.open(
                [deepLink],
                withApplicationAt: installation.applicationURL,
                configuration: configuration
            )
            return
        } catch {
            guard activate else {
                throw CodexBridgeFailure.voiceConsoleNotFound
            }
        }

        try pressVoiceConsoleSemantically()
    }

    private func pressVoiceConsoleSemantically() throws {
        guard AXIsProcessTrusted() else {
            throw CodexBridgeFailure.accessibilityPermissionRequired
        }
        guard
            let application = NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: CodexInstallation.bundleIdentifier
                )
                .first(where: {
                    $0.bundleURL?
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                        == installation.applicationURL
                            .resolvingSymlinksInPath()
                            .standardizedFileURL
                })
        else {
            throw CodexBridgeFailure.applicationUnavailable
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = findVoiceConsole(in: root) else {
            throw CodexBridgeFailure.voiceConsoleNotFound
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw CodexBridgeFailure.voiceConsoleNotFound
        }
        application.activate(options: [.activateAllWindows])
    }

    private func findVoiceConsole(in root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var cursor = 0
        var inspected = 0

        while cursor < queue.count, inspected < 4_000 {
            let element = queue[cursor]
            cursor += 1
            inspected += 1

            let role = stringAttribute(kAXRoleAttribute, of: element)
            let title = stringAttribute(kAXTitleAttribute, of: element)
            let description = stringAttribute(kAXDescriptionAttribute, of: element)
            if role == (kAXButtonRole as String),
               title == "Voice Console" || description == "Voice Console"
            {
                return element
            }

            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }
}
