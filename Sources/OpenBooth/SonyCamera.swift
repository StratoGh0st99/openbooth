//
//  SonyCamera.swift
//  OpenBooth
//
//  Sony-Fernsteuerung ueber PTP (PC-Remote-Modus). Ablauf nach libgphoto2 camlibs/ptp2 (LGPL),
//  hier in Swift neu geschrieben. Getestet werden soll zuerst eine ILCE-7M4, spaeter ILCE-6400.
//

import Foundation
import ImageCaptureCore

enum SonyOp {
    static let sdioConnect: UInt16 = 0x9201            // Phasen 1, 2, 3
    static let getExtDeviceInfo: UInt16 = 0x9202       // Param1 = Protokollversion, Param2 = 1
    static let getDevicePropDesc: UInt16 = 0x9203
    static let getDevicePropValue: UInt16 = 0x9204
    static let setExtDevicePropValue: UInt16 = 0x9205  // "ControlDeviceA": Wert setzen
    static let getControlDeviceDesc: UInt16 = 0x9206
    static let controlDevice: UInt16 = 0x9207          // "ControlDeviceB": Tasten (Ausloeser) / Schritte
    static let getAllExtDevicePropInfo: UInt16 = 0x9209
}

enum SonyProp {
    static let imageQuality: UInt16 = 0xD253     // 1 RAW, 2 RAW+JPEG, 3 JPEG (Protokoll 3)
    static let pcSaveImageFormat: UInt16 = 0xD269 // 0 Aus, 1 RAW & JPEG, 2 nur JPEG, 3 nur RAW, 4 RAW & HEIF, 5 nur HEIF
    static let pcSaveImageSize: UInt16 = 0xD268  // 1 Original, 2 2M
    static let shutterSpeed: UInt16 = 0xD20D
    static let focusFound: UInt16 = 0xD213       // 1 -> 2 (oder 3) wenn Fokus sitzt
    static let objectInMemory: UInt16 = 0xD215   // >= 0x8000: Bild liegt unter 0xFFFFC001 bereit
    static let iso: UInt16 = 0xD21E
    static let liveViewStatus: UInt16 = 0xD221
    static let liveViewSettingEffect: UInt16 = 0xD231
    static let priorityMode: UInt16 = 0xD25A     // 1 = Application (PC steuert)
    static let shutterHalfRelease: UInt16 = 0xD2C1
    static let shutterRelease: UInt16 = 0xD2C2
    static let fNumber: UInt16 = 0x5007          // Standard-PTP FNumber
    static let focusMode: UInt16 = 0x500A        // Standard-PTP FocusMode, 1 = manuell
}

/// Ein aus dem Kamera-RAM abgeholtes Objekt (JPEG oder RAW).
struct CapturedObject {
    let data: Data
    let format: UInt16       // 0x3801 JPEG, 0xB101 Sony RAW (ARW)
    let filename: String
    var isRAW: Bool { format == 0xB101 || filename.uppercased().hasSuffix(".ARW") }
    var isJPEG: Bool { format == 0x3801 || filename.uppercased().hasSuffix(".JPG") }
}

enum SonyHandle {
    static let capturedImage: UInt32 = 0xFFFFC001
    static let liveView: UInt32 = 0xFFFFC002
}

let sonyProtocol300: UInt32 = 0x12C

struct SonyPropDesc {
    let code: UInt16
    let dataType: UInt16
    let getSet: UInt8
    let isEnabled: UInt8
    let defaultValue: Int64?
    let currentValue: Int64?
    let enumValues: [Int64]
}

enum SonyError: LocalizedError {
    case ptp(op: UInt16, code: UInt16)
    case noSession
    case timeout(String)
    case noImage
    case badData(String)

    var errorDescription: String? {
        switch self {
        case .ptp(let op, let code): return String(format: "PTP error 0x%04X in operation 0x%04X", code, op)
        case .noSession: return "No camera session"
        case .timeout(let s): return "Timeout: \(s)"
        case .noImage: return "No image received from the camera"
        case .badData(let s): return "Unexpected data: \(s)"
        }
    }
}

/// Fuehrt PTP-Transaktionen ueber ein ICCameraDevice aus. Serialisiert alle Aufrufe.
actor PTPTransport {
    private let device: ICCameraDevice
    private var transactionID: UInt32 = 1
    private(set) var log: [String] = []
    var logHandler: ((String) -> Void)?

    init(device: ICCameraDevice) {
        self.device = device
    }

    func setLogHandler(_ h: @escaping (String) -> Void) { logHandler = h }

    private func emit(_ s: String) {
        log.append(s)
        if log.count > 400 { log.removeFirst(log.count - 400) }
        logHandler?(s)
    }

    /// Log aus dem Completion-Handler heraus (nicht im Actor-Kontext), nur Weitergabe an den Handler.
    nonisolated private func emitSync(_ s: String) {
        Task { await self.emit(s) }
    }

    /// Eine komplette Transaktion: Command (+ optional Data-Out) -> (Response, Data-In).
    func transaction(_ op: UInt16, params: [UInt32] = [], dataOut: Data? = nil) async throws -> (PTP.Response, Data) {
        let tid = transactionID
        transactionID &+= 1
        let cmd = PTP.command(op, params: params, transactionID: tid)
        return try await withCheckedThrowingContinuation { cont in
            // Reihenfolge der Completion-Parameter (am Geraet verifiziert): 1. Data-In-Payload, 2. Response-Container
            device.requestSendPTPCommand(cmd, outData: dataOut) { inData, responseData, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                let resp = PTP.parseResponse(responseData) ?? PTP.Response(code: 0, transactionID: tid, params: [])
                cont.resume(returning: (resp, PTP.stripDataHeader(inData)))
            }
        }
    }

    /// Transaktion, die bei Nicht-OK wirft.
    @discardableResult
    func run(_ op: UInt16, params: [UInt32] = [], dataOut: Data? = nil, allow: Set<UInt16> = []) async throws -> Data {
        let (resp, data) = try await transaction(op, params: params, dataOut: dataOut)
        let paramStr = params.map { String(format: "0x%X", $0) }.joined(separator: ",")
        emit(String(format: "op 0x%04X(%@) -> %@ (%d bytes)", op, paramStr, resp.codeHex, data.count))
        if !resp.ok && !allow.contains(resp.code) {
            throw SonyError.ptp(op: op, code: resp.code)
        }
        return data
    }

    func runWithResponse(_ op: UInt16, params: [UInt32] = [], dataOut: Data? = nil, quiet: Bool = false) async throws -> (PTP.Response, Data) {
        let (resp, data) = try await transaction(op, params: params, dataOut: dataOut)
        // quiet: nur echte Fehler loggen; AccessDenied/DeviceBusy sind beim Liveview normal (zu schnell gefragt)
        if !quiet || (!resp.ok && resp.code != PTP.RC.accessDenied && resp.code != PTP.RC.deviceBusy && resp.code != PTP.RC.invalidObjectHandle) {
            emit(String(format: "op 0x%04X -> %@ (%d bytes)", op, resp.codeHex, data.count))
        }
        return (resp, data)
    }
}

/// Der Sony-Treiber: Handshake, Liveview, Ausloesen, Bildabruf.
final class SonyCamera {
    let transport: PTPTransport
    private(set) var deviceInfo = PTP.DeviceInfo()
    private(set) var protocolVersion: UInt16 = 0
    private(set) var vendorCodes: [UInt16] = []
    /// Rohdaten der wichtigsten Antworten fuer die Diagnose (Hex im Bericht), damit sich fremde Modelle aus dem Log heraus
    /// nachbauen lassen: DeviceInfo, 0x9202, erstes 0x9209, ObjectInfos der Aufnahmen, Kopf des ersten Liveview-Blocks.
    private(set) var rawDumps: [(name: String, data: Data)] = []
    private var liveHeaderDumped = false
    func dump(_ name: String, _ d: Data, limit: Int = 65536) {
        guard rawDumps.count < 40 else { return }
        rawDumps.append((name, d.prefix(limit)))
    }
    private(set) var vendorProps: [UInt16] = []    // erste Liste aus 0x9202: Sony-Properties
    private(set) var controlCodes: [UInt16] = []   // zweite Liste aus 0x9202: Steuercodes fuer 0x9207
    private(set) var connectedAt = Date.distantPast
    /// Von der Kamera gemeldetes ObjectAdded (Event 0xC201): Bild liegt bereit, nicht mehr pollen.
    let objectAdded = EventSignal()
    private(set) var props: [UInt16: SonyPropDesc] = [:]

    init(device: ICCameraDevice) {
        transport = PTPTransport(device: device)
    }

    // MARK: Verbindung

    /// Schritt 1: nur GetDeviceInfo. Das ist der Machbarkeitstest fuer das PTP-Durchreichen auf iPadOS.
    func probe() async throws -> PTP.DeviceInfo {
        let data = try await transport.run(PTP.Op.getDeviceInfo)
        dump("GetDeviceInfo 0x1001", data)
        deviceInfo = PTP.parseDeviceInfo(data)
        return deviceInfo
    }

    /// Schritt 2: Sony-Handshake wie libgphoto2 camera_init.
    func connect() async throws {
        if deviceInfo.model.isEmpty { _ = try await probe() }

        try await transport.run(SonyOp.sdioConnect, params: [1, 0, 0])
        try await transport.run(SonyOp.sdioConnect, params: [2, 0, 0])

        var tries = 20
        var ext = Data()
        while ext.isEmpty && tries > 0 {
            ext = try await transport.run(SonyOp.getExtDeviceInfo, params: [sonyProtocol300, 1])
            tries -= 1
            if ext.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        dump("Sony GetExtDeviceInfo 0x9202", ext)
        if ext.count >= 2 {
            protocolVersion = ext.readLE(UInt16.self, at: 0)
            var off = 2
            let a = PTP.readUInt16Array(ext, at: &off)
            let b = PTP.readUInt16Array(ext, at: &off)
            vendorCodes = a + b
            vendorProps = a
            controlCodes = b
        }

        try await transport.run(SonyOp.sdioConnect, params: [3, 0, 0])

        // PriorityMode = 1 (Application): Kamera nimmt Einstellungen vom Rechner an
        _ = try? await setValue(SonyProp.priorityMode, value: 1, type: PTP.DTC.int8)
        connectedAt = Date()

        try await refreshProps()
    }

    // MARK: Properties

    /// Holt alle Sony-Properties (0x9209) und parst sie.
    func refreshProps() async throws {
        let (resp, d) = try await transport.runWithResponse(SonyOp.getAllExtDevicePropInfo, quiet: true)
        guard resp.ok else { throw SonyError.ptp(op: SonyOp.getAllExtDevicePropInfo, code: resp.code) }
        if !rawDumps.contains(where: { $0.name.hasPrefix("Sony GetAllExtDevicePropInfo") }) { dump("Sony GetAllExtDevicePropInfo 0x9209", d) }
        props = Self.parseAllProps(d)
    }

    /// Format je Eintrag (nach libgphoto2 ptp_unpack_Sony_DPD):
    ///   u16 PropCode, u16 DataType, u8 GetSet, u8 IsEnabled, Default, Current, u8 FormFlag,
    ///   FormFlag 1: Min, Max, Step;  FormFlag 2: u16 N, N Werte;
    ///   danach optional eine zweite Liste (u16 N < 0x200, N Werte), die bei neueren Kameras die gueltigen Werte traegt.
    static func parseAllProps(_ d: Data) -> [UInt16: SonyPropDesc] {
        var out: [UInt16: SonyPropDesc] = [:]
        guard d.count > 8 else { return out }
        var off = 8 // u32 Anzahl, u32 0
        while off + 6 <= d.count {
            let code = d.readLE(UInt16.self, at: off)
            let dtc = d.readLE(UInt16.self, at: off + 2)
            let getSet = d[d.startIndex + off + 4]
            let isEnabled = d[d.startIndex + off + 5]
            off += 6
            guard PTP.size(of: dtc) > 0 || dtc == PTP.DTC.string || (dtc & 0x4000) != 0 else { break }
            let defV = PTP.readValue(d, type: dtc, at: &off)
            let curV = PTP.readValue(d, type: dtc, at: &off)
            var enumVals: [Int64] = []
            if off < d.count {
                let form = d[d.startIndex + off]; off += 1
                switch form {
                case 1:
                    _ = PTP.readValue(d, type: dtc, at: &off)
                    _ = PTP.readValue(d, type: dtc, at: &off)
                    _ = PTP.readValue(d, type: dtc, at: &off)
                case 2:
                    enumVals = readEnum(d, type: dtc, at: &off)
                default: break
                }
                // zweite Liste?
                if form == 2, off + 2 <= d.count, d.readLE(UInt16.self, at: off) < 0x200 {
                    let second = readEnum(d, type: dtc, at: &off)
                    if !second.isEmpty { enumVals = second }
                }
            }
            out[code] = SonyPropDesc(code: code, dataType: dtc, getSet: getSet, isEnabled: isEnabled,
                                     defaultValue: defV, currentValue: curV, enumValues: enumVals)
        }
        return out
    }

    private static func readEnum(_ d: Data, type dtc: UInt16, at off: inout Int) -> [Int64] {
        guard off + 2 <= d.count else { return [] }
        let n = Int(d.readLE(UInt16.self, at: off)); off += 2
        var vals: [Int64] = []
        for _ in 0..<n {
            let before = off
            let v = PTP.readValue(d, type: dtc, at: &off)
            if off == before { break }
            if let v { vals.append(v) }
        }
        return vals
    }

    func currentValue(_ code: UInt16) -> Int64? { props[code]?.currentValue }

    /// ControlDeviceA: Property-Wert setzen (z. B. ISO, Blende, PriorityMode).
    func setValue(_ code: UInt16, value: Int64, type: UInt16) async throws {
        try await transport.run(SonyOp.setExtDevicePropValue, params: [UInt32(code)],
                                dataOut: PTP.encodeValue(value, type: type))
    }

    /// ControlDeviceB: Tasten und Schritte (Ausloeser halb/voll, +/-).
    func control(_ code: UInt16, value: Int64, type: UInt16 = PTP.DTC.uint16) async throws {
        try await transport.run(SonyOp.controlDevice, params: [UInt32(code)],
                                dataOut: PTP.encodeValue(value, type: type))
    }

    // MARK: Liveview

    /// Ein Liveview-Frame als JPEG. Gibt nil zurueck, wenn die Kamera gerade keins liefert.
    func liveViewFrame() async throws -> Data? {
        var tries = 10
        while tries > 0 {
            tries -= 1
            let (oiResp, _) = try await transport.runWithResponse(PTP.Op.getObjectInfo, params: [SonyHandle.liveView], quiet: true)
            if oiResp.code == PTP.RC.invalidObjectHandle {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            let (resp, data) = try await transport.runWithResponse(PTP.Op.getObject, params: [SonyHandle.liveView], quiet: true)
            if resp.ok, data.count > 4 {
                if !liveHeaderDumped { liveHeaderDumped = true; dump("Liveview 0xFFFFC002 header (\(data.count) bytes)", data, limit: 96) }
                return Self.extractJPEG(data)
            }
            if resp.code == PTP.RC.accessDenied || resp.code == PTP.RC.deviceBusy {
                try await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            if !resp.ok { throw SonyError.ptp(op: PTP.Op.getObject, code: resp.code) }
        }
        return nil
    }

    /// Sony liefert vorne einen Header: die ersten 4 Byte sind der Offset zum JPEG. Fallback: FFD8 suchen.
    static func extractJPEG(_ d: Data) -> Data? {
        if d.count > 4 {
            let off = Int(d.readLE(UInt32.self, at: 0))
            if off + 1 < d.count, d[d.startIndex + off] == 0xFF, d[d.startIndex + off + 1] == 0xD8 {
                return d.subdata(in: (d.startIndex + off)..<d.endIndex)
            }
        }
        // Suche nach SOI
        let bytes = [UInt8](d)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 { return Data(bytes[i...]) }
            i += 1
        }
        return nil
    }

    // MARK: Ausloesen

    /// Loest aus und liefert alle Objekte aus dem Kamera-RAM (JPEG, bei RAW+JPEG zusaetzlich das ARW).
    /// Ablauf wie libgphoto2 camera_sony_capture; mehrere Objekte wie in ptp_wait_event: solange 0xD215 > 0x8000,
    /// liegt das naechste Objekt wieder unter 0xFFFFC001.
    func capture(progress: ((String) -> Void)? = nil) async throws -> [CapturedObject] {
        // Neuere Bodies (A7 IV u. a.) brauchen ~3 s nach dem Handshake, bevor sie ausloesen koennen
        let sinceConnect = Date().timeIntervalSince(connectedAt)
        if sinceConnect < 3.0 {
            progress?("Preparing camera…")
            try await Task.sleep(nanoseconds: UInt64((3.0 - sinceConnect) * 1_000_000_000))
        }

        // RAM leeren, falls noch ein Bild vom letzten Mal drin liegt
        try await refreshProps()
        if let inMem = currentValue(SonyProp.objectInMemory), inMem >= 0x8000 {
            progress?("Removing old image from camera RAM…")
            _ = try? await transport.run(PTP.Op.getObjectInfo, params: [SonyHandle.capturedImage])
            _ = try? await transport.run(PTP.Op.getObject, params: [SonyHandle.capturedImage])
        }

        progress?("Releasing shutter…")
        try await control(SonyProp.shutterHalfRelease, value: 2)
        try await control(SonyProp.shutterRelease, value: 2)

        // Fokus abwarten, ausser bei manuellem Fokus (FocusMode 1)
        let manualFocus = currentValue(SonyProp.focusMode) == 1
        if !manualFocus {
            let start = Date()
            while Date().timeIntervalSince(start) < 1.0 {
                try await refreshProps()
                if let f = currentValue(SonyProp.focusFound), f == 2 || f == 3 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        try await control(SonyProp.shutterRelease, value: 1)
        try await control(SonyProp.shutterHalfRelease, value: 1)

        // Auf das Bild warten: die Kamera meldet ObjectAdded (0xC201) sofort; solange keine Events beobachtet
        // wurden, alle 100 ms pollen, sonst nur noch jede Sekunde als Sicherheitsnetz. Maximal 35 s (Langzeitbelichtung).
        progress?("Waiting for the image…")
        objectAdded.reset()
        let start = Date()
        var ready = false
        var lastPoll = Date.distantPast
        let pollEvery: TimeInterval = objectAdded.everSeen ? 1.0 : 0.1
        while Date().timeIntervalSince(start) < 35 {
            let signalled = objectAdded.consume()
            if signalled || Date().timeIntervalSince(lastPoll) >= pollEvery {
                lastPoll = Date()
                try await refreshProps()
                if let inMem = currentValue(SonyProp.objectInMemory), inMem >= 0x8000 {
                    ready = true
                    if signalled { progress?("Image announced by event") }
                    break
                }
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard ready else { throw SonyError.timeout("Camera reported no image (no focus?)") }
        return try await fetchObjects(progress: progress)
    }

    /// Liegt ein Bild im Kamera-RAM, das nicht die App ausgeloest hat (Ausloeser an der Kamera, Fernausloeser)?
    func hasPendingObject() async throws -> Bool {
        try await refreshProps()
        return (currentValue(SonyProp.objectInMemory) ?? 0) >= 0x8000
    }

    /// Alle Objekte aus dem RAM holen (JPEG, RAW oder beide), solange 0xD215 weitere meldet.
    func fetchObjects(progress: ((String) -> Void)? = nil) async throws -> [CapturedObject] {
        progress?("Fetching image…")
        var objects: [CapturedObject] = []
        var pending = true
        var rounds = 0
        while pending && rounds < 4 {
            rounds += 1
            let oiData = try await transport.run(PTP.Op.getObjectInfo, params: [SonyHandle.capturedImage])
            if rawDumps.filter({ $0.name.hasPrefix("ObjectInfo") }).count < 4 { dump("ObjectInfo 0xFFFFC001", oiData) }
            let oi = PTP.parseObjectInfo(oiData)
            let data = try await transport.run(PTP.Op.getObject, params: [SonyHandle.capturedImage])
            guard data.count > 1000 else { break }
            objects.append(CapturedObject(data: data, format: oi.objectFormat, filename: oi.filename))
            progress?(String(format: "Received: %@ format 0x%04X (%d KB)", oi.filename, oi.objectFormat, data.count / 1024))
            // Liegt noch ein Objekt im RAM (RAW+JPEG)? Kamera braucht eventuell einen Moment fuer den Zaehler.
            var mem: Int64 = 0
            for _ in 0..<4 {
                try await refreshProps()
                mem = currentValue(SonyProp.objectInMemory) ?? 0
                if mem > 0x8000 { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            progress?(String(format: "RAM counter 0xD215 after fetch: 0x%04llX", mem))
            pending = mem > 0x8000
            if pending { progress?("Fetching further object…") }
        }
        guard !objects.isEmpty else { throw SonyError.noImage }
        return objects
    }
}

/// Thread-sicheres Signal fuer PTP-Events (gesetzt vom Delegaten, gelesen in der Aufnahmeschleife).
final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private(set) var everSeen = false
    func fire() { lock.lock(); flag = true; everSeen = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
    func consume() -> Bool { lock.lock(); defer { lock.unlock() }; let f = flag; flag = false; return f }
}
