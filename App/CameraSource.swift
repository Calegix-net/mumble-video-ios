@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import MumbleKit

/// Pictures to send as our camera stream. The real camera, or (where there is none, as in the Simulator)
/// a moving test pattern so the whole sending path can still be tried.
protocol CameraSource: AnyObject {
    /// Called on a background queue for every picture.
    var onFrame: (@Sendable (I420Frame, UInt64) -> Void)? { get set }
    var facing: AVCaptureDevice.Position { get }
    func start()
    func stop()
    func switchCamera()
}

func makeCameraSource() -> CameraSource {
    if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil {
        return DeviceCamera()
    }
    return TestPatternCamera()
}

/// AVCaptureSession at 640x480 (VGA keeps VP8 software encoding cheap), NV12 out. The picture is turned
/// upright with the rotation coordinator, so its size flips with the phone, and VideoSender moves to a
/// new stream when it does.
final class DeviceCamera: NSObject, CameraSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (I420Frame, UInt64) -> Void)?
    private(set) var facing: AVCaptureDevice.Position = .front
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "mumble.camera")
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() {
        queue.async { [self] in
            configure(facing)
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func switchCamera() {
        queue.async { [self] in configure(facing == .front ? .back : .front) }
    }

    private func configure(_ position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        session.inputs.forEach(session.removeInput)
        if session.canAddInput(input) { session.addInput(input) }
        if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
        facing = device.position
        if let connection = output.connection(with: .video) {
            connection.isVideoMirrored = false // viewers see the scene as it is
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        session.commitConfiguration()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelCapture
            self?.queue.async {
                guard let connection = self?.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sample), let frame = I420Frame(pixelBuffer: pb) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sample)
        onFrame?(frame, UInt64(max(0, t.seconds) * 1_000_000))
    }
}

/// A 640x360 picture with a sweeping bar and a clock-like block, at 30 frames a second.
final class TestPatternCamera: CameraSource, @unchecked Sendable {
    var onFrame: (@Sendable (I420Frame, UInt64) -> Void)?
    private(set) var facing: AVCaptureDevice.Position = .unspecified
    private var timer: DispatchSourceTimer?
    private var n = 0
    private var hue = 0

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mumble.testpattern"))
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// No second camera: change the colours instead, so the switch is still visible.
    func switchCamera() { hue = (hue + 1) % 3 }

    private func tick() {
        let w = 640, h = 360
        var y = Data(repeating: 90, count: w * h)
        let bar = (n * 6) % w
        y.withUnsafeMutableBytes { p in
            let o = p.bindMemory(to: UInt8.self)
            for row in 0 ..< h {
                for col in max(0, bar - 24) ..< min(w, bar + 24) { o[row * w + col] = 220 }
            }
            // A block that steps once a second, so a frozen picture is obvious.
            let s = (n / 30) % 8
            for row in 40 ..< 100 { for col in 40 + s * 70 ..< 100 + s * 70 { o[row * w + col] = 30 } }
        }
        let c = (w / 2) * (h / 2)
        let (u, v): (UInt8, UInt8) = [(110, 160), (160, 90), (90, 120)][hue]
        onFrame?(I420Frame(width: w, height: h, y: y, u: Data(repeating: u, count: c), v: Data(repeating: v, count: c)), UInt64(n) * 33_333)
        n += 1
    }
}
