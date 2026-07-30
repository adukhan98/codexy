#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let requiredSizes = [16, 32, 64, 128, 256, 512, 1024]

private func color(
    _ red: CGFloat,
    _ green: CGFloat,
    _ blue: CGFloat,
    _ alpha: CGFloat = 1
) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [red, green, blue, alpha]
    )!
}

private func gradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: locations
    )!
}

private func drawRadialGlow(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    inner: CGColor,
    outer: CGColor
) {
    context.drawRadialGradient(
        gradient([inner, outer], locations: [0, 1]),
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsAfterEndLocation]
    )
}

private func iconImage(size: Int) throws -> Data {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphicsContext.cgContext
    let edge = CGFloat(size)
    let canvas = CGRect(x: 0, y: 0, width: edge, height: edge)
    context.clear(canvas)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let margin = max(edge * 0.055, size <= 32 ? 1 : 0)
    let tileRect = canvas.insetBy(dx: margin, dy: margin)
    let cornerRadius = tileRect.width * 0.225
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // A restrained, soft tile shadow keeps the icon dimensional without
    // sacrificing the silhouette at 16 points.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -edge * 0.018),
        blur: edge * 0.042,
        color: color(0, 0, 0, 0.46)
    )
    context.addPath(tilePath)
    context.setFillColor(color(0.02, 0.022, 0.032, 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    context.drawLinearGradient(
        gradient(
            [
                color(0.12, 0.13, 0.18, 1),
                color(0.045, 0.048, 0.068, 1),
                color(0.025, 0.027, 0.038, 1)
            ],
            locations: [0, 0.56, 1]
        ),
        start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    drawRadialGlow(
        in: context,
        center: CGPoint(
            x: tileRect.minX + tileRect.width * 0.26,
            y: tileRect.maxY - tileRect.height * 0.18
        ),
        radius: tileRect.width * 0.78,
        inner: color(0.22, 0.32, 0.55, 0.18),
        outer: color(0.08, 0.08, 0.12, 0)
    )

    drawRadialGlow(
        in: context,
        center: CGPoint(
            x: tileRect.maxX - tileRect.width * 0.18,
            y: tileRect.minY + tileRect.height * 0.18
        ),
        radius: tileRect.width * 0.62,
        inner: color(0.44, 0.19, 0.52, 0.10),
        outer: color(0.08, 0.08, 0.12, 0)
    )

    if size >= 64 {
        // Deterministic graphite grain avoids a sterile flat tile at large
        // sizes while disappearing cleanly from the small renditions.
        for index in 0..<84 {
            let xSeed = CGFloat((index * 67 + 13) % 191) / 191
            let ySeed = CGFloat((index * 103 + 29) % 193) / 193
            let grainRadius = max(0.45, edge * 0.00065)
            let point = CGPoint(
                x: tileRect.minX + tileRect.width * xSeed,
                y: tileRect.minY + tileRect.height * ySeed
            )
            context.setFillColor(color(1, 1, 1, index.isMultiple(of: 3) ? 0.018 : 0.010))
            context.fillEllipse(
                in: CGRect(
                    x: point.x - grainRadius,
                    y: point.y - grainRadius,
                    width: grainRadius * 2,
                    height: grainRadius * 2
                )
            )
        }
    }

    context.restoreGState()

    // Two rim passes preserve the tile edge on both dark and bright desktops.
    context.addPath(tilePath)
    context.setStrokeColor(color(1, 1, 1, size <= 32 ? 0.09 : 0.15))
    context.setLineWidth(size <= 32 ? 0.5 : max(0.7, edge * 0.0022))
    context.strokePath()

    if size >= 64 {
        let innerInset = max(0.8, edge * 0.004)
        let innerTilePath = CGPath(
            roundedRect: tileRect.insetBy(dx: innerInset, dy: innerInset),
            cornerWidth: max(0, cornerRadius - innerInset),
            cornerHeight: max(0, cornerRadius - innerInset),
            transform: nil
        )
        context.addPath(innerTilePath)
        context.setStrokeColor(color(0, 0, 0, 0.34))
        context.setLineWidth(max(0.5, edge * 0.0016))
        context.strokePath()
    }

    let orbCenter = CGPoint(
        x: tileRect.midX,
        y: tileRect.midY + tileRect.height * 0.012
    )
    let orbRadius = tileRect.width * 0.272
    let orbRect = CGRect(
        x: orbCenter.x - orbRadius,
        y: orbCenter.y - orbRadius,
        width: orbRadius * 2,
        height: orbRadius * 2
    )
    let orbPath = CGPath(ellipseIn: orbRect, transform: nil)

    // The halo is intentionally broad and low-alpha; the orb remains a clean
    // circle instead of turning into a fuzzy badge at small sizes.
    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: max(1.1, edge * 0.047),
        color: color(0.18, 0.77, 1, size <= 32 ? 0.36 : 0.46)
    )
    context.addPath(orbPath)
    context.setFillColor(color(0.16, 0.70, 0.96, 0.72))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(orbPath)
    context.clip()

    context.drawLinearGradient(
        gradient(
            [
                color(0.27, 0.94, 0.96, 1),
                color(0.18, 0.55, 0.98, 1),
                color(0.47, 0.26, 0.96, 1),
                color(0.84, 0.24, 0.69, 1)
            ],
            locations: [0, 0.37, 0.70, 1]
        ),
        start: CGPoint(x: orbRect.minX, y: orbRect.maxY),
        end: CGPoint(x: orbRect.maxX, y: orbRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    drawRadialGlow(
        in: context,
        center: CGPoint(
            x: orbRect.minX + orbRect.width * 0.24,
            y: orbRect.maxY - orbRect.height * 0.21
        ),
        radius: orbRect.width * 0.74,
        inner: color(0.88, 1, 1, 0.66),
        outer: color(0.22, 0.75, 1, 0)
    )

    drawRadialGlow(
        in: context,
        center: CGPoint(
            x: orbRect.maxX - orbRect.width * 0.12,
            y: orbRect.minY + orbRect.height * 0.14
        ),
        radius: orbRect.width * 0.64,
        inner: color(0.95, 0.19, 0.62, 0.50),
        outer: color(0.42, 0.20, 0.95, 0)
    )

    drawRadialGlow(
        in: context,
        center: CGPoint(
            x: orbRect.minX + orbRect.width * 0.28,
            y: orbRect.minY + orbRect.height * 0.12
        ),
        radius: orbRect.width * 0.52,
        inner: color(0.20, 0.96, 0.63, 0.34),
        outer: color(0.16, 0.64, 0.74, 0)
    )

    // Subtle internal voice traces are omitted below 32 px so the smallest
    // icon reads as a jewel instead of a noisy waveform.
    if size >= 64 {
        context.setBlendMode(.screen)
        context.setLineCap(.round)
        context.setLineWidth(max(0.7, edge * 0.0042))

        for index in 0..<3 {
            let inset = CGFloat(index) * orbRadius * 0.13
            let arcRect = orbRect.insetBy(dx: inset, dy: inset * 0.72)
            let arcPath = CGMutablePath()
            arcPath.addArc(
                center: CGPoint(x: arcRect.midX, y: arcRect.midY),
                radius: arcRect.width * 0.46,
                startAngle: .pi * (0.12 + CGFloat(index) * 0.09),
                endAngle: .pi * (0.66 + CGFloat(index) * 0.08),
                clockwise: false
            )
            context.addPath(arcPath)
            context.setStrokeColor(color(1, 1, 1, 0.13 - CGFloat(index) * 0.025))
            context.strokePath()
        }

        context.setBlendMode(.normal)
    }

    if size >= 128 {
        for index in 0..<28 {
            let xSeed = CGFloat((index * 43 + 17) % 89) / 89
            let ySeed = CGFloat((index * 71 + 23) % 97) / 97
            let point = CGPoint(
                x: orbRect.minX + orbRect.width * (0.12 + xSeed * 0.76),
                y: orbRect.minY + orbRect.height * (0.12 + ySeed * 0.76)
            )
            let radius = max(0.5, edge * (0.0007 + xSeed * 0.0006))
            context.setFillColor(color(1, 1, 1, index.isMultiple(of: 4) ? 0.12 : 0.05))
            context.fillEllipse(
                in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
    }

    context.restoreGState()

    context.addPath(orbPath)
    context.setStrokeColor(color(1, 1, 1, size <= 32 ? 0.58 : 0.40))
    context.setLineWidth(max(0.75, edge * 0.0028))
    context.strokePath()

    let specularRect = CGRect(
        x: orbRect.minX + orbRect.width * 0.19,
        y: orbRect.minY + orbRect.height * 0.66,
        width: orbRect.width * 0.25,
        height: orbRect.height * 0.095
    )
    context.saveGState()
    context.translateBy(x: specularRect.midX, y: specularRect.midY)
    context.rotate(by: -.pi * 0.13)
    context.translateBy(x: -specularRect.midX, y: -specularRect.midY)
    context.setFillColor(color(1, 1, 1, size <= 32 ? 0.72 : 0.58))
    context.fillEllipse(in: specularRect)
    context.restoreGState()

    guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 1]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

private func writeIconSet(to directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )

    let filenames: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]

    var cache: [Int: Data] = [:]
    for (filename, size) in filenames {
        let data: Data
        if let cached = cache[size] {
            data = cached
        } else {
            data = try iconImage(size: size)
            cache[size] = data
        }
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift Tools/AppIconGenerator.swift OUTPUT.iconset\n".utf8)
    )
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try writeIconSet(to: outputURL)
print("Rendered \(requiredSizes.count) native icon sizes to \(outputURL.path)")
