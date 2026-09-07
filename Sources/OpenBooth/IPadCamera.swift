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
    private var frameSkip = 0
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
    func start(front: Bool, onFrame: @escaping (UIImage) -> Void) throws {
        position = front ? .front : .back
        frameHandler = onFrame
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ?? AVCaptureDevice.default(for: .video) else {
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
        session.commitConfiguration()
        if let c = video.connection(with: .video) { c.isVideoMirrored = false }
        applyRotation()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        queue.async { [session] in session.startRunning() }
    }

    /// Adapt image rotation to the iPad's orientation (landscape left or right), for live view and photo.
    @objc private func orientationChanged() { applyRotation() }
    private func applyRotation() {
        let angle: CGFloat
        switch UIDevice.current.orientation {
        case .landscapeLeft: angle = 0        // USB-C rechts
        case .landscapeRight: angle = 180     // USB-C links
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
    func capture() async throws -> CapturedObject {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.photoContinuation = cont
                let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                s.photoQualityPrioritization = .quality
                self.photo.capturePhoto(with: s, delegate: self)
            }
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return CapturedObject(data: data, format: 0x3801, filename: "IPAD-\(f.string(from: Date())).JPG")
    }
}

extension IPadCamera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // every 2nd frame (~15 fps) is enough for the live view, saves CPU
        frameSkip += 1
        if frameSkip % 2 == 0 { return }
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
        guard let cont = photoContinuation else { return }
        photoContinuation = nil
        if let error { cont.resume(throwing: error); return }
        guard let data = photo.fileDataRepresentation() else {
            cont.resume(throwing: NSError(domain: "IPadCamera", code: 3, userInfo: [NSLocalizedDescriptionKey: "No image from the iPad camera"])); return
        }
        // Photo stays unmirrored, like a camera photo (the Sony does not mirror either)
        cont.resume(returning: data)
    }

}
