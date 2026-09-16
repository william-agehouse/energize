// Draws the app icon: a dark rounded tile with the same red bolt the menu bar
// uses, so the two read as one thing. Run through build.sh, not by hand.
import AppKit

_ = NSApplication.shared

let boltRed = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
let tileTop = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.22, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)

func iconPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let canvas = CGFloat(pixels)
    // macOS icons leave a margin round the artwork rather than filling the square.
    let inset = canvas * 0.085
    let tile = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let corner = tile.width * 0.225

    let path = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
    NSGradient(colors: [tileTop, tileBottom])?.draw(in: path, angle: -90)

    // An original bolt, drawn here as a plain polygon.
    //
    // This deliberately does NOT use Apple's `bolt.fill` SF Symbol, even though
    // the menu bar does. Apple's SF Symbols licence permits the symbols inside an
    // app's interface but forbids them "in your app icons, logos, or any other
    // trademark-related use" — so an icon built from one could not be shipped.
    // Using the symbol for the menu bar glyph is fine; using it here was not.
    let bolt = NSBezierPath()
    // Points are fractions of the tile, measured from its bottom-left corner.
    let shape: [(CGFloat, CGFloat)] = [
        (0.60, 1.00), (0.17, 0.47), (0.44, 0.47),
        (0.36, 0.00), (0.83, 0.56), (0.55, 0.56),
    ]
    for (index, point) in shape.enumerated() {
        let spot = NSPoint(x: tile.minX + point.0 * tile.width,
                           y: tile.minY + point.1 * tile.height)
        if index == 0 { bolt.move(to: spot) } else { bolt.line(to: spot) }
    }
    bolt.close()
    boltRed.setFill()
    bolt.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// The filenames iconutil expects.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(points)x\(points)\(suffix).png"
    let data = iconPNG(pixels: points * scale)
    try! data.write(to: URL(fileURLWithPath: outputDir + "/" + name))
}
print("wrote 10 sizes to \(outputDir)")
