//
//  Sounds.swift
//  OpenBooth
//
//  Kleine, selbst erzeugte Toene (Sinus mit Huellkurve, 44,1 kHz), kein Asset noetig:
//  Willkommensklang beim Aufwachen aus der Collage, Countdown-Piep, Ausloesesignal.
//

import AVFoundation

@MainActor
final class Sounds {
    static let shared = Sounds()

    private var players: [String: AVAudioPlayer] = [:]

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Willkommen: sanftes Dreiklang-Arpeggio C5 E5 G5, weich ausklingend
        players["welcome"] = make(notes: [(523.25, 0.0, 0.55), (659.25, 0.16, 0.55), (783.99, 0.32, 0.7)], volume: 0.5)
        // Countdown: kurzer Piep A5
        players["tick"] = make(notes: [(880, 0, 0.09)], volume: 0.6)
        // Ausloesen: hoeherer Doppelton
        players["shot"] = make(notes: [(1318.5, 0, 0.12), (1760, 0.10, 0.22)], volume: 0.7)
        players.values.forEach { $0.prepareToPlay() }
    }

    func play(_ name: String) {
        guard let p = players[name] else { return }
        p.currentTime = 0
        p.play()
    }

    /// Sinusnoten (Frequenz, Startzeit s, Dauer s) zu einer WAV-Datei im Speicher mischen.
    private func make(notes: [(Double, Double, Double)], volume: Float) -> AVAudioPlayer? {
        let rate = 44100.0
        let total = (notes.map { $0.1 + $0.2 }.max() ?? 0.5) + 0.05
        let n = Int(total * rate)
        var samples = [Float](repeating: 0, count: n)
        for (f, start, dur) in notes {
            let s0 = Int(start * rate), len = Int(dur * rate)
            for i in 0..<len where s0 + i < n {
                let t = Double(i) / rate
                let attack = min(1.0, t / 0.012)
                let release = min(1.0, (dur - t) / (dur * 0.6))
                let env = attack * max(0, release)
                // Grundton plus leiser Oberton fuer etwas Waerme
                let v = sin(2 * .pi * f * t) + 0.25 * sin(2 * .pi * f * 2 * t)
                samples[s0 + i] += Float(v * env) * 0.5
            }
        }
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; data.append(Data(bytes: &x, count: MemoryLayout<T>.size)) }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        data.append("RIFF".data(using: .ascii)!); le(UInt32(36 + pcm.count * 2)); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append("data".data(using: .ascii)!); le(UInt32(pcm.count * 2))
        pcm.forEach { le($0) }
        let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        p?.volume = volume
        return p
    }
}
