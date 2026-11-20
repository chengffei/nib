// Draws Nib's app icon: a dark nib on a light background, with a blue ink line under the nib.
// Usage: swift design/make_icon.swift <output.png> (1024 px)
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Flip to a top-left origin; the coordinates below are all written per the design mock-up
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, alpha: alpha)
}
func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
}

// Base plate: standard macOS placeholder of 824, corner radius about 22.4%
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(platePath)
ctx.setFillColor(color(0xffffff))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
ctx.drawLinearGradient(gradient(0xffffff, 0xe9e9ee), start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
ctx.restoreGState()

// Ink line: drawn from the left edge up to the nib
let tip = CGPoint(x: 512, y: 742)
ctx.setStrokeColor(color(0x0071e3))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 268, y: tip.y + 22))
ctx.addLine(to: CGPoint(x: tip.x - 4, y: tip.y + 22))
ctx.strokePath()

// Nib
let nib = CGMutablePath()
nib.move(to: CGPoint(x: 436, y: 236))
nib.addLine(to: CGPoint(x: 588, y: 236))
nib.addQuadCurve(to: CGPoint(x: 612, y: 256), control: CGPoint(x: 606, y: 236))
nib.addCurve(to: CGPoint(x: 676, y: 468), control1: CGPoint(x: 630, y: 330), control2: CGPoint(x: 676, y: 392))
nib.addCurve(to: tip, control1: CGPoint(x: 676, y: 560), control2: CGPoint(x: 556, y: 668))
nib.addCurve(to: CGPoint(x: 348, y: 468), control1: CGPoint(x: 468, y: 668), control2: CGPoint(x: 348, y: 560))
nib.addCurve(to: CGPoint(x: 412, y: 256), control1: CGPoint(x: 348, y: 392), control2: CGPoint(x: 394, y: 330))
nib.addQuadCurve(to: CGPoint(x: 436, y: 236), control: CGPoint(x: 418, y: 236))
nib.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.22))
ctx.addPath(nib)
ctx.setFillColor(color(0x1d1d1f))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(nib)
ctx.clip()
ctx.drawLinearGradient(gradient(0x48484d, 0x1a1a1c), start: CGPoint(x: 0, y: 236), end: CGPoint(x: 0, y: 742), options: [])
// Brighten the left half a little, to make the facets on either side of the centre seam
ctx.setFillColor(color(0xffffff, 0.07))
ctx.fill(CGRect(x: 300, y: 200, width: 212, height: 600))
ctx.restoreGState()

// Breather hole and centre seam, revealing the base colour
ctx.setFillColor(color(0xf4f4f7))
ctx.fillEllipse(in: CGRect(x: 512 - 30, y: 440, width: 60, height: 60))
ctx.setStrokeColor(color(0xf4f4f7))
ctx.setLineWidth(11)
ctx.setLineCap(.butt)
ctx.move(to: CGPoint(x: 512, y: 494))
ctx.addLine(to: CGPoint(x: 512, y: 716))
ctx.strokePath()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
