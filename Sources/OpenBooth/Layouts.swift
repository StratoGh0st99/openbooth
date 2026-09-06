//
//  Layouts.swift
//  OpenBooth
//
//  Drei feste Layouts (1 Bild 10x15, 4 Bilder 10x15, 4 Bilder Streifen 5x15) und drei Rahmen (Hochzeit, Geburtstag, Feier).
//  Der Schriftzug und ein optionales Logo stehen auf jedem Layout. Das Original bleibt immer unberuehrt.
//

import UIKit

enum FixedLayout: String, CaseIterable, Identifiable {
    case single, grid4, strip4
    var id: String { rawValue }
    static let originalID = "original"
    var label: String {
        switch self { case .single: "1 Bild, 10×15"; case .grid4: "4 Bilder, 10×15"; case .strip4: "4 Bilder, Streifen 5×15" }
    }
    var slots: Int { self == .single ? 1 : 4 }
    var columns: Int { switch self { case .single: 1; case .grid4: 2; case .strip4: 1 } }
    var rows: Int { slots / columns }
    /// Breite/Hoehe der Ausgabe
    var aspect: CGFloat { self == .strip4 ? 1.0 / 3.0 : 1.5 }
    static func from(_ source: String) -> FixedLayout? { FixedLayout(rawValue: source) }
}

enum FrameStyle: String, CaseIterable, Identifiable {
    case wedding, birthday, party
    var id: String { rawValue }
    var label: String { switch self { case .wedding: "Hochzeit"; case .birthday: "Geburtstag"; case .party: "Feier" } }
    var description: String {
        switch self {
        case .wedding: "Elfenbein, feine goldene Linien, Schreibschrift"
        case .birthday: "Weiß mit buntem Konfetti, runde kräftige Schrift"
        case .party: "Anthrazit mit heller Kontur, klare moderne Schrift"
        }
    }
    var background: UIColor {
        switch self {
        case .wedding: UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1)
        case .birthday: .white
        case .party: UIColor(white: 0.13, alpha: 1)
        }
    }
    var accent: UIColor {
        switch self {
        case .wedding: UIColor(red: 0.78, green: 0.63, blue: 0.32, alpha: 1)   // Gold
        case .birthday: UIColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1)
        case .party: UIColor(white: 0.85, alpha: 1)
        }
    }
    var textColor: UIColor {
        switch self { case .wedding: UIColor(red: 0.42, green: 0.32, blue: 0.14, alpha: 1); case .birthday: UIColor(white: 0.15, alpha: 1); case .party: .white }
    }
    func font(size: CGFloat) -> UIFont {
        switch self {
        case .wedding:
            if let f = UIFont(name: "SnellRoundhand-Bold", size: size * 1.25) { return f }
            let d = UIFont.systemFont(ofSize: size, weight: .medium).fontDescriptor.withDesign(.serif)!.withSymbolicTraits(.traitItalic)!
            return UIFont(descriptor: d, size: size)
        case .birthday:
            let d = UIFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor.withDesign(.rounded)!
            return UIFont(descriptor: d, size: size)
        case .party:
            return UIFont.systemFont(ofSize: size, weight: .semibold)
        }
    }
}

enum LayoutRenderer {
    static let maxEdge: CGFloat = 4000

    /// Fotos (Aufnahmereihenfolge) ins Layout setzen, Rahmen zeichnen, Text und Logo in die Leiste unten.
    nonisolated static func render(photos: [Data], layout: FixedLayout, frame: FrameStyle, text: String, logo: UIImage?,
                                   maxEdge: CGFloat = maxEdge, quality: CGFloat = 0.9) -> Data? {
        let a = layout.aspect
        let W = (a >= 1 ? maxEdge : maxEdge * a).rounded(), H = (a >= 1 ? maxEdge / a : maxEdge).rounded()
        let canvas = CGSize(width: W, height: H)
        let short = min(W, H)
        let margin = short * 0.04
        let bandH = short * 0.14
        let cols = CGFloat(layout.columns), rows = CGFloat(layout.rows)
        let tileW = (W - margin * (cols + 1)) / cols
        let tileH = (H - margin * (rows + 1) - bandH) / rows
        let tilePx = Int(max(tileW, tileH) * 1.05)
        let images: [UIImage] = photos.compactMap { d in
            guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(tilePx, 800)] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            let g = ctx.cgContext
            frame.background.setFill(); g.fill(CGRect(origin: .zero, size: canvas))
            drawDecoration(frame, canvas: canvas, margin: margin)

            for i in 0..<layout.slots {
                let c = CGFloat(i % layout.columns), r = CGFloat(i / layout.columns)
                let rect = CGRect(x: margin + c * (tileW + margin), y: margin + r * (tileH + margin), width: tileW, height: tileH)
                // weisser Passepartout-Rand wie ein Abzug
                let border = short * 0.006
                UIColor.white.setFill(); g.fill(rect.insetBy(dx: -border, dy: -border))
                if i < images.count {
                    g.saveGState(); UIBezierPath(rect: rect).addClip(); drawFill(images[i], in: rect); g.restoreGState()
                } else {
                    UIColor(white: 0.88, alpha: 1).setFill(); g.fill(rect)
                }
            }

            // Textleiste unten: Logo links vom Text, alles mittig
            let band = CGRect(x: margin, y: H - margin * 0.6 - bandH, width: W - 2 * margin, height: bandH)
            let blockH = bandH * 0.62
            let t = text.trimmingCharacters(in: .whitespaces)
            let font = frame.font(size: blockH * 0.7)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: frame.textColor]
            let ts = t.isEmpty ? .zero : (t as NSString).size(withAttributes: attrs)
            var logoW: CGFloat = 0
            if let logo { logoW = blockH * logo.size.width / max(1, logo.size.height) }
            let gap = blockH * 0.35
            let total = logoW + (logoW > 0 && !t.isEmpty ? gap : 0) + ts.width
            var x = band.midX - total / 2
            let y = band.midY - blockH / 2
            if let logo { logo.draw(in: CGRect(x: x, y: y, width: logoW, height: blockH)); x += logoW + gap }
            if !t.isEmpty { (t as NSString).draw(at: CGPoint(x: x, y: band.midY - ts.height / 2), withAttributes: attrs) }
        }
        return out.jpegData(compressionQuality: quality)
    }

    private static func drawFill(_ img: UIImage, in rect: CGRect) {
        let s = max(rect.width / img.size.width, rect.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// Rahmen-Dekor je Stil, deterministisch (Konfetti ueber festen Seed).
    private static func drawDecoration(_ frame: FrameStyle, canvas: CGSize, margin: CGFloat) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        let short = min(canvas.width, canvas.height)
        switch frame {
        case .wedding:
            // doppelte Goldlinie innen am Rand
            frame.accent.setStroke()
            let outer = CGRect(origin: .zero, size: canvas).insetBy(dx: margin * 0.45, dy: margin * 0.45)
            g.setLineWidth(short * 0.004); g.stroke(outer)
            g.setLineWidth(short * 0.0015); g.stroke(outer.insetBy(dx: short * 0.012, dy: short * 0.012))
        case .party:
            frame.accent.withAlphaComponent(0.7).setStroke()
            g.setLineWidth(short * 0.003)
            g.stroke(CGRect(origin: .zero, size: canvas).insetBy(dx: margin * 0.5, dy: margin * 0.5))
        case .birthday:
            // Konfetti: kleine Kreise und Striche in Kraeftigfarben, nur in den Randzonen
            let colors: [UIColor] = [UIColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1), UIColor(red: 0.99, green: 0.76, blue: 0.2, alpha: 1),
                                     UIColor(red: 0.25, green: 0.65, blue: 0.95, alpha: 1), UIColor(red: 0.35, green: 0.78, blue: 0.5, alpha: 1),
                                     UIColor(red: 0.6, green: 0.4, blue: 0.9, alpha: 1)]
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10000) / 10000 }
            let count = Int(canvas.width * canvas.height / (short * short) * 140)
            for _ in 0..<count {
                let x = rnd() * canvas.width, y = rnd() * canvas.height
                // nur Randzone (aussen 0.9 * margin), sonst ueberspringen
                let inX = x < margin * 0.9 || x > canvas.width - margin * 0.9
                let inY = y < margin * 0.9 || y > canvas.height - margin * 0.9
                guard inX || inY else { continue }
                colors[Int(rnd() * CGFloat(colors.count)) % colors.count].setFill()
                let s = short * (0.006 + rnd() * 0.008)
                if rnd() < 0.5 { g.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s)) }
                else {
                    g.saveGState(); g.translateBy(x: x, y: y); g.rotate(by: rnd() * .pi)
                    g.fill(CGRect(x: -s, y: -s * 0.25, width: s * 2, height: s * 0.5)); g.restoreGState()
                }
            }
        }
    }
}
