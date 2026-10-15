import CoreMedia
import Foundation
import VideoToolbox

/// One compressed H.264 access unit in Annex B form (start codes, parameter sets in front of keyframes),
/// the form Mumble Video carries on the wire.
public struct H264Frame: Sendable {
    public var data: Data
    public var isKeyframe: Bool
    public var width: Int
    public var height: Int
    /// Presentation time in microseconds.
    public var timestampUsec: UInt64

    public init(data: Data, isKeyframe: Bool, width: Int, height: Int, timestampUsec: UInt64) {
        self.data = data
        self.isKeyframe = isKeyframe
        self.width = width
        self.height = height
        self.timestampUsec = timestampUsec
    }
}

/// Hardware H.264 through VideoToolbox, set up the way every Mumble Video receiver expects: Baseline, no
/// frame reordering (no B-frames), realtime rate control, a keyframe at least every few seconds.
///
/// Used by the screen-sharing broadcast extension, so it depends on nothing but Apple frameworks.
public final class H264Encoder: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var output: [H264Frame] = []
    private var forceKeyframe = true

    public init?(width: Int, height: Int, fps: Int = 30, bitrate: Int) {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        let spec: CFDictionary? = nil
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else { return nil }
        session = s
        let set = { (key: CFString, value: CFTypeRef) in VTSessionSetProperty(s, key: key, value: value) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as CFNumber)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as CFNumber)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    public func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // Hard ceiling over one second, so a burst cannot overrun the server's per-stream budget.
        let limit = [bitrate / 8 * 3 / 2, 1] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    /// The next frame will be a keyframe (a viewer asked, or one just subscribed).
    public func requestKeyframe() {
        lock.withLock { forceKeyframe = true }
    }

    /// Encodes one picture (any pixel format VideoToolbox accepts, the frame's own size is used as is).
    /// Returns the access units that came out, normally exactly one.
    public func encode(_ pixelBuffer: CVPixelBuffer, timestampUsec: UInt64) -> [H264Frame] {
        guard let session else { return [] }
        let key = lock.withLock { () -> Bool in defer { forceKeyframe = false }; return forceKeyframe }
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let pts = CMTime(value: CMTimeValue(timestampUsec), timescale: 1_000_000)
        let w = width, h = height
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self, let frame = Self.annexB(sample, width: w, height: h, timestampUsec: timestampUsec) else { return }
            lock.withLock { output.append(frame) }
        }
        // Realtime sessions emit within the call or shortly after; flushing keeps one frame in, one out.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        return lock.withLock { defer { output.removeAll() }; return output }
    }

    /// AVCC (length-prefixed) sample to Annex B, with SPS and PPS in front of keyframes.
    static func annexB(_ sample: CMSampleBuffer, width: Int, height: Int, timestampUsec: UInt64) -> H264Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync
        let startCode = Data([0, 0, 0, 1])
        var out = Data()
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0 ..< count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out += startCode
                    out.append(ptr, count: size)
                }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        var offset = 0
        while offset + 4 <= length {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer + offset, 4)
            let n = Int(UInt32(bigEndian: nalLength))
            offset += 4
            guard n > 0, offset + n <= length else { break }
            out += startCode
            out.append(UnsafeRawPointer(pointer + offset).assumingMemoryBound(to: UInt8.self), count: n)
            offset += n
        }
        return out.isEmpty ? nil : H264Frame(data: out, isKeyframe: isKey, width: width, height: height, timestampUsec: timestampUsec)
    }
}
