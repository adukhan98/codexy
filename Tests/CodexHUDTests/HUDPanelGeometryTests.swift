import CoreGraphics
import Testing
@testable import CodexHUD

@Suite("HUD panel geometry")
struct HUDPanelGeometryTests {
    @Test("The visible surface stays top-centred on a notchless display")
    func notchlessPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let phase = HUDPhase.listening
        let frame = HUDPanelGeometry.windowFrame(
            screenFrame: screen,
            safeAreaTop: 0,
            phase: phase
        )
        let surface = HUDPanelGeometry.surfaceFrame(for: phase)

        #expect(frame.midX == screen.midX)
        #expect(
            frame.minY + surface.maxY
                == screen.maxY - DesignMetrics.screenTopInset
        )
    }

    @Test("A camera housing moves the surface below the safe-area boundary")
    func notchedPlacement() {
        let screen = CGRect(x: -200, y: 30, width: 1_728, height: 1_117)
        let safeAreaTop: CGFloat = 38
        let phase = HUDPhase.dormant
        let frame = HUDPanelGeometry.windowFrame(
            screenFrame: screen,
            safeAreaTop: safeAreaTop,
            phase: phase
        )
        let surface = HUDPanelGeometry.surfaceFrame(for: phase)

        #expect(frame.midX == screen.midX)
        #expect(
            frame.minY + surface.maxY
                == screen.maxY - safeAreaTop
        )
    }

    @Test("The interactive surface excludes every transparent shadow margin")
    func shadowMarginsAreClickThroughGeometry() {
        for phase in HUDPhase.allCases {
            let surface = HUDPanelGeometry.surfaceFrame(for: phase)
            let window = CGRect(origin: .zero, size: phase.hudWindowSize)

            #expect(window.contains(surface))
            #expect(surface.minX == DesignMetrics.shadowHorizontalPadding)
            #expect(surface.minY == phase.hudShadowBottomPadding)
            #expect(
                window.maxX - surface.maxX
                    == DesignMetrics.shadowHorizontalPadding
            )
            #expect(
                window.maxY - surface.maxY
                    == phase.hudShadowTopPadding
            )
        }
    }
}
