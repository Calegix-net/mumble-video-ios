@preconcurrency import Accelerate
import CMumbleBridge
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public struct StreamKey: Hashable, Sendable, CustomStringConvertible {
    public var session: UInt32
    public var streamID: UInt32
    public init(session: UInt32, streamID: UInt32) {
        self.session = session
        self.streamID = streamID
    }
    public var description: String { "\(session)/\(streamID)" }
}

public enum VideoCodec: Sendable, Equatable {
    case vp8, vp9, h264, opusAudio, unsupported(Int)

    init(_ c: MumbleProto_VideoState.Codec) {
        switch c {
        case .vp8: self = .vp8
        case .vp9: self = .vp9
        case .h264: self = .h264
        case .opusAudio: self = .opusAudio
        default: self = .unsupported(c.rawValue)
        }
    }

    /// Whether this client can show it (TiledImage, AV1 and unknown codecs are dropped).
    public var isPicture: Bool { self == .vp8 || self == .vp9 || self == .h264 }
}

public enum VideoSourceKind: Sendable, Equatable { case camera, display, window, application, unknown }

/// A stream another user is sending, from their VideoState.
public struct RemoteVideoStream: Identifiable, Sendable, Equatable {
    public var key: StreamKey
    public var codec: VideoCodec
    public var source: VideoSourceKind
    public var sourceName: String
    public var width: UInt32
    public var height: UInt32
    public var maxFramerate: UInt32
    /// The server refused our subscription.
    public var denied = false
    public var id: StreamKey { key }
}

// MARK: - Frame assembly

/// Turns one stream's video units into whole compressed frames in order. VP8/VP9 send one unit per frame;
/// an H.264 frame may span several units, unit i of n carrying x = i and y = n, joined before decoding.
/// Frame numbers are sequential: a gap means a lost frame, after which nothing decodes until a keyframe,
/// and the receiver asks the sender for one.
final class FrameAssembler {
    struct Frame { var data: Data; var isKeyframe: Bool; var frameNumber: UInt64 }

    let codec: VideoCodec
    private var lastFrame: UInt64?
    private(set) var waitingForKeyframe = true
    private var partialNumber: UInt64?
    private var partial: [UInt32: Data] = [:]
    private var partialCount: UInt32 = 0
    private var partialKey = false

    init(codec: VideoCodec) { self.codec = codec }

    /// Feeds one unit. Returns a frame when one completed, and whether a keyframe should be requested.
    func add(_ u: VideoUnit) -> (frame: Frame?, needKeyframe: Bool) {
        if let last = lastFrame, u.frameNumber <= last { return (nil, false) } // stale or duplicate
        if codec == .h264 && u.y > 1 {
            if partialNumber != u.frameNumber {
                let lostPartial = partialNumber != nil
                partialNumber = u.frameNumber
                partial = [:]
                partialCount = u.y
                partialKey = false
                if lostPartial { waitingForKeyframe = true }
            }
            partial[u.x] = u.payload
            partialKey = partialKey || u.isKeyframe
            guard partial.count == Int(partialCount) else { return (nil, false) }
            let joined = (0 ..< partialCount).reduce(into: Data()) { $0 += partial[$1] ?? Data() }
            partialNumber = nil
            return accept(Frame(data: joined, isKeyframe: partialKey, frameNumber: u.frameNumber))
        }
        return accept(Frame(data: u.payload, isKeyframe: u.isKeyframe, frameNumber: u.frameNumber))
    }

    private func accept(_ f: Frame) -> (frame: Frame?, needKeyframe: Bool) {
        let gap = lastFrame.map { f.frameNumber != $0 + 1 } ?? false
        if gap { waitingForKeyframe = true }
        lastFrame = f.frameNumber
        if waitingForKeyframe {
            guard f.isKeyframe else { return (nil, true) }
            waitingForKeyframe = false
        }
        return (f, false)
    }

    /// The decoder failed: wait for a keyframe.
    func decodeFailed() { waitingForKeyframe = true }
}

// MARK: - Decoders

/// Used only on VideoReceiver's queue.
protocol FrameDecoder: AnyObject, Sendable {
    func decode(_ frame: FrameAssembler.Frame) -> CGImage?
}

final class VPXFrameDecoder: FrameDecoder, @unchecked Sendable {
    private let vpx: VPXDecoder
    init?(codec: Int) {
        guard let d = VPXDecoder(codec: codec) else { return nil }
        vpx = d
    }
    func decode(_ frame: FrameAssembler.Frame) -> CGImage? { vpx.decode(frame.data)?.cgImage() }
}

/// H.264 Annex B through VideoToolbox.
final class H264FrameDecoder: FrameDecoder, @unchecked Sendable {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps = Data(), pps = Data()

    func decode(_ frame: FrameAssembler.Frame) -> CGImage? {
        var slices: [Data] = []
        for nal in Self.nalUnits(frame.data) {
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7: if nal != sps { sps = nal; format = nil }
            case 8: if nal != pps { pps = nal; format = nil }
            default: slices.append(nal)
            }
        }
        guard !slices.isEmpty, !sps.isEmpty, !pps.isEmpty else { return nil }
        if format == nil {
            if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
            format = makeFormat()
        }
        guard let format else { return nil }
        if session == nil {
            let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
            var s: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                         imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
            session = s
        }
        guard let session else { return nil }
        var avcc = Data()
        for s in slices {
            var len = UInt32(s.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(s)
        }
        guard let sample = makeSample(avcc, format: format) else { return nil }
        nonisolated(unsafe) var image: CGImage? // the output handler runs synchronously (no async flag)
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        }
        return image
    }

    private func makeFormat() -> CMVideoFormatDescription? {
        var out: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return out
    }

    private func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let count = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var size = count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    /// Splits Annex B on 3- and 4-byte start codes.
    static func nalUnits(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [(Int, Int)] = [] // (start code index, payload index)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().map { n, s in
            let end = n + 1 < starts.count ? starts[n + 1].0 : b.count
            return Data(b[s.1 ..< end])
        }
    }
}

extension I420Frame {
    /// BT.601 video-range YUV to an sRGB CGImage, via vImage.
    public func cgImage() -> CGImage? {
        var info = vImage_YpCbCrToARGB()
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                                 YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        guard vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &pixelRange, &info,
                                                            kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        let cw = (width + 1) / 2
        var argb = Data(count: width * height * 4)
        let ok: Bool = y.withUnsafeBytes { yp in u.withUnsafeBytes { up in v.withUnsafeBytes { vp in argb.withUnsafeMutableBytes { out in
            var yb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: yp.baseAddress), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var ub = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: up.baseAddress), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount(cw), rowBytes: cw)
            var vb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: vp.baseAddress), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount(cw), rowBytes: cw)
            var ob = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yb, &ub, &vb, &ob, &info, [0, 1, 2, 3], 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        } } } }
        guard ok, let provider = CGDataProvider(data: argb as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Receiver

/// Decodes the streams the user is watching. Units arrive on the network queue and are decoded on the
/// receiver's own queue; each new picture goes to `onFrame`.
public final class VideoReceiver: @unchecked Sendable {
    public var onFrame: ((StreamKey, CGImage) -> Void)?
    /// Called (rate-limited by the client) when a stream needs a keyframe to recover.
    public var onKeyframeNeeded: ((StreamKey) -> Void)?

    private let queue = DispatchQueue(label: "mumble.video")
    private var streams: [StreamKey: (assembler: FrameAssembler, decoder: FrameDecoder)] = [:]
    private let lock = NSLock()

    public init() {}

    /// Start decoding a stream (call alongside MumbleClient.subscribe).
    public func watch(_ stream: RemoteVideoStream) {
        let decoder: FrameDecoder?
        switch stream.codec {
        case .vp8: decoder = VPXFrameDecoder(codec: 8)
        case .vp9: decoder = VPXFrameDecoder(codec: 9)
        case .h264: decoder = H264FrameDecoder()
        default: decoder = nil
        }
        guard let decoder else { return }
        queue.async { [self] in streams[stream.key] = (FrameAssembler(codec: stream.codec), decoder) }
    }

    public func stop(_ key: StreamKey) {
        queue.async { [self] in streams[key] = nil }
    }

    public func stopAll(from session: UInt32) {
        queue.async { [self] in streams = streams.filter { $0.key.session != session } }
    }

    public func receive(_ unit: VideoUnit) {
        queue.async { [self] in
            let key = StreamKey(session: unit.senderSession, streamID: unit.streamID)
            guard let s = streams[key] else { return }
            let (frame, needKey) = s.assembler.add(unit)
            if needKey { onKeyframeNeeded?(key) }
            guard let frame else { return }
            if let image = s.decoder.decode(frame) {
                onFrame?(key, image)
            } else if frame.isKeyframe {
                s.assembler.decodeFailed()
                onKeyframeNeeded?(key)
            }
        }
    }
}

/// Routes the client's media: voice to the mixer, video units to the receiver.
public final class MediaHub: MediaSink, @unchecked Sendable {
    public let mixer: VoiceMixer
    public let video: VideoReceiver

    public init(mixer: VoiceMixer, video: VideoReceiver) {
        self.mixer = mixer
        self.video = video
    }

    public func audio(_ packet: AudioPacket) { mixer.push(packet) }
    public func video(_ unit: VideoUnit) { video.receive(unit) }
    public func senderRemoved(_ session: UserSession) {
        mixer.remove(session.raw)
        video.stopAll(from: session.raw)
    }
}

// MARK: - VP8 encoding (sending; also drives the end-to-end tests)

public final class VP8Encoder {
    private let handle: OpaquePointer
    public let width: Int, height: Int

    public init?(width: Int, height: Int, fps: Int = 30, bitrateKbps: Int = 800) {
        guard let h = mv_vpx_encoder_create(UInt32(width), UInt32(height), UInt32(fps), UInt32(bitrateKbps)) else { return nil }
        handle = h
        self.width = width
        self.height = height
    }

    deinit { mv_vpx_encoder_destroy(handle) }

    /// Encodes one I420 frame; returns the compressed frames (normally exactly one).
    public func encode(_ f: I420Frame, pts: Int64, forceKeyframe: Bool = false) -> [(data: Data, keyframe: Bool)] {
        final class Out { var frames: [(Data, Bool)] = [] }
        let out = Out()
        f.y.withUnsafeBytes { y in f.u.withUnsafeBytes { u in f.v.withUnsafeBytes { v in
            _ = mv_vpx_encode(handle, y.bindMemory(to: UInt8.self).baseAddress, u.bindMemory(to: UInt8.self).baseAddress,
                              v.bindMemory(to: UInt8.self).baseAddress, pts, forceKeyframe, Unmanaged.passUnretained(out).toOpaque()) { ctx, data, len, key in
                guard let ctx, let data else { return }
                Unmanaged<Out>.fromOpaque(ctx).takeUnretainedValue().frames.append((Data(bytes: data, count: len), key))
            }
        } } }
        return out.frames
    }
}
