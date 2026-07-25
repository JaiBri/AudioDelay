#!/usr/bin/env swift

// Renders AppIcon.icns from code so the icon lives in version control as a recipe
// rather than a binary blob. Run ./make-icon.swift; build-app.sh does this for you.

import AppKit
import Foundation

// Anchor on the script's own location, not the caller's working directory, so
// running it from elsewhere cannot write into (or delete from) another project.
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")
let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// A speaker cone emitting a wave, with a dimmer echo of that wave trailing behind it —
// the delay, drawn literally.
func drawIcon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = side / 1024  // All geometry below is authored against a 1024pt canvas.
    let rect = CGRect(x: 0, y: 0, width: side, height: side)

    // macOS icons are squircles inset from the full canvas.
    let inset = 100 * s
    let body = rect.insetBy(dx: inset, dy: inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.76, blue: 0.86, alpha: 1)
    ])!
    gradient.draw(in: body, angle: -60)

    // A soft highlight across the top keeps the face from reading as flat plastic.
    NSColor(calibratedWhite: 1, alpha: 0.16).setFill()
    NSBezierPath(ovalIn: CGRect(x: body.minX - body.width * 0.25,
                                y: body.midY + body.height * 0.14,
                                width: body.width * 1.5,
                                height: body.height * 0.95)).fill()
    ctx.restoreGState()

    // The same burst of sound twice: once live, then again later and quieter. Two
    // clearly separated groups read as an echo; overlapping copies just read as noise.
    let heights: [CGFloat] = [0.26, 0.58, 0.92, 0.70, 0.44, 0.20]
    let barWidth = 40 * s
    let spacing = 58 * s
    // Nudged up so the duration tick below balances the composition.
    let midY = body.midY + 46 * s
    let maxBar = 280 * s

    func drawBurst(originX: CGFloat, alpha: CGFloat, scale: CGFloat) {
        NSColor(calibratedWhite: 1, alpha: alpha).setFill()
        for (index, height) in heights.enumerated() {
            let barHeight = max(barWidth, height * maxBar * scale)
            let bar = CGRect(x: originX + CGFloat(index) * spacing - barWidth / 2,
                             y: midY - barHeight / 2,
                             width: barWidth,
                             height: barHeight)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    let burstSpan = CGFloat(heights.count - 1) * spacing
    let gap = 112 * s
    let totalSpan = burstSpan * 2 + gap
    let startX = body.midX - totalSpan / 2

    drawBurst(originX: startX, alpha: 1.0, scale: 1.0)
    drawBurst(originX: startX + burstSpan + gap, alpha: 0.38, scale: 0.78)

    // A tick joining the two bursts, marking the elapsed time between them.
    let tickY = midY - 232 * s
    let tick = NSBezierPath()
    tick.move(to: CGPoint(x: startX, y: tickY))
    tick.line(to: CGPoint(x: startX + burstSpan + gap, y: tickY))
    tick.lineWidth = 16 * s
    tick.lineCapStyle = .round
    NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
    tick.stroke()

    for endpoint in [startX, startX + burstSpan + gap] {
        let cap = NSBezierPath()
        cap.move(to: CGPoint(x: endpoint, y: tickY - 26 * s))
        cap.line(to: CGPoint(x: endpoint, y: tickY + 26 * s))
        cap.lineWidth = 16 * s
        cap.lineCapStyle = .round
        NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
        cap.stroke()
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not encode \(url.lastPathComponent)"])
    }
    try png.write(to: url)
}

// The set of sizes iconutil expects.
let variants: [(name: String, side: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let image = drawIcon(side: variant.side)
    try writePNG(image, to: iconset.appendingPathComponent("\(variant.name).png"))
}

// A standalone 512pt PNG for the README.
try writePNG(drawIcon(side: 512), to: outputDirectory.appendingPathComponent("icon.png"))

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("✅ Wrote Resources/AppIcon.icns and Resources/icon.png")
