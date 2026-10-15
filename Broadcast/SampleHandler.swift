import CoreMedia
import MumbleShare
import ReplayKit
import VideoToolbox

/// The screen-sharing broadcast extension: scales the screen to at most 1280 on its long side, encodes it
/// as H.264 in hardware and streams the frames to the app, which sends them to the server. Extensions get
/// about 50 MB, so nothing is buffered beyond the last picture (kept to answer keyframe requests while the
/// screen is still, when ReplayKit delivers no new frames).
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mumble.broadcast.encode")
    private var connection: BroadcastConnection?
    private var encoder: H264Encoder?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var bitrate = 2_500_000
    private var lastPicture: CVPixelBuffer?
    private var lastSentUsec: UInt64 = 0
    private var finished = false

    private static let maxLongSide = 1280
    private static let frameInterval: UInt64 = 33_333

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let path = BroadcastChannel.socketPath(), let conn = BroadcastConnection.connect(path: path) else {
            fail("Open Mumble Video and connect to a server first.")
            return
        }
        connection = conn
        conn.onMessage = { [weak self] m in self?.handle(m) }
        conn.onClose = { [weak self] in self?.fail("Mumble Video disconnected from the server.") }
        conn.start()
    }

    override func processSampleBuffer(_ sample: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let t = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds) * 1_000_000)
        nonisolated(unsafe) let pb = buffer // read-only from here on; ReplayKit keeps it alive while retained
        queue.async { [self] in
            guard t >= lastSentUsec + Self.frameInterval * 9 / 10 else { return }
            guard let picture = scaled(pb) else { return }
            lastPicture = picture
            encode(picture, at: t)
        }
    }

    override func broadcastFinished() {
        queue.sync {
            finished = true
            connection?.send(.ended)
            connection?.close()
            connection = nil
        }
    }

    private func handle(_ m: BroadcastMessage) {
        queue.async { [self] in
            switch m {
            case let .configure(b):
                bitrate = Int(b)
                encoder?.setBitrate(bitrate)
            case .keyframe:
                encoder?.requestKeyframe()
                // A still screen produces no frames; send the last picture again so the viewer is not left waiting.
                let now = UInt64(CACurrentMediaTime() * 1_000_000)
                if let lastPicture, now > lastSentUsec + 200_000 { encode(lastPicture, at: now) }
            case .stop:
                fail("Stopped from Mumble Video.")
            default:
                break
            }
        }
    }

    private func encode(_ picture: CVPixelBuffer, at t: UInt64) {
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        if encoder.map({ $0.width != w || $0.height != h }) ?? true {
            encoder = H264Encoder(width: w, height: h, fps: 30, bitrate: bitrate)
        }
        guard let encoder, let connection else { return }
        for frame in encoder.encode(picture, timestampUsec: t) { connection.send(.frame(frame)) }
        lastSentUsec = t
    }

    /// The screen at most maxLongSide on its long side, even dimensions, NV12.
    private func scaled(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let scale = min(1, Double(Self.maxLongSide) / Double(max(w, h)))
        let tw = Int(Double(w) * scale) & ~1, th = Int(Double(h) * scale) & ~1
        if scale == 1, tw == w, th == h { return pb }
        if poolSize != (tw, th) {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        kCVPixelBufferWidthKey as String: tw, kCVPixelBufferHeightKey as String: th,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = (tw, th)
        }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let pool, let transfer else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: pb, to: out) == noErr else { return nil }
        return out
    }

    private func fail(_ message: String) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            connection?.close()
            connection = nil
            finishBroadcastWithError(NSError(domain: "com.calegix.mumblevideo.broadcast", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}
