//
//  MotionDetector.swift
//  OpenBooth
//
//  Bewegung im Liveview erkennen: Bild auf 32x18 Graustufen verkleinern, in 4x4 Felder teilen und je Feld die
//  mittlere Helligkeitsaenderung zum Vorbild messen. Globale Aenderungen (Licht an/aus, fremder Blitz) werden als
//  Mittel ueber alle Felder abgezogen; es zaehlt das staerkste Feld. So faellt eine Person am Rand oder weit hinten
//  auf, ein Helligkeitssprung im ganzen Bild nicht. Adaptive Schwelle gegen Rauschen, drei Treffer in Folge noetig.
//

import UIKit

struct MotionDetector {
    private var previous: [UInt8]?
    private var noise: Double = 0          // gleitender Mittelwert der Aenderung ohne Bewegung
    private var hits = 0
    private(set) var level: Double = 0     // staerkstes Feld nach Abzug der globalen Aenderung (Graustufen 0-255)
    private(set) var globalLevel: Double = 0   // Aenderung im ganzen Bild (Lichtwechsel)
    var noiseLevel: Double { noise }

    private static let w = 32, h = 18
    private static let cells = 4            // 4x4 Felder aus 8x4 (bzw. 8x5) Pixeln

    mutating func reset() { previous = nil; noise = 0; hits = 0; level = 0 }

    /// Liefert true, wenn Bewegung erkannt wurde. `threshold` = Mindestaenderung in Graustufen.
    mutating func feed(_ image: UIImage, threshold: Double) -> Bool {
        guard let gray = Self.downsample(image) else { return false }
        defer { previous = gray }
        guard let prev = previous, prev.count == gray.count else { return false }
        // Aenderung je Feld
        let cw = Self.w / Self.cells, ch = Self.h / Self.cells
        var cell = [Double](repeating: 0, count: Self.cells * Self.cells)
        var count = [Int](repeating: 0, count: Self.cells * Self.cells)
        for y in 0..<Self.h {
            let cy = min(Self.cells - 1, y / ch)
            for x in 0..<Self.w {
                let cx = min(Self.cells - 1, x / cw)
                let i = y * Self.w + x
                cell[cy * Self.cells + cx] += Double(abs(Int(gray[i]) - Int(prev[i])))
                count[cy * Self.cells + cx] += 1
            }
        }
        for i in cell.indices { cell[i] /= Double(max(1, count[i])) }
        // globale Aenderung (Median der Felder) herausrechnen: Licht an/aus betrifft alle Felder gleich
        let sorted = cell.sorted()
        globalLevel = sorted[sorted.count / 2]
        level = (cell.max() ?? 0) - globalLevel
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
