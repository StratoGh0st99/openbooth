//
//  SonyCamera.swift
//  OpenBooth
//
//  Sony remote control via PTP (PC Remote mode). Flow after libgphoto2 camlibs/ptp2 (LGPL),
//  rewritten here in Swift. Tested first with an ILCE-7M4, later ILCE-6400.
//

import Foundation
import ImageCaptureCore

enum SonyOp {
    static let sdioConnect: UInt16 = 0x9201            // phases 1, 2, 3
    static let getExtDeviceInfo: UInt16 = 0x9202       // param1 = protocol version, param2 = 1
    static let getDevicePropDesc: UInt16 = 0x9203
    static let getDevicePropValue: UInt16 = 0x9204
    static let setExtDevicePropValue: UInt16 = 0x9205  // "ControlDeviceA": set a value
    static let getControlDeviceDesc: UInt16 = 0x9206
    static let controlDevice: UInt16 = 0x9207          // "ControlDeviceB": buttons (shutter) / steps
    static let getAllExtDevicePropInfo: UInt16 = 0x9209
}

enum SonyProp {
    static let imageQuality: UInt16 = 0xD253     // 1 RAW, 2 RAW+JPEG, 3 JPEG (protocol 3)
    static let pcSaveImageFormat: UInt16 = 0xD269 // 0 off, 1 RAW & JPEG, 2 JPEG only, 3 RAW only, 4 RAW & HEIF, 5 HEIF only
    static let pcSaveImageSize: UInt16 = 0xD268  // 1 Original, 2 2M
    static let shutterSpeed: UInt16 = 0xD20D
    static let focusFound: UInt16 = 0xD213       // 1 -> 2 (or 3) when focus is locked
    static let objectInMemory: UInt16 = 0xD215   // >= 0x8000: image is ready under 0xFFFFC001
    static let iso: UInt16 = 0xD21E
    static let liveViewStatus: UInt16 = 0xD221
    static let liveViewSettingEffect: UInt16 = 0xD231
    static let priorityMode: UInt16 = 0xD25A     // 1 = application (host controls)
    static let shutterHalfRelease: UInt16 = 0xD2C1
    static let shutterRelease: UInt16 = 0xD2C2
    static let fNumber: UInt16 = 0x5007          // standard PTP FNumber
    static let focusMode: UInt16 = 0x500A        // standard PTP FocusMode, 1 = manual
}

/// An object fetched from camera RAM (JPEG or RAW).
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

/// Runs PTP transactions through an ICCameraDevice. Serializes all calls.
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

    /// Log from the completion handler (not in the actor context), just forwarded to the handler.
    nonisolated private func emitSync(_ s: String) {
        Task { await self.emit(s) }
    }

    /// One complete transaction: command (+ optional data-out) -> (response, data-in).
    func transaction(_ op: UInt16, params: [UInt32] = [], dataOut: Data? = nil) async throws -> (PTP.Response, Data) {
        let tid = transactionID
        transactionID &+= 1
        let cmd = PTP.command(op, params: params, transactionID: tid)
        return try await withCheckedThrowingContinuation { cont in
            // Order of the completion parameters (verified on device): 1. data-in payload, 2. response container
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

    /// Transaction that throws on non-OK.
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
        // quiet: log only real errors; AccessDenied/DeviceBusy are normal during live view (asked too fast)
        if !quiet || (!resp.ok && resp.code != PTP.RC.accessDenied && resp.code != PTP.RC.deviceBusy && resp.code != PTP.RC.invalidObjectHandle) {
            emit(String(format: "op 0x%04X -> %@ (%d bytes)", op, resp.codeHex, data.count))
        }
        return (resp, data)
    }
}

/// The Sony driver: handshake, live view, shutter release, image retrieval.
final class SonyCamera: CameraDriver {
    let transport: PTPTransport
    private(set) var deviceInfo = PTP.DeviceInfo()
    private(set) var protocolVersion: UInt16 = 0
    private(set) var vendorCodes: [UInt16] = []
    /// Raw data of the key responses for diagnostics (hex in the report) so unknown models can be reverse-engineered
    /// from the log: DeviceInfo, 0x9202, first 0x9209, ObjectInfos of captures, header of the first live view block.
    private(set) var rawDumps: [(name: String, data: Data)] = []
    private var liveHeaderDumped = false
    func dump(_ name: String, _ d: Data, limit: Int = 65536) {
        guard rawDumps.count < 40 else { return }
        rawDumps.append((name, d.prefix(limit)))
    }
    private(set) var vendorProps: [UInt16] = []    // first list from 0x9202: Sony properties
    private(set) var controlCodes: [UInt16] = []   // second list from 0x9202: control codes for 0x9207
    private(set) var connectedAt = Date.distantPast
    /// ObjectAdded reported by the camera (event 0xC201): image is ready, stop polling.
    let objectAdded = EventSignal()
    private(set) var props: [UInt16: SonyPropDesc] = [:]

    init(device: ICCameraDevice) {
        transport = PTPTransport(device: device)
    }
    init(transport: PTPTransport, deviceInfo: PTP.DeviceInfo) {
        self.transport = transport
        self.deviceInfo = deviceInfo
    }

    var supportsRemoteControl: Bool { true }
    var objectAddedEventCodes: Set<UInt16> { [0xC201] }
    var quickSettingCodes: Set<UInt16> { [0x500E, SonyProp.iso, SonyProp.fNumber, SonyProp.shutterSpeed, 0x500C, 0xD200] }
    /// Debug aid: called with one line per property whose value changed between two fetches (finds unknown codes,
    /// e.g. change a flash setting in the camera menu and watch which 0xD2xx moves)
    var propWatch: ((String) -> Void)?
    private static let noisyProps: Set<UInt16> = [0xD213, 0xD215, 0xD216, 0xD218, 0xD20E, 0xD2B4]
    var vendorPropertyCount: Int { max(vendorProps.count, props.count) }
    var controlCodeCount: Int { controlCodes.count }
    var connectSummary: String { "Handshake OK, protocol 0x\(String(protocolVersion, radix: 16)), \(vendorCodes.count) vendor codes, \(props.count) properties" }
    /// Image quality RAW (1) or RAW+JPEG (2)
    var deliversRAW: Bool { let v = currentValue(SonyProp.imageQuality); return v == 1 || v == 2 }
    func batteryPercent() -> Int? {
        if let v = currentValue(0xD218) { return Int(v) }
        if let v = currentValue(0x5001) { return Int(v) }
        return nil
    }
    func capabilitiesReport() -> String {
        CapabilityReport.build(deviceInfo: deviceInfo, protocolLine: "Sony protocol version 0x\(String(protocolVersion, radix: 16))",
                               vendorProps: vendorProps, controlCodes: controlCodes, props: props, rawDumps: rawDumps)
    }

    // MARK: Connection

    /// Step 1: GetDeviceInfo only. This is the feasibility test for PTP pass-through on iPadOS.
    func probe() async throws -> PTP.DeviceInfo {
        let data = try await transport.run(PTP.Op.getDeviceInfo)
        dump("GetDeviceInfo 0x1001", data)
        deviceInfo = PTP.parseDeviceInfo(data)
        return deviceInfo
    }

    /// Step 2: Sony handshake like libgphoto2 camera_init.
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

        // PriorityMode = 1 (application): the camera accepts settings from the host
        _ = try? await setValue(SonyProp.priorityMode, value: 1, type: PTP.DTC.int8)
        connectedAt = Date()

        try await refreshProps()
    }

    // MARK: Properties

    /// Fetches all Sony properties (0x9209) and parses them.
    func refreshProps() async throws {
        let (resp, d) = try await transport.runWithResponse(SonyOp.getAllExtDevicePropInfo, quiet: true)
        guard resp.ok else { throw SonyError.ptp(op: SonyOp.getAllExtDevicePropInfo, code: resp.code) }
        if !rawDumps.contains(where: { $0.name.hasPrefix("Sony GetAllExtDevicePropInfo") }) { dump("Sony GetAllExtDevicePropInfo 0x9209", d) }
        let new = Self.parseAllProps(d)
        if let watch = propWatch, !props.isEmpty {
            for (code, np) in new where !Self.noisyProps.contains(code) {
                guard let op = props[code], op.currentValue != np.currentValue else { continue }
                let title = SonyFormat.wanted.first { $0.code == code }?.title ?? ""
                watch(String(format: "Prop 0x%04X %@: %@ -> %@", code, title,
                             op.currentValue.map { SonyFormat.label(code: code, value: $0) } ?? "-",
                             np.currentValue.map { SonyFormat.label(code: code, value: $0) } ?? "-"))
            }
        }
        props = new
    }

    /// Format per entry (after libgphoto2 ptp_unpack_Sony_DPD):
    ///   u16 PropCode, u16 DataType, u8 GetSet, u8 IsEnabled, Default, Current, u8 FormFlag,
    ///   FormFlag 1: Min, Max, Step;  FormFlag 2: u16 N, N values;
    ///   then optionally a second list (u16 N < 0x200, N values) that carries the valid values on newer cameras.
    static func parseAllProps(_ d: Data) -> [UInt16: SonyPropDesc] {
        var out: [UInt16: SonyPropDesc] = [:]
        guard d.count > 8 else { return out }
        var off = 8 // u32 count, u32 0
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
                // second list?
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

    /// ControlDeviceA: set a property value (e.g. ISO, aperture, PriorityMode).
    func setValue(_ code: UInt16, value: Int64, type: UInt16) async throws {
        try await transport.run(SonyOp.setExtDevicePropValue, params: [UInt32(code)],
                                dataOut: PTP.encodeValue(value, type: type))
    }

    /// ControlDeviceB: buttons and steps (shutter half/full, +/-).
    func control(_ code: UInt16, value: Int64, type: UInt16 = PTP.DTC.uint16) async throws {
        try await transport.run(SonyOp.controlDevice, params: [UInt32(code)],
                                dataOut: PTP.encodeValue(value, type: type))
    }

    // MARK: Liveview

    /// One live view frame as JPEG. Returns nil when the camera has none right now.
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

    /// Sony prepends a header: the first 4 bytes are the offset to the JPEG. Fallback: search for FFD8.
    static func extractJPEG(_ d: Data) -> Data? {
        if d.count > 4 {
            let off = Int(d.readLE(UInt32.self, at: 0))
            if off + 1 < d.count, d[d.startIndex + off] == 0xFF, d[d.startIndex + off + 1] == 0xD8 {
                return d.subdata(in: (d.startIndex + off)..<d.endIndex)
            }
        }
        // Search for SOI
        let bytes = [UInt8](d)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 { return Data(bytes[i...]) }
            i += 1
        }
        return nil
    }

    // MARK: Capture

    /// Releases the shutter and returns all objects from camera RAM (JPEG, plus the ARW with RAW+JPEG).
    /// Flow like libgphoto2 camera_sony_capture; multiple objects as in ptp_wait_event: while 0xD215 > 0x8000,
    /// the next object is again available under 0xFFFFC001.
    func capture(progress: ((String) -> Void)? = nil) async throws -> [CapturedObject] {
        // Newer bodies (A7 IV and others) need ~3 s after the handshake before they can release
        let sinceConnect = Date().timeIntervalSince(connectedAt)
        if sinceConnect < 3.0 {
            progress?("Preparing camera…")
            try await Task.sleep(nanoseconds: UInt64((3.0 - sinceConnect) * 1_000_000_000))
        }

        // Clear RAM in case an image from last time is still there
        try await refreshProps()
        if let inMem = currentValue(SonyProp.objectInMemory), inMem >= 0x8000 {
            progress?("Removing old image from camera RAM…")
            _ = try? await transport.run(PTP.Op.getObjectInfo, params: [SonyHandle.capturedImage])
            _ = try? await transport.run(PTP.Op.getObject, params: [SonyHandle.capturedImage])
        }

        progress?("Releasing shutter…")
        try await control(SonyProp.shutterHalfRelease, value: 2)
        try await control(SonyProp.shutterRelease, value: 2)

        // Wait for focus, except with manual focus (FocusMode 1)
        let manualFocus = currentValue(SonyProp.focusMode) == 1
        if !manualFocus {
            let start = Date()
            while Date().timeIntervalSince(start) < 1.0 {
                try await refreshProps()
                if let f = currentValue(SonyProp.focusFound), f == 2 || f == 3 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        // Arm the signal before releasing: the ObjectAdded event can arrive while the release commands are still in flight
        objectAdded.reset()
        try await control(SonyProp.shutterRelease, value: 1)
        try await control(SonyProp.shutterHalfRelease, value: 1)

        // Wait for the image: the camera reports ObjectAdded (0xC201) immediately; as long as no events have been
        // observed, poll every 100 ms, otherwise only once a second as a safety net. At most 35 s (long exposure).
        progress?("Waiting for the image…")
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

    /// Is there an image in camera RAM the app did not trigger (camera shutter, remote release)?
    func hasPendingObject() async throws -> Bool {
        try await refreshProps()
        return (currentValue(SonyProp.objectInMemory) ?? 0) >= 0x8000
    }

    /// Fetch all objects from RAM (JPEG, RAW or both) while 0xD215 reports more.
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
            // Another object in RAM (RAW+JPEG)? The camera may need a moment for the counter.
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

/// Thread-safe signal for PTP events (set by the delegate, read in the capture loop).
final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private(set) var everSeen = false
    func fire() { lock.lock(); flag = true; everSeen = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
    func consume() -> Bool { lock.lock(); defer { lock.unlock() }; let f = flag; flag = false; return f }
}
