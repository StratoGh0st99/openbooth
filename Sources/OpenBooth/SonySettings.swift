//
//  SonySettings.swift
//  OpenBooth
//
//  Kameraeinstellungen: Werte lesen, lesbar formatieren und setzen.
//  Kodierungen nach libgphoto2 camlibs/ptp2/config.c (Sony).
//

import Foundation

/// Eine anzeigbare, aenderbare Kameraeinstellung.
struct CameraSetting: Identifiable, Equatable {
    let code: UInt16
    let title: String
    let options: [Option]
    let current: Int64?
    let writable: Bool

    struct Option: Identifiable, Equatable {
        let value: Int64
        let label: String
        var id: Int64 { value }
    }

    var id: UInt16 { code }
    var currentLabel: String {
        guard let c = current else { return "–" }
        return options.first { $0.value == c }?.label ?? SonyFormat.label(code: code, value: c)
    }
}

enum SonyFormat {
    static let isoMask: Int64 = 0x00FF_FFFF

    static let exposurePrograms: [Int64: String] = [
        1: "M", 2: "P", 3: "A", 4: "S", 0x8000: "Intelligent Auto", 0x8001: "Superior Auto",
        0x8050: "Movie P", 0x8051: "Movie A", 0x8052: "Movie S", 0x8053: "Movie M",
    ]
    static let focusModes: [Int64: String] = [
        1: String(localized: "Manual"), 2: "AF-S", 3: "AF Makro", 0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF",
        0x8007: String(localized: "Manual (reversed)"), 0x8008: "AF-D", 0x8009: String(localized: "Preset focus"),
    ]
    static let onOff12: [Int64: String] = [1: String(localized: "On"), 2: String(localized: "Off")]
    static let storeDestinations: [Int64: String] = [1: String(localized: "Camera RAM"), 16: String(localized: "Memory card"), 17: String(localized: "Card + RAM")]
    static let imageQualities: [Int64: String] = [1: "RAW", 2: "RAW+JPEG", 3: "JPEG"]
    static let pcSaveFormats: [Int64: String] = [0: String(localized: "Off"), 1: "RAW & JPEG", 2: String(localized: "JPEG only"), 3: String(localized: "RAW only"), 4: "RAW & HEIF", 5: String(localized: "HEIF only")]
    static let pcSaveSizes: [Int64: String] = [1: "Original", 2: "2 MP"]

    /// Die Einstellungen, die die Fotobox braucht, in Anzeigereihenfolge.
    static let wanted: [(code: UInt16, title: String)] = [
        (0x500E, String(localized: "Program")),
        (SonyProp.iso, "ISO"),
        (SonyProp.fNumber, String(localized: "Aperture")),
        (SonyProp.shutterSpeed, String(localized: "Shutter speed")),
        (SonyProp.focusMode, "Fokus"),
        (SonyProp.liveViewSettingEffect, String(localized: "Setting effect in live view")),
        (SonyProp.imageQuality, String(localized: "Image quality")),
        (SonyProp.pcSaveImageFormat, String(localized: "Transfer to the app")),
        (SonyProp.pcSaveImageSize, String(localized: "Transferred size")),
        (0xD222, String(localized: "Save destination")),
    ]

    static func label(code: UInt16, value v: Int64) -> String {
        switch code {
        case SonyProp.iso:
            let base = v & isoMask
            var s = base == isoMask ? "Auto" : "\(base)"
            let nr = (v >> 24) & 0xFF
            if nr == 1 { s += " MFNR" } else if nr == 2 { s += " MFNR+" }
            return s
        case SonyProp.fNumber:
            let f = Double(v) / 100
            return f == f.rounded() ? String(format: "f/%.0f", f) : String(format: "f/%.1f", f)
        case SonyProp.shutterSpeed:
            if v == 0 { return "Bulb" }
            var x = (v >> 16) & 0xFFFF, y = v & 0xFFFF
            if y == 10 && x % 10 == 0 { x /= 10; y = 1 }
            if y == 1 { return "\(x)\"" }
            if y == 10 { return String(format: "%.1f\"", Double(x) / 10) }
            return "\(x)/\(y)"
        case SonyProp.focusMode: return focusModes[v] ?? "0x\(String(v, radix: 16))"
        case 0x500E: return exposurePrograms[v] ?? "0x\(String(v, radix: 16))"
        case SonyProp.liveViewSettingEffect: return onOff12[v] ?? "\(v)"
        case 0xD222: return storeDestinations[v] ?? "\(v)"
        case SonyProp.imageQuality: return imageQualities[v] ?? "\(v)"
        case SonyProp.pcSaveImageFormat: return pcSaveFormats[v] ?? "\(v)"
        case SonyProp.pcSaveImageSize: return pcSaveSizes[v] ?? "\(v)"
        default: return "\(v)"
        }
    }

    static func setting(from desc: SonyPropDesc, title: String) -> CameraSetting {
        let opts = desc.enumValues.map { CameraSetting.Option(value: $0, label: label(code: desc.code, value: $0)) }
        // GetSet 1 = setzbar; isEnabled 0 = ausgegraut
        let writable = desc.getSet == 1 && desc.isEnabled != 0
        return CameraSetting(code: desc.code, title: title, options: opts, current: desc.currentValue, writable: writable)
    }
}

extension SonyCamera {
    /// Die fuer die Fotobox relevanten Einstellungen aus dem letzten Property-Abruf.
    func settings() -> [CameraSetting] {
        SonyFormat.wanted.compactMap { w in
            guard let d = props[w.code] else { return nil }
            return SonyFormat.setting(from: d, title: w.title)
        }
    }

    /// Setzt einen Wert. Erst direkt (ControlDeviceA, Protokoll 3), dann als 32-Bit-Wert, dann schrittweise
    /// ueber ControlDeviceB entlang der Enum-Reihenfolge (noetig bei Protokoll 2, z. B. ILCE-6400).
    func setSetting(_ code: UInt16, to target: Int64, log: ((String) -> Void)? = nil) async throws {
        guard let desc = props[code] else { throw SonyError.badData("Property 0x\(String(code, radix: 16)) unknown") }
        if desc.currentValue == target { return }

        func verify() async throws -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < 1.2 {
                try await Task.sleep(nanoseconds: 150_000_000)
                try await refreshProps()
                if currentValue(code) == target { return true }
            }
            return false
        }

        if protocolVersion >= 0x12C {
            log?("setting 0x\(String(code, radix: 16)) directly to \(target)")
            try await setValue(code, value: target, type: desc.dataType)
            if try await verify() { return }
            if PTP.size(of: desc.dataType) == 2 {
                // libgphoto2 schickt z. B. FNumber im Protokoll 3 als UINT32
                log?("retry as 32-bit value")
                try await setValue(code, value: target, type: PTP.DTC.uint32)
                if try await verify() { return }
            }
        }

        // Schrittweise: Position in der Enum vergleichen, mit +1/-1 (u8 0x01 / 0xFF) laufen, nach jedem Schritt lesen
        guard !desc.enumValues.isEmpty else { throw SonyError.badData("no value list for stepping") }
        log?("setting 0x\(String(code, radix: 16)) stepwise")
        var steps = 60
        var first = true
        while steps > 0 {
            steps -= 1
            try await refreshProps()
            guard let d = props[code], let cur = d.currentValue else { break }
            if cur == target { return }
            let list = d.enumValues
            guard let posNew = list.firstIndex(of: target) else { throw SonyError.badData("target value not in list") }
            let posCur = list.firstIndex(of: cur) ?? posNew
            var stepVal: Int64
            if posNew > posCur { stepVal = first ? Int64(posNew - posCur) : 1 }
            else { stepVal = first ? Int64(0x100 - (posCur - posNew)) : 0xFF }
            first = false
            try await control(code, value: stepVal, type: PTP.DTC.uint8)
            // Kamera braucht bis ~0,7 s pro Schritt
            let start = Date()
            while Date().timeIntervalSince(start) < 0.8 {
                try await Task.sleep(nanoseconds: 100_000_000)
                try await refreshProps()
                if currentValue(code) != cur { break }
            }
        }
        if currentValue(code) != target { throw SonyError.timeout("value could not be set") }
    }
}
