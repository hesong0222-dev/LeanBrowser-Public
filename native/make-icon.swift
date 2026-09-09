#!/usr/bin/swift

import AppKit
import Darwin
import Foundation

private let forest = (red: CGFloat(32.0 / 255.0), green: CGFloat(41.0 / 255.0), blue: CGFloat(37.0 / 255.0))
private let mint = (red: CGFloat(197.0 / 255.0), green: CGFloat(233.0 / 255.0), blue: CGFloat(215.0 / 255.0))

private func fail(_ message: String, status: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

private func makeImage(pixelSize: Int) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let bitmapData = bitmap.bitmapData,
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
        data: bitmapData,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: bitmap.bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("unable to create icon bitmap", status: 1)
    }

    let size = CGFloat(pixelSize)
    let safeInset = size * 0.12
    let square = CGRect(x: safeInset, y: safeInset, width: size - (safeInset * 2), height: size - (safeInset * 2))
    let radius = size * 0.18

    context.setFillColor(CGColor(red: forest.red, green: forest.green, blue: forest.blue, alpha: 1))
    context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()

    let markThickness = size * 0.14
    let markLeft = size * 0.35
    let markBottom = size * 0.30
    let markTop = size * 0.70
    let markRight = size * 0.69
    let vertical = CGRect(x: markLeft, y: markBottom, width: markThickness, height: markTop - markBottom)
    let horizontal = CGRect(x: markLeft, y: markBottom, width: markRight - markLeft, height: markThickness)

    context.setFillColor(CGColor(red: mint.red, green: mint.green, blue: mint.blue, alpha: 1))
    context.fill(vertical)
    context.fill(horizontal)
    return bitmap
}

private func writePNG(_ image: NSBitmapImageRep, to url: URL) throws {
    guard let data = image.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LeanBrowserIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to encode PNG"])
    }
    try data.write(to: url, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: make-icon.swift OUTPUT.iconset")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
do {
    try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        let baseName = "icon_\(size)x\(size)"
        try writePNG(makeImage(pixelSize: size), to: outputURL.appendingPathComponent(baseName + ".png"))
        try writePNG(makeImage(pixelSize: size * 2), to: outputURL.appendingPathComponent(baseName + "@2x.png"))
    }
} catch {
    fail("unable to write icon set: \(error.localizedDescription)", status: 1)
}
