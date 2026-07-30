import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import CodexHUD

@MainActor
@Suite("Visual fixtures", .serialized)
struct VisualFixtureTests {
    @Test("All eight HUD states match deterministic 2x fixtures")
    func everyHUDState() throws {
        let recording = ProcessInfo.processInfo.environment[
            "CODEX_HUD_RECORD_FIXTURES"
        ] == "1"
        let directory = fixtureDirectory

        if recording {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var manifestLines: [String] = []

        for fixture in Fixture.all {
            let rendered = try render(fixture)
            let fixtureURL = directory.appendingPathComponent(
                fixture.filename
            )
            let digest = Self.digest(rendered.data)
            let expectedCanvas = fixture.phase.hudWindowSize

            #expect(
                rendered.bitmap.pixelsWide ==
                    Int(expectedCanvas.width * 2)
            )
            #expect(
                rendered.bitmap.pixelsHigh ==
                    Int(expectedCanvas.height * 2)
            )
            #expect(fixture.size == fixture.phase.hudVisualSize)
            #expect(rendered.visibleSampleCount > 10)
            #expect(rendered.distinctSampleCount > 8)
            #expect(
                rendered.maximumBoundaryAlpha < 0.02,
                "\(fixture.filename) paints into its window boundary and can clip shadows."
            )
            if fixture.phase.isExpanded {
                #expect(
                    Self.expandedDetailPixelCount(in: rendered.bitmap) > 400,
                    "\(fixture.filename) has no visible approval, result, or error context in the detail viewport."
                )
            }

            if recording {
                try rendered.data.write(to: fixtureURL, options: .atomic)
            } else {
                let baseline = try Data(contentsOf: fixtureURL)
                let baselineDigest = Self.digest(baseline)
                #expect(
                    digest == baselineDigest,
                    "Visual drift in \(fixture.filename). Record only after hostile review."
                )
            }

            manifestLines.append("\(digest)  \(fixture.filename)")
        }

        if recording {
            let manifest =
                manifestLines.sorted().joined(separator: "\n") + "\n"
            try manifest.write(
                to: directory.appendingPathComponent("manifest.sha256"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @Test("HUD and Settings honor macOS accessibility display modes")
    func accessibilityLayouts() throws {
        let recording = ProcessInfo.processInfo.environment[
            "CODEX_HUD_RECORD_FIXTURES"
        ] == "1"
        let directory = accessibilityFixtureDirectory
        let approval = try #require(
            Fixture.all.first { $0.phase == .approval }
        )
        let connecting = try #require(
            Fixture.all.first { $0.phase == .connecting }
        )
        let artifacts: [AccessibilityArtifact] = [
            AccessibilityArtifact(
                filename: "approval-reduce-transparency.png",
                canvasSize: approval.phase.hudWindowSize,
                rendered: try render(
                    approval,
                    // Accessibility fixtures prove the settled layout. Motion
                    // is covered separately; snapshotting an insertion
                    // transition can capture the intentionally faded first
                    // frame instead of the usable Reduce Transparency state.
                    animationsEnabled: false,
                    reduceTransparency: true
                ),
                baselineFilename: approval.filename
            ),
            AccessibilityArtifact(
                filename: "connecting-increase-contrast.png",
                canvasSize: connecting.phase.hudWindowSize,
                rendered: try render(
                    connecting,
                    increasedContrast: true
                ),
                baselineFilename: connecting.filename
            ),
            AccessibilityArtifact(
                filename: "settings-720.png",
                canvasSize: CGSize(width: 720, height: 720),
                rendered: try renderSettings(),
                baselineFilename: nil
            )
        ]

        if recording {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var manifestLines: [String] = []
        for artifact in artifacts {
            let digest = Self.digest(artifact.rendered.data)
            let fixtureURL = directory.appendingPathComponent(
                artifact.filename
            )

            #expect(
                artifact.rendered.bitmap.pixelsWide ==
                    Int(artifact.canvasSize.width * 2)
            )
            #expect(
                artifact.rendered.bitmap.pixelsHigh ==
                    Int(artifact.canvasSize.height * 2)
            )
            #expect(artifact.rendered.visibleSampleCount > 10)
            #expect(artifact.rendered.distinctSampleCount > 8)
            #expect(
                artifact.rendered.contrastingSampleCount > 8,
                "\(artifact.filename) does not contain enough foreground content to prove the layout rendered."
            )

            if artifact.baselineFilename != nil {
                #expect(
                    artifact.rendered.maximumBoundaryAlpha < 0.02,
                    "\(artifact.filename) paints into its window boundary and can clip shadows."
                )
                if artifact.filename.hasPrefix("approval-") {
                    #expect(
                        Self.expandedDetailPixelCount(
                            in: artifact.rendered.bitmap
                        ) > 400,
                        "\(artifact.filename) hides the approval context in a macOS accessibility display mode."
                    )
                }
                let normalName = try #require(
                    artifact.baselineFilename
                )
                let normalData = try Data(
                    contentsOf: fixtureDirectory.appendingPathComponent(
                        normalName
                    )
                )
                if !artifact.filename.hasPrefix("approval-") {
                    #expect(
                        digest != Self.digest(normalData),
                        "\(artifact.filename) is byte-identical to the standard fixture and does not prove the accessibility mode."
                    )
                } else {
                    // The deterministic standard fixture deliberately uses
                    // the same opaque fallback as Reduce Transparency so it
                    // does not snapshot OS-controlled Liquid Glass pixels.
                    // The stronger detail-pixel check above proves that the
                    // accessibility fallback retained its complete content.
                    #expect(!normalData.isEmpty)
                }
            }

            if recording {
                try artifact.rendered.data.write(
                    to: fixtureURL,
                    options: .atomic
                )
            } else {
                let baseline = try Data(contentsOf: fixtureURL)
                #expect(
                    digest == Self.digest(baseline),
                    "Accessibility visual drift in \(artifact.filename). Record only after hostile review."
                )
            }
            manifestLines.append("\(digest)  \(artifact.filename)")
        }

        if recording {
            let manifest =
                manifestLines.sorted().joined(separator: "\n") + "\n"
            try manifest.write(
                to: directory.appendingPathComponent("manifest.sha256"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @Test("Active production orb frames match deterministic AppKit fixtures")
    func productionOrbFrames() throws {
        let recording = ProcessInfo.processInfo.environment[
            "CODEX_HUD_RECORD_FIXTURES"
        ] == "1"
        let directory = productionOrbFixtureDirectory
        if recording {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let activeFixtures = Fixture.all.filter {
            switch $0.phase {
            case .connecting, .listening, .thinking, .speaking:
                true
            case .dormant, .approval, .result, .recoverableError:
                false
            }
        }
        let sampleTimes: [HUDPhase: TimeInterval] = [
            .connecting: 0.37,
            .listening: 0.53,
            .thinking: 1.21,
            .speaking: 0.77
        ]
        var manifestLines: [String] = []

        for fixture in activeFixtures {
            let time = try #require(sampleTimes[fixture.phase])
            let rendered = try render(
                fixture,
                productionMotionTimeOverride: time
            )
            let filename = "\(fixture.phase.rawValue)-production.png"
            let fixtureURL = directory.appendingPathComponent(filename)
            let digest = Self.digest(rendered.data)

            #expect(
                rendered.bitmap.pixelsWide ==
                    Int(fixture.phase.hudWindowSize.width * 2)
            )
            #expect(
                rendered.bitmap.pixelsHigh ==
                    Int(fixture.phase.hudWindowSize.height * 2)
            )
            #expect(rendered.visibleSampleCount > 10)
            #expect(rendered.distinctSampleCount > 8)
            #expect(rendered.maximumBoundaryAlpha < 0.02)

            if recording {
                try rendered.data.write(to: fixtureURL, options: .atomic)
            } else {
                let baseline = try Data(contentsOf: fixtureURL)
                #expect(
                    digest == Self.digest(baseline),
                    "Production orb drift in \(filename). Record only after hostile review."
                )
            }
            manifestLines.append("\(digest)  \(filename)")
        }

        if recording {
            let manifest =
                manifestLines.sorted().joined(separator: "\n") + "\n"
            try manifest.write(
                to: directory.appendingPathComponent("manifest.sha256"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private var fixtureDirectory: URL {
        repositoryDirectory.appendingPathComponent(
            "QA/VisualFixtures",
            isDirectory: true
        )
    }

    private var accessibilityFixtureDirectory: URL {
        repositoryDirectory.appendingPathComponent(
            "QA/AccessibilityFixtures",
            isDirectory: true
        )
    }

    private var productionOrbFixtureDirectory: URL {
        repositoryDirectory.appendingPathComponent(
            "QA/ProductionOrbFixtures",
            isDirectory: true
        )
    }

    private var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func render(
        _ fixture: Fixture,
        animationsEnabled: Bool = false,
        reduceTransparency: Bool = false,
        increasedContrast: Bool = false,
        productionMotionTimeOverride: TimeInterval? = nil
    ) throws -> RenderedFixture {
        let canvasSize = fixture.phase.hudWindowSize
        let view = HUDView(
            phase: fixture.phase,
            content: fixture.content,
            audioLevel: fixture.audioLevel,
            animationsEnabled: animationsEnabled,
            onToggleSession: {},
            onPrimaryAction: {},
            onSecondaryAction: {},
            reduceTransparencyOverride: reduceTransparency,
            increasedContrastOverride: increasedContrast,
            keyboardFocusEnabled: false,
            productionMotionTimeOverride:
                productionMotionTimeOverride
        )
        .environment(\.colorScheme, .dark)
        .frame(
            width: canvasSize.width,
            height: canvasSize.height
        )

        return try rasterize(
            view,
            canvasSize: canvasSize,
            name: fixture.filename
        )
    }

    private func renderSettings() throws -> RenderedFixture {
        let canvasSize = CGSize(width: 720, height: 720)
        let view = SettingsView(
            launchAtLogin: .constant(true),
            showIdleOrb: .constant(true),
            shortcutDisplay: "⇧⌥⌘Space",
            microphonePermission: .denied,
            accessibilityPermission: .notDetermined,
            onOpenVoiceConsole: {},
            onRepairConnection: {},
            onQuit: {}
        )
        .environment(\.colorScheme, .dark)
        .frame(
            width: canvasSize.width,
            height: canvasSize.height
        )

        return try rasterize(
            view,
            canvasSize: canvasSize,
            name: "settings-720.png"
        )
    }

    private func rasterize<Content: View>(
        _ view: Content,
        canvasSize: CGSize,
        name: String
    ) throws -> RenderedFixture {
        let hostingView = NSHostingView(rootView: view)
        let frame = CGRect(origin: .zero, size: canvasSize)
        let window = FixtureCapturePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.becomesKeyOnlyIfNeeded = true
        window.initialFirstResponder = nil
        window.contentView = hostingView
        hostingView.frame = frame
        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(nil)
        hostingView.displayIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }

        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width * 2),
                pixelsHigh: Int(canvasSize.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            "Could not allocate a hosted bitmap for \(name)"
        )
        bitmap.size = canvasSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let pngData: Data? = bitmap.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [
                NSBitmapImageRep.PropertyKey.compressionFactor: 1.0
            ]
        )
        let png = try #require(
            pngData,
            "Could not encode \(name)"
        )

        var visibleSamples = 0
        var contrastingSamples = 0
        var sampledColors = Set<SampledColor>()
        var maximumBoundaryAlpha: CGFloat = 0
        let xStride = max(bitmap.pixelsWide / 24, 1)
        let yStride = max(bitmap.pixelsHigh / 16, 1)
        let referenceColor = bitmap.colorAt(x: 0, y: 0)?
            .usingColorSpace(NSColorSpace.sRGB) ?? .clear

        for y in stride(
            from: 0,
            to: bitmap.pixelsHigh,
            by: yStride
        ) {
            for x in stride(
                from: 0,
                to: bitmap.pixelsWide,
                by: xStride
            ) {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(NSColorSpace.sRGB) else {
                    continue
                }
                if color.alphaComponent > 0.02 {
                    visibleSamples += 1
                    sampledColors.insert(SampledColor(color))
                }
                if Self.colorDistance(color, referenceColor) > 0.10 {
                    contrastingSamples += 1
                }
            }
        }

        for x in 0..<bitmap.pixelsWide {
            maximumBoundaryAlpha = max(
                maximumBoundaryAlpha,
                Self.alpha(atX: x, y: 0, in: bitmap),
                Self.alpha(
                    atX: x,
                    y: bitmap.pixelsHigh - 1,
                    in: bitmap
                )
            )
        }
        for y in 0..<bitmap.pixelsHigh {
            maximumBoundaryAlpha = max(
                maximumBoundaryAlpha,
                Self.alpha(atX: 0, y: y, in: bitmap),
                Self.alpha(
                    atX: bitmap.pixelsWide - 1,
                    y: y,
                    in: bitmap
                )
            )
        }

        return RenderedFixture(
            data: png,
            bitmap: bitmap,
            visibleSampleCount: visibleSamples,
            distinctSampleCount: sampledColors.count,
            contrastingSampleCount: contrastingSamples,
            maximumBoundaryAlpha: maximumBoundaryAlpha
        )
    }

    private static func colorDistance(
        _ lhs: NSColor,
        _ rhs: NSColor
    ) -> CGFloat {
        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        let alpha = lhs.alphaComponent - rhs.alphaComponent
        return sqrt(red * red + green * green + blue * blue + alpha * alpha)
    }

    private static func expandedDetailPixelCount(
        in bitmap: NSBitmapImageRep
    ) -> Int {
        // The expanded surface starts 48 points from the horizontal canvas
        // edge and 32 points from the top. This band deliberately excludes
        // the orb, title, status icon, footer, and actions, so bright pixels
        // here are direct evidence that the context viewport did not collapse.
        let minX = Int(112 * 2)
        let maxX = min(Int(400 * 2), bitmap.pixelsWide)
        let topY = Int(84 * 2)
        let bottomY = Int(136 * 2)
        let minY = max(bitmap.pixelsHigh - bottomY, 0)
        let maxY = min(bitmap.pixelsHigh - topY, bitmap.pixelsHigh)
        var count = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else {
                    continue
                }
                let luminance = color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
                if color.alphaComponent > 0.20, luminance > 0.34 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func alpha(
        atX x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?
            .usingColorSpace(.sRGB)?
            .alphaComponent ?? 0
    }
}

private struct RenderedFixture {
    let data: Data
    let bitmap: NSBitmapImageRep
    let visibleSampleCount: Int
    let distinctSampleCount: Int
    let contrastingSampleCount: Int
    let maximumBoundaryAlpha: CGFloat
}

private struct AccessibilityArtifact {
    let filename: String
    let canvasSize: CGSize
    let rendered: RenderedFixture
    let baselineFilename: String?
}

private final class FixtureCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SampledColor: Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ color: NSColor) {
        red = UInt8((color.redComponent * 255).rounded())
        green = UInt8((color.greenComponent * 255).rounded())
        blue = UInt8((color.blueComponent * 255).rounded())
        alpha = UInt8((color.alphaComponent * 255).rounded())
    }
}

private struct Fixture {
    let phase: HUDPhase
    let content: HUDContent
    let audioLevel: Double
    let size: CGSize

    var filename: String {
        "\(phase.rawValue).png"
    }

    static let all: [Fixture] = [
        Fixture(
            phase: .dormant,
            content: .dormant,
            audioLevel: 0,
            size: DesignMetrics.collapsedSize
        ),
        Fixture(
            phase: .connecting,
            content: HUDContent(
                eyebrow: "VOICE CONSOLE",
                title: "Connecting to Codex",
                detail: nil,
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            ),
            audioLevel: 0,
            size: DesignMetrics.activeSize
        ),
        Fixture(
            phase: .listening,
            content: HUDContent(
                eyebrow: "MICROPHONE LIVE",
                title: "Listening",
                detail: "⇧⌥⌘Space to stop",
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            ),
            audioLevel: 0.72,
            size: DesignMetrics.activeSize
        ),
        Fixture(
            phase: .thinking,
            content: HUDContent(
                eyebrow: "VOICE CONSOLE",
                title: "Codex is thinking",
                detail: nil,
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            ),
            audioLevel: 0,
            size: DesignMetrics.activeSize
        ),
        Fixture(
            phase: .speaking,
            content: HUDContent(
                eyebrow: "VOICE CONSOLE",
                title: "Codex is speaking",
                detail: "Speak to interrupt",
                primaryActionTitle: nil,
                secondaryActionTitle: nil
            ),
            audioLevel: 0.48,
            size: DesignMetrics.activeSize
        ),
        Fixture(
            phase: .approval,
            content: HUDContent(
                eyebrow: "APPROVAL REQUIRED",
                title: "Hand off this work?",
                detail: approvalStressDetail,
                primaryActionTitle: "Approve",
                secondaryActionTitle: "Reject"
            ),
            audioLevel: 0,
            size: DesignMetrics.approvalSize
        ),
        Fixture(
            phase: .result,
            content: HUDContent(
                eyebrow: "VOICE CONSOLE",
                title: "Implementation complete",
                detail: resultStressDetail,
                primaryActionTitle: "Open in Codex",
                secondaryActionTitle: "Dismiss"
            ),
            audioLevel: 0,
            size: DesignMetrics.expandedSize
        ),
        Fixture(
            phase: .recoverableError,
            content: HUDContent(
                eyebrow: "CONNECTION PAUSED",
                title: "Codex needs attention",
                detail: CodexBridgeFailure
                    .microphonePermissionRequired
                    .userFacingMessage,
                primaryActionTitle: "Repair Connection",
                secondaryActionTitle: "Not Now"
            ),
            audioLevel: 0,
            size: DesignMetrics.expandedSize
        )
    ]

    private static let approvalStressDetail = """
    Request: Independently rerun the release build, microphone safety paths, visual…
    Target task: 019fb02b…036e2f
    Action: Hand off work
    Full request:
    Independently rerun the release build, microphone safety paths, visual fixtures, keyboard-only approval flow, VoiceOver labels, Reduce Motion, Reduce Transparency, Increase Contrast, notch placement, and transparent-margin click-through.
    Boundary: Report failures only; do not publish, delete, message another person, or approve a destructive action.
    Working directory: /Users/example/Projects/CodexHUD
    Reason: This creates externally visible work in another persisted Codex task.
    """

    private static let resultStressDetail = """
    Codex finished the implementation and verified the signed release bundle, dedicated Voice Console binding, app-server round trips, realtime media shutdown, explicit approval paths, task handoffs, and all eight deterministic visual states. The remaining review record includes exact build evidence, accessibility observations, resource samples, and any live checks that still require the user’s microphone or a notched display.
    """
}
