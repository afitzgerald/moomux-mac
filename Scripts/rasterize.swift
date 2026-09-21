// SVG -> PNG. `NSImage` reads SVG and `UIImage` does not, so the cow mark the
// Mac app loads straight from `Resources/icons` has to be rasterized for the
// iOS bundle. At build time rather than checked in, so the two cannot drift.
//
//   swift Scripts/rasterize.swift <in.svg> <out.png> <pixels>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let side = Int(args[3]),
      let image = NSImage(contentsOfFile: args[1])
else {
    FileHandle.standardError.write(Data("usage: rasterize.swift <in.svg> <out.png> <px>\n".utf8))
    exit(1)
}
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { exit(1) }
rep.size = NSSize(width: side, height: side)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
           from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
