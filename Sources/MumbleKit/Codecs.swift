import CMumbleBridge
import Foundation

public enum Opus {
    public static let sampleRate = 48_000
    /// 10 ms at 48 kHz.
    public static let frameSamples = 480

    public static var version: String { String(cString: mv_opus_version()) }

    public static func packetSamples(_ packet: Data) -> Int {
        Int(packet.withUnsafeBytes { mv_opus_packet_samples($0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    /// 48 kHz mono decoder.
    public final class Decoder {
        private let handle: OpaquePointer

        public init?() {
            guard let h = mv_opus_decoder_create() else { return nil }
            handle = h
        }

        deinit { mv_opus_decoder_destroy(handle) }

        /// Decodes one packet; nil packet conceals `concealSamples` of loss. Returns the PCM, empty on error.
        public func decode(_ packet: Data?, concealSamples: Int = Opus.frameSamples) -> [Int16] {
            var pcm = [Int16](repeating: 0, count: 5760)
            let n: Int32
            if let packet {
                n = packet.withUnsafeBytes { mv_opus_decode(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &pcm, Int32(pcm.count)) }
            } else {
                n = mv_opus_decode(handle, nil, 0, &pcm, Int32(concealSamples))
            }
            return n > 0 ? Array(pcm[0 ..< Int(n)]) : []
        }
    }

    /// 48 kHz mono VOIP encoder.
    public final class Encoder {
        private let handle: OpaquePointer

        public init?(bitrate: Int) {
            guard let h = mv_opus_encoder_create(Int32(bitrate)) else { return nil }
            handle = h
        }

        deinit { mv_opus_encoder_destroy(handle) }

        public func encode(_ pcm: [Int16]) -> Data? {
            var out = [UInt8](repeating: 0, count: 1500)
            let n = mv_opus_encode(handle, pcm, Int32(pcm.count), &out, out.count)
            return n > 0 ? Data(out[0 ..< Int(n)]) : nil
        }
    }
}

/// One decoded picture in I420 (planar YUV 4:2:0), copied out of the decoder.
public struct I420Frame: Sendable {
    public var width: Int
    public var height: Int
    public var y: Data
    public var u: Data
    public var v: Data
}

/// libvpx VP8/VP9 decoder (VideoToolbox has no VP8, which is what desktop and Android send by default).
public final class VPXDecoder {
    private let handle: OpaquePointer

    /// codec: 8 or 9.
    public init?(codec: Int) {
        guard let h = mv_vpx_decoder_create(Int32(codec)) else { return nil }
        handle = h
    }

    deinit { mv_vpx_decoder_destroy(handle) }

    /// Decodes one compressed frame. nil when no picture came out (or on error).
    public func decode(_ data: Data) -> I420Frame? {
        var f = mv_i420_frame()
        let r = data.withUnsafeBytes { mv_vpx_decode(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &f) }
        guard r == 1, let yp = f.y, let up = f.u, let vp = f.v else { return nil }
        let w = Int(f.width), h = Int(f.height), cw = (w + 1) / 2, ch = (h + 1) / 2
        func plane(_ p: UnsafePointer<UInt8>, _ stride: Int32, _ pw: Int, _ ph: Int) -> Data {
            var d = Data(count: pw * ph)
            d.withUnsafeMutableBytes { dst in
                for row in 0 ..< ph {
                    memcpy(dst.baseAddress! + row * pw, p + row * Int(stride), pw)
                }
            }
            return d
        }
        return I420Frame(width: w, height: h, y: plane(yp, f.y_stride, w, h), u: plane(up, f.u_stride, cw, ch), v: plane(vp, f.v_stride, cw, ch))
    }
}
