import AVFoundation
import CoreImage
import UIKit

enum CameraResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"

    var id: String { rawValue }
    var preset: AVCaptureSession.Preset {
        switch self {
        case .hd720: return .hd1280x720
        case .hd1080: return .hd1920x1080
        }
    }
}

/// Rear wide camera. Preview uses AVCaptureVideoPreviewLayer; the image conversion
/// and Gemini frame callback are performed at most once per second on the camera queue.
final class IPhoneCameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "iphone.camera.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private var isConfigured = false
    private var activeResolution: CameraResolution = .hd720
    private var previousSubmittedUptime: TimeInterval = -1
    private var resolutionSetUptime: TimeInterval = 0
    private var previousWidth: Int = 0
    private var previousHeight: Int = 0

    var onFrame: ((UIImage, Date, CameraResolution) -> Void)?
    var onDimensions: ((Int, Int) -> Void)?
    var onResolutionResult: ((CameraResolution, String?) -> Void)?
    var onCameraFailure: ((String) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(resolution: CameraResolution) {
        cameraQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured && !self.configure(resolution: resolution) { return }
            if self.activeResolution != resolution { self.applyResolution(resolution) }
            self.previousSubmittedUptime = -1
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func changeResolution(_ resolution: CameraResolution) {
        cameraQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            self.applyResolution(resolution)
        }
    }

    func stop() {
        cameraQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure(resolution: CameraResolution) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            onCameraFailure?("Cannot open rear wide-angle camera")
            return false
        }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        guard session.canAddOutput(videoOutput) else {
            onCameraFailure?("Cannot add camera video output")
            return false
        }
        session.addOutput(videoOutput)
        if session.canSetSessionPreset(resolution.preset) {
            session.sessionPreset = resolution.preset
            activeResolution = resolution
            resolutionSetUptime = ProcessInfo.processInfo.systemUptime
            onResolutionResult?(resolution, nil)
        } else {
            onCameraFailure?("Requested camera resolution \(resolution.rawValue) is unsupported")
            return false
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // Portrait-oriented sample buffer
        }
        isConfigured = true
        return true
    }

    private func applyResolution(_ resolution: CameraResolution) {
        guard session.canSetSessionPreset(resolution.preset) else {
            onResolutionResult?(activeResolution, "\(resolution.rawValue) unsupported on this camera; still using \(activeResolution.rawValue)")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = resolution.preset
        session.commitConfiguration()
        activeResolution = resolution
        resolutionSetUptime = ProcessInfo.processInfo.systemUptime
        // Preserve global 1-FPS limit across resolution changes.
        previousWidth = 0
        previousHeight = 0
        onResolutionResult?(resolution, nil)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if width != previousWidth || height != previousHeight {
            previousWidth = width
            previousHeight = height
            onDimensions?(width, height)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        // After a live resolution change, old-format sample buffers can remain
        // queued. Only export frames matching the requested real pixel dimensions.
        let expectedLong = activeResolution == .hd720 ? 1280 : 1920
        let expectedShort = activeResolution == .hd720 ? 720 : 1080
        guard max(width, height) == expectedLong, min(width, height) == expectedShort,
              uptime - resolutionSetUptime >= 0.3 else { return }
        guard previousSubmittedUptime < 0 ||
              uptime - previousSubmittedUptime >= GeminiConfig.videoFrameInterval else { return }
        previousSubmittedUptime = uptime

        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        onFrame?(image, Date(), activeResolution)
    }
}
