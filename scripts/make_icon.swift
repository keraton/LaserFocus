// Draws the LaserFocus app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make_icon.swift   (run from the project root)
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024

    // macOS icon grid: 824pt rounded square centered in 1024.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: color(0x2A2C31), ending: color(0x141518))!.draw(in: shape, angle: -90)

    // Lines of "text": faded above and below, one bright focused line.
    let left = 210 * s
    let lines: [(y: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (720, 520, 0.12), (640, 600, 0.18), (480, 604, 1.0), (320, 560, 0.18), (240, 430, 0.12),
    ]
    for line in lines {
        let rect = NSRect(x: left, y: line.y * s, width: line.width * s, height: 44 * s)
        let bar = NSBezierPath(roundedRect: rect, xRadius: 22 * s, yRadius: 22 * s)
        color(0xF2F2F2, line.alpha).setFill()
        bar.fill()
    }

    // Laser beam glowing under the focused line.
    let beam = NSRect(x: 150 * s, y: 452 * s, width: 724 * s, height: 10 * s)
    for step in stride(from: 40, through: 2, by: -2) {
        let glow = beam.insetBy(dx: 0, dy: -CGFloat(step) * s)
        color(0xFF3B47, 0.045).setFill()
        NSBezierPath(roundedRect: glow, xRadius: glow.height / 2, yRadius: glow.height / 2).fill()
    }
    color(0xFF5A63).setFill()
    NSBezierPath(roundedRect: beam, xRadius: 5 * s, yRadius: 5 * s).fill()

    // Caret at the end of the focused line.
    color(0x1A9FFF).setFill()
    NSBezierPath(roundedRect: NSRect(x: 836 * s, y: 466 * s, width: 16 * s, height: 72 * s),
                 xRadius: 8 * s, yRadius: 8 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try! drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
