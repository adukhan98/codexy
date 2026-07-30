import CoreGraphics
import Foundation
import SwiftUI

struct OrbMotionSample: Equatable {
    let energy: CGFloat
    let deformation: CGFloat
    let scale: CGFloat
    let rotation: Angle
    let highlightOffset: CGSize
    let haloOpacity: CGFloat

    init(
        phase: HUDPhase,
        audioLevel: Double,
        time: TimeInterval,
        motionEnabled: Bool
    ) {
        let profile = OrbPhaseProfile(phase: phase)
        self.init(
            phase: phase,
            audioLevel: audioLevel,
            phasePosition: CGFloat(time) * profile.speed,
            motionEnabled: motionEnabled,
            closesLoop: false
        )
    }

    /// Samples the compositor animation on a mathematically closed loop.
    /// Every animated component uses an integer harmonic of `loopProgress`,
    /// so progress zero and one have identical geometry and lighting.
    init(
        phase: HUDPhase,
        audioLevel: Double,
        loopProgress: Double,
        motionEnabled: Bool
    ) {
        self.init(
            phase: phase,
            audioLevel: audioLevel,
            phasePosition: CGFloat(loopProgress),
            motionEnabled: motionEnabled,
            closesLoop: true
        )
    }

    private init(
        phase: HUDPhase,
        audioLevel: Double,
        phasePosition: CGFloat,
        motionEnabled: Bool,
        closesLoop: Bool
    ) {
        let level = CGFloat(pow(max(0, min(audioLevel, 1)), 0.68))
        let profile = OrbPhaseProfile(phase: phase)
        let cycle: CGFloat
        if closesLoop {
            let remainder = phasePosition.truncatingRemainder(
                dividingBy: 1
            )
            cycle = remainder >= 0 ? remainder : remainder + 1
        } else {
            cycle = phasePosition
        }
        let breath = (sin(cycle * .pi * 2) + 1) * 0.5
        let secondaryFrequency: CGFloat = closesLoop ? 2 : 0.73
        let secondary = (
            sin((cycle * secondaryFrequency + 0.17) * .pi * 2) + 1
        ) * 0.5

        let liveEnergy: CGFloat
        switch phase {
        case .listening:
            liveEnergy = max(level, 0.08 + breath * 0.08)
        case .speaking:
            liveEnergy = max(level * 0.72, 0.22 + breath * 0.28)
        case .connecting:
            liveEnergy = 0.20 + breath * 0.17
        case .thinking:
            liveEnergy = 0.17 + secondary * 0.12
        case .dormant, .approval, .result, .recoverableError:
            liveEnergy = profile.baseEnergy
        }

        energy = liveEnergy
        deformation = motionEnabled
            ? profile.baseDeformation + liveEnergy * profile.energyDeformation
            : 0
        scale = motionEnabled
            ? 1 + liveEnergy * profile.energyScale
            : 1
        if motionEnabled, closesLoop {
            rotation = .radians(
                Double(
                    sin(cycle * .pi * 2)
                        * profile.rotationDirection
                        * 0.42
                )
            )
        } else {
            rotation = motionEnabled
                ? .radians(Double(cycle * profile.rotationDirection))
                : .zero
        }

        let orbit = motionEnabled ? cycle * .pi * 2 : -.pi * 0.72
        highlightOffset = CGSize(
            width: cos(orbit) * (1.2 + liveEnergy * 1.8),
            height: sin(
                orbit * (closesLoop ? 1 : 0.83)
            ) * (1.0 + liveEnergy * 1.3)
        )
        haloOpacity = profile.haloBase + liveEnergy * profile.haloEnergy
    }
}

private struct OrbPhaseProfile {
    let speed: CGFloat
    let baseEnergy: CGFloat
    let baseDeformation: CGFloat
    let energyDeformation: CGFloat
    let energyScale: CGFloat
    let rotationDirection: CGFloat
    let haloBase: CGFloat
    let haloEnergy: CGFloat

    init(phase: HUDPhase) {
        switch phase {
        case .dormant:
            self.init(
                speed: 0,
                baseEnergy: 0.04,
                baseDeformation: 0,
                energyDeformation: 0,
                energyScale: 0,
                rotationDirection: 0,
                haloBase: 0.12,
                haloEnergy: 0.08
            )
        case .connecting:
            self.init(
                speed: 0.62,
                baseEnergy: 0.20,
                baseDeformation: 0.018,
                energyDeformation: 0.035,
                energyScale: 0.045,
                rotationDirection: 1,
                haloBase: 0.22,
                haloEnergy: 0.30
            )
        case .listening:
            self.init(
                speed: 0.84,
                baseEnergy: 0.10,
                baseDeformation: 0.016,
                energyDeformation: 0.085,
                energyScale: 0.13,
                rotationDirection: -0.74,
                haloBase: 0.20,
                haloEnergy: 0.42
            )
        case .thinking:
            self.init(
                speed: 0.31,
                baseEnergy: 0.18,
                baseDeformation: 0.026,
                energyDeformation: 0.045,
                energyScale: 0.035,
                rotationDirection: 0.66,
                haloBase: 0.24,
                haloEnergy: 0.24
            )
        case .speaking:
            self.init(
                speed: 0.70,
                baseEnergy: 0.24,
                baseDeformation: 0.022,
                energyDeformation: 0.076,
                energyScale: 0.085,
                rotationDirection: 0.83,
                haloBase: 0.24,
                haloEnergy: 0.38
            )
        case .approval:
            self.init(
                speed: 0,
                baseEnergy: 0.16,
                baseDeformation: 0,
                energyDeformation: 0,
                energyScale: 0,
                rotationDirection: 0,
                haloBase: 0.26,
                haloEnergy: 0.16
            )
        case .result:
            self.init(
                speed: 0,
                baseEnergy: 0.12,
                baseDeformation: 0,
                energyDeformation: 0,
                energyScale: 0,
                rotationDirection: 0,
                haloBase: 0.24,
                haloEnergy: 0.15
            )
        case .recoverableError:
            self.init(
                speed: 0,
                baseEnergy: 0.18,
                baseDeformation: 0,
                energyDeformation: 0,
                energyScale: 0,
                rotationDirection: 0,
                haloBase: 0.24,
                haloEnergy: 0.20
            )
        }
    }

    private init(
        speed: CGFloat,
        baseEnergy: CGFloat,
        baseDeformation: CGFloat,
        energyDeformation: CGFloat,
        energyScale: CGFloat,
        rotationDirection: CGFloat,
        haloBase: CGFloat,
        haloEnergy: CGFloat
    ) {
        self.speed = speed
        self.baseEnergy = baseEnergy
        self.baseDeformation = baseDeformation
        self.energyDeformation = energyDeformation
        self.energyScale = energyScale
        self.rotationDirection = rotationDirection
        self.haloBase = haloBase
        self.haloEnergy = haloEnergy
    }
}

struct OrbBlobShape: Shape {
    var deformation: CGFloat
    var rotation: Angle

    func path(in rect: CGRect) -> Path {
        let sampleCount = 72
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) * 0.45
        var path = Path()

        for index in 0...sampleCount {
            let fraction = CGFloat(index) / CGFloat(sampleCount)
            let angle = fraction * .pi * 2
            let rotatedAngle = angle + CGFloat(rotation.radians)
            let harmonic =
                sin(rotatedAngle * 3 + 0.8) * 0.56
                + sin(rotatedAngle * 5 - 0.35) * 0.29
                + cos(rotatedAngle * 2 + 1.12) * 0.15
            let radius = baseRadius * (1 + harmonic * deformation)
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}
