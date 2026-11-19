import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 3, let size = Int(arguments[2]) else {
    print("usage: make-icon.swift <out.png> <size> [--full-bleed]")
    exit(1)
}
let output = arguments[1]
let fullBleed = arguments.contains("--full-bleed")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let scale = CGFloat(size) / 1024
ctx.scaleBy(x: scale, y: scale)

let tile = fullBleed ? CGRect(x: 24, y: 24, width: 976, height: 976) : CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = fullBleed ? 210 : 185
let tilePath = roundedRect(tile, tileRadius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: fullBleed ? 0 : 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x151C45))
ctx.fillPath()
ctx.restoreGState()
fill(ctx, tilePath, gradient([color(0x3A4BC4), color(0x161B47)]), from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))

let screenColors = gradient([color(0x6FF2D8), color(0x3C8DFF)])

let s = tile.width / 824
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: tile.minX + (x - 100) * s, y: tile.minY + (y - 100) * s, width: w * s, height: h * s)
}

let far = r(400, 500, 420, 270)
let farPath = roundedRect(far, 34 * s)
fill(ctx, farPath, screenColors, from: CGPoint(x: far.minX, y: far.maxY), to: CGPoint(x: far.maxX, y: far.minY))
ctx.addPath(farPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.85))
ctx.setLineWidth(14 * s)
ctx.strokePath()
ctx.setFillColor(color(0xFFFFFF, 0.85))
ctx.fill(r(590, 470, 40, 34))
ctx.addPath(roundedRect(r(540, 456, 140, 18), 9 * s))
ctx.fillPath()

let lid = r(190, 290, 440, 290)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s, color: color(0x000000, 0.45))
ctx.addPath(roundedRect(lid, 34 * s))
ctx.setFillColor(color(0xF2F5FC))
ctx.fillPath()
ctx.restoreGState()

let display = lid.insetBy(dx: 22 * s, dy: 22 * s)
ctx.addPath(roundedRect(display, 16 * s))
ctx.setFillColor(color(0x10163A))
ctx.fillPath()

ctx.addPath(roundedRect(r(150, 250, 520, 40), 20 * s))
ctx.setFillColor(color(0xC7D0EA))
ctx.fillPath()

let pip = CGRect(x: display.maxX - 214 * s, y: display.minY + 26 * s, width: 188 * s, height: 121 * s)
let pipPath = roundedRect(pip, 14 * s)
fill(ctx, pipPath, screenColors, from: CGPoint(x: pip.minX, y: pip.maxY), to: CGPoint(x: pip.maxX, y: pip.minY))
ctx.addPath(pipPath)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(8 * s)
ctx.strokePath()

ctx.setStrokeColor(color(0xFFFFFF, 0.35))
ctx.setLineWidth(12 * s)
ctx.setLineCap(.round)
for (i, width) in [CGFloat(200), 140, 100].enumerated() {
    let y = display.maxY - CGFloat(52 + i * 40) * s
    ctx.move(to: CGPoint(x: display.minX + 34 * s, y: y))
    ctx.addLine(to: CGPoint(x: display.minX + (34 + width) * s, y: y))
}
ctx.strokePath()

let dot = CGPoint(x: pip.midX + 18 * s, y: pip.midY - 6 * s)
ctx.setFillColor(color(0xFF5A36))
ctx.addEllipse(in: CGRect(x: dot.x - 22 * s, y: dot.y - 22 * s, width: 44 * s, height: 44 * s))
ctx.fillPath()
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(7 * s)
ctx.addEllipse(in: CGRect(x: dot.x - 22 * s, y: dot.y - 22 * s, width: 44 * s, height: 44 * s))
ctx.strokePath()

let farDot = CGPoint(x: far.minX + far.width * (dot.x - pip.minX) / pip.width, y: far.minY + far.height * (dot.y - pip.minY) / pip.height)
ctx.setFillColor(color(0xFF5A36))
ctx.addEllipse(in: CGRect(x: farDot.x - 30 * s, y: farDot.y - 30 * s, width: 60 * s, height: 60 * s))
ctx.fillPath()
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(9 * s)
ctx.addEllipse(in: CGRect(x: farDot.x - 30 * s, y: farDot.y - 30 * s, width: 60 * s, height: 60 * s))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
