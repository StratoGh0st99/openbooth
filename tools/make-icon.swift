// Zeichnet das OpenBooth-Icon: offener Blendenring mit rotem Ausloeser. Aufruf: swift tools/make-icon.swift <ausgabe.png> [groesse]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let S = CGFloat(size)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Hintergrund: sehr dunkles Grau mit leichtem Verlauf nach unten
let bg = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1), CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

let c = CGPoint(x: S / 2, y: S / 2)
let r = S * 0.30          // Ringradius
let w = S * 0.085         // Ringstaerke
let gapCenter = CGFloat.pi / 4          // Luecke oben rechts (45 Grad)
let gapHalf = CGFloat.pi * 0.16         // halbe Lueckenbreite

// Ring (weiss, offen), runde Enden
ctx.setStrokeColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1))
ctx.setLineWidth(w)
ctx.setLineCap(.round)
ctx.addArc(center: c, radius: r, startAngle: gapCenter + gapHalf, endAngle: gapCenter - gapHalf + 2 * .pi, clockwise: false)
ctx.strokePath()

// Roter Ausloeser in der Luecke, leicht nach aussen versetzt
let dotR = S * 0.072
let dotC = CGPoint(x: c.x + cos(gapCenter) * (r + w * 0.05), y: c.y + sin(gapCenter) * (r + w * 0.05))
ctx.setFillColor(CGColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1))
ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))

// Innere Linse: kleiner dunkler Kreis mit feinem Glanz, gibt Tiefe
let lensR = r - w * 0.9
ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
ctx.fillEllipse(in: CGRect(x: c.x - lensR, y: c.y - lensR, width: lensR * 2, height: lensR * 2))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
ctx.setLineWidth(S * 0.012)
ctx.addArc(center: c, radius: lensR * 0.72, startAngle: .pi * 0.55, endAngle: .pi * 1.05, clockwise: false)
ctx.strokePath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("geschrieben: \(out) \(size)x\(size)")
