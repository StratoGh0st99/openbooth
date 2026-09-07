//
//  MotionDetector.swift
//  OpenBooth
//
//  Detect motion in the live view: downscale the image to 32x18 gray, split into 4x4 cells and measure per cell the
//  mean brightness change to the previous frame. Global changes (lights on/off, someone else's flash) are
//  subtracted as the median over all cells; the strongest cell counts. So a person at the edge or far back
//  stands out, a brightness jump across the whole frame does not. Adaptive threshold against noise, three hits in a row needed.
//

import UIKit

struct MotionDetector {
    private var previous: [UInt8]?
    private var noise: Double = 0          // moving average of the change without motion
    private var hits = 0
    private(set) var level: Double = 0     // strongest cell after subtracting the global change (gray levels 0-255)
    private(set) var globalLevel: Double = 0   // change across the whole frame (lighting change)
    var noiseLevel: Double { noise }

    private static let w = 32, h = 18
    private static let cells = 4            // 4x4 cells of 8x4 (or 8x5) pixels

    mutating func reset() { previous = nil; noise = 0; hits = 0; level = 0 }

    /// Returns true when motion was detected. `threshold` = minimum change in gray levels.
    mutating func feed(_ image: UIImage, threshold: Double) -> Bool {
        guard let gray = Self.downsample(image) else { return false }
        defer { previous = gray }
        guard let prev = previous, prev.count == gray.count else { return false }
        // Change per cell
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
        // Remove the global change (median of the cells): lights on/off affects all cells equally
        let sorted = cell.sorted()
        globalLevel = sorted[sorted.count / 2]
        level = (cell.max() ?? 0) - globalLevel
        // Learn the noise, but only from quiet frames
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
