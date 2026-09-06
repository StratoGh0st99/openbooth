//
//  IPadCamera.swift
//  OpenBooth
//
//  Ersatzkamera: Front- oder Rueckkamera des iPads ueber AVFoundation, wenn keine Kamera per USB da ist.
//  Liefert Liveview-Bilder als UIImage (wie die Sony) und JPEG-Aufnahmen als CapturedObject.
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

    /// Kamera oeffnen; `front` = Frontkamera (zeigt zu den Gaesten, wenn das iPad im Gehaeuse steckt).
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

    /// Bilddrehung an die Lage des iPads anpassen (Querformat links oder rechts), fuer Liveview und Foto.
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

    /// Foto als JPEG (volle Aufloesung der iPad-Kamera).
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
        // ~15 Bilder/s reichen fuer den Liveview, spart Rechenzeit
        frameSkip += 1
        if frameSkip % 2 == 0 { return }
        guard let handler = frameHandler, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        // Querformat-Orientierung: Landscape-Right (Home-Button rechts) entspricht der Fotobox-Aufstellung
        let ctx = Self.ciContext
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        // nicht spiegeln: die Spiegelung fuer die Gaeste macht die Buehne (Einstellung "Mirror live view"), wie bei der Sony
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
        // Foto bleibt ungespiegelt, wie ein Kamerafoto (die Sony spiegelt auch nicht)
        cont.resume(returning: data)
    }

}
