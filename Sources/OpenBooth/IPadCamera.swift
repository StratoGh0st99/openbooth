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
            throw NSError(domain: "IPadCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine iPad-Kamera gefunden"])
        }
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { session.commitConfiguration(); throw NSError(domain: "IPadCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kamera nicht nutzbar"]) }
        session.addInput(input)
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(video) { session.addOutput(video) }
        if session.canAddOutput(photo) { session.addOutput(photo) }
        photo.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()
        if let c = video.connection(with: .video) {
            if #available(iOS 17, *) { if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 } }
            c.isVideoMirrored = false
        }
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
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
                if let c = self.photo.connection(with: .video), #available(iOS 17, *), c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }
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
        handler(UIImage(cgImage: cg, scale: 1, orientation: position == .front ? .downMirrored : .up))
    }
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let cont = photoContinuation else { return }
        photoContinuation = nil
        if let error { cont.resume(throwing: error); return }
        guard var data = photo.fileDataRepresentation() else {
            cont.resume(throwing: NSError(domain: "IPadCamera", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kein Bild von der iPad-Kamera"])); return
        }
        // Frontkamera spiegeln, damit das Foto so aussieht wie der Liveview
        if position == .front, let img = UIImage(data: data), let cg = img.cgImage {
            let m = UIImage(cgImage: cg, scale: 1, orientation: Self.mirrored(img.imageOrientation))
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let flat = UIGraphicsImageRenderer(size: m.size, format: fmt).image { _ in m.draw(at: .zero) }
            if let d = flat.jpegData(compressionQuality: 0.92) { data = d }
        }
        cont.resume(returning: data)
    }
    private static func mirrored(_ o: UIImage.Orientation) -> UIImage.Orientation {
        switch o { case .up: .upMirrored; case .down: .downMirrored; case .left: .rightMirrored; case .right: .leftMirrored
        case .upMirrored: .up; case .downMirrored: .down; case .leftMirrored: .right; case .rightMirrored: .left; @unknown default: o }
    }
}
