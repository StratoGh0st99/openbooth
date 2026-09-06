//
//  MotionDetector.swift
//  OpenBooth
//
//  Bewegung im Liveview erkennen: Bild auf 32x18 Graustufen verkleinern, mittlere Helligkeitsaenderung
//  zum Vorbild messen. Adaptive Schwelle gegen Rauschen, mehrere Treffer in Folge noetig.
//

import UIKit

struct MotionDetector {
    private var previous: [UInt8]?
    private var noise: Double = 0          // gleitender Mittelwert der Aenderung ohne Bewegung
    private var hits = 0
    private(set) var level: Double = 0     // letzte gemessene Aenderung (Graustufen 0-255)

    private static let w = 32, h = 18

    mutating func reset() { previous = nil; noise = 0; hits = 0; level = 0 }

    /// Liefert true, wenn Bewegung erkannt wurde. `threshold` = Mindestaenderung in Graustufen.
    mutating func feed(_ image: UIImage, threshold: Double) -> Bool {
        guard let gray = Self.downsample(image) else { return false }
        defer { previous = gray }
        guard let prev = previous, prev.count == gray.count else { return false }
        var sum = 0
        for i in 0..<gray.count { sum += abs(Int(gray[i]) - Int(prev[i])) }
        level = Double(sum) / Double(gray.count)
        // Rauschen lernen, aber nur aus ruhigen Bildern
        if noise == 0 { noise = level } else if level < noise * 3 { noise = noise * 0.95 + level * 0.05 }
        let limit = max(threshold, noise * 3)
        if level > limit { hits += 1 } else { hits = 0 }
        if hits >= 3 { hits = 0; return true }
        return false
    }

    private static func downsample(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
