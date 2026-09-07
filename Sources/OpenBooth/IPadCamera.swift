//
//  IPadCamera.swift
//  OpenBooth
//
//  Fallback camera: front or rear camera of the iPad via AVFoundation when no USB camera is present.
//  Delivers live view frames as UIImage (like the Sony) and JPEG captures as CapturedObject.
//

import AVFoundation
import UIKit

final class IPadCamera: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "openbooth.ipadcam")
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private var frameHandler: ((UIImage) -> Void)?
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private(set) var position: AVCaptureDevice.Position = .front
    var running: Bool { session.isRunning }

    static func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Open the camera; `front` = front camera (faces the guests when the iPad sits in the enclosure).
    private(set) var ultraWide = false
    func start(front: Bool, ultraWide: Bool, onFrame: @escaping (UIImage) -> Void) throws {
        position = front ? .front : .back
        self.ultraWide = ultraWide
        frameHandler = onFrame
        session.beginConfiguration()
        // inputPriority: we pick the device format ourselves (30 fps video + full-size photos), see pickFormat()
        session.sessionPreset = .inputPriority
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        // Lens per setting: ultra wide (more megapixels on the iPad Air front, wider view) or the standard wide angle
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera]
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        deviceList = discovered.map { d in
            let px = d.formats.compactMap { $0.supportedMaxPhotoDimensions.last }.map { Int($0.width) * Int($0.height) }.max() ?? 0
            return "\(d.localizedName) [\(d.deviceType.rawValue)] max \(px / 1_000_000) MP"
        }
        let wanted: AVCaptureDevice.DeviceType = ultraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera
        let pick = discovered.first { $0.deviceType == wanted } ?? discovered.first
        guard let dev = pick ?? AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw NSError(domain: "IPadCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "No iPad camera found"])
        }
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { session.commitConfiguration(); throw NSError(domain: "IPadCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Camera not usable"]) }
        session.addInput(input)
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(video) { session.addOutput(video) }
        if session.canAddOutput(photo) { session.addOutput(photo) }
        photo.maxPhotoQualityPrioritization = .quality
        pickFormat(dev)
        session.commitConfiguration()
        if let c = video.connection(with: .video) { c.isVideoMirrored = false }
        applyRotation()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        queue.async { [session] in session.startRunning() }
    }

    /// Format with at least 30 fps video and the largest photo size: smooth live view, full-resolution photos.
    private(set) var deviceList: [String] = []
    private func pickFormat(_ dev: AVCaptureDevice) {
        var best: AVCaptureDevice.Format?
        var bestPhoto = 0
        for f in dev.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width >= 1280, f.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 30 }) else { continue }
            let photoDims = f.supportedMaxPhotoDimensions.last ?? dims
            let px = Int(photoDims.width) * Int(photoDims.height)
            // prefer the largest photo size; among equals the smallest video size (cheaper to process)
            if px > bestPhoto || (px == bestPhoto && best.map({ dims.width < CMVideoFormatDescriptionGetDimensions($0.formatDescription).width }) == true) {
                best = f; bestPhoto = px
            }
        }
        guard let f = best else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = f
            // 15 fps is plenty for the guest live view (the Sony delivers ~24) and halves the work
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
            dev.unlockForConfiguration()
            if let pd = f.supportedMaxPhotoDimensions.last { photo.maxPhotoDimensions = pd }
            let vd = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            formatSummary = "video \(vd.width)x\(vd.height) @15, photo \(photo.maxPhotoDimensions.width)x\(photo.maxPhotoDimensions.height)"
        } catch {}
    }
    private(set) var formatSummary = ""

    /// Adapt image rotation to the iPad's orientation (landscape left or right), for live view and photo.
    @objc private func orientationChanged() { applyRotation() }
    private func applyRotation() {
        let angle: CGFloat
        switch UIDevice.current.orientation {
        case .landscapeLeft: angle = 0        // USB-C on the right
        case .landscapeRight: angle = 180     // USB-C on the left
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        default: angle = lastAngle
        }
        lastAngle = angle
        for c in [video.connection(with: .video), photo.connection(with: .video)].compactMap({ $0 }) {
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
    }
    private var lastAngle: CGFloat = 0

    func stop() {
        NotificationCenter.default.removeObserver(self)
        frameHandler = nil
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    /// Photo as JPEG (full resolution of the iPad camera).
    private var photoID = 0
    func capture() async throws -> CapturedObject {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.session.isRunning, self.photoContinuation == nil else {
                    cont.resume(throwing: NSError(domain: "IPadCamera", code: 4, userInfo: [NSLocalizedDescriptionKey: "iPad camera not running"])); return
                }
                self.photoID += 1
                let id = self.photoID
                self.photoContinuation = cont
                let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                s.photoQualityPrioritization = .quality
                s.maxPhotoDimensions = self.photo.maxPhotoDimensions   // otherwise iOS captures at the video size
                self.photo.capturePhoto(with: s, delegate: self)
                // Safety net: never leave the capture flow hanging if the delegate is not called
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard self.photoID == id, let c = self.photoContinuation else { return }
                    self.photoContinuation = nil
                    c.resume(throwing: NSError(domain: "IPadCamera", code: 5, userInfo: [NSLocalizedDescriptionKey: "Timeout: iPad camera delivered no photo"]))
                }
            }
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return CapturedObject(data: data, format: 0x3801, filename: "IPAD-\(f.string(from: Date())).JPG")
    }
}

extension IPadCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let handler = frameHandler, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ci = CIImage(cvPixelBuffer: pb)
        // The .photo preset delivers ~12 MP frames; scale to ~1600 px wide before rendering, that is all the live view needs
        let scale = min(1, 1600 / max(1, ci.extent.width))
        if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        let ctx = Self.ciContext
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        // do not mirror: the stage mirrors for the guests ("Mirror live view" setting), same as with the Sony
        handler(UIImage(cgImage: cg, scale: 1, orientation: .up))
    }
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async {
            guard let cont = self.photoContinuation else { return }
            self.photoContinuation = nil
            if let error { cont.resume(throwing: error); return }
            guard let data else {
                cont.resume(throwing: NSError(domain: "IPadCamera", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image from the iPad camera"])); return
            }
            // Photo stays unmirrored, like a camera photo (the Sony does not mirror either)
            cont.resume(returning: data)
        }
    }

}
