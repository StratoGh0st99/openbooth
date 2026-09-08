//
//  Capabilities.swift
//  OpenBooth
//
//  Camera capabilities as a readable report: standard operations, events, properties from DeviceInfo,
//  Sony vendor properties and control codes from 0x9202, plus all 0x9209 properties with type, value and choices.
//

import Foundation
import UIKit

enum PTPNames {
    static let operations: [UInt16: String] = [
        0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession", 0x1004: "GetStorageIDs", 0x1005: "GetStorageInfo",
        0x1006: "GetNumObjects", 0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo", 0x1009: "GetObject", 0x100A: "GetThumb",
        0x100B: "DeleteObject", 0x100C: "SendObjectInfo", 0x100D: "SendObject", 0x100E: "InitiateCapture", 0x100F: "FormatStore",
        0x1010: "ResetDevice", 0x1011: "SelfTest", 0x1012: "SetObjectProtection", 0x1013: "PowerDown", 0x1014: "GetDevicePropDesc",
        0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue", 0x1017: "ResetDevicePropValue", 0x1018: "TerminateOpenCapture",
        0x1019: "MoveObject", 0x101A: "CopyObject", 0x101B: "GetPartialObject", 0x101C: "InitiateOpenCapture",
        0x9201: "Sony SDIOConnect", 0x9202: "Sony GetExtDeviceInfo", 0x9203: "Sony GetDevicePropDesc", 0x9204: "Sony GetDevicePropValue",
        0x9205: "Sony SetExtDevicePropValue (ControlDeviceA)", 0x9206: "Sony GetControlDeviceDesc", 0x9207: "Sony ControlDevice (ControlDeviceB)",
        0x9208: "Sony SDIO 0x9208", 0x9209: "Sony GetAllExtDevicePropInfo", 0x920A: "Sony SDIO 0x920A",
        0x920B: "Sony SDIO 0x920B", 0x920C: "Sony SDIO 0x920C", 0x920D: "Sony SDIO 0x920D", 0x920E: "Sony SDIO 0x920E",
        0x920F: "Sony SDIO 0x920F", 0x9210: "Sony SDIO 0x9210", 0x9211: "Sony SDIO 0x9211", 0x9212: "Sony SDIO 0x9212",
        0x9213: "Sony SDIO 0x9213", 0x9214: "Sony SDIO 0x9214", 0x9215: "Sony SDIO 0x9215", 0x9216: "Sony SDIO 0x9216",
        0x9217: "Sony SDIO 0x9217", 0x9218: "Sony SDIO 0x9218", 0x9219: "Sony SDIO 0x9219", 0x921A: "Sony SDIO 0x921A",
        0x921B: "Sony SDIO 0x921B", 0x921C: "Sony SDIO 0x921C", 0x921D: "Sony SDIO 0x921D", 0x921E: "Sony SDIO 0x921E",
    ]
    static let events: [UInt16: String] = [
        0x4001: "CancelTransaction", 0x4002: "ObjectAdded", 0x4003: "ObjectRemoved", 0x4004: "StoreAdded", 0x4005: "StoreRemoved",
        0x4006: "DevicePropChanged", 0x4007: "ObjectInfoChanged", 0x4008: "DeviceInfoChanged", 0x4009: "RequestObjectTransfer",
        0x400A: "StoreFull", 0x400B: "DeviceReset", 0x400C: "StorageInfoChanged", 0x400D: "CaptureComplete",
        0xC201: "Sony ObjectAdded", 0xC202: "Sony ObjectRemoved", 0xC203: "Sony PropertyChanged", 0xC204: "Sony 0xC204",
        0xC205: "Sony 0xC205", 0xC206: "Sony 0xC206", 0xC207: "Sony 0xC207", 0xC208: "Sony 0xC208",
    ]
    static let properties: [UInt16: String] = [
        0x5001: "BatteryLevel", 0x5003: "ImageSize", 0x5004: "CompressionSetting", 0x5005: "WhiteBalance", 0x5007: "FNumber",
        0x5008: "FocalLength", 0x500A: "FocusMode", 0x500B: "ExposureMeteringMode", 0x500C: "FlashMode", 0x500D: "ExposureTime",
        0x500E: "ExposureProgramMode", 0x500F: "ExposureIndex", 0x5010: "ExposureBiasCompensation", 0x5013: "StillCaptureMode",
        0x5015: "Sharpness", 0x5016: "DigitalZoom", 0x5018: "BurstNumber", 0x501C: "FocusMeteringMode",
        0xD200: "Sony DPCCompensation", 0xD201: "Sony DRangeOptimize", 0xD203: "Sony ImageSize", 0xD20D: "Sony ShutterSpeed",
        0xD20E: "Sony 0xD20E", 0xD20F: "Sony ColorTemp", 0xD210: "Sony CCFilter", 0xD211: "Sony AspectRatio", 0xD212: "Sony 0xD212",
        0xD213: "Sony FocusFound", 0xD214: "Sony Zoom", 0xD215: "Sony ObjectInMemory", 0xD216: "Sony 0xD216", 0xD217: "Sony 0xD217",
        0xD218: "Sony BatteryLevel", 0xD219: "Sony 0xD219", 0xD21A: "Sony 0xD21A", 0xD21B: "Sony PictureEffect", 0xD21C: "Sony ABFilter",
        0xD21D: "Sony 0xD21D", 0xD21E: "Sony ISO", 0xD21F: "Sony 0xD21F", 0xD220: "Sony 0xD220", 0xD221: "Sony LiveViewStatus",
        0xD222: "Sony StillImageStoreDestination", 0xD223: "Sony 0xD223", 0xD224: "Sony 0xD224", 0xD226: "Sony 0xD226",
        0xD22A: "Sony 0xD22A", 0xD22C: "Sony 0xD22C", 0xD231: "Sony LiveViewSettingEffect", 0xD22E: "Sony 0xD22E",
        0xD22F: "Sony 0xD22F", 0xD230: "Sony 0xD230", 0xD232: "Sony 0xD232", 0xD233: "Sony 0xD233", 0xD235: "Sony ExposureCtrlType",
        0xD236: "Sony 0xD236", 0xD238: "Sony 0xD238", 0xD239: "Sony 0xD239", 0xD23A: "Sony 0xD23A", 0xD23B: "Sony 0xD23B",
        0xD23C: "Sony 0xD23C", 0xD23D: "Sony 0xD23D", 0xD23E: "Sony 0xD23E", 0xD23F: "Sony 0xD23F", 0xD240: "Sony 0xD240",
        0xD241: "Sony 0xD241", 0xD242: "Sony 0xD242", 0xD243: "Sony 0xD243", 0xD244: "Sony 0xD244", 0xD245: "Sony 0xD245",
        0xD246: "Sony 0xD246", 0xD247: "Sony 0xD247", 0xD248: "Sony 0xD248", 0xD249: "Sony 0xD249", 0xD24A: "Sony 0xD24A",
        0xD24B: "Sony 0xD24B", 0xD24C: "Sony 0xD24C", 0xD24D: "Sony 0xD24D", 0xD24E: "Sony 0xD24E", 0xD24F: "Sony 0xD24F",
        0xD250: "Sony 0xD250", 0xD251: "Sony 0xD251", 0xD252: "Sony 0xD252", 0xD253: "Sony ImageQuality",
        0xD254: "Sony 0xD254", 0xD255: "Sony 0xD255", 0xD256: "Sony 0xD256", 0xD257: "Sony 0xD257", 0xD258: "Sony 0xD258",
        0xD259: "Sony 0xD259", 0xD25A: "Sony PriorityMode", 0xD25B: "Sony 0xD25B", 0xD25C: "Sony 0xD25C", 0xD25D: "Sony 0xD25D",
        0xD25E: "Sony 0xD25E", 0xD25F: "Sony 0xD25F", 0xD260: "Sony 0xD260", 0xD261: "Sony 0xD261", 0xD262: "Sony 0xD262",
        0xD263: "Sony 0xD263", 0xD264: "Sony 0xD264", 0xD265: "Sony 0xD265", 0xD266: "Sony 0xD266", 0xD267: "Sony 0xD267",
        0xD268: "Sony PcSaveImageSize", 0xD269: "Sony PcSaveImageFormat (transfer to app)", 0xD26A: "Sony 0xD26A",
        0xD2C1: "Sony Ctrl ShutterHalfRelease", 0xD2C2: "Sony Ctrl ShutterRelease", 0xD2C3: "Sony Ctrl AELButton", 0xD2C4: "Sony Ctrl 0xD2C4",
        0xD2C5: "Sony Ctrl 0xD2C5", 0xD2C7: "Sony Ctrl StillImage/Movie", 0xD2C8: "Sony Ctrl Movie", 0xD2C9: "Sony Ctrl FELButton",
        0xD2CB: "Sony Ctrl 0xD2CB", 0xD2CC: "Sony Ctrl 0xD2CC", 0xD2CD: "Sony Ctrl 0xD2CD", 0xD2CE: "Sony Ctrl 0xD2CE",
        0xD2D1: "Sony Ctrl NearFar (manual focus)", 0xD2D2: "Sony Ctrl 0xD2D2", 0xD2D3: "Sony Ctrl 0xD2D3", 0xD2D4: "Sony Ctrl 0xD2D4",
        0xD2DB: "Sony Ctrl Zoom", 0xD2DD: "Sony Ctrl 0xD2DD", 0xD2DE: "Sony Ctrl 0xD2DE", 0xD2E0: "Sony Ctrl 0xD2E0",
    ]
    static let dataTypes: [UInt16: String] = [
        0x0001: "i8", 0x0002: "u8", 0x0003: "i16", 0x0004: "u16", 0x0005: "i32", 0x0006: "u32", 0x0007: "i64", 0x0008: "u64",
        0x4001: "i8[]", 0x4002: "u8[]", 0x4003: "i16[]", 0x4004: "u16[]", 0x4005: "i32[]", 0x4006: "u32[]", 0xFFFF: "str",
    ]
    static func hex(_ v: UInt16) -> String { String(format: "0x%04X", v) }
    static let canonOperations: [UInt16: String] = [
        0x9101: "Canon GetStorageIDs", 0x9102: "Canon GetStorageInfo", 0x9103: "Canon GetObjectInfo", 0x9104: "Canon GetObject",
        0x9107: "Canon GetPartialObjectEx", 0x910F: "Canon EOS Capture (full)", 0x9110: "Canon SetDevicePropValueEx",
        0x9114: "Canon SetRemoteMode", 0x9115: "Canon SetEventMode", 0x9116: "Canon GetEvent", 0x9117: "Canon TransferComplete",
        0x911B: "Canon SetUILock", 0x911C: "Canon ResetUILock", 0x9127: "Canon RequestDevicePropValue",
        0x9128: "Canon RemoteReleaseOn", 0x9129: "Canon RemoteReleaseOff", 0x9153: "Canon GetViewFinderData",
        0x9154: "Canon DoAf", 0x9155: "Canon DriveLens", 0x9158: "Canon Zoom", 0x9160: "Canon AfCancel",
    ]
    static let canonEvents: [UInt16: String] = [
        0xC181: "Canon ObjectAddedEx", 0xC182: "Canon ObjectRemoved", 0xC183: "Canon RequestGetObjectInfoEx",
        0xC184: "Canon StorageStatusChanged", 0xC185: "Canon StorageInfoChanged", 0xC186: "Canon RequestObjectTransfer",
        0xC187: "Canon ObjectInfoChangedEx", 0xC188: "Canon ObjectContentChanged", 0xC189: "Canon PropValueChanged",
        0xC18A: "Canon AvailListChanged", 0xC18B: "Canon CameraStatusChanged", 0xC18D: "Canon WillSoonShutdown",
        0xC18E: "Canon ShutdownTimerUpdated", 0xC18F: "Canon RequestCancelTransfer", 0xC190: "Canon RequestObjectTransferDT",
        0xC191: "Canon RequestCancelTransferDT", 0xC1A1: "Canon RequestObjectTransferFTP", 0xC1A7: "Canon ObjectAddedEx64",
    ]
    static let canonProperties: [UInt16: String] = [
        0xD101: "Canon Aperture", 0xD102: "Canon ShutterSpeed", 0xD103: "Canon ISO", 0xD104: "Canon ExpCompensation",
        0xD105: "Canon AEMode", 0xD106: "Canon DriveMode", 0xD107: "Canon MeteringMode", 0xD108: "Canon FocusMode",
        0xD109: "Canon WhiteBalance", 0xD10A: "Canon ColorTemperature", 0xD10F: "Canon ColorSpace", 0xD110: "Canon PictureStyle",
        0xD111: "Canon BatteryPower", 0xD113: "Canon CameraTime", 0xD115: "Canon Owner", 0xD116: "Canon ModelID",
        0xD11B: "Canon AvailableShots", 0xD11C: "Canon CaptureDestination", 0xD11E: "Canon CurrentStorage", 0xD11F: "Canon CurrentFolder",
        0xD120: "Canon ImageFormat", 0xD1B0: "Canon EVFOutputDevice", 0xD1B3: "Canon EVFMode", 0xD1B9: "Canon ExposureSimMode",
        0xD1C0: "Canon FlashChargingState", 0xD1C6: "Canon BuiltinStroboMode", 0xD1D0: "Canon Artist", 0xD1D1: "Canon Copyright",
        0xD1D8: "Canon LensName", 0xD1DA: "Canon StroboSetting", 0xD1DB: "Canon StroboWirelessSetting", 0xD1DC: "Canon StroboFiring",
        0xD1DD: "Canon LensID", 0xD303: "Canon 0xD303", 0xD402: "MTP DeviceFriendlyName", 0xD406: "MTP SessionInitiatorInfo", 0xD407: "MTP PerceivedDeviceType",
    ]
    /// Canon bodies share the 0x91xx/0xC1xx/0xD1xx ranges only with themselves, so the tables can simply be merged
    static func op(_ v: UInt16) -> String { "\(hex(v)) \(operations[v] ?? canonOperations[v] ?? (v >= 0x9000 ? "Vendor" : "?"))" }
    static func ev(_ v: UInt16) -> String { "\(hex(v)) \(events[v] ?? canonEvents[v] ?? "?")" }
    static func prop(_ v: UInt16) -> String { "\(hex(v)) \(properties[v] ?? canonProperties[v] ?? (v >= 0xD200 ? "Sony" : v >= 0xD100 ? "Canon" : "?"))" }
}

enum CapabilityReport {
    /// Full capability report; generic for every driver.
    static func build(deviceInfo di: PTP.DeviceInfo, protocolLine: String, vendorProps: [UInt16], controlCodes: [UInt16],
                      props: [UInt16: SonyPropDesc], rawDumps: [(name: String, data: Data)]) -> String {
        var out: [String] = []
        out.append("# OpenBooth camera capabilities, \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        out.append("Model: \(di.manufacturer) \(di.model), firmware \(di.deviceVersion), serial \(di.serialNumber)")
        out.append("PTP standard \(di.standardVersion), vendor extension 0x\(String(di.vendorExtensionID, radix: 16)) \(di.vendorExtensionDesc)")
        out.append(protocolLine)
        out.append("")
        out.append("## Operations (\(di.operations.count), from GetDeviceInfo)")
        out += di.operations.sorted().map { "  " + PTPNames.op($0) }
        out.append("")
        out.append("## Events (\(di.events.count))")
        out += di.events.sorted().map { "  " + PTPNames.ev($0) }
        out.append("")
        out.append("## Properties per GetDeviceInfo (\(di.properties.count))")
        out += di.properties.sorted().map { "  " + PTPNames.prop($0) }
        out.append("")
        out.append("## Sony vendor properties from 0x9202 (\(vendorProps.count))")
        out += vendorProps.sorted().map { "  " + PTPNames.prop($0) }
        out.append("")
        out.append("## Sony control codes from 0x9202 (\(controlCodes.count), for ControlDevice 0x9207)")
        out += controlCodes.sorted().map { "  " + PTPNames.prop($0) }
        out.append("")
        out.append("## All properties from 0x9209 with value (\(props.count))")
        for code in props.keys.sorted() {
            let p = props[code]!
            var line = "  \(PTPNames.prop(code))  type=\(PTPNames.dataTypes[p.dataType] ?? PTPNames.hex(p.dataType)) getset=\(p.getSet) enabled=\(p.isEnabled)"
            if let c = p.currentValue { line += " current=\(c) (0x\(String(c, radix: 16)))" }
            if let d = p.defaultValue { line += " default=\(d)" }
            if !p.enumValues.isEmpty {
                let shown = p.enumValues.prefix(40).map(String.init).joined(separator: ",")
                line += " choices[\(p.enumValues.count)]=\(shown)\(p.enumValues.count > 40 ? ",…" : "")"
            }
            out.append(line)
        }
        out.append("")
        out.append("## Raw data (hex, little endian, PTP data phase without container header)")
        for (name, d) in rawDumps {
            out.append("### \(name), \(d.count) bytes")
            out.append(Self.hexDump(d))
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func hexDump(_ d: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](d)
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i..<min(i + 32, bytes.count)]
            lines.append(String(format: "%06X  ", i) + chunk.map { String(format: "%02X", $0) }.joined(separator: " "))
            i += 32
        }
        return lines.joined(separator: "\n")
    }
}

/// Environment for the diagnostics report: iPad, OS, app version, settings without secrets.
enum Diagnostics {
    @MainActor static func environment(_ s: AppSettings?) -> String {
        let dev = UIDevice.current
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var out = ["# OpenBooth diagnostics, \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)) (\(TimeZone.current.identifier))",
                   "App \(v) (\(b)), \(dev.systemName) \(dev.systemVersion), device \(Self.modelIdentifier()), locale \(Locale.current.identifier)"]
        if let s {
            out.append("Settings: autoConnect=\(s.autoConnect) countdown=\(s.countdownSeconds) shots=\(s.shotsPerCapture)/\(s.shotInterval)s result=\(s.resultSeconds)s idle=\(s.idleSeconds)s slideshow=\(s.slideshowInterval)s mirror=\(s.mirrorLiveView) pickupExternal=\(s.pickupExternal) motionWake=\(s.motionWake)/\(s.motionThreshold) saveToPhotos=\(s.saveToPhotos) immich=\(s.immichEnabled)(\(s.immichURL.isEmpty ? "empty" : "set")) webdav=\(s.webdavEnabled)(\(s.webdavURL.isEmpty ? "empty" : "set")) sounds=\(s.soundsEnabled) maxBrightness=\(s.maxBrightness) debug=\(s.debugMode)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func modelIdentifier() -> String {
        var sys = utsname(); uname(&sys)
        return withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }
}
