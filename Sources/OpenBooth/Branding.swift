//
//  Branding.swift
//  OpenBooth
//
//  Optionales Logo und/oder Schriftzug auf einer Kopie des Fotos. Das Original bleibt immer unberuehrt
//  (App-Galerie, Mediathek); die Kopie geht an die Upload-Ziele und damit an die Gaeste.
//

import UIKit

enum BrandingPosition: String, CaseIterable, Identifiable {
    case bottomRight = "unten rechts", bottomLeft = "unten links", bottomCenter = "unten mittig",
         topRight = "oben rechts", topLeft = "oben links"
    var id: String { rawValue }
}

enum BrandingSize: String, CaseIterable, Identifiable {
    case small = "klein", medium = "mittel", large = "groß"
    var id: String { rawValue }
    /// Hoehe des Blocks relativ zur Bildhoehe
    var fraction: CGFloat { switch self { case .small: 0.06; case .medium: 0.09; case .large: 0.13 } }
}

enum Branding {
    static var logoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("branding-logo.png")
    }
    static func loadLogo() -> UIImage? { UIImage(contentsOfFile: logoURL.path) }
    static func saveLogo(_ data: Data) -> Bool {
        guard let img = UIImage(data: data) else { return false }
        // auf 1200 px begrenzen, PNG mit Transparenz behalten
        let scale = min(1, 1200 / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = out.pngData() else { return false }
        return (try? png.write(to: logoURL, options: .atomic)) != nil
    }
    static func removeLogo() { try? FileManager.default.removeItem(at: logoURL) }

    /// Kopie mit Branding rendern. Lange Kante auf `maxEdge` begrenzt (Gaeste-Kopie, spart Upload und Speicher).
    nonisolated static func render(jpeg: Data, text: String, logo: UIImage?, position: BrandingPosition, size: BrandingSize,
                                   maxEdge: CGFloat = 4000, quality: CGFloat = 0.9) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxEdge)] as CFDictionary) else { return nil }
        let base = UIImage(cgImage: cg)
        let W = base.size.width, H = base.size.height
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: base.size, format: fmt).image { ctx in
            base.draw(at: .zero)
            let blockH = H * size.fraction
            let margin = H * 0.03
            let gap = blockH * 0.25
            // Logo (Hoehe = Block) und Text (Hoehe ~60 % des Blocks) nebeneinander
            var logoW: CGFloat = 0
            if let logo { logoW = blockH * logo.size.width / max(1, logo.size.height) }
            let font = UIFont.systemFont(ofSize: blockH * 0.55, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: attrs)
            let totalW = logoW + (logoW > 0 && !text.isEmpty ? gap : 0) + textSize.width
            guard totalW > 0 else { return }
            var x: CGFloat, y: CGFloat
            switch position {
            case .bottomRight: x = W - margin - totalW; y = H - margin - blockH
            case .bottomLeft: x = margin; y = H - margin - blockH
            case .bottomCenter: x = (W - totalW) / 2; y = H - margin - blockH
            case .topRight: x = W - margin - totalW; y = margin
            case .topLeft: x = margin; y = margin
            }
            // weicher Schatten fuer Lesbarkeit auf hellem Grund
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: blockH * 0.04), blur: blockH * 0.18, color: UIColor.black.withAlphaComponent(0.7).cgColor)
            if let logo {
                logo.draw(in: CGRect(x: x, y: y, width: logoW, height: blockH))
                x += logoW + gap
            }
            if !text.isEmpty {
                (text as NSString).draw(at: CGPoint(x: x, y: y + (blockH - textSize.height) / 2), withAttributes: attrs)
            }
        }
        return img.jpegData(compressionQuality: quality)
    }
}
