import AppKit
import CoreGraphics
import QuartzCore
import Testing
@testable import CodexHUD

@Suite("HUD geometry and motion contract")
struct DesignMetricsTests {
    @Test("Every surface size is positive and grows monotonically")
    func surfaceSizing() {
        let sizes = [
            DesignMetrics.collapsedSize,
            DesignMetrics.activeSize,
            DesignMetrics.expandedSize,
            DesignMetrics.approvalSize
        ]

        #expect(sizes.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(DesignMetrics.collapsedSize.width < DesignMetrics.activeSize.width)
        #expect(DesignMetrics.collapsedSize.height < DesignMetrics.activeSize.height)
        #expect(DesignMetrics.activeSize.width < DesignMetrics.expandedSize.width)
        #expect(DesignMetrics.activeSize.height < DesignMetrics.expandedSize.height)
        #expect(DesignMetrics.expandedSize.width < DesignMetrics.approvalSize.width)
        #expect(DesignMetrics.expandedSize.height < DesignMetrics.approvalSize.height)
    }

    @Test("The expanded card remains compact on the target laptop")
    func expandedCardIsCompact() {
        #expect(DesignMetrics.expandedSize.width <= 420)
        #expect(DesignMetrics.expandedSize.height <= 220)
        #expect(DesignMetrics.approvalSize.width <= 420)
        #expect(DesignMetrics.approvalSize.height <= 240)
    }

    @Test("Window canvases reserve deterministic shadow room")
    func shadowCanvasSizing() {
        #expect(
            HUDPhase.dormant.hudWindowSize ==
                CGSize(width: 154, height: 122)
        )
        #expect(
            HUDPhase.listening.hudWindowSize ==
                CGSize(width: 214, height: 132)
        )
        #expect(
            HUDPhase.approval.hudWindowSize ==
                CGSize(width: 516, height: 364)
        )

        for phase in HUDPhase.allCases {
            #expect(
                phase.hudWindowSize.width ==
                    phase.hudVisualSize.width + 96
            )
            #expect(
                phase.hudWindowSize.height ==
                    phase.hudVisualSize.height
                        + phase.hudShadowTopPadding
                        + phase.hudShadowBottomPadding
            )
        }
    }

    @Test("Notch safe area always lowers the visible surface")
    func notchAwarePlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let phase = HUDPhase.listening

        let notchless = HUDPanelGeometry.windowFrame(
            screenFrame: screen,
            safeAreaTop: 0,
            phase: phase
        )
        let notched = HUDPanelGeometry.windowFrame(
            screenFrame: screen,
            safeAreaTop: 38,
            phase: phase
        )

        let localSurface = HUDPanelGeometry.surfaceFrame(for: phase)
        #expect(notchless.midX == screen.midX)
        #expect(notched.midX == screen.midX)
        #expect(notched.minY == notchless.minY - 31)
        #expect(
            notchless.minY + localSurface.maxY ==
                screen.maxY - DesignMetrics.screenTopInset
        )
        #expect(
            notched.minY + localSurface.maxY ==
                screen.maxY - 38
        )
    }

    @Test("Only the visible surface is interactive, never shadow padding")
    func surfaceHitRegion() {
        for phase in HUDPhase.allCases {
            let surface = HUDPanelGeometry.surfaceFrame(for: phase)
            #expect(
                surface.size == phase.hudVisualSize
            )
            #expect(surface.contains(CGPoint(x: surface.midX, y: surface.midY)))
            #expect(!surface.contains(CGPoint(x: 1, y: 1)))
            #expect(
                !surface.contains(
                    CGPoint(
                        x: phase.hudWindowSize.width - 1,
                        y: phase.hudWindowSize.height - 1
                    )
                )
            )
        }
    }

    @Test("Motion constants are finite, responsive, and physically valid")
    func motionConstants() {
        #expect(DesignMetrics.animationResponse.isFinite)
        #expect(DesignMetrics.animationDamping.isFinite)
        #expect(DesignMetrics.animationResponse > 0)
        #expect(DesignMetrics.animationResponse <= 0.5)
        #expect((0 ... 1).contains(DesignMetrics.animationDamping))
        #expect(DesignMetrics.screenTopInset >= 0)
    }

    @Test("Every compositor motion channel closes without a loop seam")
    func compositorMotionIsPeriodic() {
        let activePhases: [HUDPhase] = [
            .connecting,
            .listening,
            .thinking,
            .speaking
        ]

        for phase in activePhases {
            for level in [0.0, 0.53, 1.0] {
                let start = OrbMotionSample(
                    phase: phase,
                    audioLevel: level,
                    loopProgress: 0,
                    motionEnabled: true
                )
                let end = OrbMotionSample(
                    phase: phase,
                    audioLevel: level,
                    loopProgress: 1,
                    motionEnabled: true
                )

                #expect(abs(start.energy - end.energy) < 0.000_001)
                #expect(
                    abs(start.deformation - end.deformation) < 0.000_001
                )
                #expect(abs(start.scale - end.scale) < 0.000_001)
                #expect(
                    abs(start.rotation.radians - end.rotation.radians)
                        < 0.000_001
                )
                #expect(
                    abs(
                        start.highlightOffset.width
                            - end.highlightOffset.width
                    ) < 0.000_001
                )
                #expect(
                    abs(
                        start.highlightOffset.height
                            - end.highlightOffset.height
                    ) < 0.000_001
                )
                #expect(
                    abs(start.haloOpacity - end.haloOpacity) < 0.000_001
                )
            }
        }
    }

    @MainActor
    @Test("Material animation preserves one fully composited image layer")
    func materialAnimationUsesOneLayer() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let view = OrbMaterialFramesView(
            frame: CGRect(x: 0, y: 0, width: 28, height: 28)
        )

        view.configure(
            frames: [image, image],
            contentsScale: 2,
            contentPadding: 8,
            cycleDuration: 1,
            referenceMediaTime: CACurrentMediaTime(),
            animates: true
        )
        view.layoutSubtreeIfNeeded()

        let imageLayers = try #require(view.layer?.sublayers)
        #expect(imageLayers.count == 1)
        #expect(imageLayers[0].sublayers?.isEmpty != false)
        #expect(imageLayers[0].opacity == 1)
        #expect(imageLayers[0].frame == view.bounds.insetBy(dx: -8, dy: -8))
        let animation = try #require(
            imageLayers[0].animation(
                forKey: "orbMaterialFrames"
            ) as? CAKeyframeAnimation
        )
        #expect(animation.calculationMode == .discrete)
        #expect(animation.values?.count == 2)
        #expect(animation.repeatCount == .infinity)
        #expect(imageLayers[0].animationKeys() == ["orbMaterialFrames"])

        view.configure(
            frames: [image],
            contentsScale: 2,
            contentPadding: 8,
            cycleDuration: 1,
            referenceMediaTime: CACurrentMediaTime(),
            animates: false
        )
        #expect(imageLayers[0].animationKeys()?.isEmpty != false)
    }

    @MainActor
    @Test("Material frame banks cache only complete renders")
    func materialFrameStoreIsAtomic() async throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let successfulKey = OrbMaterialFrameKey(
            phase: "test-success",
            pointSizeHundredths: 2_800,
            backingScaleHundredths: 200,
            darkAppearance: true,
            increasedContrast: false,
            frameCount: 3,
            renderVersion: 90_001
        )

        var renderCalls = 0
        let first = await OrbMaterialFrameStore.shared.frames(
            for: successfulKey,
            frameCount: 3
        ) { _ in
            renderCalls += 1
            return image
        }
        var cacheMissBuilderCalls = 0
        let second = await OrbMaterialFrameStore.shared.frames(
            for: successfulKey,
            frameCount: 3
        ) { _ in
            cacheMissBuilderCalls += 1
            return nil
        }

        #expect(first?.count == 3)
        #expect(second?.count == 3)
        #expect(renderCalls == 3)
        #expect(cacheMissBuilderCalls == 0)

        let failedKey = OrbMaterialFrameKey(
            phase: "test-failure",
            pointSizeHundredths: 2_800,
            backingScaleHundredths: 200,
            darkAppearance: true,
            increasedContrast: false,
            frameCount: 3,
            renderVersion: 90_002
        )
        let failed = await OrbMaterialFrameStore.shared.frames(
            for: failedKey,
            frameCount: 3
        ) { index in
            index == 1 ? nil : image
        }
        #expect(failed == nil)
        #expect(
            OrbMaterialFrameStore.shared.cachedFrames(
                for: failedKey
            ) == nil
        )

        var retryCalls = 0
        let retried = await OrbMaterialFrameStore.shared.frames(
            for: failedKey,
            frameCount: 3
        ) { _ in
            retryCalls += 1
            return image
        }
        #expect(retried?.count == 3)
        #expect(retryCalls == 3)
    }
}
