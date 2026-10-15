@preconcurrency import Accelerate
import CoreVideo
import Foundation

// MARK: - Unit limits

public enum VideoUnits {
    /// The largest payload one video unit may carry: MAX_VIDEO_FRAGMENTS_PER_UNIT fragments of what one
    /// fragment holds. Worked out the way mumble-core's VideoFragmenter does it, by measuring a message with
    /// every field at its widest, so it moves with the protocol instead of being a copied number.
    public static let maxUnitSize: Int = {
        let maxDatagram = 1200, header = 8, typeByte = 1 // VideoTransport.h
        let senderSessionStamp = 6, payloadField = 1 + 2 // VideoFragmentation.h
        var probe = MumbleUDP_Video()
        probe.senderSession = .max
        probe.streamID = .max
        probe.frameNumber = .max
        probe.unitID = .max
        probe.fragmentIndex = .max
        probe.fragmentCount = .max
        probe.isKeyframe = true
        probe.isFrameEnd = true
        probe.captureTimestampUsec = .max
        probe.x = .max
        probe.y = .max
        probe.width = .max
        probe.height = .max
        let metadata = (try? probe.serializedBytes() as Data)?.count ?? 100
        return 256 * (maxDatagram - header - typeByte - metadata - payloadField - senderSessionStamp)
    }()

    /// H.264 access units are cut into at most this many units (the desktop's H264Encoder::MAX_UNITS_PER_FRAME).
    public static let maxH264UnitsPerFrame = 32

    /// Cuts an H.264 access unit into units the way the desktop does: unit i of n carries x = i and y = n,
    /// the last one is the frame end. Empty if it would need more than maxH264UnitsPerFrame units.
    public static func splitH264(_ accessUnit: Data, streamID: UInt32, frameNumber: UInt64, timestampUsec: UInt64, isKeyframe: Bool,
                                 width: Int, height: Int, maxUnitSize: Int = VideoUnits.maxUnitSize) -> [VideoUnit] {
        guard !accessUnit.isEmpty, maxUnitSize > 0 else { return [] }
        let count = (accessUnit.count + maxUnitSize - 1) / maxUnitSize
        guard count <= maxH264UnitsPerFrame else { return [] }
        return (0 ..< count).map { i in
            let begin = accessUnit.startIndex + i * maxUnitSize
            let end = min(accessUnit.endIndex, begin + maxUnitSize)
            return VideoUnit(senderSession: 0, streamID: streamID, frameNumber: frameNumber, unitID: UInt32(i), isKeyframe: isKeyframe,
                             isFrameEnd: i + 1 == count, captureTimestampUsec: timestampUsec, x: UInt32(i), y: UInt32(count),
                             width: UInt32(width), height: UInt32(height), payload: Data(accessUnit[begin ..< end]))
        }
    }
}

// MARK: - Retransmission

/// What we sent in the last second, so a viewer that lost some fragments can ask for them again
/// (MumbleUDP.VideoNack). Mirrors the desktop's ServerHandler::resendVideoUnits: 1 s or 8 MB of history,
/// at most 32 units per request, and at most 1 MB/s of resends whatever viewers ask for.
///
/// Units are kept, not datagrams: a resend encrypts the unit again under fresh sequence numbers (a
/// datagram sent twice would be dropped as a replay) and sends only the fragments asked for.
final class VideoResendHistory {
    struct Key: Hashable { var stream: UInt32; var frame: UInt64; var unit: UInt32 }

    static let historyUsec: UInt64 = 1_000_000
    static let historyBytes = 8 * 1024 * 1024
    static let maxUnitsPerNack = 32
    static let maxResendBytesPerSecond = 1024 * 1024

    private var units: [Key: (unit: VideoUnit, at: UInt64)] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var windowStart: UInt64 = 0
    private var windowBytes = 0
    private(set) var fragmentsResent = 0

    func record(_ unit: VideoUnit, nowUsec: UInt64) {
        let key = Key(stream: unit.streamID, frame: unit.frameNumber, unit: unit.unitID)
        if let old = units[key] { bytes -= old.unit.payload.count }
        units[key] = (unit, nowUsec)
        order.append(key)
        bytes += unit.payload.count
        while let oldest = order.first {
            if let held = units[oldest], nowUsec &- held.at < Self.historyUsec, bytes <= Self.historyBytes { break }
            if let held = units[oldest], held.at <= nowUsec { bytes -= held.unit.payload.count; units[oldest] = nil }
            order.removeFirst()
        }
    }

    func forget(stream: UInt32) {
        for key in units.keys where key.stream == stream {
            bytes -= units[key]!.unit.payload.count
            units[key] = nil
        }
        order.removeAll { $0.stream == stream }
    }

    /// The datagrams that answer one VideoNack. `encrypt` turns a unit into its fragments' datagrams, in
    /// fragment order (MediaSession.makeVideo).
    func answer(_ nack: MumbleUDP_VideoNack, nowUsec: UInt64, encrypt: (VideoUnit) -> [Data]) -> [Data] {
        if nowUsec &- windowStart >= 1_000_000 {
            windowStart = nowUsec
            windowBytes = 0
        }
        var out: [Data] = []
        for u in nack.units.prefix(Self.maxUnitsPerNack) {
            guard let held = units[Key(stream: nack.streamID, frame: u.frameNumber, unit: u.unitID)] else { continue }
            let datagrams = encrypt(held.unit)
            let wanted: [Int]
            if !u.missingIndices.isEmpty {
                wanted = u.missingIndices.map(Int.init).filter { $0 < datagrams.count } // checked, not trusted
            } else if u.missingFragments == 0 {
                wanted = Array(datagrams.indices) // nothing of it arrived
            } else {
                wanted = datagrams.indices.filter { $0 < 64 && u.missingFragments & (1 << UInt64($0)) != 0 }
            }
            for i in wanted {
                guard windowBytes + datagrams[i].count <= Self.maxResendBytesPerSecond else { return out }
                windowBytes += datagrams[i].count
                fragmentsResent += 1
                out.append(datagrams[i])
            }
        }
        return out
    }
}

// MARK: - Sending a stream

public enum OutgoingVideoCodec: Sendable { case vp8, h264 }

/// One of our outgoing streams (the camera, or the shared screen): announces it, numbers its frames, cuts
/// them into units and hands them to the client, and moves to a new stream id whenever the picture's size
/// changes (receivers size their decoders from VideoState, so a size change needs a new stream).
///
/// Two ways in: raw pictures (`send(_: I420Frame)` / `send(pixelBuffer:)`), which are VP8-encoded here, or
/// frames already encoded as H.264 by the broadcast extension (`sendEncoded`). All calls may come from any
/// thread; work runs on the sender's own queue.
public final class VideoSender: @unchecked Sendable {
    public let codec: OutgoingVideoCodec
    public let source: MumbleProto_VideoState.SourceKind
    public let name: String
    public let fps: Int

    private let client: MumbleClient
    private let ids: VideoStreamIDs
    private let queue = DispatchQueue(label: "mumble.video.send")
    private var streamID: UInt32?
    private var size: (width: Int, height: Int)?
    private var frameNumber: UInt64 = 0
    private var bitrate: Int
    private var encoder: VP8Encoder?
    private var keyframeWanted = true
    /// Pre-encoded input: deltas are useless until a keyframe (stream start, or after a dropped frame).
    private var awaitingKeyframe = true
    private var stopped = false
    private var lastFrameUsec: UInt64?

    /// For pre-encoded input: asked for a keyframe (a viewer joined or lost data). Called on the sender's queue.
    public var onKeyframeNeeded: (() -> Void)?
    /// Frames sent and dropped (too large for a unit), for the UI and tests.
    public private(set) var framesSent = 0
    public private(set) var framesDropped = 0

    /// `bitrate` in bits per second; it is clamped to the server's per-stream limit when there is one. Not
    /// to be created on the client's own queue.
    public init(client: MumbleClient, codec: OutgoingVideoCodec, source: MumbleProto_VideoState.SourceKind, name: String,
                fps: Int = 30, bitrate: Int) {
        let maxVideoBandwidth = client.currentCapabilities.maxVideoBandwidth
        self.client = client
        self.ids = client.videoStreamIDs
        self.codec = codec
        self.source = source
        self.name = name
        self.fps = fps
        self.bitrate = maxVideoBandwidth > 0 ? min(bitrate, Int(maxVideoBandwidth)) : bitrate
    }

    /// The bitrate in use after clamping, bits per second.
    public var targetBitrate: Int { bitrate }

    /// The id of the stream being sent, once the first frame set it up.
    public var currentStreamID: UInt32? { queue.sync { streamID } }

    /// A viewer asked for a keyframe of `streamID`; ignored unless it is ours.
    public func keyframeRequested(streamID id: UInt32) {
        queue.async { [self] in
            guard id == streamID else { return }
            keyframeWanted = true
            if codec == .h264 { onKeyframeNeeded?() } // deltas keep flowing to the other viewers meanwhile
        }
    }

    /// One camera picture (NV12 or BGRA): converted to I420 and VP8-encoded.
    public func send(pixelBuffer: CVPixelBuffer, timestampUsec: UInt64) {
        guard let frame = I420Frame(pixelBuffer: pixelBuffer) else { return }
        send(frame, timestampUsec: timestampUsec)
    }

    public func send(_ frame: I420Frame, timestampUsec: UInt64) {
        queue.async { [self] in
            guard !stopped, codec == .vp8, throttle(timestampUsec) else { return }
            prepareStream(width: frame.width, height: frame.height)
            if encoder == nil { encoder = VP8Encoder(width: frame.width, height: frame.height, fps: fps, bitrateKbps: bitrate / 1000) }
            guard let encoder, let streamID else { return }
            let force = keyframeWanted
            keyframeWanted = false
            for (data, key) in encoder.encode(frame, pts: Int64(timestampUsec / 1000), forceKeyframe: force) {
                guard data.count <= VideoUnits.maxUnitSize else {
                    // Too large for one unit: drop it without using up a frame number, so viewers see no gap,
                    // and make the next frame a keyframe (what came after this one referenced it).
                    framesDropped += 1
                    keyframeWanted = true
                    continue
                }
                client.sendVideo(VideoUnit(senderSession: 0, streamID: streamID, frameNumber: frameNumber, unitID: 0, isKeyframe: key,
                                           isFrameEnd: true, captureTimestampUsec: timestampUsec, x: 0, y: 0,
                                           width: UInt32(frame.width), height: UInt32(frame.height), payload: data))
                frameNumber += 1
                framesSent += 1
            }
        }
    }

    /// One H.264 access unit (Annex B) encoded elsewhere. Delta frames before the stream's first keyframe,
    /// or after a frame had to be dropped, are skipped: nobody could decode them.
    public func sendEncoded(_ accessUnit: Data, isKeyframe: Bool, width: Int, height: Int, timestampUsec: UInt64) {
        queue.async { [self] in
            guard !stopped, codec == .h264 else { return }
            prepareStream(width: width, height: height)
            guard let streamID else { return }
            if awaitingKeyframe && !isKeyframe { return }
            let units = VideoUnits.splitH264(accessUnit, streamID: streamID, frameNumber: frameNumber, timestampUsec: timestampUsec,
                                             isKeyframe: isKeyframe, width: width, height: height)
            guard !units.isEmpty else {
                framesDropped += 1
                awaitingKeyframe = true
                onKeyframeNeeded?()
                return
            }
            awaitingKeyframe = false
            units.forEach(client.sendVideo)
            frameNumber += 1
            framesSent += 1
        }
    }

    /// Ends the stream (VideoState inactive).
    public func stop() {
        queue.sync {
            stopped = true
            if let streamID { client.endVideo(streamID: streamID) }
            streamID = nil
            encoder = nil
        }
    }

    /// Starts a stream on the first frame, and a new one when the size changes.
    private func prepareStream(width: Int, height: Int) {
        if let size, size == (width, height), streamID != nil { return }
        if let old = streamID { client.endVideo(streamID: old) }
        let id = ids.next()
        streamID = id
        size = (width, height)
        frameNumber = 0
        encoder = nil
        keyframeWanted = true
        awaitingKeyframe = true
        let codec: MumbleProto_VideoState.Codec = codec == .vp8 ? .vp8 : .h264
        client.announceVideo(streamID: id, codec: codec, source: source, name: name, width: UInt32(width), height: UInt32(height),
                             fps: UInt32(fps), bitrate: UInt32(bitrate))
        if self.codec == .h264 { onKeyframeNeeded?() }
    }

    /// Holds the frame rate to `fps` whatever the source delivers.
    private func throttle(_ t: UInt64) -> Bool {
        let interval = UInt64(1_000_000 / max(fps, 1))
        if let last = lastFrameUsec, t > last, t - last < interval * 9 / 10 { return false }
        lastFrameUsec = t
        return true
    }
}

/// Hands out stream ids for one connection's outgoing streams. Ids are never reused on a connection, so a
/// late unit of an old stream cannot be mistaken for the new one.
public final class VideoStreamIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt32 = 0
    public func next() -> UInt32 { lock.withLock { last += 1; return last } }
}

// MARK: - Pixel conversion

extension I420Frame {
    /// A camera or screen picture to tightly packed I420. NV12 (the camera's native format, video or full
    /// range) is split by plane; BGRA goes through vImage. Odd sizes are trimmed to even, as VP8 needs.
    public init?(pixelBuffer pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb) & ~1, h = CVPixelBufferGetHeight(pb) & ~1
        guard w > 0, h > 0 else { return nil }
        let cw = w / 2, ch = h / 2
        var y = Data(count: w * h), u = Data(count: cw * ch), v = Data(count: cw * ch)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let full = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            y.withUnsafeMutableBytes { out in
                let o = out.bindMemory(to: UInt8.self).baseAddress!
                for row in 0 ..< h {
                    let src = yBase.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self)
                    if full {
                        // Receivers decode as BT.601 video range; squeeze 0-255 into 16-235.
                        for col in 0 ..< w { o[row * w + col] = UInt8(16 + (Int(src[col]) * 219 + 127) / 255) }
                    } else {
                        (o + row * w).update(from: src, count: w)
                    }
                }
            }
            u.withUnsafeMutableBytes { ub in v.withUnsafeMutableBytes { vb in
                let uo = ub.bindMemory(to: UInt8.self).baseAddress!, vo = vb.bindMemory(to: UInt8.self).baseAddress!
                for row in 0 ..< ch {
                    let src = cBase.advanced(by: row * cStride).assumingMemoryBound(to: UInt8.self)
                    for col in 0 ..< cw {
                        var cb = Int(src[col * 2]), cr = Int(src[col * 2 + 1])
                        if full { cb = 16 + (cb * 224 + 127) / 255; cr = 16 + (cr * 224 + 127) / 255 }
                        uo[row * cw + col] = UInt8(cb)
                        vo[row * cw + col] = UInt8(cr)
                    }
                }
            } }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            var info = vImage_ARGBToYpCbCr()
            var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                                YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            guard vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
                                                                kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            else { return nil }
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let ok = y.withUnsafeMutableBytes { yb in u.withUnsafeMutableBytes { ub in v.withUnsafeMutableBytes { vb in
                var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
                var yo = vImage_Buffer(data: yb.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var uo = vImage_Buffer(data: ub.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                var vo = vImage_Buffer(data: vb.baseAddress, height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: cw)
                // BGRA in memory is ARGB with the channel order permuted to [A, R, G, B] = [3, 2, 1, 0].
                return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&src, &yo, &uo, &vo, &info, [3, 2, 1, 0], vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } } }
            guard ok else { return nil }
        default:
            return nil
        }
        self.init(width: w, height: h, y: y, u: u, v: v)
    }
}
