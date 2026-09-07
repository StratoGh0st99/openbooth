//
//  CameraDriver.swift
//  OpenBooth
//
//  Common interface for camera protocols. SonyCamera implements the Sony PC Remote protocol; GenericPTPCamera handles
//  any other PTP camera: it can probe and write the capability report, but offers no remote control yet. Driver
//  selection happens after GetDeviceInfo based on the vendor extension ID.
//

import Foundation
import ImageCaptureCore

protocol CameraDriver: AnyObject {
    var transport: PTPTransport { get }
    var deviceInfo: PTP.DeviceInfo { get }
    /// Fired by the PTP event delegate when the camera reports a new object (image ready).
    var objectAdded: EventSignal { get }
    /// Vendor event codes that mean "new object" (Sony 0xC201, Canon 0xC181, standard PTP 0x4002)
    var objectAddedEventCodes: Set<UInt16> { get }
    /// false = probe and report only, no live view, capture or settings
    var supportsRemoteControl: Bool { get }
    /// One line for the log after a successful connect
    var connectSummary: String { get }
    /// Vendor-specific property and control code counts for the capability log line (0 when unknown)
    var vendorPropertyCount: Int { get }
    var controlCodeCount: Int { get }
    /// Does the camera currently deliver RAW files?
    var deliversRAW: Bool { get }

    func probe() async throws -> PTP.DeviceInfo
    func connect() async throws
    func refreshProps() async throws
    func currentValue(_ code: UInt16) -> Int64?
    func settings() -> [CameraSetting]
    func setSetting(_ code: UInt16, to target: Int64, log: ((String) -> Void)?) async throws
    func liveViewFrame() async throws -> Data?
    func capture(progress: ((String) -> Void)?) async throws -> [CapturedObject]
    func fetchObjects(progress: ((String) -> Void)?) async throws -> [CapturedObject]
    func hasPendingObject() async throws -> Bool
    func batteryPercent() -> Int?
    func capabilitiesReport() -> String
}

enum CameraDriverError: LocalizedError {
    case unsupported(vendor: String)
    case notAvailable(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let v): return "Camera recognized, but its protocol (\(v)) is not supported yet. Please send diagnostics."
        case .notAvailable(let what): return "\(what) is not available for this camera"
        }
    }
}

/// PTP vendor extension IDs (ISO 15740 / libgphoto2)
enum PTPVendor {
    static let sony: UInt32 = 0x11
    static let canon: UInt32 = 0xB
    static let nikon: UInt32 = 0xA
    static let fuji: UInt32 = 0x1A   // Fujifilm uses 0x0A with its own desc on some bodies; kept informational
    static func name(_ id: UInt32, desc: String) -> String {
        switch id {
        case sony: return "Sony"
        case canon: return "Canon"
        case nikon: return "Nikon"
        default: return desc.isEmpty ? String(format: "vendor 0x%X", id) : desc
        }
    }
}

/// Picks the driver for a probed camera. Sony gets the full PC Remote implementation, everything else the generic one.
enum CameraDrivers {
    static func make(for info: PTP.DeviceInfo, transport: PTPTransport) -> CameraDriver {
        let desc = info.vendorExtensionDesc.lowercased() + " " + info.manufacturer.lowercased()
        if info.vendorExtensionID == PTPVendor.sony || desc.contains("sony") {
            return SonyCamera(transport: transport, deviceInfo: info)
        }
        return GenericPTPCamera(transport: transport, deviceInfo: info)
    }
}

/// Any PTP camera we do not control yet: GetDeviceInfo works, the capability report is written, the rest is refused
/// with a clear message. Its report is what a tester sends us to build a real driver.
final class GenericPTPCamera: CameraDriver {
    let transport: PTPTransport
    private(set) var deviceInfo: PTP.DeviceInfo
    let objectAdded = EventSignal()
    var objectAddedEventCodes: Set<UInt16> { [0x4002] }
    var supportsRemoteControl: Bool { false }
    var deliversRAW: Bool { false }
    var vendorPropertyCount: Int { 0 }
    var controlCodeCount: Int { 0 }
    private(set) var rawDumps: [(name: String, data: Data)] = []

    init(transport: PTPTransport, deviceInfo: PTP.DeviceInfo) {
        self.transport = transport
        self.deviceInfo = deviceInfo
    }

    var vendorName: String { PTPVendor.name(deviceInfo.vendorExtensionID, desc: deviceInfo.vendorExtensionDesc) }
    var connectSummary: String { "Probe OK: \(deviceInfo.manufacturer) \(deviceInfo.model), \(vendorName), \(deviceInfo.operations.count) operations, no driver" }

    func probe() async throws -> PTP.DeviceInfo {
        let data = try await transport.run(PTP.Op.getDeviceInfo)
        rawDumps = [("GetDeviceInfo 0x1001", data)]
        deviceInfo = PTP.parseDeviceInfo(data)
        return deviceInfo
    }
    func connect() async throws { throw CameraDriverError.unsupported(vendor: vendorName) }
    func refreshProps() async throws {}
    func currentValue(_ code: UInt16) -> Int64? { nil }
    func settings() -> [CameraSetting] { [] }
    func setSetting(_ code: UInt16, to target: Int64, log: ((String) -> Void)?) async throws { throw CameraDriverError.notAvailable("Setting") }
    func liveViewFrame() async throws -> Data? { nil }
    func capture(progress: ((String) -> Void)?) async throws -> [CapturedObject] { throw CameraDriverError.notAvailable("Capture") }
    func fetchObjects(progress: ((String) -> Void)?) async throws -> [CapturedObject] { throw CameraDriverError.notAvailable("Fetch") }
    func hasPendingObject() async throws -> Bool { false }
    func batteryPercent() -> Int? { nil }
    func capabilitiesReport() -> String {
        CapabilityReport.build(deviceInfo: deviceInfo, protocolLine: "Driver: none (\(vendorName))", vendorProps: [], controlCodes: [], props: [:], rawDumps: rawDumps)
    }
}
