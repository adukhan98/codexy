import AppKit
import QuartzCore
import SwiftUI

struct OrbView: View {
    let phase: HUDPhase
    let audioLevel: Double
    var animationsEnabled = true
    var size: CGFloat = 28
    var increasedContrastOverride: Bool?
    var productionMotionTimeOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale

    private var motionEnabled: Bool {
        animationsEnabled && !reduceMotion
    }

    private var usesNativeActiveHost: Bool {
        (animationsEnabled || productionMotionTimeOverride != nil) && {
            switch phase {
            case .connecting, .listening, .thinking, .speaking:
                true
            case .dormant, .approval, .result, .recoverableError:
                false
            }
        }()
    }

    var body: some View {
        Group {
            if usesNativeActiveHost {
                AnimatedOrbHost(
                    phase: phase,
                    audioLevel: audioLevel,
                    size: size,
                    colorScheme: colorScheme,
                    increasedContrast: increasedContrastOverride
                        ?? (colorSchemeContrast == .increased),
                    backingScale: displayScale,
                    ambientMotionEnabled:
                        motionEnabled || productionMotionTimeOverride != nil,
                    frozenTimeOverride: productionMotionTimeOverride
                )
            } else {
                staticArtwork
            }
        }
        .frame(width: size, height: size)
        .task(id: prewarmTaskID) {
            guard
                phase == .dormant,
                animationsEnabled,
                !reduceMotion
            else {
                return
            }
            await AnimatedOrbHost.prewarmMaterialFrames(
                size: size,
                colorScheme: colorScheme,
                increasedContrast: increasedContrastOverride
                    ?? (colorSchemeContrast == .increased),
                backingScale: displayScale
            )
        }
        .accessibilityHidden(true)
    }

    private var prewarmTaskID: String {
        [
            phase.rawValue,
            String(format: "%.2f", size),
            colorScheme == .dark ? "dark" : "light",
            (increasedContrastOverride
                ?? (colorSchemeContrast == .increased))
                ? "high-contrast"
                : "standard-contrast",
            String(format: "%.2f", displayScale),
            reduceMotion ? "reduced-motion" : "motion"
        ].joined(separator: "|")
    }

    private var staticArtwork: some View {
        let sample = OrbMotionSample(
            phase: phase,
            audioLevel: motionEnabled ? audioLevel : 0,
            time: 0,
            motionEnabled: motionEnabled
        )

        return OrbArtwork(
            phase: phase,
            sample: sample,
            colorScheme: colorScheme,
            increasedContrast: increasedContrastOverride
                ?? (colorSchemeContrast == .increased)
        )
        .scaleEffect(sample.scale)
    }
}

@MainActor
private struct AnimatedOrbHost: NSViewRepresentable {
    let phase: HUDPhase
    let audioLevel: Double
    let size: CGFloat
    let colorScheme: ColorScheme
    let increasedContrast: Bool
    let backingScale: CGFloat
    let ambientMotionEnabled: Bool
    let frozenTimeOverride: TimeInterval?

    private static let phaseHandoffDuration = 0.16
    private static let materialFrameRate = 60.0
    private static let materialOverscanFactor: CGFloat = 0.62

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let frame = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        let root = AnimatedOrbRootView(frame: frame)

        let audioHost = NSView(frame: frame)
        audioHost.wantsLayer = true
        audioHost.layer?.masksToBounds = false
        audioHost.setAccessibilityElement(false)
        root.addSubview(audioHost)

        let phaseBlendHost = NSView(frame: frame)
        phaseBlendHost.wantsLayer = true
        phaseBlendHost.layer?.masksToBounds = false
        phaseBlendHost.setAccessibilityElement(false)
        audioHost.addSubview(phaseBlendHost)

        let ambientHost = NSView(frame: frame)
        ambientHost.wantsLayer = true
        ambientHost.layer?.masksToBounds = false
        ambientHost.setAccessibilityElement(false)
        phaseBlendHost.addSubview(ambientHost)

        let materialView = OrbMaterialFramesView(frame: frame)
        ambientHost.addSubview(materialView)

        context.coordinator.audioHost = audioHost
        context.coordinator.phaseBlendHost = phaseBlendHost
        context.coordinator.ambientHost = ambientHost
        context.coordinator.materialView = materialView
        updateNSView(root, context: context)
        return root
    }

    func updateNSView(_ root: NSView, context: Context) {
        guard
            let audioHost = context.coordinator.audioHost,
            let phaseBlendHost = context.coordinator.phaseBlendHost,
            let ambientHost = context.coordinator.ambientHost,
            let materialView = context.coordinator.materialView
        else {
            return
        }

        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: size, height: size)
        )
        if root.frame.size != bounds.size {
            root.setFrameSize(bounds.size)
        }
        for view in [
            audioHost,
            phaseBlendHost,
            ambientHost,
            materialView
        ] where view.frame != bounds {
            view.frame = bounds
        }

        let signature = RenderSignature(
            phase: phase,
            size: size,
            colorScheme: colorScheme,
            increasedContrast: increasedContrast,
            backingScale: backingScale,
            ambientMotionEnabled: ambientMotionEnabled,
            frozenTimeOverride: frozenTimeOverride
        )
        let signatureChanged = context.coordinator.signature != signature
        if signatureChanged {
            let referenceMediaTime = CACurrentMediaTime()
            let nextMaterialView = makeMaterialView(
                referenceMediaTime: referenceMediaTime
            )
            if context.coordinator.signature == nil {
                materialView.removeFromSuperview()
                ambientHost.addSubview(nextMaterialView)
                context.coordinator.materialView = nextMaterialView
            } else {
                replaceMaterial(
                    nextMaterialView,
                    in: ambientHost,
                    replacing: materialView,
                    coordinator: context.coordinator
                )
            }

            configureAmbientMotion(
                ambientHost: ambientHost,
                phaseBlendHost: phaseBlendHost,
                coordinator: context.coordinator,
                referenceMediaTime: referenceMediaTime
            )
            context.coordinator.signature = signature
        }

        updateAudioScale(
            audioHost.layer,
            force: signatureChanged,
            animated:
                ambientMotionEnabled && frozenTimeOverride == nil
        )
    }

    static func dismantleNSView(
        _ nsView: NSView,
        coordinator: Coordinator
    ) {
        removeAnimations(in: nsView)
    }

    final class Coordinator {
        var audioHost: NSView?
        var phaseBlendHost: NSView?
        var ambientHost: NSView?
        var materialView: OrbMaterialFramesView?
        var signature: RenderSignature?
    }

    struct RenderSignature: Equatable {
        let phase: HUDPhase
        let size: CGFloat
        let colorScheme: ColorScheme
        let increasedContrast: Bool
        let backingScale: CGFloat
        let ambientMotionEnabled: Bool
        let frozenTimeOverride: TimeInterval?
    }

    private static func frequency(for phase: HUDPhase) -> Double {
        switch phase {
        case .connecting:
            0.62
        case .listening:
            0.84
        case .thinking:
            0.31
        case .speaking:
            0.70
        case .dormant, .approval, .result, .recoverableError:
            1
        }
    }

    private var scaleFrequency: Double {
        Self.scaleFrequency(for: phase)
    }

    private static func scaleFrequency(for phase: HUDPhase) -> Double {
        let frequency = frequency(for: phase)
        return phase == .thinking ? frequency * 0.73 : frequency
    }

    private var wobbleAmplitude: CGFloat {
        switch phase {
        case .connecting:
            0.009
        case .listening:
            0.007
        case .thinking:
            0.011
        case .speaking:
            0.010
        case .dormant, .approval, .result, .recoverableError:
            0
        }
    }

    private var audioScale: CGFloat {
        guard ambientMotionEnabled else { return 1 }
        let level = CGFloat(pow(max(0, min(audioLevel, 1)), 0.68))
        switch phase {
        case .listening:
            return 1 + level * 0.070
        case .speaking:
            return 1 + level * 0.045
        case .dormant, .connecting, .thinking, .approval, .result,
             .recoverableError:
            return 1
        }
    }

    private func makeMaterialView(
        referenceMediaTime: CFTimeInterval
    ) -> OrbMaterialFramesView {
        let frame = CGRect(
            origin: .zero,
            size: CGSize(width: size, height: size)
        )
        let materialView = OrbMaterialFramesView(frame: frame)
        let duration = 1 / scaleFrequency
        let contentsScale = max(1, backingScale)
        let animates = ambientMotionEnabled && frozenTimeOverride == nil
        let frameCount = animates
            ? Self.materialFrameCount(duration: duration)
            : 1
        let contentPadding = Self.materialContentPadding(
            size: size,
            backingScale: contentsScale
        )
        let frozenProgress = frozenTimeOverride.map {
            normalizedLoopProgress(for: $0, duration: duration)
        }

        if !animates {
            let frame = Self.renderMaterialFrame(
                phase: phase,
                audioLevel: 0,
                loopProgress: frozenProgress ?? 0,
                motionEnabled: ambientMotionEnabled,
                size: size,
                colorScheme: colorScheme,
                increasedContrast: increasedContrast,
                backingScale: contentsScale,
                contentPadding: contentPadding
            )
            materialView.configure(
                frames: frame.map { [$0] } ?? [],
                contentsScale: contentsScale,
                contentPadding: contentPadding,
                cycleDuration: duration,
                referenceMediaTime: referenceMediaTime,
                animates: false
            )
            return materialView
        }

        let key = Self.materialFrameKey(
            phase: phase,
            size: size,
            colorScheme: colorScheme,
            increasedContrast: increasedContrast,
            backingScale: contentsScale,
            frameCount: frameCount
        )
        if let cached = OrbMaterialFrameStore.shared.cachedFrames(
            for: key
        ) {
            materialView.configure(
                frames: cached,
                contentsScale: contentsScale,
                contentPadding: contentPadding,
                cycleDuration: duration,
                referenceMediaTime: referenceMediaTime,
                animates: true
            )
            return materialView
        }

        // Never make a voice transition wait for a frame bank. One complete
        // material frame is installed immediately; the ambient transform
        // remains live while the cache fills in yielded MainActor slices.
        let fallbackProgress = normalizedLoopProgress(
            for: referenceMediaTime,
            duration: duration
        )
        let fallback = Self.renderMaterialFrame(
            phase: phase,
            audioLevel: 0,
            loopProgress: fallbackProgress,
            motionEnabled: true,
            size: size,
            colorScheme: colorScheme,
            increasedContrast: increasedContrast,
            backingScale: contentsScale,
            contentPadding: contentPadding
        )
        materialView.configure(
            frames: fallback.map { [$0] } ?? [],
            contentsScale: contentsScale,
            contentPadding: contentPadding,
            cycleDuration: duration,
            referenceMediaTime: referenceMediaTime,
            animates: false
        )

        Task { @MainActor [weak materialView] in
            let frames = await OrbMaterialFrameStore.shared.frames(
                for: key,
                frameCount: frameCount
            ) { frameIndex in
                Self.renderMaterialFrame(
                    phase: phase,
                    audioLevel: 0,
                    loopProgress:
                        Double(frameIndex) / Double(frameCount),
                    motionEnabled: true,
                    size: size,
                    colorScheme: colorScheme,
                    increasedContrast: increasedContrast,
                    backingScale: contentsScale,
                    contentPadding: contentPadding
                )
            }
            guard
                let materialView,
                materialView.superview != nil,
                let frames
            else {
                return
            }
            materialView.configure(
                frames: frames,
                contentsScale: contentsScale,
                contentPadding: contentPadding,
                cycleDuration: duration,
                referenceMediaTime: CACurrentMediaTime(),
                animates: true
            )
        }
        return materialView
    }

    static func prewarmMaterialFrames(
        size: CGFloat,
        colorScheme: ColorScheme,
        increasedContrast: Bool,
        backingScale: CGFloat
    ) async {
        let contentsScale = max(1, backingScale)
        let contentPadding = materialContentPadding(
            size: size,
            backingScale: contentsScale
        )
        let phases: [HUDPhase] = [
            .connecting,
            .listening,
            .thinking,
            .speaking
        ]

        for phase in phases {
            let duration = 1 / scaleFrequency(for: phase)
            let frameCount = materialFrameCount(duration: duration)
            let key = materialFrameKey(
                phase: phase,
                size: size,
                colorScheme: colorScheme,
                increasedContrast: increasedContrast,
                backingScale: contentsScale,
                frameCount: frameCount
            )
            _ = await OrbMaterialFrameStore.shared.frames(
                for: key,
                frameCount: frameCount
            ) { frameIndex in
                renderMaterialFrame(
                    phase: phase,
                    audioLevel: 0,
                    loopProgress:
                        Double(frameIndex) / Double(frameCount),
                    motionEnabled: true,
                    size: size,
                    colorScheme: colorScheme,
                    increasedContrast: increasedContrast,
                    backingScale: contentsScale,
                    contentPadding: contentPadding
                )
            }
        }
    }

    private static func materialFrameCount(
        duration: TimeInterval
    ) -> Int {
        max(2, Int(ceil(duration * materialFrameRate)))
    }

    private static func materialContentPadding(
        size: CGFloat,
        backingScale: CGFloat
    ) -> CGFloat {
        let rawPadding = size * materialOverscanFactor
        return ceil(rawPadding * backingScale) / backingScale
    }

    private static func materialFrameKey(
        phase: HUDPhase,
        size: CGFloat,
        colorScheme: ColorScheme,
        increasedContrast: Bool,
        backingScale: CGFloat,
        frameCount: Int
    ) -> OrbMaterialFrameKey {
        OrbMaterialFrameKey(
            phase: phase.rawValue,
            pointSizeHundredths: Int((size * 100).rounded()),
            backingScaleHundredths: Int(
                (backingScale * 100).rounded()
            ),
            darkAppearance: colorScheme == .dark,
            increasedContrast: increasedContrast,
            frameCount: frameCount,
            renderVersion: 3
        )
    }

    private static func renderMaterialFrame(
        phase: HUDPhase,
        audioLevel: Double,
        loopProgress: Double,
        motionEnabled: Bool,
        size: CGFloat,
        colorScheme: ColorScheme,
        increasedContrast: Bool,
        backingScale: CGFloat,
        contentPadding: CGFloat
    ) -> CGImage? {
        autoreleasepool {
            let canvasSize = size + contentPadding * 2
            let sample = OrbMotionSample(
                phase: phase,
                audioLevel: audioLevel,
                loopProgress: loopProgress,
                motionEnabled: motionEnabled
            )
            let renderer = ImageRenderer(
                content: ZStack {
                    OrbArtwork(
                        phase: phase,
                        sample: sample,
                        colorScheme: colorScheme,
                        increasedContrast: increasedContrast
                    )
                    .frame(width: size, height: size)
                }
                .frame(width: canvasSize, height: canvasSize)
            )
            renderer.proposedSize = ProposedViewSize(
                width: canvasSize,
                height: canvasSize
            )
            renderer.scale = backingScale
            return renderer.cgImage
        }
    }

    private func replaceMaterial(
        _ nextMaterialView: OrbMaterialFramesView,
        in ambientHost: NSView,
        replacing oldMaterialView: OrbMaterialFramesView,
        coordinator: Coordinator
    ) {
        nextMaterialView.frame = oldMaterialView.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldMaterialView.removeFromSuperview()
        ambientHost.addSubview(nextMaterialView)
        CATransaction.commit()
        coordinator.materialView = nextMaterialView
    }

    private func configureAmbientMotion(
        ambientHost: NSView,
        phaseBlendHost: NSView,
        coordinator: Coordinator,
        referenceMediaTime: CFTimeInterval
    ) {
        guard
            let ambientLayer = ambientHost.layer,
            let phaseBlendLayer = phaseBlendHost.layer
        else {
            return
        }

        let oldAmbientTransform = ambientLayer.presentation()?.transform
            ?? ambientLayer.transform
        let oldPhaseTransform = phaseBlendLayer.presentation()?.transform
            ?? phaseBlendLayer.transform
        let oldOverallScale = CGSize(
            width: oldAmbientTransform.m11 * oldPhaseTransform.m11,
            height: oldAmbientTransform.m22 * oldPhaseTransform.m22
        )

        ambientLayer.removeAnimation(forKey: "orbAmbientTransform")
        phaseBlendLayer.removeAnimation(forKey: "orbPhaseHandoff")

        let duration = 1 / scaleFrequency
        if let frozenTimeOverride {
            let fraction = normalizedLoopProgress(
                for: frozenTimeOverride,
                duration: duration
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ambientLayer.transform = transformValue(at: fraction)
            phaseBlendLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        guard ambientMotionEnabled else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ambientLayer.transform = CATransform3DIdentity
            phaseBlendLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        let frameCount = Self.materialFrameCount(duration: duration)
        let poseIndices = 0...frameCount
        let transforms = poseIndices.map { pose -> NSValue in
            let fraction = Double(pose) / Double(frameCount)
            return NSValue(
                caTransform3D: transformValue(at: fraction)
            )
        }
        let keyTimes = poseIndices.map {
            NSNumber(
                value: Double($0) / Double(frameCount)
            )
        }

        let transformAnimation = CAKeyframeAnimation(keyPath: "transform")
        transformAnimation.values = transforms
        transformAnimation.keyTimes = keyTimes
        transformAnimation.duration = duration
        transformAnimation.repeatCount = .infinity
        transformAnimation.calculationMode = .linear
        transformAnimation.isRemovedOnCompletion = false
        let localTime = ambientLayer.convertTime(
            referenceMediaTime,
            from: nil
        )
        let transformOffset = localTime
            .truncatingRemainder(dividingBy: duration)
        transformAnimation.beginTime = localTime
        transformAnimation.timeOffset = transformOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ambientLayer.transform = transforms[0].caTransform3DValue
        CATransaction.commit()
        ambientLayer.add(
            transformAnimation,
            forKey: "orbAmbientTransform"
        )

        let targetTransform = transformValue(
            at: transformOffset / duration
        )
        if coordinator.signature != nil {
            let handoffScale = CATransform3DMakeScale(
                oldOverallScale.width / max(targetTransform.m11, 0.001),
                oldOverallScale.height / max(targetTransform.m22, 0.001),
                1
            )
            let handoff = CABasicAnimation(keyPath: "transform")
            handoff.fromValue = NSValue(caTransform3D: handoffScale)
            handoff.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            handoff.duration = Self.phaseHandoffDuration
            handoff.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            phaseBlendLayer.transform = CATransform3DIdentity
            phaseBlendLayer.add(handoff, forKey: "orbPhaseHandoff")
        } else {
            phaseBlendLayer.transform = CATransform3DIdentity
        }
    }

    private func transformValue(
        at fraction: Double
    ) -> CATransform3D {
        let sample = OrbMotionSample(
            phase: phase,
            audioLevel: 0,
            loopProgress: fraction,
            motionEnabled: true
        )
        let wobble = sin(CGFloat(fraction) * .pi * 2)
            * wobbleAmplitude
        return CATransform3DMakeScale(
            sample.scale * (1 + wobble),
            sample.scale * (1 - wobble * 0.72),
            1
        )
    }

    private func normalizedLoopProgress(
        for time: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        let remainder = time.truncatingRemainder(dividingBy: duration)
        let normalizedTime = remainder >= 0 ? remainder : remainder + duration
        return normalizedTime / duration
    }

    private func updateAudioScale(
        _ layer: CALayer?,
        force: Bool,
        animated: Bool
    ) {
        guard let layer else {
            return
        }
        let currentScale = layer.transform.m11
        guard force || abs(currentScale - audioScale) >= 0.002 else {
            return
        }

        let target = CATransform3DMakeScale(audioScale, audioScale, 1)
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = target
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer.presentation()?.transform
            ?? layer.transform
        animation.toValue = target
        animation.duration = 0.085
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeOut
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        layer.add(animation, forKey: "orbAudioScale")
    }

    private static func removeAnimations(in view: NSView) {
        view.layer?.removeAllAnimations()
        for subview in view.subviews {
            removeAnimations(in: subview)
        }
    }
}

private struct OrbArtwork: View, Equatable {
    let phase: HUDPhase
    let sample: OrbMotionSample
    let colorScheme: ColorScheme
    let increasedContrast: Bool
    var showsSpecularGlint = true

    private var accent: Color {
        HUDVisualStyle.accent(for: phase)
    }

    private var secondaryAccent: Color {
        HUDVisualStyle.secondaryAccent(for: phase)
    }

    private var blob: OrbBlobShape {
        OrbBlobShape(
            deformation: sample.deformation,
            rotation: sample.rotation
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let meshOffsetX = Float(
                sample.highlightOffset.width / max(diameter, 1) * 0.72
            )
            let meshOffsetY = Float(
                sample.highlightOffset.height / max(diameter, 1) * 0.72
            )

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                accent.opacity(sample.haloOpacity),
                                accent.opacity(0)
                            ],
                            center: .center,
                            startRadius: diameter * 0.04,
                            endRadius: diameter * 0.62
                        )
                    )
                    .blur(radius: diameter * 0.11)
                    .scaleEffect(1.18)

                blob
                    .fill(
                        MeshGradient(
                            width: 3,
                            height: 3,
                            points: [
                                SIMD2(0.0, 0.0),
                                SIMD2(0.5 + meshOffsetX * 0.18, 0.0),
                                SIMD2(1.0, 0.0),
                                SIMD2(0.0, 0.5 + meshOffsetY * 0.12),
                                SIMD2(0.5 + meshOffsetX, 0.5 + meshOffsetY),
                                SIMD2(1.0, 0.5 - meshOffsetY * 0.16),
                                SIMD2(0.0, 1.0),
                                SIMD2(0.5 - meshOffsetX * 0.14, 1.0),
                                SIMD2(1.0, 1.0)
                            ],
                            colors: [
                                secondaryAccent,
                                accent,
                                accent.opacity(0.84),
                                accent,
                                secondaryAccent.opacity(0.86),
                                accent,
                                secondaryAccent.opacity(0.92),
                                accent.opacity(0.90),
                                accent
                            ],
                            background: accent,
                            smoothsColors: true,
                            colorSpace: .perceptual
                        )
                    )

                blob
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.76 : 0.90),
                                Color.white.opacity(0.12),
                                Color.black.opacity(colorScheme == .dark ? 0.10 : 0.18)
                            ],
                            center: UnitPoint(
                                x: 0.31 + sample.highlightOffset.width / max(diameter, 1),
                                y: 0.24 + sample.highlightOffset.height / max(diameter, 1)
                            ),
                            startRadius: 0,
                            endRadius: diameter * 0.56
                        )
                    )
                    .blendMode(.softLight)

                OrbTextureView(
                    accent: accent,
                    energy: sample.energy
                )
                .clipShape(blob)
                .blendMode(.screen)

                blob
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(increasedContrast ? 0.88 : 0.62),
                                Color.white.opacity(0.08),
                                Color.black.opacity(increasedContrast ? 0.42 : 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: increasedContrast ? 1.35 : 0.75
                    )

                if showsSpecularGlint {
                    Ellipse()
                        .fill(
                            Color.white.opacity(
                                colorScheme == .dark ? 0.52 : 0.70
                            )
                        )
                        .frame(
                            width: diameter * 0.22,
                            height: diameter * 0.10
                        )
                        .blur(radius: diameter * 0.025)
                        .offset(
                            x: -diameter * 0.16
                                + sample.highlightOffset.width * 0.32,
                            y: -diameter * 0.19
                                + sample.highlightOffset.height * 0.32
                        )
                        .rotationEffect(.degrees(-24))
                        .blendMode(.screen)
                }
            }
            .shadow(
                color: accent.opacity(colorScheme == .dark ? 0.34 : 0.24),
                radius: diameter * 0.16,
                y: diameter * 0.04
            )
        }
    }
}

private struct OrbTextureView: View {
    let accent: Color
    let energy: CGFloat

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let shortestEdge = min(size.width, size.height)

            for index in 0..<22 {
                let seed = CGFloat((index * 37 + 11) % 101) / 101
                let secondarySeed = CGFloat((index * 61 + 7) % 97) / 97
                let radius = shortestEdge * (0.007 + seed * 0.018)
                let origin = CGPoint(
                    x: size.width * (0.12 + seed * 0.76),
                    y: size.height * (0.12 + secondarySeed * 0.76)
                )
                let path = Path(
                    ellipseIn: CGRect(
                        x: origin.x - radius,
                        y: origin.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )

                context.fill(
                    path,
                    with: .color(
                        index.isMultiple(of: 3)
                            ? Color.white.opacity(0.08 + energy * 0.10)
                            : accent.opacity(0.035 + energy * 0.045)
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}
