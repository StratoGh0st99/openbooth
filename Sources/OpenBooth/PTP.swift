//
//  PTP.swift
//  OpenBooth
//
//  Minimaler PTP-Container-Codec (ISO 15740) fuer das Durchreichen ueber ImageCaptureCore.
//  Alle Werte sind Little Endian.
//

import Foundation

enum PTP {
    // Container-Typen
    static let typeCommand: UInt16 = 1
    static let typeData: UInt16 = 2
    static let typeResponse: UInt16 = 3
    static let typeEvent: UInt16 = 4

    // Standard-Operationen
    enum Op {
        static let getDeviceInfo: UInt16 = 0x1001
        static let openSession: UInt16 = 0x1002
        static let closeSession: UInt16 = 0x1003
        static let getObjectInfo: UInt16 = 0x1008
        static let getObject: UInt16 = 0x1009
        static let getDevicePropDesc: UInt16 = 0x1014
        static let getDevicePropValue: UInt16 = 0x1015
        static let setDevicePropValue: UInt16 = 0x1016
    }

    // Response-Codes
    enum RC {
        static let ok: UInt16 = 0x2001
        static let generalError: UInt16 = 0x2002
        static let sessionNotOpen: UInt16 = 0x2003
        static let invalidTransactionID: UInt16 = 0x2004
        static let operationNotSupported: UInt16 = 0x2005
        static let invalidObjectHandle: UInt16 = 0x2009
        static let devicePropNotSupported: UInt16 = 0x200A
        static let accessDenied: UInt16 = 0x200F
        static let deviceBusy: UInt16 = 0x2019
    }

    // Datentypen
    enum DTC {
        static let int8: UInt16 = 0x0001
        static let uint8: UInt16 = 0x0002
        static let int16: UInt16 = 0x0003
        static let uint16: UInt16 = 0x0004
        static let int32: UInt16 = 0x0005
        static let uint32: UInt16 = 0x0006
        static let int64: UInt16 = 0x0007
        static let uint64: UInt16 = 0x0008
        static let string: UInt16 = 0xFFFF
    }

    /// Baut einen Command-Container. Die Transaction-ID setzt die ImageCaptureCore-Schicht selbst,
    /// wir uebergeben 0.
    static func command(_ code: UInt16, params: [UInt32] = [], transactionID: UInt32 = 0) -> Data {
        var d = Data()
        d.appendLE(UInt32(12 + 4 * params.count))
        d.appendLE(typeCommand)
        d.appendLE(code)
        d.appendLE(transactionID)
        for p in params { d.appendLE(p) }
        return d
    }

    /// Zerlegt einen Response-Container.
    struct Response {
        let code: UInt16
        let transactionID: UInt32
        let params: [UInt32]

        var ok: Bool { code == RC.ok }
        var codeHex: String { String(format: "0x%04X", code) }
    }

    static func parseResponse(_ d: Data) -> Response? {
        guard d.count >= 12 else { return nil }
        let type = d.readLE(UInt16.self, at: 4)
        let code = d.readLE(UInt16.self, at: 6)
        let tid = d.readLE(UInt32.self, at: 8)
        guard type == typeResponse || type == typeCommand else {
            // Manche Schichten liefern nur den Code, ohne Typ 3 - trotzdem versuchen
            return Response(code: code, transactionID: tid, params: [])
        }
        var params: [UInt32] = []
        var off = 12
        while off + 4 <= d.count && params.count < 5 {
            params.append(d.readLE(UInt32.self, at: off))
            off += 4
        }
        return Response(code: code, transactionID: tid, params: params)
    }

    /// Entfernt einen eventuell vorhandenen Data-Container-Header (12 Byte) vom Data-In-Payload.
    static func stripDataHeader(_ d: Data) -> Data {
        guard d.count >= 12 else { return d }
        let len = d.readLE(UInt32.self, at: 0)
        let type = d.readLE(UInt16.self, at: 4)
        if type == typeData && Int(len) == d.count {
            return d.subdata(in: 12..<d.count)
        }
        return d
    }

    /// PTP-String: uint8 Anzahl Zeichen (inkl. Nullterminator), dann UTF-16LE.
    static func readString(_ d: Data, at offset: inout Int) -> String {
        guard offset < d.count else { return "" }
        let n = Int(d[d.startIndex + offset]); offset += 1
        guard n > 0, offset + 2 * n <= d.count else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for i in 0..<n { units.append(d.readLE(UInt16.self, at: offset + 2 * i)) }
        offset += 2 * n
        var s = String(decoding: units, as: UTF16.self)
        if s.hasSuffix("\0") { s.removeLast() }
        return s
    }

    static func readUInt16Array(_ d: Data, at offset: inout Int) -> [UInt16] {
        guard offset + 4 <= d.count else { return [] }
        let n = Int(d.readLE(UInt32.self, at: offset)); offset += 4
        var out: [UInt16] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            guard offset + 2 <= d.count else { break }
            out.append(d.readLE(UInt16.self, at: offset)); offset += 2
        }
        return out
    }

    /// Groesse eines Datentyps in Byte (0 = variabel / unbekannt).
    static func size(of dtc: UInt16) -> Int {
        switch dtc {
        case DTC.int8, DTC.uint8: return 1
        case DTC.int16, DTC.uint16: return 2
        case DTC.int32, DTC.uint32: return 4
        case DTC.int64, DTC.uint64: return 8
        default: return 0
        }
    }

    /// Liest einen Property-Wert als Int64 (Strings ergeben nil, Offset wird trotzdem weitergeschoben).
    static func readValue(_ d: Data, type dtc: UInt16, at offset: inout Int) -> Int64? {
        if dtc == DTC.string {
            _ = readString(d, at: &offset)
            return nil
        }
        if (dtc & 0x4000) != 0 {
            // Array: u32 Anzahl, dann Elemente des Basistyps
            guard offset + 4 <= d.count else { return nil }
            let n = Int(d.readLE(UInt32.self, at: offset)); offset += 4
            let base = dtc & 0x00FF
            let esz = size(of: base)
            guard esz > 0 else { return nil }
            offset = min(d.count, offset + n * esz)
            return nil
        }
        let n = size(of: dtc)
        guard n > 0, offset + n <= d.count else { return nil }
        var v: Int64 = 0
        switch dtc {
        case DTC.int8:   v = Int64(Int8(bitPattern: d[d.startIndex + offset]))
        case DTC.uint8:  v = Int64(d[d.startIndex + offset])
        case DTC.int16:  v = Int64(Int16(bitPattern: d.readLE(UInt16.self, at: offset)))
        case DTC.uint16: v = Int64(d.readLE(UInt16.self, at: offset))
        case DTC.int32:  v = Int64(Int32(bitPattern: d.readLE(UInt32.self, at: offset)))
        case DTC.uint32: v = Int64(d.readLE(UInt32.self, at: offset))
        case DTC.int64:  v = Int64(bitPattern: d.readLE(UInt64.self, at: offset))
        case DTC.uint64: v = Int64(bitPattern: d.readLE(UInt64.self, at: offset))
        default: return nil
        }
        offset += n
        return v
    }

    /// Kodiert einen Wert fuer die Data-Out-Phase (roher Wert, ohne Container).
    static func encodeValue(_ v: Int64, type dtc: UInt16) -> Data {
        var d = Data()
        switch dtc {
        case DTC.int8, DTC.uint8:   d.append(UInt8(truncatingIfNeeded: v))
        case DTC.int16, DTC.uint16: d.appendLE(UInt16(truncatingIfNeeded: v))
        case DTC.int32, DTC.uint32: d.appendLE(UInt32(truncatingIfNeeded: v))
        case DTC.int64, DTC.uint64: d.appendLE(UInt64(bitPattern: v))
        default: break
        }
        return d
    }

    // MARK: DeviceInfo

    struct DeviceInfo {
        var standardVersion: UInt16 = 0
        var vendorExtensionID: UInt32 = 0
        var vendorExtensionDesc = ""
        var operations: [UInt16] = []
        var events: [UInt16] = []
        var properties: [UInt16] = []
        var manufacturer = ""
        var model = ""
        var deviceVersion = ""
        var serialNumber = ""

        func supports(_ op: UInt16) -> Bool { operations.contains(op) }
    }

    static func parseDeviceInfo(_ raw: Data) -> DeviceInfo {
        let d = stripDataHeader(raw)
        var info = DeviceInfo()
        var off = 0
        guard d.count >= 8 else { return info }
        info.standardVersion = d.readLE(UInt16.self, at: off); off += 2
        info.vendorExtensionID = d.readLE(UInt32.self, at: off); off += 4
        off += 2 // VendorExtensionVersion
        info.vendorExtensionDesc = readString(d, at: &off)
        off += 2 // FunctionalMode
        info.operations = readUInt16Array(d, at: &off)
        info.events = readUInt16Array(d, at: &off)
        info.properties = readUInt16Array(d, at: &off)
        _ = readUInt16Array(d, at: &off) // CaptureFormats
        _ = readUInt16Array(d, at: &off) // ImageFormats
        info.manufacturer = readString(d, at: &off)
        info.model = readString(d, at: &off)
        info.deviceVersion = readString(d, at: &off)
        info.serialNumber = readString(d, at: &off)
        return info
    }

    // MARK: ObjectInfo (nur die Felder, die wir brauchen)

    struct ObjectInfo {
        var storageID: UInt32 = 0
        var objectFormat: UInt16 = 0
        var compressedSize: UInt32 = 0
        var filename = ""
    }

    static func parseObjectInfo(_ raw: Data) -> ObjectInfo {
        let d = stripDataHeader(raw)
        var oi = ObjectInfo()
        guard d.count >= 52 else { return oi }
        oi.storageID = d.readLE(UInt32.self, at: 0)
        oi.objectFormat = d.readLE(UInt16.self, at: 4)
        oi.compressedSize = d.readLE(UInt32.self, at: 8)
        // Feste Felder bis Offset 52, danach Filename (String)
        var off = 52
        oi.filename = readString(d, at: &off)
        return oi
    }
}

// MARK: - Data-Helfer

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let n = MemoryLayout<T>.size
        guard offset >= 0, offset + n <= count else { return 0 }
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            self.copyBytes(to: dst, from: (startIndex + offset)..<(startIndex + offset + n))
        }
        return T(littleEndian: v)
    }

    var hexPreview: String {
        prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ") + (count > 32 ? " …" : "")
    }
}
