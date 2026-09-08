//
//  CanonCamera.swift
//  OpenBooth
//
//  Canon EOS driver (PTP/IP-less USB, after libgphoto2 camlibs/ptp2): remote mode, event polling, live view,
//  release, image download from camera RAM. First body: EOS R100 (firmware 1.2.0, 155 operations).
//

import Foundation

enum CanonOp {
    static let setDevicePropValueEx: UInt16 = 0x9110   // data: u32 size, u32 code, value
    static let setRemoteMode: UInt16 = 0x9114          // param 1 = on
    static let setEventMode: UInt16 = 0x9115           // param 1 = on
    static let getEvent: UInt16 = 0x9116               // data: records (u32 size, u32 type, payload), end record type 0
    static let transferComplete: UInt16 = 0x9117       // param handle: frees a RAM object after download
    static let requestDevicePropValue: UInt16 = 0x9127
    static let remoteReleaseOn: UInt16 = 0x9128        // params (1 half | 2 full | 3 both, 0)
    static let remoteReleaseOff: UInt16 = 0x9129       // param 1 half | 2 full | 3 both
    static let getViewFinderData: UInt16 = 0x9153      // param 0x00100000; data: records (u32 size, u32 type), type 1 = JPEG
    static let captureFull: UInt16 = 0x910F            // older bodies without 0x9128
}

enum CanonProp {
    static let aperture: UInt16 = 0xD101
    static let shutterSpeed: UInt16 = 0xD102
    static let iso: UInt16 = 0xD103
    static let expCompensation: UInt16 = 0xD104
    static let aeMode: UInt16 = 0xD105
    static let driveMode: UInt16 = 0xD106
    static let meteringMode: UInt16 = 0xD107
    static let focusMode: UInt16 = 0xD108
    static let whiteBalance: UInt16 = 0xD109
    static let batteryPower: UInt16 = 0xD111
    static let availableShots: UInt16 = 0xD11B
    static let captureDestination: UInt16 = 0xD11C   // 2 = card, 4 = host RAM
    static let imageFormat: UInt16 = 0xD120          // list of (size, type 1 JPEG / 6 RAW, quality, compression)
    static let evfOutputDevice: UInt16 = 0xD1B0      // 2 = PC (live view over USB)
    static let evfMode: UInt16 = 0xD1B3
    static let lensName: UInt16 = 0xD1D8
    static let batteryLevel: UInt16 = 0x5001         // standard PTP, percent on the R100
}

enum CanonEvent {
    static let objectAddedEx: UInt16 = 0xC181
    static let propValueChanged: UInt16 = 0xC189
    static let availListChanged: UInt16 = 0xC18A
    static let cameraStatusChanged: UInt16 = 0xC18B
    static let objectAddedEx64: UInt16 = 0xC1A7
}

/// A property as learned from the event stream: value plus the list of currently allowed values.
struct CanonPropState {
    var value: Int64?
    var choices: [Int64] = []
    var raw: Data? = nil          // payload for non-u32 properties (strings, image format)
}

/// An image the camera announced (ObjectAddedEx), waiting to be downloaded from RAM or card.
struct CanonPendingObject {
    let handle: UInt32
    let format: UInt16
    let size: UInt32
    let filename: String
}

final class CanonCamera: CameraDriver {
    let transport: PTPTransport
    private(set) var deviceInfo: PTP.DeviceInfo
    let objectAdded = EventSignal()
    private let lock = NSLock()
    private var props: [UInt16: CanonPropState] = [:]
    private var pending: [CanonPendingObject] = []
    private(set) var rawDumps: [(name: String, data: Data)] = []
    private var evfOn = false
    private var lastEventPoll = Date.distantPast
    private var lastBatteryRead = Date.distantPast
    private var batteryPct: Int?
    private var sawRAWObject = false
    private var eventRecordCounts: [UInt32: Int] = [:]
    var logHandler: ((String) -> Void)?

    init(transport: PTPTransport, deviceInfo: PTP.DeviceInfo) {
        self.transport = transport
        self.deviceInfo = deviceInfo
    }

    private func dump(_ name: String, _ d: Data, limit: Int = 65536) {
        guard rawDumps.count < 40 else { return }
        rawDumps.append((name, d.prefix(limit)))
    }

    // MARK: CameraDriver

    var supportsRemoteControl: Bool { true }
    var objectAddedEventCodes: Set<UInt16> { [CanonEvent.objectAddedEx, CanonEvent.objectAddedEx64, 0x4002] }
    var quickSettingCodes: Set<UInt16> { [CanonProp.aeMode, CanonProp.iso, CanonProp.aperture, CanonProp.shutterSpeed] }
    var connectSummary: String {
        lock.lock(); defer { lock.unlock() }
        let lens = props[CanonProp.lensName]?.raw.map { Self.cString($0) } ?? ""
        return "EOS handshake OK, \(props.count) properties from events\(lens.isEmpty ? "" : ", lens \(lens)")"
    }
    var vendorPropertyCount: Int { lock.lock(); defer { lock.unlock() }; return props.count }
    var controlCodeCount: Int { 0 }
    var deliversRAW: Bool {
        if sawRAWObject { return true }
        lock.lock(); defer { lock.unlock() }
        return Self.imageFormatHasRAW(props[CanonProp.imageFormat]?.raw)
    }

    func probe() async throws -> PTP.DeviceInfo {
        let data = try await transport.run(PTP.Op.getDeviceInfo)
        dump("GetDeviceInfo 0x1001", data)
        deviceInfo = PTP.parseDeviceInfo(data)
        return deviceInfo
    }

    /// Like libgphoto2 camera_prepare_eos_capture: remote mode, event mode, drain the initial property dump,
    /// then route captures to RAM so the app receives them like from the Sony.
    func connect() async throws {
        if deviceInfo.model.isEmpty { _ = try await probe() }
        try await transport.run(CanonOp.setRemoteMode, params: [1])
        try await transport.run(CanonOp.setEventMode, params: [1])
        // The camera answers the first GetEvent calls with its full property set, spread over a few responses
        for i in 0..<6 {
            let n = try await pollEvents(dumpAs: i == 0 ? "Canon GetEvent 0x9116 (initial)" : nil)
            if n == 0 && i >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Capture destination: 6 = card + host. The R100 reports 0 shots left and refuses to focus or fire with
        // RAM only (4), so the image goes to the card and the app is told about it and downloads it.
        let choices = lock.withLock { props[CanonProp.captureDestination]?.choices ?? [] }
        let dest: UInt32 = choices.contains(6) ? 6 : 4
        do { try await setValueEx(CanonProp.captureDestination, value: dest); logHandler?("Canon: capture destination \(dest == 6 ? "card + app" : "app RAM")") }
        catch { logHandler?("Canon: capture destination not set (\(error.localizedDescription)), images may land on the card") }
        _ = try await pollEvents()
        try await ensureOneShotAF()
        await readBattery()
    }

    /// Servo AF never reports a lock to the host, so the full press stays busy forever: switch to One-Shot.
    private func ensureOneShotAF() async throws {
        guard currentValue(CanonProp.focusMode) == 1 else { return }
        logHandler?("Canon: focus mode is Servo, switching to One-Shot for remote release")
        try await setValueEx(CanonProp.focusMode, value: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await pollEvents()
    }

    func refreshProps() async throws {
        _ = try await pollEvents()
        if Date().timeIntervalSince(lastBatteryRead) > 30 { await readBattery() }
    }

    func currentValue(_ code: UInt16) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return props[code]?.value
    }

    func settings() -> [CameraSetting] {
        lock.lock(); defer { lock.unlock() }
        return CanonFormat.wanted.compactMap { w in
            guard let p = props[w.code] else { return nil }
            let opts = p.choices.map { CameraSetting.Option(value: $0, label: CanonFormat.label(code: w.code, value: $0)) }
            // Settable when the camera offers a list with more than the current value (AE mode has none: dial)
            let writable = opts.count > 1
            return CameraSetting(code: w.code, title: w.title, options: opts, current: p.value, writable: writable)
        }
    }

    func setSetting(_ code: UInt16, to target: Int64, log: ((String) -> Void)? = nil) async throws {
        if currentValue(code) == target { return }
        log?("setting 0x\(String(code, radix: 16)) to \(target)")
        try await setValueEx(code, value: UInt32(truncatingIfNeeded: target))
        // The new value comes back as a PropValueChanged event
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            try await Task.sleep(nanoseconds: 100_000_000)
            _ = try await pollEvents()
            if currentValue(code) == target { return }
        }
        throw SonyError.timeout("value could not be set")
    }

    // MARK: Live view

    /// EVF output to the PC, then GetViewFinderData; the response carries records, type 1 is the JPEG frame.
    func liveViewFrame() async throws -> Data? {
        if !evfOn {
            _ = try? await setValueEx(CanonProp.evfMode, value: 1)
            try await setValueEx(CanonProp.evfOutputDevice, value: 2)
            evfOn = true
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        // Heartbeat: the camera wants GetEvent now and then; this also catches ObjectAdded from its own shutter
        if Date().timeIntervalSince(lastEventPoll) > 1.0 { _ = try? await pollEvents() }
        var tries = 12
        while tries > 0 {
            tries -= 1
            let (resp, data) = try await transport.runWithResponse(CanonOp.getViewFinderData, params: [0x0010_0000], quiet: true)
            if resp.ok, data.count > 8 {
                if rawDumps.first(where: { $0.name.hasPrefix("Canon ViewFinder") }) == nil { dump("Canon ViewFinder header (\(data.count) bytes)", data, limit: 96) }
                if let jpeg = Self.extractViewFinderJPEG(data) { return jpeg }
                return nil
            }
            // 0xA102 not ready, busy, access denied: the frame is not there yet
            if resp.code == 0xA102 || resp.code == PTP.RC.deviceBusy || resp.code == PTP.RC.accessDenied || resp.code == 0xA104 {
                try await Task.sleep(nanoseconds: 40_000_000)
                continue
            }
            if !resp.ok { throw SonyError.ptp(op: CanonOp.getViewFinderData, code: resp.code) }
        }
        return nil
    }

    static func extractViewFinderJPEG(_ d: Data) -> Data? {
        var off = 0
        while off + 8 <= d.count {
            let size = Int(d.readLE(UInt32.self, at: off))
            let type = d.readLE(UInt32.self, at: off + 4)
            guard size >= 8, off + size <= d.count else { break }
            if type == 1 || type == 9 || type == 11 {   // 1 JPEG (classic), 9/11 JPEG on newer bodies
                let body = d.subdata(in: (d.startIndex + off + 8)..<(d.startIndex + off + size))
                if body.count > 2, body[body.startIndex] == 0xFF, body[body.startIndex + 1] == 0xD8 { return body }
            }
            off += size
        }
        return SonyCamera.extractJPEG(d)   // fallback: search for the SOI marker
    }

    // MARK: Capture

    /// Half press (AF), full press, release, then wait for ObjectAddedEx and download from RAM.
    func capture(progress: ((String) -> Void)? = nil) async throws -> [CapturedObject] {
        _ = try? await pollEvents()
        try await ensureOneShotAF()
        objectAdded.reset()
        let countBefore = pendingCount
        progress?(String(format: "Releasing shutter… (focus mode %@, AE mode %@, shots left %@, destination %@)",
                         currentValue(CanonProp.focusMode).map(String.init) ?? "?", currentValue(CanonProp.aeMode).map(String.init) ?? "?",
                         currentValue(CanonProp.availableShots).map(String.init) ?? "?", currentValue(CanonProp.captureDestination).map(String.init) ?? "?"))
        let (half, _) = try await transport.runWithResponse(CanonOp.remoteReleaseOn, params: [1, 0])
        if !half.ok && half.code != PTP.RC.deviceBusy { throw SonyError.ptp(op: CanonOp.remoteReleaseOn, code: half.code) }
        // Full press answers DeviceBusy while the AF is still working: keep asking for up to 3 s (libgphoto2 does the same)
        var full = PTP.Response(code: PTP.RC.deviceBusy, transactionID: 0, params: [])
        let afStart = Date()
        var attempts = 0
        while Date().timeIntervalSince(afStart) < 3.0 {
            try await Task.sleep(nanoseconds: attempts == 0 ? 300_000_000 : 150_000_000)
            attempts += 1
            (full, _) = try await transport.runWithResponse(CanonOp.remoteReleaseOn, params: [2, 0], quiet: true)
            if full.code != PTP.RC.deviceBusy { break }
            _ = try? await pollEvents()
        }
        progress?(String(format: "Full press after %d attempt(s): %@", attempts, full.codeHex))
        _ = try? await transport.runWithResponse(CanonOp.remoteReleaseOff, params: [2], quiet: true)
        _ = try? await transport.runWithResponse(CanonOp.remoteReleaseOff, params: [1], quiet: true)
        if full.code == PTP.RC.deviceBusy {
            // Still busy. Second route used by libgphoto2 in live view: explicit DoAf, then the full press again
            progress?("AF did not lock via half press, trying DoAf")
            let (af, _) = try await transport.runWithResponse(0x9154, params: [])
            try await Task.sleep(nanoseconds: 800_000_000)
            _ = try? await pollEvents()
            let (f2, _) = try await transport.runWithResponse(CanonOp.remoteReleaseOn, params: [2, 0])
            let (off2, _) = try await transport.runWithResponse(CanonOp.remoteReleaseOff, params: [2])
            _ = try? await transport.runWithResponse(0x9160, params: [], quiet: true)   // AfCancel
            progress?(String(format: "DoAf %@, full press %@, release %@", af.codeHex, f2.codeHex, off2.codeHex))
            if !f2.ok { throw SonyError.noImage }   // the manager shows "no focus" for this
        } else if !full.ok {
            throw SonyError.ptp(op: CanonOp.remoteReleaseOn, code: full.code)
        }

        progress?("Waiting for the image…")
        let start = Date()
        while Date().timeIntervalSince(start) < 35 {
            _ = objectAdded.consume()
            _ = try await pollEvents()
            if pendingCount > countBefore { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard pendingCount > countBefore else { throw SonyError.timeout("no image announced") }
        // RAW+JPEG: the second object follows shortly after the first
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await pollEvents()
        return try await fetchObjects(progress: progress)
    }

    /// Downloads every announced object, frees it in the camera (TransferComplete) and returns them.
    func fetchObjects(progress: ((String) -> Void)? = nil) async throws -> [CapturedObject] {
        var objects: [CapturedObject] = []
        while let obj = popPending() {
            progress?("Fetching \(obj.filename)…")
            let data = try await transport.run(PTP.Op.getObject, params: [obj.handle])
            _ = try? await transport.runWithResponse(CanonOp.transferComplete, params: [obj.handle], quiet: true)
            guard data.count > 1000 else { continue }
            let captured = CapturedObject(data: data, format: obj.format, filename: obj.filename)
            if captured.isRAW { sawRAWObject = true }
            objects.append(captured)
            progress?(String(format: "Received: %@ format 0x%04X (%d KB)", obj.filename, obj.format, data.count / 1024))
        }
        guard !objects.isEmpty else { throw SonyError.noImage }
        return objects
    }

    func hasPendingObject() async throws -> Bool {
        _ = try await pollEvents()
        return pendingCount > 0
    }

    private var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    private func popPending() -> CanonPendingObject? {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func batteryPercent() -> Int? {
        if let b = batteryPct { return b }
        // Fallback: EOS BatteryPower levels (0 empty … 3 full)
        if let v = currentValue(CanonProp.batteryPower), (0...3).contains(v) { return Int(v) * 33 }
        return nil
    }

    func capabilitiesReport() -> String {
        lock.lock()
        var desc: [UInt16: SonyPropDesc] = [:]
        for (code, p) in props {
            desc[code] = SonyPropDesc(code: code, dataType: PTP.DTC.uint32, getSet: p.choices.count > 1 ? 1 : 0, isEnabled: 1,
                                      defaultValue: nil, currentValue: p.value, enumValues: p.choices)
        }
        let count = props.count
        lock.unlock()
        return CapabilityReport.build(deviceInfo: deviceInfo, protocolLine: "Canon EOS driver, \(count) properties from the event stream (0x9116)",
                                      vendorProps: [], controlCodes: [], props: desc, rawDumps: rawDumps)
    }

    // MARK: Events and properties

    /// One GetEvent round. Returns the number of records seen.
    @discardableResult
    private func pollEvents(dumpAs: String? = nil) async throws -> Int {
        let (resp, data) = try await transport.runWithResponse(CanonOp.getEvent, quiet: true)
        lastEventPoll = Date()
        guard resp.ok else { throw SonyError.ptp(op: CanonOp.getEvent, code: resp.code) }
        if let name = dumpAs { dump(name, data) }
        return parseEvents(data)
    }

    private func parseEvents(_ d: Data) -> Int {
        var off = 0
        var n = 0
        var newObjects: [CanonPendingObject] = []
        var changes: [(UInt16, CanonPropState)] = []
        var lists: [(UInt16, [Int64])] = []
        while off + 8 <= d.count {
            let size = Int(d.readLE(UInt32.self, at: off))
            let type = d.readLE(UInt32.self, at: off + 4)
            guard size >= 8, off + size <= d.count else { break }
            if type == 0 { break }
            n += 1
            eventRecordCounts[type, default: 0] += 1
            let rec = d.subdata(in: (d.startIndex + off)..<(d.startIndex + off + size))
            switch UInt16(truncatingIfNeeded: type) {
            case CanonEvent.propValueChanged where size >= 12:
                let code = UInt16(truncatingIfNeeded: rec.readLE(UInt32.self, at: 8))
                var st = CanonPropState()
                if size == 16 { st.value = Int64(rec.readLE(UInt32.self, at: 12)) }
                else { st.raw = rec.subdata(in: (rec.startIndex + 12)..<rec.endIndex) }
                changes.append((code, st))
            case CanonEvent.availListChanged where size >= 20:
                let code = UInt16(truncatingIfNeeded: rec.readLE(UInt32.self, at: 8))
                let count = Int(rec.readLE(UInt32.self, at: 16))
                var vals: [Int64] = []
                var p = 20
                for _ in 0..<count where p + 4 <= rec.count { vals.append(Int64(rec.readLE(UInt32.self, at: p))); p += 4 }
                lists.append((code, vals))
            case CanonEvent.objectAddedEx where size >= 36, CanonEvent.objectAddedEx64 where size >= 40:
                let is64 = UInt16(truncatingIfNeeded: type) == CanonEvent.objectAddedEx64
                let handle = rec.readLE(UInt32.self, at: 8)
                let format = rec.readLE(UInt16.self, at: 20)
                let objSize = is64 ? UInt32(truncatingIfNeeded: rec.readLE(UInt64.self, at: 28)) : rec.readLE(UInt32.self, at: 28)
                let name = Self.cString(rec.subdata(in: (rec.startIndex + (is64 ? 36 : 32))..<rec.endIndex))
                if rawDumps.filter({ $0.name.hasPrefix("Canon ObjectAddedEx") }).count < 4 { dump("Canon ObjectAddedEx event", rec) }
                newObjects.append(CanonPendingObject(handle: handle, format: format, size: objSize, filename: name.isEmpty ? String(format: "IMG_%08X.JPG", handle) : name))
            default:
                break
            }
            off += size
        }
        lock.lock()
        for (code, st) in changes {
            var cur = props[code] ?? CanonPropState()
            if let v = st.value { cur.value = v }
            if let r = st.raw { cur.raw = r }
            props[code] = cur
        }
        for (code, vals) in lists {
            var cur = props[code] ?? CanonPropState()
            cur.choices = vals
            props[code] = cur
        }
        pending.append(contentsOf: newObjects)
        lock.unlock()
        if !newObjects.isEmpty {
            objectAdded.fire()
            for o in newObjects { logHandler?(String(format: "Canon: object announced %@ handle 0x%08X format 0x%04X %d KB", o.filename, o.handle, o.format, Int(o.size) / 1024)) }
        }
        return n
    }

    /// SetDevicePropValueEx: u32 total size, u32 property code, u32 value.
    private func setValueEx(_ code: UInt16, value: UInt32) async throws {
        var d = Data()
        d.appendLE(UInt32(12)); d.appendLE(UInt32(code)); d.appendLE(value)
        try await transport.run(CanonOp.setDevicePropValueEx, dataOut: d)
    }

    /// Standard BatteryLevel 0x5001 via GetDevicePropDesc: u16 code, u16 type, u8 getset, default, current, …
    private func readBattery() async {
        lastBatteryRead = Date()
        guard deviceInfo.properties.contains(CanonProp.batteryLevel) else { return }
        guard let (resp, d) = try? await transport.runWithResponse(PTP.Op.getDevicePropDesc, params: [UInt32(CanonProp.batteryLevel)], quiet: true),
              resp.ok, d.count >= 7 else { return }
        let dtc = d.readLE(UInt16.self, at: 2)
        var off = 5
        _ = PTP.readValue(d, type: dtc, at: &off)
        if let cur = PTP.readValue(d, type: dtc, at: &off), (0...100).contains(cur) { batteryPct = Int(cur) }
    }

    static func cString(_ d: Data) -> String {
        let bytes = d.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// ImageFormat 0xD120: u32 count, then per entry four u32 (size, type, quality, compression); type 6 = RAW.
    static func imageFormatHasRAW(_ raw: Data?) -> Bool {
        guard let d = raw, d.count >= 4 else { return false }
        let n = Int(d.readLE(UInt32.self, at: 0))
        for i in 0..<min(n, 4) {
            let p = 4 + i * 16
            guard p + 8 <= d.count else { break }
            if d.readLE(UInt32.self, at: p + 4) == 6 { return true }
        }
        return false
    }
}

// MARK: - Labels (EOS code tables, after libgphoto2 canon_*_table)

enum CanonFormat {
    static let wanted: [(code: UInt16, title: String)] = [
        (CanonProp.aeMode, String(localized: "Program")),
        (CanonProp.iso, "ISO"),
        (CanonProp.aperture, String(localized: "Aperture")),
        (CanonProp.shutterSpeed, String(localized: "Shutter speed")),
        (CanonProp.expCompensation, String(localized: "Exposure compensation")),
        (CanonProp.whiteBalance, String(localized: "White balance")),
        (CanonProp.focusMode, String(localized: "Focus")),
        (CanonProp.driveMode, String(localized: "Drive mode")),
        (CanonProp.captureDestination, String(localized: "Save destination")),
    ]

    static let aeModes: [Int64: String] = [
        0: "P", 1: "Tv", 2: "Av", 3: "M", 4: "Bulb", 5: "A-DEP", 6: "DEP", 7: "C", 8: "Lock", 9: String(localized: "Auto"),
        10: String(localized: "Night portrait"), 11: String(localized: "Sports"), 12: String(localized: "Portrait"),
        13: String(localized: "Landscape"), 14: String(localized: "Close-up"), 15: String(localized: "Flash off"),
        19: String(localized: "Creative Auto"), 20: String(localized: "Movie"), 22: String(localized: "Scene"),
        0x13: String(localized: "Creative Auto"), 0x16: String(localized: "Scene intelligent auto"),
    ]
    static let whiteBalances: [Int64: String] = [
        0: String(localized: "Auto"), 1: String(localized: "Daylight"), 2: String(localized: "Cloudy"), 3: String(localized: "Tungsten"),
        4: String(localized: "Fluorescent"), 5: String(localized: "Flash"), 6: String(localized: "Manual"), 8: String(localized: "Shade"),
        9: String(localized: "Color temperature"), 10: "PC-1", 11: "PC-2", 12: "PC-3", 15: String(localized: "Manual 2"),
        16: String(localized: "Manual 3"), 18: String(localized: "Manual 4"), 19: String(localized: "Manual 5"),
        20: "PC-4", 21: "PC-5", 23: String(localized: "Auto (white priority)"),
    ]
    static let driveModes: [Int64: String] = [
        0: String(localized: "Single"), 1: String(localized: "Continuous"), 2: String(localized: "Video"), 3: String(localized: "Continuous (high)"),
        4: String(localized: "Continuous (high)"), 5: String(localized: "Continuous (low)"), 6: String(localized: "Single silent"),
        7: String(localized: "Timer 10 s + continuous"), 16: String(localized: "Timer 10 s"), 17: String(localized: "Timer 2 s"),
        18: String(localized: "Continuous (super high)"), 19: String(localized: "Single silent"), 20: String(localized: "Continuous silent"),
    ]
    static let focusModes: [Int64: String] = [0: "One-Shot AF", 1: "Servo AF", 2: "AI Focus", 3: String(localized: "Manual")]
    static let destinations: [Int64: String] = [1: String(localized: "Camera"), 2: String(localized: "Memory card"), 4: String(localized: "App (RAM)"), 6: String(localized: "Card + app")]

    static let apertures: [Double] = [1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32, 36, 40, 45, 51, 57, 64]
    static let denominators: [Double] = [1, 1.3, 1.6, 2, 2.5, 3, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 45, 50, 60, 80, 90, 100, 125, 160, 180, 200, 250, 320, 350, 400, 500, 640, 750, 800, 1000, 1250, 1500, 1600, 2000, 2500, 3000, 3200, 4000, 5000, 6000, 6400, 8000, 10000, 12800, 16000]
    static let seconds: [Double] = [1, 1.3, 1.5, 1.6, 2, 2.5, 3, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]
    static let isos: [Double] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400, 204800]

    private static func snap(_ x: Double, to list: [Double]) -> Double {
        list.min { abs($0 - x) < abs($1 - x) } ?? x
    }

    static func label(code: UInt16, value v: Int64) -> String {
        switch code {
        case CanonProp.aperture:
            // f = 2^((v - 8) / 16): 0x30 -> 5.6, 0x38 -> 8
            if v == 0xFF || v == 0 { return "—" }
            let f = snap(pow(2, Double(v - 8) / 16), to: apertures)
            return f < 10 ? String(format: "f/%.1f", f) : String(format: "f/%.0f", f)
        case CanonProp.shutterSpeed:
            // t = 2^-((v - 0x38) / 8) seconds: 0x38 -> 1", 0x70 -> 1/125
            if v == 0x0C { return "Bulb" }
            if v == 0x04 || v == 0 { return "Auto" }
            let t = pow(2, -Double(v - 0x38) / 8)
            if t >= 0.95 {
                let s = snap(t, to: seconds)
                return s == s.rounded() ? String(format: "%.0f\"", s) : String(format: "%.1f\"", s)
            }
            return String(format: "1/%.0f", snap(1 / t, to: denominators))
        case CanonProp.iso:
            // ISO = 100 * 2^((v - 0x48) / 8): 0x48 -> 100, 0x60 -> 800
            if v == 0 { return "Auto" }
            return String(format: "%.0f", snap(100 * pow(2, Double(v - 0x48) / 8), to: isos))
        case CanonProp.expCompensation:
            // signed byte in 1/8 EV: 0x03 -> +1/3, 0xFD -> -1/3
            let ev = Double(Int8(truncatingIfNeeded: v)) / 8
            return ev == 0 ? "0" : String(format: "%+.1f", ev)
        case CanonProp.aeMode: return aeModes[v] ?? "0x\(String(v, radix: 16))"
        case CanonProp.whiteBalance: return whiteBalances[v] ?? "\(v)"
        case CanonProp.driveMode: return driveModes[v] ?? "\(v)"
        case CanonProp.focusMode: return focusModes[v] ?? "\(v)"
        case CanonProp.captureDestination: return destinations[v] ?? "\(v)"
        default: return "\(v)"
        }
    }
}
