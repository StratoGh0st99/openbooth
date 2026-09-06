//
//  Branding.swift
//  OpenBooth
//
//  Globales Branding (Logo, Schriftzug, Position, Groesse), verwendet vom LayoutRenderer. Das Original bleibt unberuehrt.
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
}
