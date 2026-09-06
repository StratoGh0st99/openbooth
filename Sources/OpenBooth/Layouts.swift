//
//  Layouts.swift
//  OpenBooth
//
//  Layouts: aus einem oder mehreren Fotos entsteht ein fertiges Bild (Einzelbild mit Branding, Collage, Streifen).
//  Jedes Ziel (Rueckschau, Immich, WebDAV, spaeter Drucker) waehlt als Quelle das Original oder ein Layout.
//  Das Original bleibt immer unberuehrt.
//

import UIKit

enum LayoutKind: String, Codable, CaseIterable, Identifiable {
    case single, collage2x1, collage2x2, strip3, strip4
    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: "Einzelbild"; case .collage2x1: "Collage 2 nebeneinander"; case .collage2x2: "Collage 2×2"
        case .strip3: "Streifen, 3 Bilder"; case .strip4: "Streifen, 4 Bilder"
        }
    }
    var slots: Int { switch self { case .single: 1; case .collage2x1: 2; case .collage2x2: 4; case .strip3: 3; case .strip4: 4 } }
    var columns: Int { switch self { case .single: 1; case .collage2x1: 2; case .collage2x2: 2; case .strip3, .strip4: 1 } }
    var rows: Int { slots / columns }
    var isStrip: Bool { self == .strip3 || self == .strip4 }
}

enum LayoutFormat: String, Codable, CaseIterable, Identifiable {
    case r3x2, r4x3, square, strip5x15
    var id: String { rawValue }
    var label: String {
        switch self { case .r3x2: "3:2 (Kamera, 10×15)"; case .r4x3: "4:3"; case .square: "Quadrat"; case .strip5x15: "Streifen 5×15" }
    }
    /// Breite/Hoehe
    var aspect: CGFloat { switch self { case .r3x2: 1.5; case .r4x3: 4.0 / 3.0; case .square: 1; case .strip5x15: 1.0 / 3.0 } }
}

enum LayoutBackground: String, Codable, CaseIterable, Identifiable {
    case white, black, gray
    var id: String { rawValue }
    var label: String { switch self { case .white: "Weiß"; case .black: "Schwarz"; case .gray: "Grau" } }
    var color: UIColor { switch self { case .white: .white; case .black: .black; case .gray: UIColor(white: 0.16, alpha: 1) } }
    var isDark: Bool { self != .white }
}

struct PhotoLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: LayoutKind
    var format: LayoutFormat
    var background: LayoutBackground = .white
    var margin: Int = 2               // Rand in Prozent der kurzen Kante (0 = randlos)
    var branding: Bool = true
    var hasBackgroundImage: Bool = false

    static let originalID = "original"
    static func defaultSingle() -> PhotoLayout { PhotoLayout(name: "Einzelbild", kind: .single, format: .r3x2, margin: 0, branding: true) }
    static func defaultStrip() -> PhotoLayout { PhotoLayout(name: "Fotostreifen", kind: .strip3, format: .strip5x15, margin: 4, branding: true) }
    static func defaultCollage() -> PhotoLayout { PhotoLayout(name: "Collage", kind: .collage2x2, format: .r3x2, margin: 3, branding: true) }

    /// Hintergrundbild (PNG/JPEG) pro Layout, liegt in Documents/layout-bg-<id>.png
    var backgroundImageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout-bg-\(id.uuidString).png")
    }
}

/// Globales Branding: gilt fuer alle Layouts, die es eingeschaltet haben.
struct BrandingStyle {
    var text: String
    var logo: UIImage?
    var position: BrandingPosition
    var size: BrandingSize
    var dark: Bool          // dunkle Schrift (fuer helle Hintergruende)
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || logo != nil }
}

enum LayoutRenderer {
    /// Lange Kante der Ausgabe
    static let maxEdge: CGFloat = 4000

    /// Fotos (JPEG-Daten, in Aufnahmereihenfolge) in das Layout setzen. Fehlende Slots bleiben leer (Hintergrund).
    nonisolated static func render(photos: [Data], layout: PhotoLayout, branding: BrandingStyle, maxEdge: CGFloat = maxEdge,
                                   quality: CGFloat = 0.9) -> Data? {
        let aspect = layout.format.aspect
        let W: CGFloat = aspect >= 1 ? maxEdge : maxEdge * aspect
        let H: CGFloat = aspect >= 1 ? maxEdge / aspect : maxEdge
        let canvas = CGSize(width: W.rounded(), height: H.rounded())
        let short = min(W, H)
        let margin = short * CGFloat(layout.margin) / 100

        // Fotos vorab passend klein dekodieren (ImageIO-Subsampling), Zielgroesse je Kachel
        let cols = CGFloat(layout.kind.columns), rows = CGFloat(layout.kind.rows)
        let useBranding = layout.branding && branding.hasContent
        // Bei Collage/Streifen bekommt das Branding eine eigene Leiste unten, beim Einzelbild liegt es auf dem Foto
        let bandH: CGFloat = (useBranding && layout.kind != .single) ? short * branding.size.fraction * 1.6 : 0
        let gridW = W - margin * (cols + 1)
        let gridH = H - margin * (rows + 1) - bandH
        let tileW = gridW / cols, tileH = gridH / rows
        let tilePx = Int(max(tileW, tileH) * 1.05)
        let images: [UIImage] = photos.compactMap { d in
            guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(tilePx, 800)] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        let bgImage = layout.hasBackgroundImage ? UIImage(contentsOfFile: layout.backgroundImageURL.path) : nil

        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            let g = ctx.cgContext
            layout.background.color.setFill()
            g.fill(CGRect(origin: .zero, size: canvas))
            if let bgImage { drawFill(bgImage, in: CGRect(origin: .zero, size: canvas)) }

            for i in 0..<layout.kind.slots {
                let c = CGFloat(i % layout.kind.columns), r = CGFloat(i / layout.kind.columns)
                let rect = CGRect(x: margin + c * (tileW + margin), y: margin + r * (tileH + margin), width: tileW, height: tileH)
                if i < images.count {
                    g.saveGState()
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: layout.margin == 0 ? 0 : short * 0.008)
                    path.addClip()
                    drawFill(images[i], in: rect)
                    g.restoreGState()
                } else if bgImage == nil {
                    // leerer Slot: dezent markiert
                    UIColor(white: layout.background.isDark ? 0.3 : 0.9, alpha: 1).setFill()
                    g.fill(rect)
                }
            }

            guard useBranding else { return }
            let dark = layout.kind == .single ? false : (branding.dark || !layout.background.isDark)
            let color: UIColor = dark ? UIColor(white: 0.1, alpha: 1) : .white
            if layout.kind == .single {
                // wie bisher: auf dem Foto an der gewaehlten Position, mit Schatten
                drawBranding(branding, color: .white, shadow: true, in: CGRect(origin: .zero, size: canvas),
                             blockH: H * branding.size.fraction, position: branding.position)
            } else {
                let band = CGRect(x: margin, y: H - bandH - margin * 0.5, width: W - 2 * margin, height: bandH)
                drawBranding(branding, color: color, shadow: false, in: band, blockH: bandH * 0.55, position: .bottomCenter)
            }
        }
        return out.jpegData(compressionQuality: quality)
    }

    /// Bild formatfuellend (aspect fill) in ein Rechteck zeichnen, mittig beschnitten.
    private static func drawFill(_ img: UIImage, in rect: CGRect) {
        let s = max(rect.width / img.size.width, rect.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// Logo und Text nebeneinander, Block der Hoehe blockH, an einer Position innerhalb von area.
    private static func drawBranding(_ b: BrandingStyle, color: UIColor, shadow: Bool, in area: CGRect, blockH: CGFloat, position: BrandingPosition) {
        let text = b.text.trimmingCharacters(in: .whitespaces)
        let gap = blockH * 0.3
        let pad = min(area.width, area.height) * 0.06
        var logoW: CGFloat = 0
        if let logo = b.logo { logoW = blockH * logo.size.width / max(1, logo.size.height) }
        let font = UIFont.systemFont(ofSize: blockH * 0.6, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: attrs)
        let totalW = logoW + (logoW > 0 && !text.isEmpty ? gap : 0) + textSize.width
        guard totalW > 0 else { return }
        var x: CGFloat, y: CGFloat
        switch position {
        case .bottomRight: x = area.maxX - pad - totalW; y = area.maxY - pad - blockH
        case .bottomLeft: x = area.minX + pad; y = area.maxY - pad - blockH
        case .bottomCenter: x = area.midX - totalW / 2; y = area.midY - blockH / 2
        case .topRight: x = area.maxX - pad - totalW; y = area.minY + pad
        case .topLeft: x = area.minX + pad; y = area.minY + pad
        }
        if position == .bottomCenter, area.height > blockH * 3 { y = area.maxY - pad - blockH }   // Einzelbild unten mittig
        let g = UIGraphicsGetCurrentContext()
        g?.saveGState()
        if shadow { g?.setShadow(offset: CGSize(width: 0, height: blockH * 0.04), blur: blockH * 0.2, color: UIColor.black.withAlphaComponent(0.7).cgColor) }
        if let logo = b.logo {
            logo.draw(in: CGRect(x: x, y: y, width: logoW, height: blockH))
            x += logoW + gap
        }
        if !text.isEmpty {
            (text as NSString).draw(at: CGPoint(x: x, y: y + (blockH - textSize.height) / 2), withAttributes: attrs)
        }
        g?.restoreGState()
    }
}
