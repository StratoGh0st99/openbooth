//
//  Histogram.swift
//  OpenBooth
//
//  RGB- und Luminanz-Histogramm aus einem verkleinerten Bild (160x90 RGBA, 64 Klassen). Rechnet im Liveview-Task,
//  Anzeige als kleines Overlay; im Admin schaltbar.
//

import UIKit
import SwiftUI

struct Histogram: Equatable {
    static let bins = 64
    var r: [Float], g: [Float], b: [Float], luma: [Float]   // normiert 0…1

    nonisolated static func compute(_ image: UIImage) -> Histogram? {
        guard let cg = image.cgImage else { return nil }
        let w = 160, h = 90
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var r = [Int](repeating: 0, count: bins), g = r, b = r, l = r
        let shift = 8 - Int(log2(Double(bins)))   // 256 -> 64 Klassen
        var i = 0
        while i < buf.count {
            let R = Int(buf[i]), G = Int(buf[i + 1]), B = Int(buf[i + 2])
            r[R >> shift] += 1; g[G >> shift] += 1; b[B >> shift] += 1
            l[((R * 299 + G * 587 + B * 114) / 1000) >> shift] += 1
            i += 4
        }
        // Normierung auf das Maximum aller Kanaele, mit leichter Wurzel, damit kleine Werte sichtbar bleiben
        let m = Float(max(r.max() ?? 1, g.max() ?? 1, b.max() ?? 1, l.max() ?? 1, 1))
        func norm(_ a: [Int]) -> [Float] { a.map { sqrt(Float($0) / m) } }
        return Histogram(r: norm(r), g: norm(g), b: norm(b), luma: norm(l))
    }
}

/// Kleines Histogramm-Overlay: Farbkanaele additiv, Luminanz als weisse Linie, Markierungen fuer Clipping.
struct HistogramView: View {
    let histogram: Histogram
    var body: some View {
        Canvas { ctx, size in
            let n = Histogram.bins
            let bw = size.width / CGFloat(n)
            func path(_ v: [Float]) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for i in 0..<n { p.addLine(to: CGPoint(x: CGFloat(i) * bw + bw / 2, y: size.height * (1 - CGFloat(v[i])))) }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.55)))
            ctx.blendMode = .screen
            ctx.fill(path(histogram.r), with: .color(Color(red: 1, green: 0.25, blue: 0.2).opacity(0.75)))
            ctx.fill(path(histogram.g), with: .color(Color(red: 0.2, green: 1, blue: 0.3).opacity(0.75)))
            ctx.fill(path(histogram.b), with: .color(Color(red: 0.25, green: 0.45, blue: 1).opacity(0.75)))
            ctx.blendMode = .normal
            var line = path(histogram.luma); line.closeSubpath()
            ctx.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
            // Clipping-Hinweise: erste/letzte Klasse stark belegt
            if histogram.luma.first ?? 0 > 0.6 { ctx.fill(Path(CGRect(x: 0, y: 0, width: 4, height: size.height)), with: .color(.blue)) }
            if histogram.luma.last ?? 0 > 0.6 { ctx.fill(Path(CGRect(x: size.width - 4, y: 0, width: 4, height: size.height)), with: .color(.red)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25)))
    }
}
