// Draws the Cafeine icon (moon and coffee cup) into a 1024×1024 PNG.
// Usage: swiftc -O app/icon.swift -o build/icon && build/icon out.png

import AppKit

let side: CGFloat = 1024
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                    bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: rounded square on the macOS icon grid (824 px of 1024)
let margin: CGFloat = 100
let box = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
let background = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(background)
ctx.setFillColor(color(0x1A2150))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(background)
ctx.clip()
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [color(0x3B2F72), color(0x18204D), color(0x0E1430)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: side / 2, y: box.maxY),
                       end: CGPoint(x: side / 2, y: box.minY), options: [])

// Stars
for (x, y, r) in [(250.0, 800.0, 7.0), (340, 690, 4.5), (430, 840, 5.5), (215, 600, 4),
                  (560, 760, 4), (300, 880, 3.5), (820, 560, 4.5), (880, 470, 3.5)] {
    ctx.setFillColor(color(0xFFF6D8, 0.85))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// Crescent moon: one circle minus another, offset
let moon = CGRect(x: 610, y: 640, width: 230, height: 230)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: color(0xFFE7A3, 0.55))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFE7A3))
ctx.fillEllipse(in: moon)
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: moon.offsetBy(dx: -70, dy: 45))
ctx.endTransparencyLayer()
ctx.restoreGState()
ctx.restoreGState()

// Saucer
ctx.setFillColor(color(0xD9CBB8))
ctx.fillEllipse(in: CGRect(x: 250, y: 200, width: 470, height: 90))
ctx.setFillColor(color(0xF3EADF))
ctx.fillEllipse(in: CGRect(x: 265, y: 215, width: 440, height: 72))

// Handle
ctx.setStrokeColor(color(0xF3EADF))
ctx.setLineWidth(34)
ctx.strokeEllipse(in: CGRect(x: 600, y: 330, width: 140, height: 130))

// Cup: straight rim, rounded bottom
let cup = CGMutablePath()
cup.move(to: CGPoint(x: 290, y: 500))
cup.addLine(to: CGPoint(x: 680, y: 500))
cup.addCurve(to: CGPoint(x: 560, y: 255), control1: CGPoint(x: 680, y: 360),
             control2: CGPoint(x: 640, y: 270))
cup.addLine(to: CGPoint(x: 410, y: 255))
cup.addCurve(to: CGPoint(x: 290, y: 500), control1: CGPoint(x: 330, y: 270),
             control2: CGPoint(x: 290, y: 360))
cup.closeSubpath()
ctx.addPath(cup)
ctx.setFillColor(color(0xFBF6F0))
ctx.fillPath()

// Coffee seen from above
ctx.setFillColor(color(0x6B3E26))
ctx.fillEllipse(in: CGRect(x: 290, y: 478, width: 390, height: 44))

// Steam: three S curves
ctx.setStrokeColor(color(0xFFFFFF, 0.75))
ctx.setLineWidth(22)
ctx.setLineCap(.round)
for x in [395.0, 485, 575] {
    let steam = CGMutablePath()
    steam.move(to: CGPoint(x: x, y: 560))
    steam.addCurve(to: CGPoint(x: x, y: 700), control1: CGPoint(x: x - 45, y: 610),
                   control2: CGPoint(x: x + 45, y: 650))
    ctx.addPath(steam)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: path))
print("Icon: \(path)")
